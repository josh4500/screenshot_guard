//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <screenshot_shield/screenshot_shield_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) screenshot_shield_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "ScreenshotShieldPlugin");
  screenshot_shield_plugin_register_with_registrar(screenshot_shield_registrar);
}
