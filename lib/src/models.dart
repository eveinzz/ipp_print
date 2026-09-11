/// 核心领域模型 barrel（0.4 起按域拆分至 `models/`，本文件保留兼容导出）。
///
/// 所有能力判定必须来自打印机广播/协议响应的确定性字段，禁止推断。
library;

export 'models/capabilities.dart';
export 'models/exceptions.dart';
export 'models/print_options.dart';
export 'models/print_ticket.dart';
export 'models/printer_identity.dart';
