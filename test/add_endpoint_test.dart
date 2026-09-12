import 'dart:typed_data';

import 'package:ipp_print/src/document/print_document.dart';
import 'package:ipp_print/src/ipp_print_core.dart';
import 'package:ipp_print/src/models.dart';
import 'package:test/test.dart';

import 'ipp_wire_fixtures.dart';

/// 0.7 addEndpoint（手动直连）：发现不到 ≠ 不能打印。
///
/// 契约要点：
/// - URI 本身即 IPP endpoint 存在性证据（用户断言）——**绕过 TXT 分类
///   否定门**，能力判定交给 probe / print 的实时查询 + 协商器（probe 驱动）；
/// - 端点解析诚实：scheme 白名单、无 query/fragment、缺省端口按
///   RFC 8010 §4.1 / RFC 7472（ipp/ipps = 631）与 HTTP 标准（80/443）；
/// - 非 manual 的发现打印机仍受 TXT 门约束（既有锚点不放松）。
void main() {
  group('addEndpoint URI 解析（诚实解析，不猜）', () {
    test('ipp://host:631/ipp/print → 明文字段齐备，manualEndpoint=true', () {
      final p = IppPrint().addEndpoint(
        Uri.parse('ipp://192.168.1.50:631/ipp/print'),
        name: '书房打印机',
      );
      expect(p.host, '192.168.1.50');
      expect(p.port, 631);
      expect(p.resourcePath, '/ipp/print');
      expect(p.secure, isFalse);
      expect(p.manualEndpoint, isTrue);
      expect(p.name, '书房打印机');
      expect(p.ippUriString, 'ipp://192.168.1.50:631/ipp/print');
      expect(p.httpUriString, 'http://192.168.1.50:631/ipp/print');
    });

    test('ipps:// → secure，HTTP 通道走 https', () {
      final p = IppPrint()
          .addEndpoint(Uri.parse('ipps://192.168.1.50:443/ipp/print'));
      expect(p.secure, isTrue);
      expect(p.ippUriString, 'ipps://192.168.1.50:443/ipp/print');
      expect(p.httpUri.scheme, 'https');
      expect(p.name, contains('192.168.1.50'));
    });

    test('缺省端口：ipp/ipps = 631（RFC 8010 §4.1 / RFC 7472），http/https = 80/443', () {
      expect(
          IppPrint()
              .addEndpoint(Uri.parse('ipp://192.168.1.50/ipp/print'))
              .port,
          631);
      expect(
          IppPrint()
              .addEndpoint(Uri.parse('ipps://192.168.1.50/ipp/print'))
              .port,
          631);
      expect(
          IppPrint().addEndpoint(Uri.parse('http://192.168.1.50/ipp')).port,
          80);
      expect(
          IppPrint().addEndpoint(Uri.parse('https://192.168.1.50/ipp')).port,
          443);
    });

    test('空路径 → /（根端点合法， viability 交协商器）', () {
      final p = IppPrint().addEndpoint(Uri.parse('ipp://192.168.1.50:631'));
      expect(p.resourcePath, '/');
    });

    test('非 IPP/HTTP scheme 与 query/fragment 如实拒绝（不猜端点）', () {
      final ipp = IppPrint();
      expect(() => ipp.addEndpoint(Uri.parse('ftp://192.168.1.50/ipp/print')),
          throwsA(isA<IppPrintException>()));
      expect(() => ipp.addEndpoint(Uri.parse('ipp://192.168.1.50/ipp?x=1')),
          throwsA(isA<IppPrintException>()));
      expect(() => ipp.addEndpoint(Uri.parse('ipp:///ipp/print')),
          throwsA(isA<IppPrintException>()));
    });
  });

  group('manual 端点绕过 TXT 分类门（probe 驱动能力路径）', () {
    late FakeQueueClient client;
    late IppPrint ipp;
    late DiscoveredPrinter manual;

    setUp(() {
      client = FakeQueueClient();
      ipp = IppPrint(client: client);
      manual = ipp.addEndpoint(
        Uri.parse('ipp://192.168.1.50:631/ipp/print'),
        name: '书房打印机',
      );
    });

    test('probe：TXT 为空仍发起实时查询（manual 豁免 unknown 否定门）→ ready',
        () async {
      client.enqueue(0x000B, printerPwgPdf);
      final status = await ipp.probe(manual);
      expect(status, PrinterProbeStatus.ready);
      expect(client.operations, [0x000B]);
    });

    test('probe：manual 不放松能力判据——仅声明 pdf 仍如实 unsupported',
        () async {
      // 豁免的只是 TXT 分类否定门；ready 判据（声明集含 pwg-raster）
      // 对 manual 端点同样生效——manual ≠ 万能放行。
      client.enqueue(0x000B, printerPdf);
      final status = await ipp.probe(manual);
      expect(status, PrinterProbeStatus.unsupported);
    });

    test('submit：门不再拒（endpoint 存在性由用户断言）→ 实时协商 → 提交',
        () async {
      client.enqueue(0x000B, printerPdf);
      client.enqueue(0x0002, jobSubmitted);
      final job = await ipp.submit(
        document: PrintDocument(
          bytes: Uint8List.fromList([1, 2, 3]),
          mimeType: 'application/pdf',
        ),
        printer: manual,
      );
      expect(job.jobId, 42);
      expect(client.operations, [0x000B, 0x0002]);
    });

    test('发现打印机空 TXT 仍被门拒绝（manual 豁免不外溢）', () async {
      final discovered = DiscoveredPrinter(
        name: 'no-txt',
        host: '10.0.0.9',
        port: 631,
        resourcePath: '/ipp/print',
      );
      await expectLater(
        ipp.submit(
          document: PrintDocument(
            bytes: Uint8List.fromList([1]),
            mimeType: 'application/pdf',
          ),
        printer: discovered,
        ),
        throwsA(isA<IppUnsupportedException>()),
      );
      expect(client.operations, isEmpty);
    });
  });
}
