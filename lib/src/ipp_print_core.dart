import 'dart:async' show TimeoutException;
import 'dart:io' show SocketException;
import 'dart:typed_data';

import 'capability/capability.dart';
import 'discovery/native_bonjour_discovery.dart' show defaultPlatformDiscovery;
import 'document/document_format_negotiator.dart';
import 'document/print_document.dart';
import 'ipp/ipp_client.dart';
import 'ipp/ipp_log.dart';
import 'models.dart';
import 'pwg/pwg_raster_encoder.dart';

/// 诊断日志：仅 DEBUG 输出，前缀与原生层一致，release 零开销。
/// （统一实现在 [ippLog]，本函数保留旧名以兼容既有调用方。）
void ippProbeLog(String message) => ippLog(message);

/// Facade：插件唯一入口。
///
/// 职责边界（见 README）：发现 + 分类 + 传输；无 UI、无持久化、
/// 不接管 airPrint 级机型（交还系统打印面板）。
class IppPrint {
  IppPrint({PrinterDiscovery? discovery, IppClient? client, int dpi = 300})
      : _discovery = discovery ?? defaultPlatformDiscovery(),
        _client = client ?? IppClient(),
        _dpi = dpi;

  final PrinterDiscovery _discovery;
  final IppClient _client;
  final int _dpi;
  final _encoder = const PwgRasterEncoder();

  /// 发现局域网打印机（全量平铺，含不可直连的机型）。
  Future<List<DiscoveredPrinter>> discover({
    Duration timeout = const Duration(seconds: 5),
  }) =>
      _discovery.discover(timeout: timeout);

  /// 探测单台打印机：TXT 分类 + IPP 查询交叉验证，映射为状态机。
  ///
  /// 交叉验证规则（双源确定性）：TXT 判为 ippDirect 但 IPP 声明的
  /// document-format-supported 不含 image/pwg-raster → 降级 unsupported。
  /// **缺失（空集）同样降级**——「没有声明能力」≠「支持能力」
  /// （document-format-supported 是 RFC 8011 REQUIRED 打印机描述属性，
  /// 声明集为空即非 conformant 打印机，按未声明处理绝不推断）。
  Future<PrinterProbeStatus> probe(
    DiscoveredPrinter printer, {
    void Function(PrinterInfo info)? onInfo,
  }) async {
    final txtCapability = CapabilityClassifier.classify(printer.txt);
    if (txtCapability == PrinterCapability.unknown) {
      return PrinterProbeStatus.unsupported;
    }
    if (txtCapability != PrinterCapability.ippDirect) {
      onInfo?.call(PrinterInfo(capability: txtCapability));
      return txtCapability == PrinterCapability.airPrint
          ? PrinterProbeStatus.ready
          : PrinterProbeStatus.unsupported;
    }
    try {
      ippProbeLog('probe ${printer.name} -> ${printer.httpUriString}');
      // 挂起防御：HttpClient 的 connectionTimeout 不覆盖 DNS 解析与
      // 慢响应体，整机探测限时 10s（超时按无应答=offline 处理）。
      final attrs = await _client
          .getPrinterAttributes(printer)
          .timeout(const Duration(seconds: 10));
      final formats = attrs.documentFormats;
      final ok = formats
          .any((f) => f.toLowerCase().contains('pwg-raster'));
      ippProbeLog('probe ${printer.name}: $ok formats=$formats');
      final info = PrinterInfo(
        capability: ok ? PrinterCapability.ippDirect : PrinterCapability.vendorOnly,
        mediaSupported: attrs.mediaSupported,
        documentFormats: formats,
        state: attrs.state,
        makeModel: attrs.makeModel,
        colorModesSupported: attrs.colorModesSupported,
        colorModeDefault: attrs.colorModeDefault,
        sidesSupported: attrs.sidesSupported,
        sidesDefault: attrs.sidesDefault,
        resolutionsSupported: attrs.resolutionsSupported,
        resolutionDefault: attrs.resolutionDefault,
      );
      onInfo?.call(info);
      return ok ? PrinterProbeStatus.ready : PrinterProbeStatus.unsupported;
    } on TimeoutException {
      // 无应答（DNS 挂起/慢响应/静默丢包）：如实记 offline，绝不让
      // await 挂起令条目永久停留「探测中」。
      ippProbeLog('probe ${printer.name}: TIMEOUT (10s) -> offline');
      return PrinterProbeStatus.offline;
    } on SocketException catch (e) {
      ippProbeLog('probe ${printer.name}: offline ($e)');
      return PrinterProbeStatus.offline;
    } on IppPrintException catch (e) {
      ippProbeLog('probe ${printer.name}: unsupported ($e)');
      return PrinterProbeStatus.unsupported;
    }
  }

