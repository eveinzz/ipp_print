import 'dart:typed_data';

import '../models.dart';

/// IPP 1.1（RFC 8011/RFC 8010）报文编解码。
///
/// 只实现本项目需要的三种操作：Print-Job、Get-Printer-Attributes、
/// Get-Job-Attributes；值编码覆盖 keyword/integer/enum/boolean/name/
/// uri/charset/language/mime 共用集合。首属性恒为 attributes-charset
/// （规约要求其必须第一个出现）。
class IppCodec {
  const IppCodec._();

  static const int versionMajor = 0x01;
  static const int versionMinor = 0x01;

  // delimiter tags
  static const int tagOperationGroup = 0x01;
  static const int tagJobGroup = 0x02;
  static const int tagEndOfAttributes = 0x03;
  static const int tagPrinterGroup = 0x04;

  // value tags
  static const int tagInteger = 0x21;
  static const int tagBoolean = 0x22;
  static const int tagEnum = 0x23;
  static const int tagName = 0x42;
  static const int tagKeyword = 0x44;
  static const int tagUri = 0x45;
  static const int tagCharset = 0x47;
  static const int tagLanguage = 0x48;
  static const int tagMime = 0x49;

  // operations（IANA IPP Operations 注册表；枚举值由 RFC 8011 §5.4.15
  // operations-supported 定义，与 CUPS cups/ipp.h 逐值对照核实：
  // Print-Job 0x0002 起、Cancel-Job 0x0008、Get-Job-Attributes 0x0009、
  // Get-Jobs 0x000A、Get-Printer-Attributes 0x000B）。
  static const int opPrintJob = 0x0002;
  static const int opCancelJob = 0x0008;
  static const int opGetJobAttributes = 0x0009;
  static const int opGetJobs = 0x000A;
  static const int opGetPrinterAttributes = 0x000B;

  /// 生成 Print-Job 请求头（文档数据由调用方直接追加在尾部）。
  static Uint8List buildPrintJob({
    required String printerUri,
    required String documentFormat,
    required int requestId,
    String userName = 'ipp_print',
    // IPP Guide Appendix A：Print-Job 的 job-name 为必需属性，给默认值。
    String jobName = 'ipp_print-document',
    PrintOptions options = const PrintOptions(),
  }) {
    final b = _Builder(opPrintJob, requestId)
      ..attr(tagCharset, 'attributes-charset', 'utf-8')
      ..attr(tagLanguage, 'attributes-natural-language', 'en')
      ..attr(tagUri, 'printer-uri', printerUri.toString())
      ..attr(tagName, 'requesting-user-name', userName);
    b
      ..attr(tagName, 'job-name', jobName)
      ..attr(tagMime, 'document-format', documentFormat);
    b.group(tagJobGroup)
      ..attr(tagInteger, 'copies', options.copies)
      ..attr(tagKeyword, 'media', options.media)
      ..attr(tagKeyword, 'print-color-mode', options.colorMode)
      ..attr(tagKeyword, 'sides', options.duplex);
    return b.take();
  }

  static Uint8List buildGetPrinterAttributes({
    required String printerUri,
    required int requestId,
    List<String> requestedAttributes = const [
      'media-supported',
      'document-format-supported',
      'printer-state',
      'printer-make-and-model',
    ],
  }) {
    final b = _Builder(opGetPrinterAttributes, requestId)
      ..attr(tagCharset, 'attributes-charset', 'utf-8')
      ..attr(tagLanguage, 'attributes-natural-language', 'en')
      ..attr(tagUri, 'printer-uri', printerUri.toString())
      ..attr(tagName, 'requesting-user-name', 'ipp_print');
    for (final name in requestedAttributes) {
      b.attrOrValue(tagKeyword, 'requested-attributes', name);
    }
    return b.take();
  }

  static Uint8List buildGetJobAttributes({
    required String printerUri,
    required int jobId,
    required int requestId,
  }) {
    final b = _Builder(opGetJobAttributes, requestId)
      ..attr(tagCharset, 'attributes-charset', 'utf-8')
      ..attr(tagLanguage, 'attributes-natural-language', 'en')
      ..attr(tagUri, 'printer-uri', printerUri.toString())
      ..attr(tagName, 'requesting-user-name', 'ipp_print')
      ..attr(tagInteger, 'job-id', jobId);
    return b.take();
  }

