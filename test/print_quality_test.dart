import 'dart:typed_data';

import 'package:ipp_print/src/capability/capability_validator.dart';
import 'package:ipp_print/src/ipp/ipp_client.dart';
import 'package:ipp_print/src/ipp/ipp_message.dart';
import 'package:ipp_print/src/models.dart';
import 'package:test/test.dart';

import 'ipp_wire_fixtures.dart';

/// 0.7.1 print-quality（RFC 8011 §5.2.13，type2 enum，RECOMMENDED；
/// Table 12：'3'=draft / '4'=normal / '5'=high）。原始 enum 值透出，
/// 与 finishings 同纪律——不猜测厂商扩展语义。
///
/// 注：RFC 8011 §5.2.12/§5.2.13 Note——printer-resolution 与
/// print-quality 冲突时，Printer SHOULD 以 print-quality 为准。
void main() {
  group('print-quality 线格式（job template Group 2，三操作同构）', () {
    (int, List<int>) attrOf(List<int> body, String name) {
      var i = 8; // version(2) + op(2) + request-id(4)
      final nb = name.codeUnits;
      while (i < body.length) {
        final tag = body[i++];
        if (tag == 0x03) break; // end-of-attributes
        if (tag <= 0x0F) continue; // group delimiter
        final nameLen = (body[i] << 8) | body[i + 1];
        i += 2;
        final isTarget = nameLen == nb.length;
        var hit = isTarget;
        for (var j = 0; j < nameLen; j++) {
          if (body[i + j] != (j < nb.length ? nb[j] : -1)) hit = false;
        }
        i += nameLen;
        final valueLen = (body[i] << 8) | body[i + 1];
        i += 2;
        final value = body.sublist(i, i + valueLen);
        i += valueLen;
        if (isTarget && hit) return (tag, value);
      }
      throw StateError('attribute $name not found');
    }

    Uint8List build(
      Uint8List Function({required String printerUri, required int requestId})
          buildFn,
    ) =>
        buildFn(printerUri: 'ipp://p:631/ipp/print', requestId: 1);

    test('Print-Job：print-quality=5 → Group 2 + enum tag 0x23 + 4 字节大端', () {
      final body = IppCodec.buildPrintJob(
        printerUri: 'ipp://p:631/ipp/print',
        documentFormat: 'application/pdf',
        requestId: 1,
        options: const PrintOptions(printQuality: 5),
      );
      final (tag, value) = attrOf(body, 'print-quality');
      expect(groupOf(body, 'print-quality'), IppCodec.tagJobGroup,
          reason: 'RFC 8011 §4.2.1.1：job template 属性位于 Group 2');
      expect(tag, IppCodec.tagEnum);
      expect(value, [0x00, 0x00, 0x00, 0x05]);
    });

    test('Validate-Job / Create-Job 同构（_writeJobTemplate 单一来源）', () {
      for (final body in [
        build(({required String printerUri, required int requestId}) =>
            IppCodec.buildValidateJob(
              printerUri: printerUri,
              requestId: requestId,
              documentFormat: 'application/pdf',
              options: const PrintOptions(printQuality: 3),
            )),
        build(({required String printerUri, required int requestId}) =>
            IppCodec.buildCreateJob(
              printerUri: printerUri,
              requestId: requestId,
              options: const PrintOptions(printQuality: 3),
            )),
      ]) {
        final (tag, value) = attrOf(body, 'print-quality');
        expect(groupOf(body, 'print-quality'), IppCodec.tagJobGroup);
        expect(tag, IppCodec.tagEnum);
        expect(value, [0x00, 0x00, 0x00, 0x03]);
      }
    });

    test('缺省 → 不下发（作业模板默认值语义，既有作业字节零变化）', () {
      final body = IppCodec.buildPrintJob(
        printerUri: 'ipp://p:631/ipp/print',
        documentFormat: 'application/pdf',
        requestId: 1,
      );
      expect(String.fromCharCodes(body), isNot(contains('print-quality')));
    });
  });

  group('inspect 解析（lenient：缺失 = null/空，绝不推断）', () {
    test('print-quality-supported 1setOf enum + -default → 原始值透出', () async {
      final client = FakeQueueClient()
        ..enqueue(
          IppCodec.opGetPrinterAttributes,
          resp(0, 0x04, [
            ...enumAttr('print-quality-supported', 3),
            ...enumMore(4),
            ...enumMore(5),
            ...enumAttr('print-quality-default', 4),
          ]),
        );
      final caps = await client.getPrinterCapabilities(testPrinter());
      expect(caps.printQualitiesSupported, [3, 4, 5]);
      expect(caps.printQualityDefault, 4);
    });

    test('声明缺失 → 空/null（不推断）', () async {
      final client = FakeQueueClient()
        ..enqueue(
          IppCodec.opGetPrinterAttributes,
          resp(0, 0x04, [
            ...kw('document-format-supported', 'image/pwg-raster'),
          ]),
        );
      final caps = await client.getPrinterCapabilities(testPrinter());
      expect(caps.printQualitiesSupported, isEmpty);
      expect(caps.printQualityDefault, isNull);
    });
  });

  group('CapabilityValidator：print-quality ∈ 声明集', () {
    test('越界 → unsupported 列出 print-quality', () {
      final r = CapabilityValidator.validate(
        ticket: const PrintTicket(printQuality: 5),
        capabilities: const PrinterCapabilities(
          printQualitiesSupported: [3, 4],
        ),
      );
      expect(r.valid, isFalse);
      expect(r.unsupportedAttributes, ['print-quality']);
    });

    test('命中 → valid；声明缺失 → 跳过检查（缺≠不支持）', () {
      final ok = CapabilityValidator.validate(
        ticket: const PrintTicket(printQuality: 3),
        capabilities: const PrinterCapabilities(
          printQualitiesSupported: [3, 4, 5],
        ),
      );
      expect(ok.valid, isTrue);
      final skip = CapabilityValidator.validate(
        ticket: const PrintTicket(printQuality: 5),
        capabilities: const PrinterCapabilities(),
      );
      expect(skip.valid, isTrue);
    });
  });

  group('PrintTicket ↔ PrintOptions：printQuality 往返', () {
    test('显式值往返一致；缺省保持 null 语义', () {
      const o = PrintOptions(printQuality: 4);
      expect(PrintTicket.fromOptions(o).printQuality, 4);
      expect(
        PrintTicket(printQuality: 5).toOptions().printQuality,
        5,
      );
      expect(PrintTicket().toOptions().printQuality, isNull);
    });
  });
}
