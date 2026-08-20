#include "include/screenshot_shield/screenshot_shield_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "screenshot_shield_plugin.h"

void ScreenshotShieldPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  screenshot_shield::ScreenshotShieldPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
