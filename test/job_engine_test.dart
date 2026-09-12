import 'dart:typed_data';

import 'package:ipp_print/src/ipp/ipp_message.dart';
import 'package:ipp_print/src/models.dart';
import 'package:test/test.dart';

import 'ipp_wire_fixtures.dart';

/// 线格式锚点（0.6）：组归属与 Create-Job / Send-Document 报文。
/// IppClient / Facade 层用例见 job_engine_facade_test.dart。
void main() {
  group('RFC 8011 §4.2.1.1 线格式组归属（0.6 修复锚点）', () {
    Uint8List build(PrintOptions o) => IppCodec.buildPrintJob(
          printerUri: 'ipp://p:631/ipp/print',
          documentFormat: 'application/pdf',
          requestId: 1,
          options: o,
        );

    test('ipp-attribute-fidelity 位于 Group 1 操作属性组（0.6 修复：原误入 Group 2）', () {
      final body = build(const PrintOptions(fidelity: PrintFidelity.exact));
      expect(groupOf(body, 'ipp-attribute-fidelity'), 0x01);
    });

    test('copies 等 job template 属性位于 Group 2（RFC 8011 §4.2.1.1 本就正确）', () {
      final body = build(const PrintOptions(copies: 2));
      expect(groupOf(body, 'copies'), 0x02);
    });

    test('Validate-Job 与 Print-Job 同构：fidelity 同步在操作属性组下发', () {
      final body = IppCodec.buildValidateJob(
        printerUri: 'ipp://p:631/ipp/print',
        documentFormat: 'application/pdf',
        requestId: 1,
        options: const PrintOptions(fidelity: PrintFidelity.exact),
      );
      expect(groupOf(body, 'ipp-attribute-fidelity'), 0x01);
    });

    test('Validate-Job 与 Print-Job 同构：printer-resolution 同步下发（9 字节）', () {
      final body = IppCodec.buildValidateJob(
        printerUri: 'ipp://p:631/ipp/print',
        documentFormat: 'application/pdf',
        requestId: 1,
        options: const PrintOptions(resolution: (360, 360, 3)),
      );
      expect(groupOf(body, 'printer-resolution'), 0x02);
      expect(
        String.fromCharCodes(body),
        contains('printer-resolution'),
      );
    });

    test('Validate-Job 缺省不下发 fidelity/resolution（作业模板默认值语义）', () {
      final body = IppCodec.buildValidateJob(
        printerUri: 'ipp://p:631/ipp/print',
        documentFormat: 'application/pdf',
        requestId: 1,
      );
      final s = String.fromCharCodes(body);
      expect(s, isNot(contains('ipp-attribute-fidelity')));
      expect(s, isNot(contains('printer-resolution')));
    });
  });

  group('Create-Job / Send-Document 线格式（RFC 8011 §4.2.4/§4.3.1）', () {
    test('buildCreateJob：op=0x0005，无 document-format，job template 在 Group 2',
        () {
      final body = IppCodec.buildCreateJob(
        printerUri: 'ipp://p:631/ipp/print',
        requestId: 7,
        options: const PrintOptions(copies: 2),
      );
      expect((body[2] << 8) | body[3], IppCodec.opCreateJob);
      final s = String.fromCharCodes(body);
      expect(s, contains('job-name'));
      expect(s, contains('copies'));
      // §4.2.4：Create-Job 不携带 document-format（每文档属性）。
      expect(s, isNot(contains('document-format')));
      expect(groupOf(body, 'copies'), 0x02);
      // 无文档数据：end-of-attributes 之后无字节。
      expect(body.last, 0x03);
    });

    test('buildCreateJob：fidelity 与 Print-Job 同构（§4.2.4 排除清单不含它）', () {
      final body = IppCodec.buildCreateJob(
        printerUri: 'ipp://p:631/ipp/print',
        requestId: 7,
        options: const PrintOptions(fidelity: PrintFidelity.exact),
      );
      expect(groupOf(body, 'ipp-attribute-fidelity'), 0x01);
      // 缺省不下发（打印机按默认 false 处理）。
      final plain = IppCodec.buildCreateJob(
        printerUri: 'ipp://p:631/ipp/print',
        requestId: 7,
      );
      expect(
        String.fromCharCodes(plain),
        isNot(contains('ipp-attribute-fidelity')),
      );
    });

    test('buildSendDocument：op=0x0006，job-id + last-document（MUST），数据尾随', () {
      final body = IppCodec.buildSendDocument(
        printerUri: 'ipp://p:631/ipp/print',
        jobId: 42,
        requestId: 8,
        lastDocument: true,
        documentFormat: 'application/pdf',
      );
      expect((body[2] << 8) | body[3], IppCodec.opSendDocument);
      final s = String.fromCharCodes(body);
      expect(s, contains('job-id'));
      expect(s, contains('last-document'));
      expect(s, contains('document-format'));
      expect(groupOf(body, 'last-document'), 0x01);
      // last-document = true：boolean 线格式 1 字节 0x01。
      // （名字后为 value-len 2 字节，随后即值字节。）
      final i = s.indexOf('last-document');
      expect(body[i + 'last-document'.length + 2], 0x01);
      // 文档数据追加在 end-of-attributes 之后。
      expect(body.last, 0x03);
    });
  });
}
