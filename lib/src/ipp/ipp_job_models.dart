part of 'ipp_client.dart';

/// job-state 枚举（RFC 8011 §5.3.7 / IPP Guide：3 pending、4 pending-held、
/// 5 processing、6 processing-stopped、7 canceled、8 aborted、9 completed）。
enum IppJobState {
  unknown(-1),
  pending(3),
  pendingHeld(4),
  processing(5),
  processingStopped(6),
  canceled(7),
  aborted(8),
  completed(9);

  const IppJobState(this.code);
  final int code;

  bool get isTerminal =>
      this == canceled || this == aborted || this == completed;

  /// 未知值如实映射 [unknown]（0.4.1 修复：原 orElse→pending 属静默猜测，
  /// 违反「缺≠支持、绝不推断」纪律）；unknown 非终态，轮询方继续查询。
  static IppJobState fromCode(int code) => IppJobState.values
      .firstWhere((s) => s.code == code, orElse: () => IppJobState.unknown);
}

/// Get-Jobs / Get-Job-Attributes / Print-Job 响应的单个作业摘要。
class IppJobSummary {
  const IppJobSummary({
    required this.jobId,
    required this.jobState,
    this.jobName,
    this.userName,
    this.stateReasons = const <String>[],
    this.impressionsCompleted,
    this.mediaSheetsCompleted,
  });

  final int jobId;
  final IppJobState jobState;

  /// job-name（作业提交时的名字）。
  final String? jobName;

  /// job-originating-user-name（提交者）。
  final String? userName;

  /// job-state-reasons（RFC 8011 §5.3.8，1setOf keyword，如 `media-jam` /
  /// `job-incoming` / `job-completed-successfully`）：作业级透传，
  /// 上层错误页语义必需；原始 keyword 不做解释映射（缺 = 空集）。
  final List<String> stateReasons;

  /// job-impressions-completed（RFC 8011 §5.3.18.2）：已完成的
  /// impression 计数器。**透传原始值，绝不换算成「页」**——impression 是
  /// media sheet 的一面（§2.3.4），份数/双面/N-up 都会使其偏离本地页数；
  /// 换算属宿主职责。缺省/out-of-band（`no-value` 等，RFC 8010 §3.5.2）
  /// → null（0.8.0 起以宽容解码解析，绝不抛）。
  final int? impressionsCompleted;

  /// job-media-sheets-completed（RFC 8011 §5.3.18.3）：已完成的 media
  /// sheet 计数器。语义与 [impressionsCompleted] 相同：只透传、不换算、
  /// 缺省为 null。
  final int? mediaSheetsCompleted;
}
