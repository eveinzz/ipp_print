import 'dart:typed_data';

import 'package:ipp_print/src/models.dart';
import 'package:ipp_print/src/ipp/ipp_message.dart';
import 'package:test/test.dart';

/// 0.5 Typed IPP Value 基础层：inspect 定制解码上收为 IppValue 类型 getters。
///
/// 线编码构造独立于被测代码（手工字节），锚定 RFC 8011 语法。
void main() {
  IppValue v(List<int> raw) => IppValue(0x21, Uint8List.fromList(raw));

  group('IppValue.asBool（RFC 8011 §5.1.12）', () {
    test('1 字节 0x01/0x00 → true/false', () {
      expect(v([0x01]).asBool, isTrue);
      expect(v([0x00]).asBool, isFalse);
    });
    test('非 1 字节 → 抛（不猜测）', () {
      expect(() => v([0x01, 0x02]).asBool, throwsA(isA<IppPrintException>()));
    });
  });

  group('IppValue.asRange（RFC 8011 §5.1.14）', () {
    test('两个 int32（低、高）', () {
      // copies-supported = 1..99
      final r = v([
        0, 0, 0, 1, //
        0, 0, 0, 99,
      ]).asRange;
      expect(r.$1, 1);
      expect(r.$2, 99);
    });
    test('非 8 字节 → 抛', () {
      expect(() => v([0, 0, 0, 1]).asRange, throwsA(isA<IppPrintException>()));
    });
  });

  group('IppValue.asResolution（RFC 8011 §5.1.16）', () {
    test('cross+feed+unit 9 字节 → 结构化 + keyword 形态', () {
      // 360x360dpi（L3250 声明项）
      final r = v([
        0, 0, 1, 104, // 360
        0, 0, 1, 104, // 360
        3, // dpi
      ]).asResolution;
      expect(r.cross, 360);
      expect(r.feed, 360);
      expect(r.unit, IppResolution.dpi);
      expect(r.isDpi, isTrue);
      expect(r.asKeyword, '360x360dpi');
    });
    test('1440x720dpcm 单位原样保留不换算（不推断）', () {
      final r = v([
        0, 0, 5, 160, // 1440
        0, 0, 2, 208, // 720
        4, // dpcm
      ]).asResolution;
      expect(r.isDpcm, isTrue);
      expect(r.asKeyword, '1440x720dpcm');
    });
    test('未知单位 → 抛（绝不猜 dpi）', () {
      final bad = v([
        0, 0, 1, 104, 0, 0, 1, 104, 9, //
      ]);
      expect(() => bad.asResolution, throwsA(isA<IppPrintException>()));
    });
    test('非 9 字节 → 抛', () {
      expect(
          () => v([0, 0, 1]).asResolution, throwsA(isA<IppPrintException>()));
    });
  });

  group('IppValue.asIntOrNull（RFC 8010 §3.5.2 Table 3 out-of-band 防御）', () {
    IppValue tagged(int tag, List<int> raw) =>
        IppValue(tag, Uint8List.fromList(raw));

    test('4 字节 integer/enum → 值', () {
      expect(v([0, 0, 0, 2]).asIntOrNull, 2);
      expect(tagged(0x23, [0, 0, 0, 9]).asIntOrNull, 9);
    });

    test('out-of-band 三种（unsupported/unknown/no-value，零字节）→ null 且不抛', () {
      for (final tag in const [0x10, 0x12, 0x13]) {
        final val = tagged(tag, const <int>[]);
        expect(val.isOutOfBand, isTrue,
            reason: 'tag 0x${tag.toRadixString(16)} 应判为 out-of-band');
        expect(val.asIntOrNull, isNull,
            reason: 'tag 0x${tag.toRadixString(16)} 不应抛异常');
      }
    });

    test('非 4 字节整数 → asIntOrNull 为 null，asInt 仍严格抛（分工不混）', () {
      expect(tagged(0x21, [0x01]).asIntOrNull, isNull);
      expect(
          () => tagged(0x21, [0x01]).asInt, throwsA(isA<IppPrintException>()));
    });

    test('真机形态复现：L3250 的 job-impressions 回 no-value（0 字节）', () {
      // 2026-09-13 真机实测（EPSON L3250）：同一响应里
      // job-impressions = tag 0x13 / value-len 0，job-impressions-completed
      // = integer 2。若解析侧用严格 asInt，轮询会在读完分子后崩在分母上。
      expect(tagged(0x13, const <int>[]).asIntOrNull, isNull);
      expect(tagged(0x21, [0, 0, 0, 2]).asIntOrNull, 2);
    });
  });
}
