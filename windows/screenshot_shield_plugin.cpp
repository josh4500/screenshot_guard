#include "screenshot_shield_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include <dwmapi.h>
#include <tlhelp32.h>

#include <flutter/basic_message_channel.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/event_stream_handler.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_message_codec.h>
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>

#include <algorithm>
#include <cctype>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace screenshot_shield {

namespace {

constexpr char kStartListeningChannel[] =
    "dev.flutter.pigeon.screenshot_shield.ScreenshotShieldHostApi.startListening";
constexpr char kStopListeningChannel[] =
    "dev.flutter.pigeon.screenshot_shield.ScreenshotShieldHostApi.stopListening";
constexpr char kSetProtectedChannel[] =
    "dev.flutter.pigeon.screenshot_shield.ScreenshotShieldHostApi.setProtected";
constexpr char kSetBackgroundBlurChannel[] =
    "dev.flutter.pigeon.screenshot_shield.ScreenshotShieldHostApi.setBackgroundBlur";
constexpr char kOnScreenshotDetectedChannel[] =
    "dev.flutter.pigeon.screenshot_shield.ScreenshotShieldEventChannelApi.onScreenshotDetected";
constexpr char kOnScreenRecordingChangedChannel[] =
    "dev.flutter.pigeon.screenshot_shield.ScreenshotShieldEventChannelApi.onScreenRecordingChanged";

constexpr UINT_PTR kScreenRecordingTimerId = 0x5C7E;
constexpr UINT kScreenRecordingPollIntervalMs = 2000;

// Windows has no API that tells an app it is being recorded, so this is a
// best-effort heuristic that looks for well-known screen-recording programs in
// the process list. It can produce false positives (a recorder is running but
// not recording) and false negatives (an unlisted recorder is used).
constexpr const char* kScreenRecorderProcesses[] = {
    "obs",           "bdcam",       "bandicam",
    "camtasia",      "screenrec",   "flashback",
    "fraps",         "screencast",  "loom",
    "snagit",        "screenflow",  "movavi",
    "kazam",         "simplescreenrecorder", "recordmydesktop",
    "vokoscreen",    "kooha",       "gpu-screen-recorder",
    "wf-recorder",   "peek",        "gamebar",
};

std::string LowerAscii(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return value;
}

bool IsScreenRecorderProcessName(const std::string& name) {
  const std::string lower = LowerAscii(name);
  for (const char* token : kScreenRecorderProcesses) {
    const std::string candidate = token;
    if (candidate == "obs") {
      // Match OBS variants (obs, obs32, obs64, obs-studio, obs-browser)
      // without matching unrelated names such as "observer".
      if (lower == "obs" || lower.rfind("obs32", 0) == 0 ||
          lower.rfind("obs64", 0) == 0 || lower.rfind("obs-studio", 0) == 0 ||
          lower.rfind("obs-browser", 0) == 0) {
        return true;
      }
    } else if (lower.find(candidate) != std::string::npos) {
      return true;
    }
  }
  return false;
}

// A stream handler that accepts listeners but never emits events. Screenshot
// detection is not available on Windows (screenshots are taken by external
// tools and the OS does not notify the app).
class NoOpStreamHandler
    : public flutter::StreamHandler<flutter::EncodableValue> {
 public:
  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnListenInternal(
      const flutter::EncodableValue* arguments,
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
      override {
    return nullptr;
  }

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnCancelInternal(const flutter::EncodableValue* arguments) override {
    return nullptr;
  }
};

// Forwards screen-recording subscriptions to the plugin, which owns the
// sampling timer and the latest state.
class ScreenRecordingStreamHandler
    : public flutter::StreamHandler<flutter::EncodableValue> {
 public:
  explicit ScreenRecordingStreamHandler(ScreenshotShieldPlugin* plugin)
      : plugin_(plugin) {}

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnListenInternal(
      const flutter::EncodableValue* arguments,
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
      override {
    plugin_->AttachScreenRecordingSink(std::move(events));
    return nullptr;
  }

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnCancelInternal(const flutter::EncodableValue* arguments) override {
    plugin_->DetachScreenRecordingSink();
    return nullptr;
  }

 private:
  ScreenshotShieldPlugin* plugin_;
};

// Replies to a Pigeon host API call with an empty list, which Pigeon treats as
// a successful response.
void ReplySuccess(const flutter::BinaryReply& reply,
                  const flutter::StandardMessageCodec* codec) {
  auto encoded = codec->EncodeMessage(
      flutter::EncodableValue(std::vector<flutter::EncodableValue>{}));
  reply(encoded.get());
}

}  // namespace

// static
void ScreenshotShieldPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<ScreenshotShieldPlugin>();
  ScreenshotShieldPlugin* plugin_ptr = plugin.get();

  auto messenger = registrar->messenger();
  const auto* message_codec = &flutter::StandardMessageCodec::GetInstance();

  // Desktop does not support screenshot detection or prevention, so those host
  // API calls succeed as no-ops. start/stopListening drive the best-effort
  // screen-recording detection. The channels are thin wrappers and the handlers
  // are stored on the messenger, so the local channels are enough.
  auto register_host_channel = [messenger, message_codec](
                                   const char* name,
                                   const std::function<void()>& on_call) {
    auto channel =
        std::make_unique<flutter::BasicMessageChannel<flutter::EncodableValue>>(
            messenger, name, message_codec);
    channel->SetMessageHandler(
        [message_codec, on_call](const flutter::EncodableValue&,
                                 const flutter::BinaryReply& reply) {
          if (on_call) {
            on_call();
          }
          ReplySuccess(reply, message_codec);
        });
  };

  register_host_channel(kStartListeningChannel,
                        [plugin_ptr]() { plugin_ptr->StartListening(); });
  register_host_channel(kStopListeningChannel,
                        [plugin_ptr]() { plugin_ptr->StopListening(); });
  register_host_channel(kSetProtectedChannel, nullptr);
  register_host_channel(kSetBackgroundBlurChannel, nullptr);

  auto event_channel =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          messenger, kOnScreenshotDetectedChannel,
          &flutter::StandardMethodCodec::GetInstance());
  event_channel->SetStreamHandler(std::make_unique<NoOpStreamHandler>());

