import 'dart:typed_data';

import 'package:ipp_print/src/document/print_document.dart';
import 'package:ipp_print/src/ipp/ipp_client.dart';
import 'package:ipp_print/src/ipp/ipp_message.dart';
import 'package:ipp_print/src/ipp_print_core.dart';
import 'package:ipp_print/src/models.dart';
import 'package:test/test.dart';

/// 可注入的假 IppClient：按 operation-id 返回固定响应，并捕获请求体。
class FakeIppClient extends IppClient {
  FakeIppClient(this.responses);

  final Map<int, Uint8List> responses;
  final operations = <int>[];
  final bodies = <Uint8List>[];

  @override
  Future<IppResponse> post(Uri httpEndpoint, Uint8List ippBody) async {
    final op = (ippBody[2] << 8) | ippBody[3];
    operations.add(op);
    bodies.add(ippBody);
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

class _FakeDiscovery implements PrinterDiscovery {
  @override
  Future<List<DiscoveredPrinter>> discover({
    Duration timeout = const Duration(seconds: 5),
  }) async =>
      const [];
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

final _jobDone = _resp(0, 0x02, [
  ..._intAttr('job-id', 42),
  ..._intAttr('job-state', 9), // RFC 8011: 9 = completed
]);
final _printerPwg = _resp(0, 0x04, [
  ..._kwAttr('document-format-supported', 'image/pwg-raster'),
]);
final _printerPdf = _resp(0, 0x04, [
  ..._kwAttr('document-format-supported', 'application/pdf'),
]);
final _printerEscprOnly = _resp(0, 0x04, [
  ..._kwAttr('document-format-supported', 'application/vnd.epson.escpr'),
]);

List<int> _kwAttr(String name, String value) {
  final nb = name.codeUnits;
  final vb = value.codeUnits;
  return [
    0x44, (nb.length >> 8) & 0xFF, nb.length & 0xFF, ...nb,
    (vb.length >> 8) & 0xFF, vb.length & 0xFF, ...vb,
  ];
}

List<int> _intAttr(String name, int v) {
  final nb = name.codeUnits;
  return [
    0x21, (nb.length >> 8) & 0xFF, nb.length & 0xFF, ...nb, 0, 4,
    (v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF,
  ];
}

const _l3250Txt = {
  'ty': 'EPSON L3250 Series',
  'rp': 'ipp/print',
  'pdl': 'application/octet-stream,image/pwg-raster,'
      'application/vnd.epson.escpr',
};

DiscoveredPrinter _printer(Map<String, String> txt) => DiscoveredPrinter(
      name: 'EPSON L3250 Series',
      host: '192.168.0.106',
      port: 631,
      resourcePath: '/ipp/print',
      txt: txt,
    );

void main() {
  group('print（Document Pipeline 通用入口，0.4）', () {
    test('直投：声明 PDF → 原样提交，不经栅格化（保矢量）', () async {
      final client = FakeIppClient({
        IppCodec.opGetPrinterAttributes: _printerPdf,
        IppCodec.opPrintJob: _jobDone,
        IppCodec.opGetJobAttributes: _jobDone,
      });
      final ipp = IppPrint(discovery: _FakeDiscovery(), client: client);
      const pdfBytes = <int>[0x25, 0x50, 0x44, 0x46, 0x2D, 0x31]; // %PDF-1
      final doc = PrintDocument(
          bytes: pdfBytes, mimeType: 'application/pdf', name: 'my-doc');
      final events = <PrintProgress>[];
      await for (final p in ipp.print(
        document: doc,
        printer: _printer(_l3250Txt),
        jobTimeout: const Duration(seconds: 2),
      )) {
        events.add(p);
      }
      // 直投无栅格化/编码阶段；页数未知 → done 如实不带 pageCount。
      expect(events.map((e) => e.stage).toList(),
          [PrintStage.sending, PrintStage.waitingPrinter, PrintStage.done]);
      expect(events.last.pageCount, isNull);
      expect(events.last.jobId, 42);
      // wire 断言：document-format 取自打印机声明集；job-name 用文档名。
      final jobBody = client.bodies
          .singleWhere((b) => (b[2] << 8 | b[3]) == IppCodec.opPrintJob);
      final wire = String.fromCharCodes(jobBody);
      expect(wire, contains('application/pdf'));
      expect(wire, contains('my-doc'));
      // 文档字节原样附在 IPP 报文之后（Print-Job = 消息 + 文档）。
      expect(jobBody.sublist(jobBody.length - pdfBytes.length), pdfBytes);
    });

    test('栅格回退：L3250 型声明集（无 PDF）→ 转 PWG 栅格提交', () async {
      final client = FakeIppClient({
        IppCodec.opGetPrinterAttributes: _printerPwg,
        IppCodec.opPrintJob: _jobDone,
        IppCodec.opGetJobAttributes: _jobDone,
      });
      final ipp = IppPrint(discovery: _FakeDiscovery(), client: client);
      final rasterizer = StaticRasterizer(RasterPage(
          width: 2, height: 1, bytes: Uint8List.fromList([255, 0, 0, 255, 0, 0])));
      final events = <PrintProgress>[];
      await for (final p in ipp.print(
        document: PrintDocument(
            bytes: const [0x25, 0x50, 0x44, 0x46],
            mimeType: 'application/pdf'),
        printer: _printer(_l3250Txt),
        rasterizer: rasterizer,
        jobTimeout: const Duration(seconds: 2),
      )) {
        events.add(p);
      }
      expect(events.map((e) => e.stage).toList(), [
        PrintStage.rasterizing,
        PrintStage.encoding,
        PrintStage.sending,
        PrintStage.waitingPrinter,
        PrintStage.done,
      ]);
      expect(events.last.pageCount, 1);
      expect(rasterizer.callCount, 1);
      final jobBody = client.bodies
          .singleWhere((b) => (b[2] << 8 | b[3]) == IppCodec.opPrintJob);
      expect(String.fromCharCodes(jobBody), contains('image/pwg-raster'));
    });

    test('栅格回退但未注入 rasterizer → 明确拒绝，不发 Print-Job', () async {
      final client = FakeIppClient({
        IppCodec.opGetPrinterAttributes: _printerPwg,
      });
      final ipp = IppPrint(discovery: _FakeDiscovery(), client: client);
      await expectLater(
        ipp
            .print(
              document: PrintDocument(
                  bytes: const [0x25, 0x50, 0x44, 0x46],
                  mimeType: 'application/pdf'),
              printer: _printer(_l3250Txt),
            )
            .drain<void>(),
        throwsA(isA<IppPrintException>()),
      );
      expect(client.operations, [IppCodec.opGetPrinterAttributes]);
    });

    test('非 PDF 文档走栅格回退 → 拒绝（现管线只能栅格化 PDF，不假装能处理）',
        () async {
      final client = FakeIppClient({
        IppCodec.opGetPrinterAttributes: _printerPwg,
      });
      final ipp = IppPrint(discovery: _FakeDiscovery(), client: client);
      await expectLater(
        ipp
            .print(
              document: PrintDocument(
                  bytes: const [0xFF, 0xD8, 0xFF], mimeType: 'image/jpeg'),
              printer: _printer(_l3250Txt),
              rasterizer: StaticRasterizer(RasterPage(
                  width: 1, height: 1, bytes: Uint8List.fromList([0, 0, 0]))),
            )
            .drain<void>(),
        throwsA(isA<IppPrintException>()),
      );
      expect(client.operations, [IppCodec.opGetPrinterAttributes]);
    });

    test('声明集与文档无交集 → 拒绝（缺≠支持，绝不推断）', () async {
      final client = FakeIppClient({
        IppCodec.opGetPrinterAttributes: _printerEscprOnly,
      });
      final ipp = IppPrint(discovery: _FakeDiscovery(), client: client);
      await expectLater(
        ipp
            .print(
              document: PrintDocument(
                  bytes: const [0x25, 0x50, 0x44, 0x46],
                  mimeType: 'application/pdf'),
              printer: _printer(_l3250Txt),
              rasterizer: StaticRasterizer(RasterPage(
                  width: 1, height: 1, bytes: Uint8List.fromList([0, 0, 0]))),
            )
            .drain<void>(),
        throwsA(isA<IppPrintException>()),
      );
      expect(client.operations, [IppCodec.opGetPrinterAttributes]);
    });

    test('TXT 无 IPP 证据（unknown）→ 拒绝，不发任何请求（0.5 Gate 事实化）',
        () async {
      final client = FakeIppClient({});
      final ipp = IppPrint(discovery: _FakeDiscovery(), client: client);
      await expectLater(
        ipp
            .print(
              document: PrintDocument(
                  bytes: const [1], mimeType: 'application/pdf'),
              printer: _printer({'ty': 'Some Printer'}),
              rasterizer: StaticRasterizer(RasterPage(
                  width: 1, height: 1, bytes: Uint8List.fromList([0, 0, 0]))),
            )
            .drain<void>(),
        throwsA(isA<IppUnsupportedException>()),
      );
      expect(client.operations, isEmpty);
    });

    test('vendorOnly（仅声明 escpr）+ 打印机声明 PDF → PDF 直投放行'
        '（0.5 Gate 事实化：IPP+PDF 设备不再整包拒绝）', () async {
      final client = FakeIppClient({
        IppCodec.opGetPrinterAttributes: _printerPdf,
        IppCodec.opPrintJob: _jobDone,
        IppCodec.opGetJobAttributes: _jobDone,
      });
      final ipp = IppPrint(discovery: _FakeDiscovery(), client: client);
      final events = <PrintProgress>[];
      await for (final p in ipp.print(
        document: PrintDocument(
            bytes: const [0x25, 0x50, 0x44, 0x46],
            mimeType: 'application/pdf'),
        printer: _printer(
            {'pdl': 'application/vnd.epson.escpr', 'rp': 'ipp/print'}),
        jobTimeout: const Duration(seconds: 2),
      )) {
        events.add(p);
      }
      expect(events.map((e) => e.stage).toList(),
          [PrintStage.sending, PrintStage.waitingPrinter, PrintStage.done]);
      final jobBody = client.bodies
          .singleWhere((b) => (b[2] << 8 | b[3]) == IppCodec.opPrintJob);
      expect(String.fromCharCodes(jobBody), contains('application/pdf'));
    });
  });
}