  /// 能力引擎（0.3）：完整能力集查询——「这台机器究竟能干什么」。
  ///
  /// 返回 [PrinterCapabilities]（文档/介质/色彩/双面/分辨率/份数/作业/
  /// 安全，全部来自打印机自报，缺失即 null/空）。与 [probe] 的区别：
  /// probe 面向「可否直连」的状态机判定（8 属性集），inspect 面向
  /// 宿主 UI 的全量能力展示与 0.4 格式协商的数据源。
  /// 整机限时 10s（同 probe 挂起防御），超时抛 [IppPrintException]。
  Future<PrinterCapabilities> inspect(DiscoveredPrinter printer) async {
    ippProbeLog('inspect ${printer.name} -> ${printer.httpUriString}');
    try {
      return await _client
          .getPrinterCapabilities(printer)
          .timeout(const Duration(seconds: 10));
    } on TimeoutException {
      ippProbeLog('inspect ${printer.name}: TIMEOUT (10s)');
      throw const IppPrintException('inspect: timed out after 10s');
    }
  }

  /// Validate-Job 预检（RFC 8011 §4.2.3）：提交大文档前先问打印机
  /// 「这个 Job 你能不能处理」。返回 [PrintValidationResult]；
  /// 打印机不支持该操作时返回 client-error-operation-not-supported
  /// （valid=false），宿主可回退为直接提交。
  ///
  /// 整机限时 10s（同 [probe]/[inspect] 挂起防御——半开 TCP 连接下
  /// 无限等待是 probe 阶段验证过的真实故障模式），超时抛
  /// [IppPrintException]。
  Future<PrintValidationResult> validateJob(
    DiscoveredPrinter printer, {
    required String documentFormat,
    PrintOptions options = const PrintOptions(),
    String jobName = 'ipp_print-document',
  }) async {
    ippProbeLog('validateJob ${printer.name} -> ${printer.httpUriString}');
    try {
      return await _client
          .validateJob(
            printer,
            documentFormat: documentFormat,
            options: options,
            jobName: jobName,
          )
          .timeout(const Duration(seconds: 10));
    } on TimeoutException {
      ippProbeLog('validateJob ${printer.name}: TIMEOUT (10s)');
      throw const IppPrintException('validateJob: timed out after 10s');
    }
  }

  /// 通用文档打印（0.4 Document Pipeline 核心入口）：协商 → 直投 /
  /// PWG 栅格回退 → 提交 → 等待终态。仅接受 ippDirect 级打印机。
  ///
  /// 路由决策由 [DocumentFormatNegotiator] 依打印机**此刻实时自报**的
  /// `document-format-supported` 作出（不使用宿主缓存的 probe 结果——
  /// 声明集权威必须是当下查询，宿主缓存可能过时）：
  /// 1. 声明集含 [PrintDocument.mimeType] → **直投**原格式（免栅格化，
  ///    保矢量与文本层；`document-format` 取打印机声明原样）；
  /// 2. 否则声明集含 `image/pwg-raster` → 栅格回退：[rasterizer] 必须注入
  ///    且文档须为 PDF（现管线唯一栅格化路径；非 PDF 文档无对应编码器，
  ///    如实拒绝不假装能处理）；
  /// 3. 否则抛 [IppPrintException]（缺≠支持，绝不推断）。
  ///
  /// `job-name` 取 [PrintDocument.name]，缺省 `ipp_print-document`。
  /// 能力查询限时 10s（同 [probe] 挂起防御），作业终态限时 [jobTimeout]。
  /// 进度流：直投 = sending → waitingPrinter → done（页数未知，如实不填）；
  /// 栅格回退 = rasterizing → encoding… → sending → waitingPrinter → done。
  Stream<PrintProgress> print({
    required PrintDocument document,
    required DiscoveredPrinter printer,
    PdfRasterizer? rasterizer,
    PrintOptions options = const PrintOptions(),
    Duration jobTimeout = const Duration(minutes: 5),
    int? dpi,
  }) async* {
    if (CapabilityClassifier.classify(printer.txt) !=
        PrinterCapability.ippDirect) {
      throw const IppPrintException(
          'printer is not IPP-direct capable (see probe())');
    }
    // 声明集实时查询（协商数据源）。整机限时 10s，超时如实抛出。
    final PrinterAttributes attrs;
    try {
      attrs = await _client
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
      final encoder = dpi == null ? _encoder : PwgRasterEncoder(dpi: dpi);
      yield const PrintProgress(PrintStage.rasterizing);
      final pwg = BytesBuilder(copy: false);
      // PWG 5102.4 Figure 1：同步字为文件级，整个文档只出现一次。
      pwg.add(encoder.syncWordBytes);
      var pageNo = 0;
      await for (final page
          in rasterizer.rasterize(document.bytes, dpi: dpi ?? _dpi)) {
        pageNo++;
        pwg.add(encoder.encodePage(page));
        yield PrintProgress(PrintStage.encoding, page: pageNo);
      }
      if (pageNo == 0) {
        throw const IppPrintException('rasterizer produced no pages');
      }
      yield* _submitAndAwait(
        printer,
        bytes: pwg.takeBytes(),
        documentFormat: decision.documentFormat,
        options: options,
        jobName: document.name ?? 'ipp_print-document',
        jobTimeout: jobTimeout,
        pageCount: pageNo,
      );
      return;
    }
    // 直投：文档字节原样提交（保矢量与文本层）。
    yield* _submitAndAwait(
      printer,
      bytes: Uint8List.fromList(document.bytes),
      documentFormat: decision.documentFormat,
      options: options,
      jobName: document.name ?? 'ipp_print-document',
      jobTimeout: jobTimeout,
    );
  }

