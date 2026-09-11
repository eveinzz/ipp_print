Pod::Spec.new do |s|
  s.name             = 'ipp_print'
  s.version          = '0.4.1'
  s.summary          = 'IPP direct printing kernel: native Bonjour discovery (macOS).'
  s.description      = 'Native Bonjour discovery via NSNetServiceBrowser (no multicast entitlement), IPP 1.1 over unicast, PWG-raster encoding in Dart.'
  s.homepage         = 'https://github.com/eveinzz/ipp_print'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'eveinzz' => 'eveinzz@users.noreply.github.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform         = :osx, '10.14'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
