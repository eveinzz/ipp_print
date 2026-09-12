part of 'ipp_print_core.dart';

/// Job Engine（0.6）：submit / monitor / getJob / cancel 职责拆分，
/// 与既有 print() 共享 gate → 协商 → 编码的单一来源 `_prepareSubmission`。

/// `_prepareSubmission` 的最终事件：协商 + 编码完成、待提交的作业载荷。
class _PreparedSubmission {
  const _PreparedSubmission({
    required this.bytes,
    required this.documentFormat,
    required this.options,
    required this.jobName,
    this.pageCount,
  });

  final Uint8List bytes;
  final String documentFormat;
  final PrintOptions options;
  final String jobName;

  /// 页数仅栅格回退路径已知；直投如实为 null。
  final int? pageCount;
}

/// gate → 实时协商 → 编码的共享管线（print() 与 submit() 单一来源，
/// 0.6 防双入口漂移）。事件流：PrintProgress（rasterizing/encoding）→
/// 最终 [_PreparedSubmission]。
Stream<Object> _prepareSubmission(
  IppClient client, {
  required PwgRasterEncoder encoder,
  required int defaultDpi,
  required PrintDocument document,
  required DiscoveredPrinter printer,
  required PrintTicket ticket,
  PdfRasterizer? rasterizer,
  int? dpi,
}) async* {
  final options = ticket.toOptions();
  // Gate 事实化（0.5 重构）：TXT 分类不再是「本包可达」的终审——
  // airPrint / ippDirect / vendorOnly 三类均有 IPP endpoint 证据
  // （rp 由发现层保证非空），真正的把关交给下面的**实时能力查询 +
  // 协商器**（声明集无交集 → IppUnsupportedException）。TXT 只保留
  // 一个否定门：unknown = 广播缺可判定字段（无 rp/pdl/urf 证据），
  // 连 IPP endpoint 存在性都无法确认，拒绝且不发任何请求。
  // 修复（TODO 0.4 遗留）：仅声明 IPP+PDF 的设备（原 vendorOnly）
  // 不再被整包拒绝——PDF 直投经协商器天然可达。
  // 0.7 豁免：manualEndpoint（addEndpoint 手动直连）——URI 本身即
  // endpoint 存在性的用户断言，TXT 门对其无意义；能力终审仍在下方
  // 实时查询 + 协商器。豁免仅对 manual 生效，发现打印机不放松。
  if (!printer.manualEndpoint &&
      CapabilityClassifier.classify(printer.txt) == PrinterCapability.unknown) {
    throw const IppUnsupportedException(
        'TXT record shows no IPP evidence (no rp/pdl/urf) — see probe()');
  }
  // 声明集实时查询（协商数据源）。整机限时 10s，超时如实抛出。
  final PrinterAttributes attrs;
  try {
    attrs = await client
        .getPrinterAttributes(printer)
        .timeout(const Duration(seconds: 10));
  } on TimeoutException {
    ippProbeLog('print ${printer.name}: capability query TIMEOUT (10s)');
    throw const IppPrintException(
        'print: capability query timed out after 10s');
  }
  final decision = const DocumentFormatNegotiator().negotiate(
    document: document,
    printerFormats: attrs.documentFormats,
  );
  if (!decision.passthrough) {
    if (rasterizer == null) {
      throw IppPrintException(
          'printer does not declare ${document.mimeType} and no '
          'rasterizer was provided for the PWG-raster fallback');
    }
    if (document.mimeType.toLowerCase() != 'application/pdf') {
      throw IppPrintException(
          'no encoder for ${document.mimeType}: the current pipeline can '
          'only rasterize application/pdf (printer declares: '
          '${attrs.documentFormats})');
    }
    final enc = dpi == null ? encoder : PwgRasterEncoder(dpi: dpi);
    yield const PrintProgress(PrintStage.rasterizing);
    final pwg = BytesBuilder(copy: false);
    // PWG 5102.4 Figure 1：同步字为文件级，整个文档只出现一次。
    pwg.add(enc.syncWordBytes);
    var pageNo = 0;
    await for (final page
        in rasterizer.rasterize(document.bytes, dpi: dpi ?? defaultDpi)) {
      pageNo++;
      pwg.add(enc.encodePage(page));
      yield PrintProgress(PrintStage.encoding, page: pageNo);
    }
    if (pageNo == 0) {
      throw const IppPrintException('rasterizer produced no pages');
    }
    yield _PreparedSubmission(
      bytes: pwg.takeBytes(),
      documentFormat: decision.documentFormat,
      options: options,
      jobName: document.name ?? 'ipp_print-document',
      pageCount: pageNo,
    );
    return;
  }
  // 直投：文档字节原样提交（保矢量与文本层）。
  yield _PreparedSubmission(
    bytes: Uint8List.fromList(document.bytes),
    documentFormat: decision.documentFormat,
    options: options,
    jobName: document.name ?? 'ipp_print-document',
  );
}