  auto screen_recording_channel =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          messenger, kOnScreenRecordingChangedChannel,
          &flutter::StandardMethodCodec::GetInstance());
  screen_recording_channel->SetStreamHandler(
      std::make_unique<ScreenRecordingStreamHandler>(plugin_ptr));

  // Windows privacy: hide the window from alt-tab and the taskbar preview
  // while it is not active or is minimized, via DWMWA_CLOAK. The same window
  // proc drives the screen-recording sampling timer.
  if (auto* view = registrar->GetView()) {
    HWND window = view->GetNativeWindow();
    plugin_ptr->SetWindow(window);
    registrar->RegisterTopLevelWindowProcDelegate(
        [plugin_ptr, window](HWND, UINT message, WPARAM wparam,
                             LPARAM) -> std::optional<LRESULT> {
          if (message == WM_ACTIVATE) {
            bool cloaked = LOWORD(wparam) == WA_INACTIVE;
            BOOL value = cloaked ? TRUE : FALSE;
            DwmSetWindowAttribute(window, DWMWA_CLOAK, &value, sizeof(value));
          } else if (message == WM_SIZE && wparam == SIZE_MINIMIZED) {
            BOOL value = TRUE;
            DwmSetWindowAttribute(window, DWMWA_CLOAK, &value, sizeof(value));
          } else if (message == WM_TIMER && wparam == kScreenRecordingTimerId) {
            plugin_ptr->PollScreenRecording();
          }
          return std::nullopt;
        });
  }

  registrar->AddPlugin(std::move(plugin));
}

ScreenshotShieldPlugin::ScreenshotShieldPlugin() {}

ScreenshotShieldPlugin::~ScreenshotShieldPlugin() {
  if (window_ != nullptr) {
    KillTimer(window_, kScreenRecordingTimerId);
  }
}

void ScreenshotShieldPlugin::SetWindow(HWND window) { window_ = window; }

void ScreenshotShieldPlugin::StartListening() {
  if (listening_) {
    return;
  }
  listening_ = true;
  last_state_.reset();
  PollScreenRecording();
  if (window_ != nullptr) {
    SetTimer(window_, kScreenRecordingTimerId, kScreenRecordingPollIntervalMs,
             nullptr);
  }
}

void ScreenshotShieldPlugin::StopListening() {
  if (!listening_) {
    return;
  }
  listening_ = false;
  if (window_ != nullptr) {
    KillTimer(window_, kScreenRecordingTimerId);
  }
}

void ScreenshotShieldPlugin::AttachScreenRecordingSink(
    std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink) {
  screen_recording_sink_ = std::move(sink);
  if (listening_) {
    // Emit the current value to the new listener even if it is unchanged.
    last_state_.reset();
    PollScreenRecording();
  }
}

void ScreenshotShieldPlugin::DetachScreenRecordingSink() {
  screen_recording_sink_ = nullptr;
}

void ScreenshotShieldPlugin::PollScreenRecording() {
  if (!listening_) {
    return;
  }
  const bool recording = IsKnownRecorderRunning();
  if (last_state_.has_value() && last_state_.value() == recording) {
    return;
  }
  last_state_ = recording;
  if (screen_recording_sink_) {
    screen_recording_sink_->Success(flutter::EncodableValue(recording));
  }
}

// static
bool ScreenshotShieldPlugin::IsKnownRecorderRunning() {
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) {
    return false;
  }
  PROCESSENTRY32A entry;
  entry.dwSize = sizeof(PROCESSENTRY32A);
  bool found = false;
  if (Process32FirstA(snapshot, &entry)) {
    do {
      if (IsScreenRecorderProcessName(entry.szExeFile)) {
        found = true;
        break;
      }
    } while (Process32NextA(snapshot, &entry));
  }
  CloseHandle(snapshot);
  return found;
}

}  // namespace screenshot_shield
