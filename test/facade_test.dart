import 'dart:async';
import 'dart:typed_data';

import 'package:ipp_print/src/ipp/ipp_client.dart';
import 'package:ipp_print/src/ipp/ipp_message.dart';
import 'package:ipp_print/src/ipp_print_core.dart';
import 'package:ipp_print/src/models.dart';
import 'package:test/test.dart';

/// 可注入的假 IppClient：按 operation-id 返回固定响应。
class FakeIppClient extends IppClient {
  FakeIppClient(this.responses);

  /// operation-id → 响应报文
  final Map<int, Uint8List> responses;
  final operations = <int>[];

  @override
  Future<IppResponse> post(Uri httpEndpoint, Uint8List ippBody) async {
    final op = (ippBody[2] << 8) | ippBody[3];
    operations.add(op);
    final response = responses[op];
    if (response == null) {
      throw IppPrintException('unexpected op 0x${op.toRadixString(16)}');
    }
    return IppCodec.parseResponse(response);
  }
}

class StaticRasterizer implements PdfRasterizer {
  StaticRasterizer(this.page);
  final RasterPage page;
  var callCount = 0;

  @override
  Stream<RasterPage> rasterize(List<int> pdfBytes, {int dpi = 300}) async* {
    callCount++;
    yield page;
  }
}

/// 手工构造 IPP 响应（独立于被测代码的编码路径）。
Uint8List _resp(int status, int groupTag, List<int> attrs) {
  List<int> attr(int tag, String name, List<int> value) {
    final nb = name.codeUnits;
    return [
      tag,
      (nb.length >> 8) & 0xFF, nb.length & 0xFF, ...nb,
      (value.length >> 8) & 0xFF, value.length & 0xFF, ...value,
    ];
  }

  List<int> s(String v) => v.codeUnits;
  return Uint8List.fromList([
    0x01, 0x01, (status >> 8) & 0xFF, status & 0xFF, 0, 0, 0, 1, //
    0x01,
    ...attr(0x47, 'attributes-charset', s('utf-8')),
    ...attr(0x48, 'attributes-natural-language', s('en')),
    groupTag,
    ...attrs,
    0x03,
  ]);
}

const _l3250Txt = {
  'ty': 'EPSON L3250 Series',
  'rp': 'ipp/print',
  'pdl': 'application/octet-stream,image/pwg-raster,'
      'application/vnd.epson.escpr',
};

DiscoveredPrinter _printer(Map<String, String> txt) =>
    DiscoveredPrinter(
      name: 'EPSON L3250 Series',
      host: '192.168.0.106',
      port: 631,
      resourcePath: '/ipp/print',
      txt: txt,
    );

