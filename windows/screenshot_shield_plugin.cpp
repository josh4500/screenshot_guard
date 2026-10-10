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

#include <cwchar>
#include <functional>
#include <memory>
#include <optional>
#include <variant>

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
constexpr char kSetKeyboardProtectedChannel[] =
    "dev.flutter.pigeon.screenshot_shield.ScreenshotShieldHostApi.setKeyboardProtected";
constexpr char kOnScreenshotDetectedChannel[] =
    "dev.flutter.pigeon.screenshot_shield.ScreenshotShieldEventChannelApi.onScreenshotDetected";
constexpr char kOnScreenRecordingChangedChannel[] =
    "dev.flutter.pigeon.screenshot_shield.ScreenshotShieldEventChannelApi.onScreenRecordingChanged";

// Missing from SDKs older than Windows 10 2004.
#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011
#endif

constexpr UINT_PTR kScreenRecordingTimerId = 0x5C7E;
constexpr UINT kScreenRecordingPollIntervalMs = 2000;

// Windows has no API that tells an app it is being recorded, so this is a
// best-effort heuristic that looks for well-known screen-recording programs in
// the process list. It can produce false positives (a recorder is running but
// not recording) and false negatives (an unlisted recorder is used). Names are
// matched exactly, so resident helpers (Xbox Game Bar) and unrelated programs
// that merely contain a token ("bloomberg") are not mistaken for recorders.
constexpr const wchar_t* kScreenRecorderExecutables[] = {
    L"obs64.exe",       L"obs32.exe",          L"obs.exe",
    L"bdcam.exe",       L"bandicam.exe",       L"camtasiastudio.exe",
    L"camrecorder.exe", L"fraps.exe",          L"loom.exe",
    L"snagit32.exe",    L"screenrec.exe",      L"flashbackrecorder.exe",
    L"movavi screen recorder.exe",
};

bool IsScreenRecorderExecutable(const wchar_t* name) {
  for (const wchar_t* executable : kScreenRecorderExecutables) {
    if (_wcsicmp(name, executable) == 0) {
      return true;
    }
  }
  return false;
}

// Pigeon sends host API arguments as a list; reads the first one as a bool.
bool FirstBoolArgument(const flutter::EncodableValue& message) {
  const auto* args = std::get_if<flutter::EncodableList>(&message);
  if (args == nullptr || args->empty()) {
    return false;
  }
  const auto* value = std::get_if<bool>(&(*args)[0]);
  return value != nullptr && *value;
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

}  // namespace

// static
void ScreenshotShieldPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<ScreenshotShieldPlugin>();
  ScreenshotShieldPlugin* plugin_ptr = plugin.get();

  auto messenger = registrar->messenger();

  // Windows cannot detect screenshots, but it can keep the window out of
  // captures (setProtected) and out of thumbnails (setBackgroundBlur).
  // start/stopListening drive the best-effort screen-recording detection. The
  // channels are thin wrappers and the handlers are stored on the messenger, so
  // the local channels are enough. A void Pigeon call is answered with an
  // empty list, which the channel encodes itself.
  auto register_host_channel =
      [messenger](
          const char* name,
          const std::function<void(const flutter::EncodableValue&)>& on_call) {
        flutter::BasicMessageChannel<flutter::EncodableValue> channel(
            messenger, name, &flutter::StandardMessageCodec::GetInstance());
        channel.SetMessageHandler(
            [on_call](const flutter::EncodableValue& message,
                      const flutter::MessageReply<flutter::EncodableValue>&
                          reply) {
              if (on_call) {
                on_call(message);
              }
              reply(flutter::EncodableValue(flutter::EncodableList{}));
            });
      };

  register_host_channel(kStartListeningChannel,
                        [plugin_ptr](const flutter::EncodableValue&) {
                          plugin_ptr->StartListening();
                        });
  register_host_channel(kStopListeningChannel,
                        [plugin_ptr](const flutter::EncodableValue&) {
                          plugin_ptr->StopListening();
                        });
  register_host_channel(kSetProtectedChannel,
                        [plugin_ptr](const flutter::EncodableValue& message) {
                          plugin_ptr->SetProtected(FirstBoolArgument(message));
                        });
  register_host_channel(kSetBackgroundBlurChannel,
                        [plugin_ptr](const flutter::EncodableValue& message) {
                          plugin_ptr->SetBackgroundBlur(
                              FirstBoolArgument(message));
                        });
  // The keyboard is not a separate capturable surface on Windows.
  register_host_channel(kSetKeyboardProtectedChannel, nullptr);

  flutter::EventChannel<flutter::EncodableValue> event_channel(
      messenger, kOnScreenshotDetectedChannel,
      &flutter::StandardMethodCodec::GetInstance());
  event_channel.SetStreamHandler(std::make_unique<NoOpStreamHandler>());

  flutter::EventChannel<flutter::EncodableValue> screen_recording_channel(
      messenger, kOnScreenRecordingChangedChannel,
      &flutter::StandardMethodCodec::GetInstance());
  screen_recording_channel.SetStreamHandler(
      std::make_unique<ScreenRecordingStreamHandler>(plugin_ptr));

  if (auto* view = registrar->GetView()) {
    plugin_ptr->SetViewWindow(view->GetNativeWindow());
    // The sampling timer is set on the top-level window, whose messages reach
    // this delegate.
    registrar->RegisterTopLevelWindowProcDelegate(
        [plugin_ptr](HWND, UINT message, WPARAM wparam,
                     LPARAM) -> std::optional<LRESULT> {
          if (message == WM_TIMER && wparam == kScreenRecordingTimerId) {
            plugin_ptr->PollScreenRecording();
            return 0;
          }
          return std::nullopt;
        });
  }

  registrar->AddPlugin(std::move(plugin));
}

