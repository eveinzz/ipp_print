/// ipp_print — headless IPP direct-printing kernel.
///
/// 定位：发现 + 分类 + 传输（无 UI 内核）。展示与交互留给宿主 App。
library;

export 'src/capability/capability.dart';
export 'src/discovery/mdns_discovery.dart';
export 'src/discovery/native_bonjour_discovery.dart';
export 'src/ipp/ipp_client.dart';
export 'src/ipp/ipp_message.dart';
export 'src/ipp_print_core.dart';
export 'src/models.dart';
export 'src/pwg/pwg_raster_encoder.dart';
