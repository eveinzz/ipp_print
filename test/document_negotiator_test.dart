import 'package:ipp_print/src/document/document_encoder.dart';
import 'package:ipp_print/src/document/document_format_negotiator.dart';
import 'package:ipp_print/src/document/print_document.dart';
import 'package:ipp_print/src/models.dart';
import 'package:ipp_print/src/pwg/pwg_raster_encoder.dart';
import 'package:test/test.dart';

/// L3250 真机自报（2026-09-11 inspect）：**不含 application/pdf**。
const _l3250Formats = <String>[
  'application/octet-stream',
  'image/pwg-raster',
  'application/vnd.epson.escpr',
];

void main() {
  const negotiator = DocumentFormatNegotiator();

  group('DocumentFormatNegotiator', () {
    test('打印机声明 PDF → 直投原格式（passthrough）', () {
      const doc = PrintDocument(
          bytes: [0x25, 0x50, 0x44, 0x46], mimeType: 'application/pdf');
      final d = negotiator.negotiate(
        document: doc,
        printerFormats: const ['application/pdf', 'image/pwg-raster'],
      );
      expect(d.passthrough, isTrue);
      expect(d.documentFormat, 'application/pdf');
    });

    test('L3250 真机声明集（无 PDF）+ PDF 文档 → 回退 PWG 栅格', () {
      const doc = PrintDocument(
          bytes: [0x25, 0x50, 0x44, 0x46], mimeType: 'application/pdf');
      final d = negotiator.negotiate(
        document: doc,
        printerFormats: _l3250Formats,
      );
      expect(d.passthrough, isFalse);
      expect(d.documentFormat, DocumentFormatNegotiator.pwgRaster);
    });

    test('打印机同时声明原格式与 PWG → 原格式优先（免栅格化）', () {
      const doc = PrintDocument(bytes: [1], mimeType: 'image/jpeg');
      final d = negotiator.negotiate(
        document: doc,
        printerFormats: const ['image/jpeg', 'image/pwg-raster'],
      );
      expect(d.passthrough, isTrue);
      expect(d.documentFormat, 'image/jpeg');
    });

    test('空声明集 → 拒绝（缺≠支持，绝不推断）', () {
      const doc = PrintDocument(bytes: [1], mimeType: 'application/pdf');
      expect(
        () => negotiator.negotiate(document: doc, printerFormats: const []),
        throwsA(isA<IppPrintException>()),
      );
    });

    test('无任何共同格式 → 拒绝并透出打印机声明集', () {
      const doc = PrintDocument(bytes: [1], mimeType: 'application/pdf');
      try {
        negotiator.negotiate(
          document: doc,
          printerFormats: const ['application/vnd.epson.escpr'],
        );
        fail('should have thrown');
      } on IppPrintException catch (e) {
        expect(e.message.contains('application/vnd.epson.escpr'), isTrue);
      }
    });

    test('MIME 比较大小写不敏感（厂商实现各异，L3250 教训）', () {
      const doc = PrintDocument(bytes: [1], mimeType: 'APPLICATION/PDF');
      final d = negotiator.negotiate(
        document: doc,
        printerFormats: const ['application/pdf'],
      );
      expect(d.passthrough, isTrue);
      // 回显打印机声明的原样大小写（声明集才是权威，非文档书写形式）。
      expect(d.documentFormat, 'application/pdf');
    });
  });

  group('DocumentEncoder 体系', () {
    test('PwgRasterEncoder 已挂入体系且 documentFormat 恒为 pwg-raster', () {
      const DocumentEncoder encoder = PwgRasterEncoder();
      expect(encoder.documentFormat, 'image/pwg-raster');
      expect(encoder.documentFormat, DocumentFormatNegotiator.pwgRaster);
    });
  });
}