ScreenshotShieldPlugin::ScreenshotShieldPlugin() {}

ScreenshotShieldPlugin::~ScreenshotShieldPlugin() {
  if (timer_window_ != nullptr) {
    KillTimer(timer_window_, kScreenRecordingTimerId);
  }
}

void ScreenshotShieldPlugin::SetViewWindow(HWND view_window) {
  view_window_ = view_window;
}

HWND ScreenshotShieldPlugin::TopLevelWindow() const {
  if (view_window_ == nullptr) {
    return nullptr;
  }
  return GetAncestor(view_window_, GA_ROOT);
}

void ScreenshotShieldPlugin::SetProtected(bool protect) {
  HWND window = TopLevelWindow();
  if (window == nullptr) {
    return;
  }
  if (!protect) {
    SetWindowDisplayAffinity(window, WDA_NONE);
    return;
  }
  // Windows 10 2004+ leaves the window out of captures entirely; older versions
  // only support showing it black.
  if (!SetWindowDisplayAffinity(window, WDA_EXCLUDEFROMCAPTURE) &&
      !SetWindowDisplayAffinity(window, WDA_MONITOR)) {
    OutputDebugStringW(
        L"[ScreenshotShield] SetWindowDisplayAffinity failed; capture "
        L"prevention is unavailable on this window.\n");
  }
}

void ScreenshotShieldPlugin::SetBackgroundBlur(bool enabled) {
  HWND window = TopLevelWindow();
  if (window == nullptr) {
    return;
  }
  // Show the app icon instead of a live preview in the taskbar thumbnail and
  // Alt+Tab, and keep the window out of Aero Peek. The window itself stays
  // visible on screen.
  BOOL value = enabled ? TRUE : FALSE;
  DwmSetWindowAttribute(window, DWMWA_FORCE_ICONIC_REPRESENTATION, &value,
                        static_cast<DWORD>(sizeof(value)));
  DwmSetWindowAttribute(window, DWMWA_DISALLOW_PEEK, &value,
                        static_cast<DWORD>(sizeof(value)));
}

void ScreenshotShieldPlugin::StartListening() {
  if (listening_) {
    return;
  }
  listening_ = true;
  last_state_.reset();
  PollScreenRecording();
  HWND window = TopLevelWindow();
  if (window != nullptr &&
      SetTimer(window, kScreenRecordingTimerId, kScreenRecordingPollIntervalMs,
               nullptr) != 0) {
    timer_window_ = window;
  }
}

void ScreenshotShieldPlugin::StopListening() {
  if (!listening_) {
    return;
  }
  listening_ = false;
  if (timer_window_ != nullptr) {
    KillTimer(timer_window_, kScreenRecordingTimerId);
    timer_window_ = nullptr;
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
  PROCESSENTRY32W entry{};
  entry.dwSize = static_cast<DWORD>(sizeof(entry));
  bool found = false;
  if (Process32FirstW(snapshot, &entry)) {
    do {
      if (IsScreenRecorderExecutable(entry.szExeFile)) {
        found = true;
        break;
      }
    } while (Process32NextW(snapshot, &entry));
  }
  CloseHandle(snapshot);
  return found;
}

}  // namespace screenshot_shield
