import 'package:flutter/foundation.dart' show kDebugMode;

/// 插件统一 DEBUG 日志（release 零开销）；原生层同用 `[ipp_print]` 前缀。
void ippLog(String message) {
  if (kDebugMode) print('[ipp_print] $message');
}
