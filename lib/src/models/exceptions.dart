/// 统一异常体系。
library;

/// 统一异常基类。
class IppPrintException implements Exception {
  const IppPrintException(this.message);
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// IPP 服务端返回错误状态码（status 不在 0x0000~0x00FF 成功区间）。
class IppStatusException extends IppPrintException {
  // 非 const：消息里包含运行时插值与方法调用。
  IppStatusException(this.statusCode, String message)
      : super('$message (IPP status 0x${statusCode.toRadixString(16)})');
  final int statusCode;
}

/// 打印任务未能在时限内到达终态。
class IppJobTimeoutException extends IppPrintException {
  const IppJobTimeoutException(this.jobId, String message)
      : super('job $jobId: $message');
  final int jobId;
}
