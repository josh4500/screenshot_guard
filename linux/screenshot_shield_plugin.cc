#include "include/screenshot_shield/screenshot_shield_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include <string.h>

static const char kStartListeningChannel[] =
    "dev.flutter.pigeon.screenshot_shield.ScreenshotShieldHostApi.startListening";
static const char kStopListeningChannel[] =
    "dev.flutter.pigeon.screenshot_shield.ScreenshotShieldHostApi.stopListening";
static const char kSetProtectedChannel[] =
    "dev.flutter.pigeon.screenshot_shield.ScreenshotShieldHostApi.setProtected";
static const char kSetBackgroundBlurChannel[] =
    "dev.flutter.pigeon.screenshot_shield.ScreenshotShieldHostApi.setBackgroundBlur";
static const char kSetKeyboardProtectedChannel[] =
    "dev.flutter.pigeon.screenshot_shield.ScreenshotShieldHostApi.setKeyboardProtected";
static const char kOnScreenshotDetectedChannel[] =
    "dev.flutter.pigeon.screenshot_shield.ScreenshotShieldEventChannelApi.onScreenshotDetected";
static const char kOnScreenRecordingChangedChannel[] =
    "dev.flutter.pigeon.screenshot_shield.ScreenshotShieldEventChannelApi.onScreenRecordingChanged";

// Linux has no API that tells an app it is being recorded, so this is a
// best-effort heuristic that looks for well-known screen-recording programs in
// /proc. It can produce false positives (a recorder is running but not
// recording) and false negatives (an unlisted recorder is used, a sandboxed app
// whose binary name differs, or GNOME's built-in recorder, which runs inside
// gnome-shell). Program names are matched exactly.
static const char* kScreenRecorderPrograms[] = {
    "obs",           "simplescreenrecorder", "recordmydesktop",
    "vokoscreen",    "vokoscreenng",         "kazam",
    "kooha",         "wf-recorder",          "peek",
    "gpu-screen-recorder", "green-recorder", "blue-recorder",
    nullptr,
};

static const guint kScreenRecordingPollIntervalMs = 2000;

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
static FlBasicMessageChannel* s_set_keyboard_protected_channel = nullptr;
static FlEventChannel* s_event_channel = nullptr;
static FlEventChannel* s_screen_recording_channel = nullptr;

// Screen-recording sampling state, owned by the main thread.
static gboolean s_listening = FALSE;
static gboolean s_screen_recording_subscribed = FALSE;
static gboolean s_has_screen_recording_state = FALSE;
static gboolean s_screen_recording_state = FALSE;
static guint s_screen_recording_poll_source = 0;

static gboolean is_screen_recorder_program(const gchar* path) {
  g_autofree gchar* base = g_path_get_basename(path);
  g_autofree gchar* lower = g_ascii_strdown(base, -1);
  for (guint i = 0; kScreenRecorderPrograms[i] != nullptr; i++) {
    if (g_strcmp0(lower, kScreenRecorderPrograms[i]) == 0) {
      return TRUE;
    }
  }
  return FALSE;
}

// Interpreters a recorder may run under ("python3 /usr/bin/kazam").
static const char* kInterpreterPrefixes[] = {"python", "perl", "ruby", "node",
                                             nullptr};

// /proc/<pid>/comm is truncated to 15 characters ("gpu-screen-reco").
static const gsize kCommMaxLength = 15;

// Whether [comm] could be a recorder whose full name was cut off, or an
// interpreter running one: only then is the command line worth reading.
static gboolean needs_cmdline(const gchar* comm) {
  g_autofree gchar* lower = g_ascii_strdown(comm, -1);
  if (strlen(lower) == kCommMaxLength) {
    for (guint i = 0; kScreenRecorderPrograms[i] != nullptr; i++) {
      if (g_str_has_prefix(kScreenRecorderPrograms[i], lower)) {
        return TRUE;
      }
    }
  }
  for (guint i = 0; kInterpreterPrefixes[i] != nullptr; i++) {
    if (g_str_has_prefix(lower, kInterpreterPrefixes[i])) {
      return TRUE;
    }
  }
  return FALSE;
}

// Matches the program by /proc/<pid>/comm, and reads /proc/<pid>/cmdline only
// when comm is a truncated recorder name or an interpreter. Reading cmdline
// takes the target process's mmap lock and can block behind a stuck process,
// and this runs on the main loop, so it is kept to those few candidates.
static gboolean is_screen_recorder_pid(const gchar* pid) {
  g_autofree gchar* comm_path = g_strdup_printf("/proc/%s/comm", pid);
  g_autofree gchar* comm = nullptr;
  if (!g_file_get_contents(comm_path, &comm, nullptr, nullptr)) {
    return FALSE;
  }
  g_strstrip(comm);
  if (is_screen_recorder_program(comm)) {
    return TRUE;
  }
  if (!needs_cmdline(comm)) {
    return FALSE;
  }
  g_autofree gchar* path = g_strdup_printf("/proc/%s/cmdline", pid);
  g_autofree gchar* contents = nullptr;
  gsize length = 0;
  if (!g_file_get_contents(path, &contents, &length, nullptr) || length == 0) {
    return FALSE;
  }
  // Arguments are NUL-separated; the buffer is NUL-terminated by GLib.
  const gchar* argv0 = contents;
  if (is_screen_recorder_program(argv0)) {
    return TRUE;
  }
  const gsize argv0_length = strlen(argv0);
  if (argv0_length + 1 < length) {
    return is_screen_recorder_program(contents + argv0_length + 1);
  }
  return FALSE;
}