  /// 提交作业并等待终态（print() 的公共尾部）。
  /// [pageCount] 仅栅格回退路径已知；直投路径如实为 null。
  Stream<PrintProgress> _submitAndAwait(
    DiscoveredPrinter printer, {
    required Uint8List bytes,
    required String documentFormat,
    required PrintOptions options,
    required String jobName,
    required Duration jobTimeout,
    int? pageCount,
  }) async* {
    yield const PrintProgress(PrintStage.sending);
    final jobId = await _client.submitJob(
      printer,
      document: bytes,
      documentFormat: documentFormat,
      options: options,
      jobName: jobName,
    );
    yield PrintProgress(PrintStage.waitingPrinter, jobId: jobId);
    final state = await _client.waitForTerminalState(
      printer,
      jobId,
      timeout: jobTimeout,
    );
    if (state != IppJobState.completed) {
      throw IppPrintException('job $jobId ended as ${state.name}');
    }
    yield PrintProgress(PrintStage.done, pageCount: pageCount, jobId: jobId);
  }

  /// PDF → 栅格 → PWG → IPP 直连打印（便利 API：等价于以
  /// `mimeType: 'application/pdf'` 调用 [print]）。
  ///
  /// 0.4 起内部转调 [print]：document-format 不再硬编码
  /// `image/pwg-raster`，而是取自打印机实时声明集（协商后的栅格回退路径）；
  /// 会先发起一次 Get-Printer-Attributes 查询（10s 限时）。
  ///
  /// [rasterizer] 由宿主 App 注入（如基于 printing.rasterPdf 的适配器），
  /// 插件本体不绑定渲染实现。
  ///
  /// [dpi] 覆盖构造时的默认 dpi（0.3.1）：栅格化与 PWG 页头
  /// `cupsHWResolution` / `PageSize` 换算随之改变。**取值应来自
  /// `PrinterInfo.resolutionsSupported` 的协商结果**——300dpi 并非
  /// 所有打印机声明支持（L3250 实测声明 360x360 / 1440x720），宽容
  /// 机型接受、严格机型可能拒收或异常渲染；null（默认）沿用构造值。
  Stream<PrintProgress> printPdf({
    required List<int> pdfBytes,
    required DiscoveredPrinter printer,
    required PdfRasterizer rasterizer,
    PrintOptions options = const PrintOptions(),
    Duration jobTimeout = const Duration(minutes: 5),
    int? dpi,
  }) {
    return print(
      document: PrintDocument(bytes: pdfBytes, mimeType: 'application/pdf'),
      printer: printer,
      rasterizer: rasterizer,
      options: options,
      jobTimeout: jobTimeout,
      dpi: dpi,
    );
  }

  /// 取消指定作业（透传 [IppClient.cancelJob]）。
  Future<void> cancelJob(DiscoveredPrinter printer, int jobId) =>
      _client.cancelJob(printer, jobId);

  /// 查询作业队列（透传 [IppClient.getJobs]，参数语义见其文档）。
  Future<List<IppJobSummary>> getJobs(
    DiscoveredPrinter printer, {
    bool myJobs = false,
    String whichJobs = 'not-completed',
    List<String>? requestedAttributes,
  }) =>
      _client.getJobs(
        printer,
        myJobs: myJobs,
        whichJobs: whichJobs,
        requestedAttributes: requestedAttributes,
      );
}
