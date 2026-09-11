import 'dart:async' show TimeoutException;
import 'dart:io' show SocketException;
import 'dart:typed_data';

import 'capability/capability.dart';
import 'discovery/native_bonjour_discovery.dart' show defaultPlatformDiscovery;
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
      final ok = formats.isEmpty ||
          formats.any((f) => f.toLowerCase().contains('pwg-raster'));
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
  Future<PrintValidationResult> validateJob(
    DiscoveredPrinter printer, {
    required String documentFormat,
    PrintOptions options = const PrintOptions(),
    String jobName = 'ipp_print-document',
  }) =>
      _client.validateJob(
        printer,
        documentFormat: documentFormat,
        options: options,
        jobName: jobName,
      );

  /// PDF → 栅格 → PWG → IPP 直连打印。仅接受 ippDirect 级打印机。
  ///
  /// [rasterizer] 由宿主 App 注入（如基于 printing.rasterPdf 的适配器），
  /// 插件本体不绑定渲染实现。
  Stream<PrintProgress> printPdf({
    required List<int> pdfBytes,
    required DiscoveredPrinter printer,
    required PdfRasterizer rasterizer,
    PrintOptions options = const PrintOptions(),
    Duration jobTimeout = const Duration(minutes: 5),
  }) async* {
    if (CapabilityClassifier.classify(printer.txt) !=
        PrinterCapability.ippDirect) {
      throw const IppPrintException(
          'printer is not IPP-direct capable (see probe())');
    }
    yield const PrintProgress(PrintStage.rasterizing);
    final document = BytesBuilder(copy: false);
    // PWG 5102.4 Figure 1：同步字为文件级，整个文档只出现一次。
    document.add(_encoder.syncWordBytes);
    var pageNo = 0;
    await for (final page in rasterizer.rasterize(pdfBytes, dpi: _dpi)) {
      pageNo++;
      document.add(_encoder.encodePage(page));
      yield PrintProgress(PrintStage.encoding, page: pageNo);
    }
    if (pageNo == 0) {
      throw const IppPrintException('rasterizer produced no pages');
    }
    yield const PrintProgress(PrintStage.sending);
    final jobId = await _client.submitJob(
      printer,
      document: document.takeBytes(),
      documentFormat: 'image/pwg-raster',
      options: options,
      jobName: 'ipp_print-document',
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
    yield PrintProgress(PrintStage.done, pageCount: pageNo, jobId: jobId);
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
