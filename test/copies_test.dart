import 'dart:typed_data';

import 'package:ipp_print/src/document/print_document.dart';
import 'package:ipp_print/src/ipp/ipp_message.dart';
import 'package:ipp_print/src/ipp_print_core.dart';
import 'package:ipp_print/src/models.dart';
import 'package:ipp_print/src/pwg/pwg_raster_encoder.dart';
import 'package:test/test.dart';

import 'ipp_wire_fixtures.dart';

/// 份数（copies）端到端锚点 —— 0.7.4 缺陷修复。
///
/// 被测契约是**通用**的，与机型无关：
///  - CUPS 参考实现对流式光栅 `image/*` 与 `application/vnd.cups-raster`
///    **强制 `copies = 1`**，由上游过滤器预产副本
///    （cups/ppd-cache.c `_cupsConvertOptions` 注释原文 "Multi-page image
///    formats will have copies applied by the upstream filters"）；
///  - RFC 8011 §5.2.5：单文档 `copies=N` = N 份**完整副本**（collated Sets，
///    §2.3.10），客户端预产须整份重复页序；
///  - PWG 5100.14 Table 8 把 `copies` 列为 **REQUIRED** Job Template 属性 ——
///    声明支持却静默忽略属不合规，须客户端兜底。
///
/// 佐证（真机实测，仅佐证）：EPSON L3250（2026-09-12）自报
/// `copies-supported: 1..99`，对 `copies≥2` 的 Print-Job 与 Validate-Job
/// **一律**回 `successful-ok-ignored-or-substituted-attributes`（0x0001，
/// Unsupported Attributes 组列出 copies），作业计数 impressions=1 ——
/// 即「设 2 份只出 1 份」。其 PPD 亦声明 `*cupsManualCopies: True`。
///
/// 故本包在栅格回退路径把份数实现在**文档层**：整份页序重复 copies 次
/// （collated），下发属性 `copies` 恒为 1。以下锚点锁死该契约。
void main() {
  const encoder = PwgRasterEncoder();

  /// 单行 RGB 像素页（宽 = 字节数 / 3）。
  RasterPage page(List<int> rgb) => RasterPage(
        width: rgb.length ~/ 3,
        height: 1,
        bytes: Uint8List.fromList(rgb),
      );

  final red = page([255, 0, 0, 0, 255, 0]);

  DiscoveredPrinter discoveredPrinter() => DiscoveredPrinter(
        name: 'Generic IPP Printer',
        host: '127.0.0.1',
        port: 1,
        resourcePath: '/ipp/print',
        txt: const {
          'ty': 'Generic IPP Printer',
          'rp': 'ipp/print',
          'pdl': 'application/octet-stream,image/pwg-raster',
        },
      );

  /// 只声明 image/pwg-raster → 必然走栅格回退。
  final printerPwgOnly = resp(0, 0x04, [
    ...kw('document-format-supported', 'image/pwg-raster'),
  ]);

  /// 声明 application/pdf → 直投。
  final printerPdfOnly = resp(0, 0x04, [
    ...kw('document-format-supported', 'application/pdf'),
  ]);

  Uint8List printJobBody(FakeQueueClient c) =>
      c.bodies.singleWhere((b) => (b[2] << 8 | b[3]) == IppCodec.opPrintJob);

  /// 独立线格式步进器（不依赖被测解析代码）：读 job 属性 [name] 的
  /// integer 值；缺失返回 null。
  int? intAttrValue(List<int> body, String name) {
    var i = 8; // version(2) + op(2) + request-id(4)
    while (i < body.length) {
      final tag = body[i++];
      if (tag == 0x03) break; // end-of-attributes-tag
      if (tag <= 0x0F) continue; // group delimiter
      final nameLen = (body[i] << 8) | body[i + 1];
      i += 2;
      final attrName = String.fromCharCodes(body.sublist(i, i + nameLen));
      i += nameLen;
      final valueLen = (body[i] << 8) | body[i + 1];
      i += 2;
      if (attrName == name && tag == 0x21 && valueLen == 4) {
        return (body[i] << 24) |
            (body[i + 1] << 16) |
            (body[i + 2] << 8) |
            body[i + 3];
      }
      i += valueLen;
    }
    return null;
  }

  /// 独立线格式步进器（不依赖被测解析代码）：列出报文中的全部属性名。
  List<String> attributeNames(List<int> body) {
    final names = <String>[];
    var i = 8; // version(2) + op(2) + request-id(4)
    while (i < body.length) {
      final tag = body[i++];
      if (tag == 0x03) break; // end-of-attributes-tag
      if (tag <= 0x0F) continue; // group delimiter
      final nameLen = (body[i] << 8) | body[i + 1];
      i += 2;
      names.add(String.fromCharCodes(body.sublist(i, i + nameLen)));
      i += nameLen;
      final valueLen = (body[i] << 8) | body[i + 1];
      i += 2 + valueLen;
    }
    return names;
  }

  Future<Uint8List> submitWithCopies(int copies) async {
    final client = FakeQueueClient();
    client.enqueue(0x000B, printerPwgOnly);
    client.enqueue(0x0002, jobSubmitted);
    final ipp = IppPrint(client: client);
    await ipp.submit(
      document: PrintDocument(
        bytes: Uint8List.fromList([1, 2, 3]),
        mimeType: 'application/pdf',
      ),
      printer: discoveredPrinter(),
      rasterizer: _ListRasterizer([red, red]),
      ticket: PrintTicket(copies: copies),
    );
    return printJobBody(client);
  }

  group('栅格回退路径：份数在文档层实现', () {
    test('copies=2 → 页序重复 2 次（collated），下发属性 copies=1', () async {
      final body = await submitWithCopies(2);
      final block = encoder.encodePage(red);
      // 2 个源页 × 2 份 = 4 个页块，同步字仍只在文档开头出现一次。
      final expectedDoc = <int>[
        ...encoder.syncWordBytes,
        ...block,
        ...block,
        ...block,
        ...block,
      ];
      expect(body.sublist(body.length - expectedDoc.length), expectedDoc);
      // 关键不变量：份数已进文档，属性归一为 1（防与硬件份数重复计数）。
      expect(intAttrValue(body, 'copies'), 1);
    });

    test('copies=1 → 单份页序（与修复前逐字节一致）', () async {
      final body = await submitWithCopies(1);
      final block = encoder.encodePage(red);
      final expectedDoc = <int>[
        ...encoder.syncWordBytes,
        ...block,
        ...block,
      ];
      expect(body.sublist(body.length - expectedDoc.length), expectedDoc);
      expect(intAttrValue(body, 'copies'), 1);
    });

    test('copies=0/负值 → 归一为 1，绝不产出只有同步字的空文档', () async {
      final body = await submitWithCopies(0);
      final block = encoder.encodePage(red);
      final expectedDoc = <int>[
        ...encoder.syncWordBytes,
        ...block,
        ...block,
      ];
      expect(body.sublist(body.length - expectedDoc.length), expectedDoc);
      expect(intAttrValue(body, 'copies'), 1);
    });

    test('默认 ticket（copies 未指定）→ 单份', () async {
      final client = FakeQueueClient();
      client.enqueue(0x000B, printerPwgOnly);
      client.enqueue(0x0002, jobSubmitted);
      final ipp = IppPrint(client: client);
      await ipp.submit(
        document: PrintDocument(
          bytes: Uint8List.fromList([1, 2, 3]),
          mimeType: 'application/pdf',
        ),
        printer: discoveredPrinter(),
        rasterizer: _ListRasterizer([red, red]),
      );
      final body = printJobBody(client);
      final block = encoder.encodePage(red);
      final expectedDoc = <int>[
        ...encoder.syncWordBytes,
        ...block,
        ...block,
      ];
      expect(body.sublist(body.length - expectedDoc.length), expectedDoc);
      expect(intAttrValue(body, 'copies'), 1);
    });
  });

  group('直投路径：份数原样下发（刻意不对称）', () {
    test('PDF 直投 copies=2 → 属性 copies=2，文档字节未被复制', () async {
      final client = FakeQueueClient();
      client.enqueue(0x000B, printerPdfOnly);
      client.enqueue(0x0002, jobSubmitted);
      final ipp = IppPrint(client: client);
      const pdf = <int>[0x25, 0x50, 0x44, 0x46]; // %PDF
      await ipp.submit(
        document: PrintDocument(
          bytes: Uint8List.fromList(pdf),
          mimeType: 'application/pdf',
        ),
        printer: discoveredPrinter(),
        ticket: const PrintTicket(copies: 2),
      );
      final body = printJobBody(client);
      // 直投不下压份数：客户端无从在 PDF 内预产副本，交由打印机 RIP
      // 按 RFC 8011 §5.2.5 处理（已知边界，见 README 诚实清单）。
      expect(intAttrValue(body, 'copies'), 2);
      expect(body.sublist(body.length - pdf.length), pdf);
    });
  });

  // ── _withCopies 的字段完整性 ──────────────────────────────
  // 栅格路径经 `_withCopies` 重建 PrintOptions（把 copies 归一为 1）。该辅助
  // 函数**手工罗列全部字段**（模型无 copyWith），一旦模型新增字段而此处漏改，
  // 新字段会在栅格路径**静默丢弃**——与 0.7.4 的 `0x0001` 静默忽略同族，
  // 且正属本项目头号缺陷类（声明层 vs 实现层脱节）。
  // 本锚点锁死：全部非份数属性在**栅格与直投两条路径**都必须存活。
  test('两条路径均不得丢失任何非份数作业属性（_withCopies 字段完整性）', () async {
    const ticket = PrintTicket(
      copies: 3,
      media: 'iso_a4_210x297mm',
      colorMode: 'monochrome',
      sides: 'two-sided-long-edge',
      resolution: '300x300dpi',
      fidelity: PrintFidelity.exact,
      printQuality: 4,
    );
    const expected = <String>[
      'media',
      'print-color-mode',
      'sides',
      'printer-resolution',
      'ipp-attribute-fidelity',
      'print-quality',
    ];

    final rasterClient = FakeQueueClient();
    rasterClient.enqueue(0x000B, printerPwgOnly);
    rasterClient.enqueue(0x0002, jobSubmitted);
    await IppPrint(client: rasterClient).submit(
      document: PrintDocument(
        bytes: Uint8List.fromList([1, 2, 3]),
        mimeType: 'application/pdf',
      ),
      printer: discoveredPrinter(),
      rasterizer: _ListRasterizer([red, red]),
      ticket: ticket,
    );
    final rasterNames = attributeNames(printJobBody(rasterClient));
    for (final name in expected) {
      expect(rasterNames, contains(name),
          reason: '栅格路径丢失 job 属性 $name —— _withCopies 漏抄了它？');
    }
    // 本锚点不放松 0.7.4 契约：份数仍当归一为 1。
    expect(intAttrValue(printJobBody(rasterClient), 'copies'), 1);

    final directClient = FakeQueueClient();
    directClient.enqueue(0x000B, printerPdfOnly);
    directClient.enqueue(0x0002, jobSubmitted);
    await IppPrint(client: directClient).submit(
      document: PrintDocument(
        bytes: Uint8List.fromList([0x25, 0x50, 0x44, 0x46]),
        mimeType: 'application/pdf',
      ),
      printer: discoveredPrinter(),
      ticket: ticket,
    );
    final directNames = attributeNames(printJobBody(directClient));
    for (final name in expected) {
      expect(directNames, contains(name), reason: '直投路径丢失 job 属性 $name');
    }
    expect(intAttrValue(printJobBody(directClient), 'copies'), 3);
  });
}

class _ListRasterizer implements PdfRasterizer {
  _ListRasterizer(this.pages);

  final List<RasterPage> pages;

  @override
  Stream<RasterPage> rasterize(List<int> pdfBytes, {int dpi = 300}) async* {
    for (final p in pages) {
      yield p;
    }
  }
}