  /// Cancel-Job（RFC 8011 §4.3.3 / IPP Guide Appendix A：job-id 必需）。
  static Uint8List buildCancelJob({
    required String printerUri,
    required int jobId,
    required int requestId,
    String userName = 'ipp_print',
  }) {
    final b = _Builder(opCancelJob, requestId)
      ..attr(tagCharset, 'attributes-charset', 'utf-8')
      ..attr(tagLanguage, 'attributes-natural-language', 'en')
      ..attr(tagUri, 'printer-uri', printerUri.toString())
      ..attr(tagName, 'requesting-user-name', userName)
      ..attr(tagInteger, 'job-id', jobId);
    return b.take();
  }

  /// Get-Jobs（RFC 8011 §4.2.6 / IPP Guide Appendix A：可选 my-jobs
  /// (boolean)、which-jobs (keyword)、requested-attributes (1setOf keyword)）。
  static Uint8List buildGetJobs({
    required String printerUri,
    required int requestId,
    String userName = 'ipp_print',
    bool myJobs = false,
    String whichJobs = 'not-completed',
    List<String>? requestedAttributes,
  }) {
    final b = _Builder(opGetJobs, requestId)
      ..attr(tagCharset, 'attributes-charset', 'utf-8')
      ..attr(tagLanguage, 'attributes-natural-language', 'en')
      ..attr(tagUri, 'printer-uri', printerUri.toString())
      ..attr(tagName, 'requesting-user-name', userName)
      ..attr(tagBoolean, 'my-jobs', myJobs)
      ..attr(tagKeyword, 'which-jobs', whichJobs);
    if (requestedAttributes != null) {
      for (final name in requestedAttributes) {
        b.attrOrValue(tagKeyword, 'requested-attributes', name);
      }
    }
    return b.take();
  }

  /// 解析 IPP 响应（status 成功区间 0x0000–0x00FF）。
  static IppResponse parseResponse(Uint8List data) {
    if (data.length < 8) {
      throw const IppPrintException('IPP response too short');
    }
    final bd = ByteData.sublistView(data);
    final statusCode = bd.getUint16(2, Endian.big);
    final requestId = bd.getUint32(4, Endian.big);
    var i = 8;
    var group = IppGroup(tagOperationGroup);
    final groups = <IppGroup>[group];
    String? lastName;
    void require(int needed) {
      if (i + needed > data.length) {
        throw const IppPrintException('truncated IPP response');
      }
    }

    while (i < data.length) {
      final tag = data[i++];
      if (tag == tagEndOfAttributes) break;
      if (tag <= 0x0F) {
        group = IppGroup(tag);
        groups.add(group);
        lastName = null;
        continue;
      }
      require(2);
      final nameLen = bd.getUint16(i, Endian.big);
      i += 2;
      require(nameLen);
      final name = nameLen == 0
          ? lastName
          : String.fromCharCodes(data.sublist(i, i + nameLen));
      i += nameLen;
      require(2);
      final valueLen = bd.getUint16(i, Endian.big);
      i += 2;
      require(valueLen);
      final raw = Uint8List.sublistView(data, i, i + valueLen);
      i += valueLen;
      if (name == null) {
        throw const IppPrintException('IPP attribute value without name');
      }
      lastName = name;
      group.add(name, IppValue(tag, raw));
    }
    return IppResponse(
      statusCode: statusCode,
      requestId: requestId,
      groups: groups,
    );
  }
}

class IppResponse {
  const IppResponse({
    required this.statusCode,
    required this.requestId,
    required this.groups,
  });

  final int statusCode;
  final int requestId;
  final List<IppGroup> groups;

  bool get isSuccessful => statusCode >= 0x0000 && statusCode <= 0x00FF;

  /// 返回第一个组里（含跨组首个匹配）名为 [name] 的值列表。
  List<IppValue> values(String name) => [
        for (final g in groups)
          ...g.attributes[name] ?? const <IppValue>[],
      ];

  IppValue? firstValue(String name) {
    for (final g in groups) {
      final v = g.attributes[name];
      if (v != null && v.isNotEmpty) return v.first;
    }
    return null;
  }
}

