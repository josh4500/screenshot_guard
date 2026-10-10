Pod::Spec.new do |s|
  s.name             = 'screenshot_shield'
  s.version          = '0.2.0'
  s.summary          = 'Detect screenshots and screen recording, and prevent screen capture.'
  s.description      = <<-DESC
Detects screenshots and screen recording, blanks screen captures of the whole app or of
sensitive regions, and hides the app in the app switcher.
                       DESC
  s.homepage         = 'https://github.com/josh4500/screenshot_guard'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Ajibola Ak' => 'ajibolaak@users.noreply.github.com' }
  s.source           = { :path => '.' }
  s.source_files = 'screenshot_shield/Sources/screenshot_shield/**/*.swift'
  s.resource_bundles = { 'screenshot_shield_privacy' => ['screenshot_shield/Sources/screenshot_shield/PrivacyInfo.xcprivacy'] }
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.9'
end
