/// 插件统一 DEBUG 日志 —— 内核内部诊断通道，非宿主 API。
///
/// **门控在编译期，且不依赖 `package:flutter`。** 副作用包在 `assert` 里：
/// Dart 断言参数在非开发模式**不求值**，故 debug 有输出、profile 与 release
/// 零输出零开销——与 `kDebugMode` 在所有标准构建模式下等价（`kDebugMode`
/// 在 profile 亦为 false）。
///
/// 这正是 Flutter 官方对调试输出的建议写法：`debugPrint` 文档原文
/// 「As per convention, calls to [debugPrint] should be within a debug mode
/// check or an assert」。因此**不要改成 `print` 或 `debugPrint`**——
/// `debugPrint` 同文档明言「logs to console even in release mode」，而两者
/// 都会把协议内核与发现层重新拖回对 Flutter 的传递性依赖（README 已声明
/// 「协议内核纯 Dart」；`lib/` 现仅 `native_bonjour_discovery.dart` 因
/// MethodChannel 引用 Flutter）。
///
/// 与 `TODO.md` 的既定原则一致：**DEBUG log 给开发者；DiagnosticReport 给
/// 产品**。宿主侧的 release 现场取证不在本函数职责内（0.8.x 另议）。
///
/// 已知边界（如实记录，未优化）：`message` 在**调用点**求值，release 下字符串
/// 构造**不保证**被编译器消除（插值可能触发 `toString`，无法证明无副作用）；
/// 量级未做基准测量，故不声称「零开销」。另：裸 `print` 在按日志速率限流的
/// 平台上（典型为 Android）可能被丢弃——Flutter 的节流实现即为此而设
/// （`debugPrintThrottled` 注释原文「This avoids dropping messages on
/// platforms that rate-limit their logging」）。本通道每次操作仅两行，远低于
/// 其 12 KiB/s 的额度，但边界不因此消失。
library;

void ippLog(String message) {
  assert(() {
    print('[ipp_print] $message');
    return true;
  }());
}
