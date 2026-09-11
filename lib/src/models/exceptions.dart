/// 统一异常体系。
library;

/// 异常分类轴（0.5 Structured Error）：宿主据此区分「网络问题 / 能力
/// 不支持 / 参数问题 / 作业问题」，驱动产品级错误页，而非仅靠 message 文案。
///
/// 边界：网络层异常**不二次包装**——dart:io 的 `SocketException` /
/// `TimeoutException` / TLS `HandshakeException` 原样透出（标准类型本身
/// 即 network 分类，与 [IppClient] 既有离线语义契约一致）；本轴只覆盖
/// 插件自有异常。
enum IppErrorCategory {
  /// IPP 协议层错误（打印机返回错误状态码）。
  ipp,

  /// 能力不支持（文档格式无交集 / 无编码器 / 无 IPP 证据）。
  unsupported,

  /// 作业生命周期（超时未达终态等）。
  job,

  /// 网络传输瞬态故障（服务器 5xx，可重试吸收）。
  network,

  /// 其余内核错误（语义缺口等）。
  generic,
}

/// 统一异常基类。
class IppPrintException implements Exception {
  const IppPrintException(this.message);

  final String message;

  /// 分类轴（子类各自覆写）。
  IppErrorCategory get category => IppErrorCategory.generic;

  @override
  String toString() => '$runtimeType: $message';
}

/// IPP 服务端返回错误状态码（status 不在 0x0000~0x00FF 成功区间）。
class IppStatusException extends IppPrintException {
  // 非 const：消息里包含运行时插值与方法调用。
  IppStatusException(this.statusCode, String message)
      : super('$message (IPP status 0x${statusCode.toRadixString(16)})');
  final int statusCode;

  @override
  IppErrorCategory get category => IppErrorCategory.ipp;
}

/// 打印任务未能在时限内到达终态。
class IppJobTimeoutException extends IppPrintException {
  const IppJobTimeoutException(this.jobId, String message)
      : super('job $jobId: $message');
  final int jobId;

  @override
  IppErrorCategory get category => IppErrorCategory.job;
}

/// 能力不支持（0.5）：文档格式与打印机声明集无交集、文档无对应编码器、
/// TXT 无 IPP 证据等——「缺≠支持、绝不推断」的结构化透出。
class IppUnsupportedException extends IppPrintException {
  const IppUnsupportedException(super.message);

  @override
  IppErrorCategory get category => IppErrorCategory.unsupported;
}

/// 网络传输层瞬态故障（HTTP 5xx）：可由轮询逻辑重试吸收。
/// （0.5 起自 ipp_client.dart 迁入，统一异常体系归属。）
class IppTransientException extends IppPrintException {
  const IppTransientException(super.message);

  @override
  IppErrorCategory get category => IppErrorCategory.network;
}
