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
}
