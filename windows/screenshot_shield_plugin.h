#ifndef FLUTTER_PLUGIN_SCREENSHOT_SHIELD_PLUGIN_H_
#define FLUTTER_PLUGIN_SCREENSHOT_SHIELD_PLUGIN_H_

#include <windows.h>

#include <flutter/encodable_value.h>
#include <flutter/event_sink.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>
#include <optional>

namespace screenshot_shield {

class ScreenshotShieldPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  ScreenshotShieldPlugin();

  virtual ~ScreenshotShieldPlugin();

  // Host API: start or stop sampling for screen recorders.
  void StartListening();
  void StopListening();

  // Host API: keep the window out of screen captures.
  void SetProtected(bool protect);

  // Host API: hide the live window preview in the taskbar and Alt+Tab.
  void SetBackgroundBlur(bool enabled);

  // Event channel sink management for onScreenRecordingChanged.
  void AttachScreenRecordingSink(
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink);
  void DetachScreenRecordingSink();

  // Samples the running processes and emits a change on the screen-recording
  // stream.
  void PollScreenRecording();

  // Flutter's view window. The top-level window the attributes and the timer
  // apply to is resolved from it when needed: at registration the view is not
  // yet parented to the runner's window.
  void SetViewWindow(HWND view_window);

  // Disallow copy and assign.
  ScreenshotShieldPlugin(const ScreenshotShieldPlugin&) = delete;
  ScreenshotShieldPlugin& operator=(const ScreenshotShieldPlugin&) = delete;

 private:
  static bool IsKnownRecorderRunning();

  // The runner's top-level window, or nullptr when there is no view.
  HWND TopLevelWindow() const;

  HWND view_window_ = nullptr;
  // The window the sampling timer was set on, so it can be killed.
  HWND timer_window_ = nullptr;
  bool listening_ = false;
  std::optional<bool> last_state_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>
      screen_recording_sink_;
};

}  // namespace screenshot_shield

#endif  // FLUTTER_PLUGIN_SCREENSHOT_SHIELD_PLUGIN_H_
