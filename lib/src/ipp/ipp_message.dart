import 'dart:typed_data';

import '../models.dart';
import 'ipp_values.dart';

export 'ipp_values.dart';

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
  // Print-Job 0x0002 起、Validate-Job 0x0004、Cancel-Job 0x0008、
  // Get-Job-Attributes 0x0009、Get-Jobs 0x000A、Get-Printer-Attributes 0x000B）。
  static const int opPrintJob = 0x0002;
  static const int opValidateJob = 0x0004;
  static const int opCancelJob = 0x0008;
  static const int opGetJobAttributes = 0x0009;
  static const int opGetJobs = 0x000A;
  static const int opGetPrinterAttributes = 0x000B;

  /// Validate-Job 响应的 Unsupported Attributes 组（RFC 8010 delimiter
  /// tag 0x05；RFC 8011 §4.2.3：打印机按 Print-Job 同款返回组 2）。
  static const int tagUnsupportedGroup = 0x05;

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
    b.group(tagJobGroup).attr(tagInteger, 'copies', options.copies);
    // media / print-color-mode / sides 统一语义：null = 不下发该属性，
    // 打印机使用自己的 *-default（RFC 8011 §5.2 job template 默认值语义）。
    // 宿主无法从打印机声明能力确定取值时应传 null，而不是猜一个值。
    if (options.media != null) {
      b.attr(tagKeyword, 'media', options.media!);
    }
    if (options.colorMode != null) {
      b.attr(tagKeyword, 'print-color-mode', options.colorMode!);
    }
    if (options.duplex != null) {
      b.attr(tagKeyword, 'sides', options.duplex!);
    }
    return b.take();
  }

  /// Get-Printer-Attributes 请求。
  ///
  /// 默认请求集覆盖「宿主 UI 数据源」所必需的能力声明：
  /// - 介质与格式：判定可否直连、可选纸张；
  /// - 色彩/双面（`print-color-mode-supported|default`、`sides-supported|default`）：
  ///   宿主 UI 据此**只展示打印机声明支持的取值**——能力只来自 IPP
  ///   确定性字段，禁止推断（PWG 5107.3 §6.2.27 / PWG 5100.13）。
  ///
  /// [requestedAttributes] 传 null（默认）用内置集；能力引擎
  /// （inspect）传 [IppCodec.fullCapabilityAttributeSet] 获取完整能力集。
  static Uint8List buildGetPrinterAttributes({
    required String printerUri,
    required int requestId,
    List<String>? requestedAttributes,
  }) {
    final b = _Builder(opGetPrinterAttributes, requestId)
      ..attr(tagCharset, 'attributes-charset', 'utf-8')
      ..attr(tagLanguage, 'attributes-natural-language', 'en')
      ..attr(tagUri, 'printer-uri', printerUri.toString())
      ..attr(tagName, 'requesting-user-name', 'ipp_print');
    for (final name in requestedAttributes ?? defaultCapabilityAttributeSet) {
      b.attrOrValue(tagKeyword, 'requested-attributes', name);
    }
    return b.take();
  }

  /// probe() 兼容集（0.2 起 8 属性；0.3.1 加分辨率协商数据源 → 10 属性，
  /// 真机路径已验证入门机不截断）。
  static const List<String> defaultCapabilityAttributeSet = [
    'media-supported',
    'document-format-supported',
    'printer-state',
    'printer-make-and-model',
    'print-color-mode-supported',
    'print-color-mode-default',
    'sides-supported',
    'sides-default',
    'printer-resolution-supported',
    'printer-resolution-default',
  ];

  /// 能力引擎完整集（0.3 inspect()；全部为 RFC 8011 §5.4 定义的
  /// Printer Description / Status / Template 属性，缺一不致错——
  /// 解析侧 lenient，打印机截断响应也不崩溃）。
  static const List<String> fullCapabilityAttributeSet = [
    // 身份
    'printer-uri-supported',
    'printer-name',
    'printer-info',
    'printer-make-and-model',
    // 状态
    'printer-state',
    'printer-state-reasons',
    'printer-is-accepting-jobs',
    // 文档格式
    'document-format-supported',
    'document-format-default',
    // 介质
    'media-supported',
    'media-ready',
    // 色彩 / 双面
    'print-color-mode-supported',
    'print-color-mode-default',
    'sides-supported',
    'sides-default',
    // 分辨率 / 份数 / 整饰
    'printer-resolution-supported',
    'printer-resolution-default',
    'copies-supported',
    'finishings-supported',
    // 协议面
    'ipp-versions-supported',
    'operations-supported',
    'job-creation-attributes-supported',
    'uri-authentication-supported',
    'uri-security-supported',
  ];

  /// Validate-Job（RFC 8011 §4.2.3）：与 Print-Job 同构但**无文档数据**、
  /// 打印机不建作业，用于在提交大文档前验证「同构的 Job Creation 请求
  /// 会不会被接受」。响应：状态码 + 组 2 = Unsupported Attributes。
  static Uint8List buildValidateJob({
    required String printerUri,
    required String documentFormat,
    required int requestId,
    String userName = 'ipp_print',
    String jobName = 'ipp_print-document',
    PrintOptions options = const PrintOptions(),
  }) {
    final b = _Builder(opValidateJob, requestId)
      ..attr(tagCharset, 'attributes-charset', 'utf-8')
      ..attr(tagLanguage, 'attributes-natural-language', 'en')
      ..attr(tagUri, 'printer-uri', printerUri.toString())
      ..attr(tagName, 'requesting-user-name', userName)
      ..attr(tagName, 'job-name', jobName)
      ..attr(tagMime, 'document-format', documentFormat);
    b.group(tagJobGroup).attr(tagInteger, 'copies', options.copies);
    // 与 Print-Job 相同的 null = 不下发语义（RFC 8011 §5.2 默认值语义）。
    if (options.media != null) {
      b.attr(tagKeyword, 'media', options.media!);
    }
    if (options.colorMode != null) {
      b.attr(tagKeyword, 'print-color-mode', options.colorMode!);
    }
    if (options.duplex != null) {
      b.attr(tagKeyword, 'sides', options.duplex!);
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
