import 'dart:typed_data';

import 'package:ipp_print/src/ipp/ipp_message.dart';
import 'package:ipp_print/src/models.dart';
import 'package:test/test.dart';

/// 独立参照实现：手工按 RFC 2910 编码，用于金标比对（非被测代码）。
class RefWriter {
  final out = BytesBuilder();

  void _len(int v) {
    out.addByte((v >> 8) & 0xFF);
    out.addByte(v & 0xFF);
  }

  void u32(int v) {
    for (final shift in [24, 16, 8, 0]) {
      out.addByte((v >> shift) & 0xFF);
    }
  }

  void attr(int tag, String name, List<int> value) {
    out.addByte(tag);
    final nb = name.codeUnits;
    _len(nb.length);
    out.add(nb);
    _len(value.length);
    out.add(value);
  }

  void additionalValue(int tag, List<int> value) {
    out.addByte(tag);
    _len(0); // 额外值：零长度名（RFC 2910 §3.1.4.2）
    _len(value.length);
    out.add(value);
  }

  void group(int tag) => out.addByte(tag);
  void end() => out.addByte(0x03);

  List<int> head(int op, int requestId) => [
        0x01, 0x01, //
        (op >> 8) & 0xFF, op & 0xFF, //
        (requestId >> 24) & 0xFF, (requestId >> 16) & 0xFF,
        (requestId >> 8) & 0xFF, requestId & 0xFF,
      ];
}

