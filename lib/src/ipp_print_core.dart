import 'dart:io' show SocketException;
import 'dart:typed_data';

import 'capability/capability.dart';
import 'discovery/mdns_discovery.dart';
import 'ipp/ipp_client.dart';
import 'models.dart';
import 'pwg/pwg_raster_encoder.dart';

/// Facade：插件唯一入口。
///
/// 职责边界（见 README）：发现 + 分类 + 传输；无 UI、无持久化、
/// 不接管 airPrint 级机型（交还系统打印面板）。
class IppPrint {
  IppPrint({PrinterDiscovery? discovery, IppClient? client, int dpi = 300})
      : _discovery = discovery ?? MDnsPrinterDiscovery(),
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
      final attrs = await _client.getPrinterAttributes(printer);
      final formats = attrs.documentFormats;
      final ok = formats.isEmpty ||
          formats.any((f) => f.toLowerCase().contains('pwg-raster'));
      final info = PrinterInfo(
        capability: ok ? PrinterCapability.ippDirect : PrinterCapability.vendorOnly,
        mediaSupported: attrs.mediaSupported,
        documentFormats: formats,
        state: attrs.state,
        makeModel: attrs.makeModel,
      );
      onInfo?.call(info);
      return ok ? PrinterProbeStatus.ready : PrinterProbeStatus.unsupported;
    } on SocketException {
      return PrinterProbeStatus.offline;
    } on IppPrintException {
      return PrinterProbeStatus.unsupported;
    }
  }

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
