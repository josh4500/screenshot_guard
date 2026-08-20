#include "screenshot_shield_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include <dwmapi.h>

#include <flutter/basic_message_channel.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/event_stream_handler.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_message_codec.h>
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>

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

  auto messenger = registrar->messenger();
  const auto* message_codec = &flutter::StandardMessageCodec::GetInstance();

  // Desktop does not support screenshot detection or prevention, so all host
  // API calls succeed as no-ops. The channels are thin wrappers and the
  // handlers are stored on the messenger, so the local channels are enough.
  auto register_host_channel = [messenger, message_codec](const char* name) {
    auto channel =
        std::make_unique<flutter::BasicMessageChannel<flutter::EncodableValue>>(
            messenger, name, message_codec);
    channel->SetMessageHandler(
        [message_codec](const flutter::EncodableValue&,
                        const flutter::BinaryReply& reply) {
          ReplySuccess(reply, message_codec);
        });
  };

  register_host_channel(kStartListeningChannel);
  register_host_channel(kStopListeningChannel);
  register_host_channel(kSetProtectedChannel);
  register_host_channel(kSetBackgroundBlurChannel);

  auto event_channel =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          messenger, kOnScreenshotDetectedChannel,
          &flutter::StandardMethodCodec::GetInstance());
  event_channel->SetStreamHandler(std::make_unique<NoOpStreamHandler>());

  // Windows privacy: hide the window from alt-tab and the taskbar preview
  // while it is not active or is minimized, via DWMWA_CLOAK.
  if (auto* view = registrar->GetView()) {
    HWND window = view->GetNativeWindow();
    registrar->RegisterTopLevelWindowProcDelegate(
        [window](HWND, UINT message, WPARAM wparam,
                 LPARAM) -> std::optional<LRESULT> {
          if (message == WM_ACTIVATE) {
            bool cloaked = LOWORD(wparam) == WA_INACTIVE;
            BOOL value = cloaked ? TRUE : FALSE;
            DwmSetWindowAttribute(window, DWMWA_CLOAK, &value, sizeof(value));
          } else if (message == WM_SIZE && wparam == SIZE_MINIMIZED) {
            BOOL value = TRUE;
            DwmSetWindowAttribute(window, DWMWA_CLOAK, &value, sizeof(value));
          }
          return std::nullopt;
        });
  }

  registrar->AddPlugin(std::move(plugin));
}

ScreenshotShieldPlugin::ScreenshotShieldPlugin() {}

ScreenshotShieldPlugin::~ScreenshotShieldPlugin() {}

}  // namespace screenshot_shield
