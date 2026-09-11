/// 打印作业快照（0.6 Job Engine 契约对象；Contract v2 成员）。
///
/// 不可变值对象：每次查询/轮询产出新快照（状态机语义），作业身份由
/// [printer] + [jobId] 构成。8 态 lifecycle 即 [IppJobState]（unknown +
/// RFC 8011 §5.3.7 七态），终态判定与协议枚举同源。
library;

import '../ipp/ipp_client.dart' show IppJobState, IppJobSummary;
import '../models/printer_identity.dart';

/// 打印作业快照。
class PrintJob {
  const PrintJob({
    required this.jobId,
    required this.printer,
    required this.state,
    this.stateReasons = const <String>[],
    this.jobName,
    this.documentFormat,
  });

  /// IPP 作业号（打印机分配）。
  final int jobId;

  /// 目标打印机（monitor / cancel 的寻址上下文）。
  final DiscoveredPrinter printer;

  /// 作业状态（RFC 8011 §5.3.7 七态 + unknown）。
  final IppJobState state;

  /// job-state-reasons（RFC 8011 §5.3.8）：`media-jam` ≠ `printer-stopped`
  /// 的作业级语义；原始 keyword 透传，不做解释映射。
  final List<String> stateReasons;

  /// 作业名（提交时设定；快照刷新时以打印机应答为准）。
  final String? jobName;

  /// 提交时协商出的 document-format（本地记录，打印机快照不含此属性）。
  final String? documentFormat;

  /// 是否终态（completed / aborted / canceled）。
  bool get isTerminal => state.isTerminal;

  /// 以查询结果刷新快照（保留本地记录的 documentFormat）。
  PrintJob withSummary(IppJobSummary s) => PrintJob(
        jobId: s.jobId,
        printer: printer,
        state: s.jobState,
        stateReasons: s.stateReasons,
        jobName: s.jobName ?? jobName,
        documentFormat: documentFormat,
      );

  @override
  String toString() => 'PrintJob#$jobId(${state.name}, '
      'reasons=$stateReasons)';
}
