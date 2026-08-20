#include "include/screenshot_shield/screenshot_shield_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

static const char kStartListeningChannel[] =
    "dev.flutter.pigeon.screenshot_shield.ScreenshotShieldHostApi.startListening";
static const char kStopListeningChannel[] =
    "dev.flutter.pigeon.screenshot_shield.ScreenshotShieldHostApi.stopListening";
static const char kSetProtectedChannel[] =
    "dev.flutter.pigeon.screenshot_shield.ScreenshotShieldHostApi.setProtected";
static const char kSetBackgroundBlurChannel[] =
    "dev.flutter.pigeon.screenshot_shield.ScreenshotShieldHostApi.setBackgroundBlur";
static const char kOnScreenshotDetectedChannel[] =
    "dev.flutter.pigeon.screenshot_shield.ScreenshotShieldEventChannelApi.onScreenshotDetected";

// Desktop does not support screenshot detection or prevention (screenshots are
// taken by external tools), so every host API call succeeds as a no-op.
static void screenshot_shield_plugin_message_cb(
    FlBasicMessageChannel* channel, FlValue*,
    FlBasicMessageChannelResponseHandle* response_handle, gpointer) {
  g_autoptr(FlValue) reply = fl_value_new_list();
  fl_basic_message_channel_respond(channel, response_handle, reply, nullptr);
}

// The event channel accepts listeners but never emits events.
static FlMethodErrorResponse* screenshot_shield_plugin_listen_cb(
    FlEventChannel*, FlValue*, gpointer) {
  return nullptr;
}

static FlMethodErrorResponse* screenshot_shield_plugin_cancel_cb(
    FlEventChannel*, FlValue*, gpointer) {
  return nullptr;
}

// The channels are kept alive for the lifetime of the app, because disposing
// them unregisters the handlers from the messenger.
static FlBasicMessageChannel* s_start_channel = nullptr;
static FlBasicMessageChannel* s_stop_channel = nullptr;
static FlBasicMessageChannel* s_set_protected_channel = nullptr;
static FlBasicMessageChannel* s_set_background_blur_channel = nullptr;
static FlEventChannel* s_event_channel = nullptr;

static void register_host_channel(FlBinaryMessenger* messenger,
                                  const gchar* name,
                                  FlBasicMessageChannel** channel) {
  if (*channel != nullptr) {
    return;
  }
  g_autoptr(FlStandardMessageCodec) codec = fl_standard_message_codec_new();
  *channel =
      fl_basic_message_channel_new(messenger, name, FL_MESSAGE_CODEC(codec));
  fl_basic_message_channel_set_message_handler(
      *channel, screenshot_shield_plugin_message_cb, nullptr, nullptr);
}

void screenshot_shield_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  FlBinaryMessenger* messenger = fl_plugin_registrar_get_messenger(registrar);

  register_host_channel(messenger, kStartListeningChannel, &s_start_channel);
  register_host_channel(messenger, kStopListeningChannel, &s_stop_channel);
  register_host_channel(messenger, kSetProtectedChannel,
                        &s_set_protected_channel);
  register_host_channel(messenger, kSetBackgroundBlurChannel,
                        &s_set_background_blur_channel);

  if (s_event_channel == nullptr) {
    g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
    s_event_channel = fl_event_channel_new(messenger, kOnScreenshotDetectedChannel,
                                           FL_METHOD_CODEC(codec));
    fl_event_channel_set_stream_handlers(
        s_event_channel, screenshot_shield_plugin_listen_cb,
        screenshot_shield_plugin_cancel_cb, nullptr, nullptr);
  }
}