/// 解析后的一个属性组（operation/job/printer/unsupported 组之一）。
class IppGroup {
  IppGroup(this.tag);

  /// 组分隔 tag（0x01 operation / 0x02 job / 0x04 printer / 0x05 …）。
  final int tag;

  /// 组内属性：同名多值时列表按序追加（RFC 8010 §3.1.3）。
  final Map<String, List<IppValue>> attributes = {};

  /// 同名追加即多值（RFC 8010：后续值零长度名）。
  void add(String name, IppValue value) =>
      attributes.putIfAbsent(name, () => <IppValue>[]).add(value);
}

/// 单个属性值（保留原始字节 + value-tag，按需解码）。
class IppValue {
  const IppValue(this.tag, this.raw);

  /// value-tag（0x21 integer / 0x23 enum / 0x44 keyword / 0x47 charset …）。
  final int tag;

  /// 原始值字节（大端；integer/enum 恒 4 字节）。
  final Uint8List raw;

  /// 文本类值（keyword/uri/charset/name/mime 等）解码。
  String get asString => String.fromCharCodes(raw);

  /// integer/enum 值解码（非 4 字节抛 [IppPrintException]）。
  int get asInt {
    if (raw.length != 4) {
      throw IppPrintException('integer/enum value must be 4 bytes, '
          'got ${raw.length}');
    }
    return ByteData.sublistView(raw).getInt32(0, Endian.big);
  }
}

class _Builder {
  _Builder(this.operation, this.requestId) : _body = BytesBuilder();

  final int operation;
  final int requestId;
  final BytesBuilder _body;
  int _currentGroup = -1;
  String? _lastName;

  _Builder group(int tag) {
    _flushName();
    _currentGroup = tag;
    _body.addByte(tag);
    return this;
  }

  /// RFC 8010 §3.1.4 编码序：value-tag → name-len → name → value-len
  /// → value。value-tag 必须在 name 之前。
  _Builder attr(int tag, String name, Object value) {
    if (_currentGroup < 0) group(IppCodec.tagOperationGroup);
    if (tag == IppCodec.tagCharset || tag == IppCodec.tagLanguage) {
      _flushName();
    }
    _body.addByte(tag);
    _writeName(name);
    _writeValue(value, asInteger: tag == IppCodec.tagInteger || tag == IppCodec.tagEnum);
    _lastName = name;
    return this;
  }

  /// 同名多值：首个用 attr()，后续值走 tag + 零长度名（RFC 8010 §3.1.5）。
  _Builder attrOrValue(int tag, String name, Object value) {
    if (_lastName != name) return attr(tag, name, value);
    _body.addByte(tag);
    _body
      ..addByte(0)
      ..addByte(0);
    _writeValue(value, asInteger: tag == IppCodec.tagInteger || tag == IppCodec.tagEnum);
    return this;
  }

  void _flushName() => _lastName = null;

  void _writeName(String name) {
    final nb = Uint8List.fromList(name.codeUnits);
    _body.addByte((nb.length >> 8) & 0xFF);
    _body.addByte(nb.length & 0xFF);
    _body.add(nb);
  }

  void _writeValue(Object value, {required bool asInteger}) {
    final Uint8List vb;
    if (value is bool) {
      // RFC 8011 §5.1.12：boolean 语法；线编码恒 1 字节（0x00/0x01）。
      vb = Uint8List(1)..[0] = value ? 1 : 0;
    } else if (asInteger && value is int) {
      vb = Uint8List(4)
        ..buffer.asByteData().setInt32(0, value, Endian.big);
    } else {
      vb = Uint8List.fromList(value.toString().codeUnits);
    }
    _body.addByte((vb.length >> 8) & 0xFF);
    _body.addByte(vb.length & 0xFF);
    _body.add(vb);
  }

  Uint8List take() {
    final head = ByteData(8);
    head.setUint8(0, IppCodec.versionMajor);
    head.setUint8(1, IppCodec.versionMinor);
    head.setUint16(2, operation, Endian.big);
    head.setUint32(4, requestId, Endian.big);
    final out = BytesBuilder()
      ..add(head.buffer.asUint8List())
      ..add(_body.takeBytes())
      ..addByte(IppCodec.tagEndOfAttributes);
    return out.toBytes();
  }
}
