Pod::Spec.new do |s|
  s.name             = 'ipp_print'
  s.version          = '0.7.3'
  s.summary          = 'IPP direct printing kernel: native Bonjour discovery (iOS).'
  s.description      = 'Native Bonjour discovery via NSNetServiceBrowser (no multicast entitlement), IPP 1.1 over unicast, PWG-raster encoding in Dart.'
  s.homepage         = 'https://github.com/eveinzz/ipp_print'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'eveinzz' => 'eveinzz@users.noreply.github.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '12.0'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
end
