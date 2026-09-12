import 'dart:convert';
import 'dart:typed_data';

import 'package:ipp_print/src/ipp/ipp_message.dart';
import 'package:ipp_print/src/models.dart';
import 'package:test/test.dart';

/// 独立参照实现：手工按 RFC 8010 编码，用于金标比对（非被测代码）。
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
    _len(0); // 额外值：零长度名（RFC 8010 §3.1.5）
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
    // 金标锚定「全属性下发」路径（0.3.2 起 PrintOptions() 默认全 null
    // = 全不下发；显式构造才产生 job template 属性）。
    const options = PrintOptions(
      media: 'iso_a4_210x297mm',
      duplex: 'one-sided',
    );
    final actual = IppCodec.buildPrintJob(
      printerUri: 'ipp://EPSONBCAA32.local:631/ipp/print',
      documentFormat: 'image/pwg-raster',
      requestId: 7,
      options: options,
    );

    final r = RefWriter();
    r.out.add(r.head(IppCodec.opPrintJob, 7));
    r.group(0x01);
    r.attr(0x47, 'attributes-charset', _s('utf-8'));
    r.attr(0x48, 'attributes-natural-language', _s('en'));
    r.attr(0x45, 'printer-uri', _s('ipp://EPSONBCAA32.local:631/ipp/print'));
    r.attr(0x42, 'requesting-user-name', _s('ipp_print'));
    // IPP Guide Appendix A：Print-Job 必含 job-name（默认值）。
    r.attr(0x42, 'job-name', _s('ipp_print-document'));
    r.attr(0x49, 'document-format', _s('image/pwg-raster'));
    r.group(0x02);
    r.attr(0x21, 'copies', _i32(options.copies));
    // media / print-color-mode / sides：null = 不下发（RFC 8011 §5.2
    // job template 默认值语义 → 打印机用自身 *-default）。
    if (options.media != null) r.attr(0x44, 'media', _s(options.media!));
    if (options.colorMode != null) {
      r.attr(0x44, 'print-color-mode', _s(options.colorMode!));
    }
    if (options.duplex != null) r.attr(0x44, 'sides', _s(options.duplex!));
    r.end();

    expect(actual, r.out.toBytes());
  });

  test('Print-Job：media/duplex 为 null 时整条属性不下发（回归锚点）', () {
    final plain = IppCodec.buildPrintJob(
      printerUri: 'ipp://p.local:631/ipp/print',
      documentFormat: 'image/pwg-raster',
      requestId: 3,
      options: const PrintOptions(media: null, duplex: null),
    );
    final s = String.fromCharCodes(plain);
    expect(s.contains('media'), isFalse);
    expect(s.contains('sides'), isFalse);
    // copies 恒下发（份数是必选语义，无「打印机默认」概念）
    expect(s.contains('copies'), isTrue);
  });

  test('Print-Job：默认构造（全 null）只下发 copies（0.3.2 回归锚点）', () {
    final plain = IppCodec.buildPrintJob(
      printerUri: 'ipp://p.local:631/ipp/print',
      documentFormat: 'image/pwg-raster',
      requestId: 4,
    );
    final s = String.fromCharCodes(plain);
    expect(s.contains('media'), isFalse);
    expect(s.contains('sides'), isFalse);
    expect(s.contains('print-color-mode'), isFalse);
    expect(s.contains('copies'), isTrue);
  });

  test('Print-Job：显式 colorMode 才下发 print-color-mode（回归锚点）', () {
    final actual = IppCodec.buildPrintJob(
      printerUri: 'ipp://p.local:631/ipp/print',
      documentFormat: 'image/pwg-raster',
      requestId: 1,
      options: const PrintOptions(colorMode: 'color'),
    );
    final s = String.fromCharCodes(actual);
    expect('print-color-mode'.allMatches(s), hasLength(1));
    expect(s.contains('color'), isTrue);

    // 默认（null）：报文中完全不含 print-color-mode。
    final plain = IppCodec.buildPrintJob(
      printerUri: 'ipp://p.local:631/ipp/print',
      documentFormat: 'image/pwg-raster',
      requestId: 2,
    );
    expect(String.fromCharCodes(plain).contains('print-color-mode'), isFalse);
  });

  test('Get-Printer-Attributes：requested-attributes 多值用零长度名', () {
    final actual = IppCodec.buildGetPrinterAttributes(
      printerUri: 'ipp://p.local:631/ipp/print',
      requestId: 1,
    );
    // 手工验证：报文里 "requested-attributes" 恰好出现一次且含 10 个值
    // （后 4 项为色彩/双面能力协商，供宿主 UI 生成可选项；
    //  0.3.1 加分辨率 supported/default——栅格 dpi 协商数据源）
    final s = String.fromCharCodes(actual);
    expect('requested-attributes'.allMatches(s), hasLength(1));
    expect(s.contains('media-supported'), isTrue);
    expect(s.contains('printer-make-and-model'), isTrue);
    expect(s.contains('print-color-mode-supported'), isTrue);
    expect(s.contains('print-color-mode-default'), isTrue);
    expect(s.contains('sides-supported'), isTrue);
    expect(s.contains('sides-default'), isTrue);
    expect(s.contains('printer-resolution-supported'), isTrue);
    expect(s.contains('printer-resolution-default'), isTrue);
    // 头部 operation = 0x000B
    expect(actual[2], 0x00);
    expect(actual[3], 0x0B);
  });

  test(
      'operation-id 回归锚点：Get-Job-Attributes=0x0009 ≠ Get-Jobs=0x000A'
      '（历史 Bug：两者曾混淆，实际发送了 Get-Jobs 操作码）', () {
    expect(IppCodec.opPrintJob, 0x0002);
    expect(IppCodec.opCancelJob, 0x0008);
    expect(IppCodec.opGetJobAttributes, 0x0009);
    expect(IppCodec.opGetJobs, 0x000A);
    expect(IppCodec.opGetPrinterAttributes, 0x000B);
    // Get-Job-Attributes 请求头部必须携带 0x0009
    final req = IppCodec.buildGetJobAttributes(
      printerUri: 'ipp://p.local:631/ipp/print',
      jobId: 1,
      requestId: 1,
    );
    expect(req[3], 0x09);
  });

  test('Cancel-Job 请求金标：与独立参照实现逐字节一致', () {
    final actual = IppCodec.buildCancelJob(
      printerUri: 'ipps://EPSONBCAA32.local:631/ipp/print',
      jobId: 42,
      requestId: 9,
    );

    final r = RefWriter();
    r.out.add(r.head(IppCodec.opCancelJob, 9));
    r.group(0x01);
    r.attr(0x47, 'attributes-charset', _s('utf-8'));
    r.attr(0x48, 'attributes-natural-language', _s('en'));
    r.attr(0x45, 'printer-uri', _s('ipps://EPSONBCAA32.local:631/ipp/print'));
    r.attr(0x42, 'requesting-user-name', _s('ipp_print'));
    // IPP Guide Appendix A：Cancel-Job 必需 job-id (integer)。
    r.attr(0x21, 'job-id', _i32(42));
    r.end();

    expect(actual, r.out.toBytes());
  });

  test('Get-Jobs 请求金标：boolean 单字节 + keyword + 多值 requested', () {
    final actual = IppCodec.buildGetJobs(
      printerUri: 'ipp://p.local:631/ipp/print',
      requestId: 3,
      myJobs: true,
      whichJobs: 'completed',
      requestedAttributes: const ['job-id', 'job-state'],
    );

    final r = RefWriter();
    r.out.add(r.head(IppCodec.opGetJobs, 3));
    r.group(0x01);
    r.attr(0x47, 'attributes-charset', _s('utf-8'));
    r.attr(0x48, 'attributes-natural-language', _s('en'));
    r.attr(0x45, 'printer-uri', _s('ipp://p.local:631/ipp/print'));
    r.attr(0x42, 'requesting-user-name', _s('ipp_print'));
    r.attr(0x22, 'my-jobs', [0x01]); // RFC 8011 §5.1.12：boolean 恒 1 字节
    r.attr(0x44, 'which-jobs', _s('completed'));
    r.attr(0x44, 'requested-attributes', _s('job-id'));
    r.additionalValue(0x44, _s('job-state'));
    r.end();

    expect(actual, r.out.toBytes());
  });

  test('Validate-Job 请求金标：操作码 0x0004、无文档数据、与 Print-Job 同构', () {
    const options = PrintOptions(
      media: 'iso_a4_210x297mm',
      duplex: 'one-sided',
    );
    final actual = IppCodec.buildValidateJob(
      printerUri: 'ipp://EPSONBCAA32.local:631/ipp/print',
      documentFormat: 'image/pwg-raster',
      requestId: 9,
      options: options,
    );

    final r = RefWriter();
    r.out.add(r.head(IppCodec.opValidateJob, 9));
    r.group(0x01);
    r.attr(0x47, 'attributes-charset', _s('utf-8'));
    r.attr(0x48, 'attributes-natural-language', _s('en'));
    r.attr(0x45, 'printer-uri', _s('ipp://EPSONBCAA32.local:631/ipp/print'));
    r.attr(0x42, 'requesting-user-name', _s('ipp_print'));
    r.attr(0x42, 'job-name', _s('ipp_print-document'));
    r.attr(0x49, 'document-format', _s('image/pwg-raster'));
    r.group(0x02);
    r.attr(0x21, 'copies', _i32(options.copies));
    r.attr(0x44, 'media', _s(options.media!));
    r.attr(0x44, 'sides', _s(options.duplex!));
    r.end();

    // 逐字节金标：报文恰以 end-of-attributes 结尾（无任何文档数据追加，
    // RFC 8011 §4.2.3「a Client supplies no Document data」）。
    expect(actual, r.out.toBytes());
    expect(actual.last, 0x03);
  });

  test('Get-Printer-Attributes：默认 8 属性集（probe 兼容路径不变）', () {
    final request = IppCodec.buildGetPrinterAttributes(
      printerUri: 'ipp://p.local:631/ipp/print',
      requestId: 1,
    );
    final parsed = IppCodec.parseResponse(request);
    expect(parsed.values('requested-attributes'),
        hasLength(IppCodec.defaultCapabilityAttributeSet.length));
  });

  test(
      'Get-Printer-Attributes：能力引擎传 fullCapabilityAttributeSet '
      '时逐值下发', () {
    final request = IppCodec.buildGetPrinterAttributes(
      printerUri: 'ipp://p.local:631/ipp/print',
      requestId: 1,
      requestedAttributes: IppCodec.fullCapabilityAttributeSet,
    );
    final parsed = IppCodec.parseResponse(request);
    final requested = [
      for (final v in parsed.values('requested-attributes')) v.asString,
    ];
    expect(requested, IppCodec.fullCapabilityAttributeSet);
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
    Uint8List header() =>
        Uint8List.fromList([0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01]);

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

  group('UTF-8 编码契约（RFC 8011：attributes-charset=utf-8，0.4.1）', () {
    test('buildPrintJob：中文 job-name 按 UTF-8 编码（非 UTF-16 码元直写）', () {
      final body = IppCodec.buildPrintJob(
        printerUri: 'ipp://192.168.0.106:631/ipp/print',
        documentFormat: 'application/pdf',
        requestId: 7,
        jobName: '好字帖',
      );
      // UTF-8 字节（好=E5A5BD 字=E5AD97 帖=E5B896）确实出现在线格式。
      expect(_indexOf(body, utf8.encode('好字帖')), isNonNegative,
          reason: 'job-name 必须按 attributes-charset=utf-8 编码');
      // 旧缺陷指纹：codeUnits 直写 '好字帖' → 59 7D 5B 57 5E 16。
      expect(_indexOf(body, const [0x59, 0x7D, 0x5B, 0x57, 0x5E, 0x16]), -1,
          reason: 'UTF-16 码元直写不得再出现');
    });

    test('parseResponse：UTF-8 中文值正确解码（name 语法，中文 printer-info）', () {
      final parsed = IppCodec.parseResponse(_utf8Resp(
        _utf8Attr(0x42, 'printer-make-and-model', utf8.encode('爱普生 L3250 系列')),
      ));
      expect(parsed.firstValue('printer-make-and-model')!.asString,
          '爱普生 L3250 系列');
    });

    test('parseResponse：非 UTF-8 字节宽容解码不抛（lenient 纪律）', () {
      final parsed = IppCodec.parseResponse(_utf8Resp(
        _utf8Attr(0x42, 'printer-make-and-model', const [0xFF, 0xFE, 0xC3]),
      ));
      expect(
          parsed.firstValue('printer-make-and-model')!.asString, isA<String>());
    });
  });
}

/// 子序列查找（金标断言用，独立于被测代码）。
int _indexOf(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var ok = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}

List<int> _utf8Attr(int tag, String name, List<int> value) {
  final nb = utf8.encode(name);
  return [
    tag,
    (nb.length >> 8) & 0xFF,
    nb.length & 0xFF,
    ...nb,
    (value.length >> 8) & 0xFF,
    value.length & 0xFF,
    ...value,
  ];
}

Uint8List _utf8Resp(List<int> attrs) => Uint8List.fromList([
      0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 1, //
      0x01,
      ..._utf8Attr(0x47, 'attributes-charset', utf8.encode('utf-8')),
      ..._utf8Attr(0x48, 'attributes-natural-language', utf8.encode('en')),
      0x04,
      ...attrs,
      0x03,
    ]);
