import 'dart:typed_data';

import 'package:ipp_print/src/capability/capability_validator.dart';
import 'package:ipp_print/src/ipp/ipp_message.dart';
import 'package:ipp_print/src/models.dart';
import 'package:test/test.dart';

/// 0.5 PrintTicket / CapabilityValidator / fidelity·resolution 线格式。
void main() {
  group('PrintTicket ↔ PrintOptions 互转', () {
    test('toOptions：字段映射 + resolution keyword → 线格式 record', () {
      const ticket = PrintTicket(
        media: 'iso_a4_210x297mm',
        colorMode: 'monochrome',
        sides: 'two-sided-long-edge',
        resolution: '360x360dpi',
        copies: 2,
        fidelity: PrintFidelity.exact,
      );
      final o = ticket.toOptions();
      expect(o.media, 'iso_a4_210x297mm');
      expect(o.colorMode, 'monochrome');
      expect(o.duplex, 'two-sided-long-edge');
      expect(o.copies, 2);
      expect(o.fidelity, PrintFidelity.exact);
      expect(o.resolution, (360, 360, 3));
    });

    test('fromOptions：反向映射 + record → keyword（往返一致）', () {
      const o = PrintOptions(
        media: 'om_16k_195x270mm',
        colorMode: 'color',
        duplex: 'one-sided',
        fidelity: PrintFidelity.bestEffort,
        resolution: (1440, 720, 4),
      );
      final t = PrintTicket.fromOptions(o);
      expect(t.media, 'om_16k_195x270mm');
      expect(t.sides, 'one-sided');
      expect(t.fidelity, PrintFidelity.bestEffort);
      expect(t.resolution, '1440x720dpcm');
      // 往返：ticket → options 与原值等价
      expect(t.toOptions().resolution, (1440, 720, 4));
    });

    test('null 字段往返保默认语义（copies null → Options 1）', () {
      const t = PrintTicket();
      final o = t.toOptions();
      expect(o.copies, 1);
      expect(o.media, isNull);
      expect(o.fidelity, isNull);
      expect(o.resolution, isNull);
    });

    test('非法 resolution keyword → ArgumentError（程序员错误）', () {
      const t = PrintTicket(resolution: '360dpi');
      expect(() => t.toOptions(), throwsA(isA<ArgumentError>()));
    });
  });

  group('fidelity / printer-resolution 线格式（RFC 8011 §5.2.2/§5.1.14）', () {
    Uint8List build(PrintOptions o) => IppCodec.buildPrintJob(
          printerUri: 'ipp://p:631/ipp/print',
          documentFormat: 'application/pdf',
          requestId: 1,
          options: o,
        );

    List<int> attrTail(Uint8List body, String name) {
      // 找到属性名（ASCII）首次出现位置，返回其后值长度前缀 + 值字节。
      final nb = name.codeUnits;
      for (var i = 0; i < body.length - nb.length; i++) {
        var hit = true;
        for (var j = 0; j < nb.length; j++) {
          if (body[i + j] != nb[j]) {
            hit = false;
            break;
          }
        }
        if (hit) return body.sublist(i + nb.length);
      }
      throw StateError('attribute $name not found');
    }

    test('fidelity=exact → 下发 ipp-attribute-fidelity=true（1 字节 0x01）', () {
      final tail =
          attrTail(build(const PrintOptions(fidelity: PrintFidelity.exact)),
              'ipp-attribute-fidelity');
      expect(tail[0], 0x00); // value-len 高字节
      expect(tail[1], 0x01); // value-len 低字节 = 1
      expect(tail[2], 0x01); // true
    });

    test('fidelity 缺省 → 不下发（默认尽力打印，作业模板默认值语义）', () {
      final body = build(const PrintOptions());
      expect(
        String.fromCharCodes(body),
        isNot(contains('ipp-attribute-fidelity')),
      );
    });

    test('resolution → printer-resolution 9 字节线格式', () {
      final tail = attrTail(
        build(const PrintOptions(resolution: (360, 360, 3))),
        'printer-resolution',
      );
      expect(tail[1], 0x09); // value-len = 9
      // cross=360 (0x00000168), feed=360, unit=3
      expect(tail.sublist(2, 11),
          [0, 0, 1, 104, 0, 0, 1, 104, 3]);
    });
  });

  group('CapabilityValidator（本地预检，双层第一层）', () {
    const caps = PrinterCapabilities(
      mediaSupported: ['iso_a4_210x297mm', 'om_16k_195x270mm'],
      colorModesSupported: ['monochrome', 'auto', 'color'],
      sidesSupported: ['one-sided'],
      resolutionsSupported: ['360x360dpi', '1440x720dpi'],
      copiesMin: 1,
      copiesMax: 99,
    );

    test('全部命中 → valid', () {
      final r = CapabilityValidator.validate(
        ticket: const PrintTicket(
          media: 'iso_a4_210x297mm',
          colorMode: 'monochrome',
          sides: 'one-sided',
          resolution: '360x360dpi',
          copies: 20,
        ),
        capabilities: caps,
      );
      expect(r.valid, isTrue);
      expect(r.unsupportedAttributes, isEmpty);
    });

    test('逐项越界 → 结构化列出属性名（大小写不敏感）', () {
      final r = CapabilityValidator.validate(
        ticket: const PrintTicket(
          media: 'iso_a3_297x420mm', // ∉ 声明集
          colorMode: 'COLOR', // 大小写不敏感命中
          sides: 'two-sided-long-edge', // ∉
          resolution: '600x600dpi', // ∉
          copies: 100, // > max
        ),
        capabilities: caps,
      );
      expect(r.valid, isFalse);
      expect(r.unsupportedAttributes,
          ['media', 'sides', 'printer-resolution', 'copies']);
    });

    test('能力缺失的字段跳过（缺≠不支持，绝不推断）', () {
      const empty = PrinterCapabilities();
      final r = CapabilityValidator.validate(
        ticket: const PrintTicket(
          media: 'iso_a4_210x297mm',
          copies: 5,
        ),
        capabilities: empty,
      );
      expect(r.valid, isTrue);
    });
  });
}