List<int> _s(String s) => s.codeUnits;
List<int> _i32(int v) => [
      (v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF, //
    ];

void main() {
  test('Print-Job 请求金标：与独立参照实现逐字节一致', () {
    const options = PrintOptions();
    final actual = IppCodec.buildPrintJob(
      printerUri: 'ipp://EPSONBCAA32.local:631/ipp/print',
      documentFormat: 'image/pwg-raster',
      requestId: 7,
    );

    final r = RefWriter();
    r.out.add(r.head(IppCodec.opPrintJob, 7));
    r.group(0x01);
    r.attr(0x47, 'attributes-charset', _s('utf-8'));
    r.attr(0x48, 'attributes-natural-language', _s('en'));
    r.attr(0x45, 'printer-uri',
        _s('ipp://EPSONBCAA32.local:631/ipp/print'));
    r.attr(0x42, 'requesting-user-name', _s('ipp_print'));
    // IPP Guide Appendix A：Print-Job 必含 job-name（默认值）。
    r.attr(0x42, 'job-name', _s('ipp_print-document'));
    r.attr(0x49, 'document-format', _s('image/pwg-raster'));
    r.group(0x02);
    r.attr(0x21, 'copies', _i32(options.copies));
    r.attr(0x44, 'media', _s(options.media));
    r.attr(0x44, 'print-color-mode', _s(options.colorMode));
    r.attr(0x44, 'sides', _s(options.duplex));
    r.end();

    expect(actual, r.out.toBytes());
  });

  test('Get-Printer-Attributes：requested-attributes 多值用零长度名', () {
    final actual = IppCodec.buildGetPrinterAttributes(
      printerUri: 'ipp://p.local:631/ipp/print',
      requestId: 1,
    );
    // 手工验证：报文里 "requested-attributes" 恰好出现一次且含 4 个值
    final s = String.fromCharCodes(actual);
    expect('requested-attributes'.allMatches(s), hasLength(1));
    expect(s.contains('media-supported'), isTrue);
    expect(s.contains('printer-make-and-model'), isTrue);
    // 头部 operation = 0x000B
    expect(actual[2], 0x00);
    expect(actual[3], 0x0B);
  });

  test('parseResponse：解析状态码、组、多值属性与 enum/integer', () {
    // 手工构造响应头（status successful-ok，requestId 0x1234）
    final resp = BytesBuilder()
      ..add([0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x12, 0x34])
      ..addByte(0x01) // operation group
      ;
    void attr(int tag, String name, List<int> v) {
      resp.addByte(tag);
      final nb = name.codeUnits;
      resp.addByte((nb.length >> 8) & 0xFF);
      resp.addByte(nb.length & 0xFF);
      resp.add(nb);
      resp.addByte((v.length >> 8) & 0xFF);
      resp.addByte(v.length & 0xFF);
      resp.add(v);
    }

    attr(0x47, 'attributes-charset', _s('utf-8'));
    attr(0x48, 'attributes-natural-language', _s('en'));
    resp.addByte(0x04); // printer group
    attr(0x44, 'media-supported', _s('iso_a4_210x297mm'));
    resp.addByte(0x44); // additional value：零长度名
    resp.addByte(0x00);
    resp.addByte(0x00);
    final letter = _s('na_letter_8.5x11in');
    resp.addByte((letter.length >> 8) & 0xFF);
    resp.addByte(letter.length & 0xFF);
    resp.add(letter);
    attr(0x23, 'printer-state', _i32(3));
    attr(0x42, 'printer-make-and-model', _s('EPSON L3250 Series'));
    resp.addByte(0x03);
    resp.add(_s('document-data-not-present')); // 属性后冗余数据应被忽略

    final parsed = IppCodec.parseResponse(resp.toBytes());
    expect(parsed.isSuccessful, isTrue);
    expect(parsed.requestId, 0x1234);
    expect(parsed.values('media-supported').map((v) => v.asString),
        ['iso_a4_210x297mm', 'na_letter_8.5x11in']);
    expect(parsed.firstValue('printer-state')!.asInt, 3);
    expect(parsed.firstValue('printer-make-and-model')!.asString,
        'EPSON L3250 Series');
  });

  test('parseResponse：错误状态码被识别为失败', () {
    final resp = BytesBuilder()
      ..add([0x01, 0x01, 0x05, 0x03, 0x00, 0x00, 0x00, 0x01, 0x03]);
    final parsed = IppCodec.parseResponse(resp.toBytes());
    expect(parsed.isSuccessful, isFalse);
    expect(parsed.statusCode, 0x0503);
  });

  group('parseResponse：截断/畸形报文（对抗性种子）', () {
    Uint8List header() => Uint8List.fromList(
        [0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01]);

    test('短于 8 字节头部 → IppPrintException（非 RangeError）', () {
      expect(
        () => IppCodec.parseResponse(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<IppPrintException>()),
      );
    });

    test('属性名长度越界（截断）→ IppPrintException', () {
      final b = BytesBuilder()
        ..add(header())
        ..addByte(0x01)
        ..addByte(0x44)
        ..addByte(0x00)
        ..addByte(0x20) // 声称名字长 32 字节，但报文到此结束
        ;
      expect(
        () => IppCodec.parseResponse(b.toBytes()),
        throwsA(isA<IppPrintException>()),
      );
    });

    test('属性值长度越界（截断）→ IppPrintException', () {
      final nb = 'media'.codeUnits;
      final b = BytesBuilder()
        ..add(header())
        ..addByte(0x01)
        ..addByte(0x44)
        ..addByte(0x00)
        ..addByte(nb.length)
        ..add(nb)
        ..addByte(0x00)
        ..addByte(0x40) // 声称值长 64 字节，实际 0
        ;
      expect(
        () => IppCodec.parseResponse(b.toBytes()),
        throwsA(isA<IppPrintException>()),
      );
    });

    test('值字段本身被截断 → IppPrintException', () {
      final nb = 'media'.codeUnits;
      final b = BytesBuilder()
        ..add(header())
        ..addByte(0x01)
        ..addByte(0x44)
        ..addByte(0x00)
        ..addByte(nb.length)
        ..add(nb)
        ..addByte(0x00)
        ..addByte(0x08)
        ..add([1, 2, 3]); // 只有 3 字节
      expect(
        () => IppCodec.parseResponse(b.toBytes()),
        throwsA(isA<IppPrintException>()),
      );
    });

    test('零长度名且无前名可继承 → IppPrintException', () {
      final b = BytesBuilder()
        ..add(header())
        ..addByte(0x01)
        ..addByte(0x44) // 直接 additional-value，之前没有任何命名属性
        ..addByte(0x00)
        ..addByte(0x00)
        ..addByte(0x00)
        ..addByte(0x00);
      expect(
        () => IppCodec.parseResponse(b.toBytes()),
        throwsA(isA<IppPrintException>()),
      );
    });
  });
}