void main() {
  final printOk = _resp(0, 0x02, [
    ..._respAttr('job-id', 42),
    ..._respEnum('job-state', 9), // RFC 8011: 9 = completed
  ]);
  final printerOk = _resp(0, 0x04, [
    ..._respKw('media-supported', 'iso_a4_210x297mm'),
    ..._respKw('document-format-supported', 'image/pwg-raster'),
    ..._respKw('print-color-mode-supported', 'monochrome'),
    ..._respKw('print-color-mode-default', 'monochrome'),
    ..._respKw('sides-supported', 'one-sided'),
    ..._respKw('sides-default', 'one-sided'),
    ..._respRes('printer-resolution-supported', 360, 360),
    ..._respRes('printer-resolution-default', 360, 360),
  ]);
  final printerNoPwg = _resp(0, 0x04, [
    ..._respKw('document-format-supported', 'application/octet-stream'),
  ]);

  test('probe：ippDirect 级 + IPP 查询确认 pwg-raster → ready', () async {
    final client = FakeIppClient({
      IppCodec.opGetPrinterAttributes: printerOk,
    });
    final ipp = IppPrint(discovery: _FakeDiscovery(), client: client);
    PrinterInfo? info;
    final status = await ipp.probe(_printer(_l3250Txt),
        onInfo: (i) => info = i);
    expect(status, PrinterProbeStatus.ready);
    expect(info!.mediaSupported, ['iso_a4_210x297mm']);
    // 能力协商透出：宿主 UI 据此生成色彩/双面可选项
    expect(info!.colorModesSupported, ['monochrome']);
    expect(info!.colorModeDefault, 'monochrome');
    expect(info!.sidesSupported, ['one-sided']);
    expect(info!.sidesDefault, 'one-sided');
    // 0.3.1：分辨率协商数据源透出（宿主据此选栅格 dpi）
    expect(info!.resolutionsSupported, ['360x360dpi']);
    expect(info!.resolutionDefault, '360x360dpi');
  });

  test('probe：TXT 判 ippDirect 但 IPP 不支持 pwg-raster → 降级', () async {
    final client = FakeIppClient({
      IppCodec.opGetPrinterAttributes: printerNoPwg,
    });
    final ipp = IppPrint(discovery: _FakeDiscovery(), client: client);
    final status = await ipp.probe(_printer(_l3250Txt));
    expect(status, PrinterProbeStatus.unsupported);
  });

  test('probe：airPrint 级不发起任何网络请求', () async {
    final client = FakeIppClient({});
    final ipp = IppPrint(discovery: _FakeDiscovery(), client: client);
    final status = await ipp.probe(_printer({'URF': 'DM3', 'rp': 'ipp/print'}));
    expect(status, PrinterProbeStatus.ready);
    expect(client.operations, isEmpty);
  });

  test('printPdf：栅格 → 编码 → 提交 → 终态 done（进度流完整）', () async {
    final client = FakeIppClient({
      IppCodec.opPrintJob: printOk,
      IppCodec.opGetJobAttributes: printOk,
    });
    final ipp = IppPrint(discovery: _FakeDiscovery(), client: client);
    final red = Uint8List.fromList([255, 0, 0, 255, 0, 0]);
    final rasterizer = StaticRasterizer(
        RasterPage(width: 2, height: 1, bytes: red));

    final stages = <PrintStage>[];
    await for (final p in ipp.printPdf(
      pdfBytes: const [0x25, 0x50, 0x44, 0x46],
      printer: _printer(_l3250Txt),
      rasterizer: rasterizer,
      jobTimeout: const Duration(seconds: 2),
    )) {
      stages.add(p.stage);
    }
    expect(stages, [
      PrintStage.rasterizing,
      PrintStage.encoding,
      PrintStage.sending,
      PrintStage.waitingPrinter,
      PrintStage.done,
    ]);
    expect(rasterizer.callCount, 1);
  });

  test('printPdf：非直连机型直接拒绝（不会误投厂商私有格式）', () async {
    final client = FakeIppClient({});
    final ipp = IppPrint(discovery: _FakeDiscovery(), client: client);
    await expectLater(
      ipp
          .printPdf(
            pdfBytes: const [1],
            printer: _printer({'pdl': 'application/vnd.epson.escpr',
              'rp': 'ipp/print'}),
            rasterizer: StaticRasterizer(RasterPage(
                width: 1, height: 1, bytes: Uint8List.fromList([0, 0, 0]))),
          )
          .drain<void>(),
      throwsA(isA<IppPrintException>()),
    );
    expect(client.operations, isEmpty);
  });
}

// —— 测试辅助：属性字节拼装（与 FakeIppClient 响应构造配套）——

List<int> _respAttr(String name, int v) {
  final nb = name.codeUnits;
  return [
    0x21, (nb.length >> 8) & 0xFF, nb.length & 0xFF, ...nb, 0, 4,
    (v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF,
  ];
}

List<int> _respEnum(String name, int v) => _respAttr(name, v)
    .map((b) => b)
    .toList()
  ..[0] = 0x23;

List<int> _respKw(String name, String value) {
  final nb = name.codeUnits;
  final vb = value.codeUnits;
  return [
    0x44, (nb.length >> 8) & 0xFF, nb.length & 0xFF, ...nb,
    (vb.length >> 8) & 0xFF, vb.length & 0xFF, ...vb,
  ];
}

/// resolution 语法属性（RFC 8011 §5.1.14：cross(i32)+feed(i32)+unit，
/// 3=dpi，共 9 字节值）。
List<int> _respRes(String name, int cross, int feed) {
  final nb = name.codeUnits;
  return [
    0x35, (nb.length >> 8) & 0xFF, nb.length & 0xFF, ...nb, 0, 9,
    (cross >> 24) & 0xFF, (cross >> 16) & 0xFF, (cross >> 8) & 0xFF, cross,
    (feed >> 24) & 0xFF, (feed >> 16) & 0xFF, (feed >> 8) & 0xFF, feed,
    3,
  ];
}

class _FakeDiscovery implements PrinterDiscovery {
  @override
  Future<List<DiscoveredPrinter>> discover({
    Duration timeout = const Duration(seconds: 5),
  }) async =>
      const [];
}