static gboolean is_known_recorder_running(void) {
  g_autoptr(GError) error = nullptr;
  GDir* proc = g_dir_open("/proc", 0, &error);
  if (proc == nullptr) {
    return FALSE;
  }
  gboolean found = FALSE;
  const gchar* entry_name;
  while (!found && (entry_name = g_dir_read_name(proc)) != nullptr) {
    gboolean numeric = entry_name[0] != '\0';
    for (const gchar* c = entry_name; *c != '\0'; c++) {
      if (!g_ascii_isdigit(*c)) {
        numeric = FALSE;
        break;
      }
    }
    if (numeric && is_screen_recorder_pid(entry_name)) {
      found = TRUE;
    }
  }
  g_dir_close(proc);
  return found;
}

static void emit_screen_recording_state(void) {
  if (!s_screen_recording_subscribed || s_screen_recording_channel == nullptr) {
    return;
  }
  g_autoptr(FlValue) value = fl_value_new_bool(s_screen_recording_state);
  g_autoptr(GError) error = nullptr;
  fl_event_channel_send(s_screen_recording_channel, value, nullptr, &error);
}

static gboolean poll_screen_recording(gpointer) {
  if (!s_listening) {
    return G_SOURCE_CONTINUE;
  }
  const gboolean recording = is_known_recorder_running();
  if (s_has_screen_recording_state && s_screen_recording_state == recording) {
    return G_SOURCE_CONTINUE;
  }
  s_has_screen_recording_state = TRUE;
  s_screen_recording_state = recording;
  emit_screen_recording_state();
  return G_SOURCE_CONTINUE;
}

static void start_screen_recording_polling(void) {
  if (s_listening) {
    return;
  }
  s_listening = TRUE;
  s_has_screen_recording_state = FALSE;
  poll_screen_recording(nullptr);
  if (s_screen_recording_poll_source == 0) {
    s_screen_recording_poll_source =
        g_timeout_add(kScreenRecordingPollIntervalMs, poll_screen_recording,
                      nullptr);
  }
}

static void stop_screen_recording_polling(void) {
  if (!s_listening) {
    return;
  }
  s_listening = FALSE;
  if (s_screen_recording_poll_source != 0) {
    g_source_remove(s_screen_recording_poll_source);
    s_screen_recording_poll_source = 0;
  }
}

static void screenshot_shield_plugin_start_listening_cb(
    FlBasicMessageChannel* channel, FlValue*,
    FlBasicMessageChannelResponseHandle* response_handle, gpointer) {
  start_screen_recording_polling();
  g_autoptr(FlValue) reply = fl_value_new_list();
  fl_basic_message_channel_respond(channel, response_handle, reply, nullptr);
}

static void screenshot_shield_plugin_stop_listening_cb(
    FlBasicMessageChannel* channel, FlValue*,
    FlBasicMessageChannelResponseHandle* response_handle, gpointer) {
  stop_screen_recording_polling();
  g_autoptr(FlValue) reply = fl_value_new_list();
  fl_basic_message_channel_respond(channel, response_handle, reply, nullptr);
}

static FlMethodErrorResponse* screen_recording_listen_cb(FlEventChannel*,
                                                         FlValue*, gpointer) {
  s_screen_recording_subscribed = TRUE;
  if (s_has_screen_recording_state) {
    emit_screen_recording_state();
  }
  return nullptr;
}

static FlMethodErrorResponse* screen_recording_cancel_cb(FlEventChannel*,
                                                         FlValue*, gpointer) {
  s_screen_recording_subscribed = FALSE;
  return nullptr;
}

static void register_host_channel(FlBinaryMessenger* messenger,
                                  const gchar* name,
                                  FlBasicMessageChannel** channel,
                                  FlBasicMessageChannelMessageHandler handler) {
  if (*channel != nullptr) {
    return;
  }
  g_autoptr(FlStandardMessageCodec) codec = fl_standard_message_codec_new();
  *channel =
      fl_basic_message_channel_new(messenger, name, FL_MESSAGE_CODEC(codec));
  fl_basic_message_channel_set_message_handler(*channel, handler, nullptr,
                                               nullptr);
}

void screenshot_shield_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  FlBinaryMessenger* messenger = fl_plugin_registrar_get_messenger(registrar);

  register_host_channel(messenger, kStartListeningChannel, &s_start_channel,
                        screenshot_shield_plugin_start_listening_cb);
  register_host_channel(messenger, kStopListeningChannel, &s_stop_channel,
                        screenshot_shield_plugin_stop_listening_cb);
  register_host_channel(messenger, kSetProtectedChannel,
                        &s_set_protected_channel,
                        screenshot_shield_plugin_message_cb);
  register_host_channel(messenger, kSetBackgroundBlurChannel,
                        &s_set_background_blur_channel,
                        screenshot_shield_plugin_message_cb);
  register_host_channel(messenger, kSetKeyboardProtectedChannel,
                        &s_set_keyboard_protected_channel,
                        screenshot_shield_plugin_message_cb);

  if (s_event_channel == nullptr) {
    g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
    s_event_channel = fl_event_channel_new(messenger, kOnScreenshotDetectedChannel,
                                           FL_METHOD_CODEC(codec));
    fl_event_channel_set_stream_handlers(
        s_event_channel, screenshot_shield_plugin_listen_cb,
        screenshot_shield_plugin_cancel_cb, nullptr, nullptr);
  }

  if (s_screen_recording_channel == nullptr) {
    g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
    s_screen_recording_channel =
        fl_event_channel_new(messenger, kOnScreenRecordingChangedChannel,
                             FL_METHOD_CODEC(codec));
    fl_event_channel_set_stream_handlers(
        s_screen_recording_channel, screen_recording_listen_cb,
        screen_recording_cancel_cb, nullptr, nullptr);
  }
}
