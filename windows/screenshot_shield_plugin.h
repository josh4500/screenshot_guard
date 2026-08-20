#ifndef FLUTTER_PLUGIN_SCREENSHOT_SHIELD_PLUGIN_H_
#define FLUTTER_PLUGIN_SCREENSHOT_SHIELD_PLUGIN_H_

#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace screenshot_shield {

class ScreenshotShieldPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  ScreenshotShieldPlugin();

  virtual ~ScreenshotShieldPlugin();

  // Disallow copy and assign.
  ScreenshotShieldPlugin(const ScreenshotShieldPlugin&) = delete;
  ScreenshotShieldPlugin& operator=(const ScreenshotShieldPlugin&) = delete;
};

}  // namespace screenshot_shield

#endif  // FLUTTER_PLUGIN_SCREENSHOT_SHIELD_PLUGIN_H_
