Pod::Spec.new do |s|
  s.name             = 'screenshot_shield'
  s.version          = '0.1.0'
  s.summary          = 'Detect user screenshots and optionally prevent screen capture on Android and iOS.'
  s.description      = <<-DESC
Detect user screenshots and optionally prevent screen capture on Android and iOS.
                       DESC
  s.homepage         = "https://github.com/josh4500/screenshot_shield"
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Ajibola Ak' => 'ajibolaak@users.noreply.github.com' }
  s.source           = { :path => '.' }
  s.source_files = 'screenshot_shield/Sources/screenshot_shield/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