/// 提交作业并等待终态（print() 的公共尾部）。
/// [pageCount] 仅栅格回退路径已知；直投路径如实为 null。
Stream<PrintProgress> _submitAndAwait(
  IppClient client,
  DiscoveredPrinter printer, {
  required Uint8List bytes,
  required String documentFormat,
  required PrintOptions options,
  required String jobName,
  required Duration jobTimeout,
  int? pageCount,
}) async* {
  yield const PrintProgress(PrintStage.sending);
  final summary = await client.submitJob(
    printer,
    document: bytes,
    documentFormat: documentFormat,
    options: options,
    jobName: jobName,
  );
  yield PrintProgress(PrintStage.waitingPrinter, jobId: summary.jobId);
  final state = await client.waitForTerminalState(
    printer,
    summary.jobId,
    timeout: jobTimeout,
  );
  if (state != IppJobState.completed) {
    throw IppPrintException('job ${summary.jobId} ended as ${state.name}');
  }
  yield PrintProgress(PrintStage.done,
      pageCount: pageCount, jobId: summary.jobId);
}

/// Job Engine 实现（宿主 IppPrint 的私有协作类；同库 part 共享私有成员）。
class _JobEngine {
  _JobEngine(this._ipp);

  final IppPrint _ipp;

  IppClient get _client => _ipp._client;
  int get _defaultDpi => _ipp._dpi;

  /// 提交作业不等待终态：共享管线（含栅格进度回调）→ Print-Job →
  /// 以打印机应答快照构造 [PrintJob]。
  Future<PrintJob> submit({
    required PrintDocument document,
    required DiscoveredPrinter printer,
    PdfRasterizer? rasterizer,
    PrintTicket ticket = const PrintTicket(),
    int? dpi,
    void Function(PrintProgress progress)? onProgress,
  }) async {
    _PreparedSubmission? prepared;
    await for (final ev in _prepareSubmission(
      _client,
      encoder: _ipp._encoder,
      defaultDpi: _defaultDpi,
      document: document,
      printer: printer,
      ticket: ticket,
      rasterizer: rasterizer,
      dpi: dpi,
    )) {
      if (ev is PrintProgress) {
        onProgress?.call(ev);
        continue;
      }
      prepared = ev as _PreparedSubmission;
    }
    final p = prepared!;
    final summary = await _client.submitJob(
      printer,
      document: p.bytes,
      documentFormat: p.documentFormat,
      options: p.options,
      jobName: p.jobName,
    );
    return PrintJob(
      jobId: summary.jobId,
      printer: printer,
      state: summary.jobState,
      stateReasons: summary.stateReasons,
      jobName: p.jobName,
      documentFormat: p.documentFormat,
    );
  }

  /// 轮询作业状态流：终态快照产出后关流；超时抛
  /// [IppJobTimeoutException]——**硬上界**，瞬态吸收不得越界（与
  /// [IppClient.waitForTerminalState] 的 deadline 语义一致；0.7.2 前
  /// deadline 只在查询成功分支判定，瞬态分支绕过它属实现缺陷）。
  Stream<PrintJob> monitor(
    PrintJob job, {
    Duration interval = const Duration(seconds: 2),
    Duration timeout = const Duration(minutes: 5),
    int maxTransientErrors = 3,
  }) async* {
    final deadline = DateTime.now().add(timeout);
    var transientErrors = 0;
    while (true) {
      // 超时判定置于循环首：瞬态异常路径（continue）同样受 deadline 约束，
      // 否则设备持续不可达时实际耗时 = timeout + 重试退避，且最终抛
      // SocketException 而非文档承诺的 IppJobTimeoutException。
      if (!DateTime.now().isBefore(deadline)) {
        throw IppJobTimeoutException(job.jobId, 'not terminal within timeout');
      }
      final IppJobSummary s;
      try {
        s = await _client.getJob(job.printer, job.jobId);
        transientErrors = 0;
      } on SocketException {
        if (++transientErrors > maxTransientErrors) rethrow;
        await Future<void>.delayed(interval);
        continue;
      } on HandshakeException {
        // ipps 打印机的 TLS 握手瞬时失败与网络抖动同性质：可重试吸收。
        if (++transientErrors > maxTransientErrors) rethrow;
        await Future<void>.delayed(interval);
        continue;
      } on IppTransientException {
        if (++transientErrors > maxTransientErrors) rethrow;
        await Future<void>.delayed(interval);
        continue;
      }
      yield job.withSummary(s);
      if (s.jobState.isTerminal) return;
      // 超时判定只在循环首（此处原有一次等价判定，提上后删除，避免两处
      // 判据漂移）。
      await Future<void>.delayed(interval);
    }
  }

  /// 单查作业快照。
  Future<PrintJob> getJob(DiscoveredPrinter printer, int jobId) async {
    final s = await _client.getJob(printer, jobId);
    return PrintJob(
      jobId: jobId,
      printer: printer,
      state: s.jobState,
      stateReasons: s.stateReasons,
      jobName: s.jobName,
    );
  }

  /// 取消作业（Cancel-Job）。
  Future<void> cancel(PrintJob job) =>
      _client.cancelJob(job.printer, job.jobId);
}
