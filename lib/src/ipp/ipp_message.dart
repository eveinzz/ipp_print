import 'dart:convert';
import 'dart:typed_data';

import '../models.dart';
import 'ipp_values.dart';

export 'ipp_values.dart';

part 'ipp_message_builder.dart';

/// IPP 1.1（RFC 8011/RFC 8010）报文编解码。
///
/// 实现的操作（0.6：8 种）：Print-Job、Validate-Job、Create-Job、
/// Send-Document、Get-Printer-Attributes、Get-Job-Attributes、Get-Jobs、
/// Cancel-Job；值编码覆盖 keyword/integer/enum/boolean/resolution/name/
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
  static const int tagResolution = 0x32;
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
  static const int opCreateJob = 0x0005;
  static const int opSendDocument = 0x0006;
  static const int opValidateJob = 0x0004;
  static const int opCancelJob = 0x0008;
  static const int opGetJobAttributes = 0x0009;
  static const int opGetJobs = 0x000A;
  static const int opGetPrinterAttributes = 0x000B;

  /// Unsupported Attributes 组（RFC 8010 §3.5.1 Table 2：delimiter tag 0x05）。
  /// RFC 8011 §4.1.7 明言该组「all operations can return」；在 Validate-Job
  /// 的响应中它固定为组 2（§4.2.3）。
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
      ..attr(tagName, 'requesting-user-name', userName)
      ..attr(tagName, 'job-name', jobName)
      ..attr(tagMime, 'document-format', documentFormat);
    // ipp-attribute-fidelity 是 **Operation Attribute**（RFC 8011 §4.2.1.1
    // Group 1 定义；0.6 修复：原误写入 Group 2 job template 组）。
    // bestEffort → 不下发（打印机按默认 false 处理）；exact → 显式 true
    // （任一 job template 值不被支持则拒绝整个作业，§4.2.1.1）。
    if (options.fidelity != null) {
      b.attr(tagBoolean, 'ipp-attribute-fidelity',
          options.fidelity == PrintFidelity.exact);
    }
    // Job template 属性（RFC 8011 §4.2.1.1 Group 2），与 Validate-Job /
    // Create-Job 共用单一来源 `_writeJobTemplate`（0.6 防三处漂移）。
    b.group(tagJobGroup);
    _writeJobTemplate(b, options);
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
    // 分辨率 / 份数 / 整饰 / 质量
    'printer-resolution-supported',
    'printer-resolution-default',
    'copies-supported',
    'finishings-supported',
    'print-quality-supported',
    'print-quality-default',
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
    // 与 Print-Job 严格同构（§4.2.3）：fidelity 同为操作属性组。
    if (options.fidelity != null) {
      b.attr(tagBoolean, 'ipp-attribute-fidelity',
          options.fidelity == PrintFidelity.exact);
    }
    b.group(tagJobGroup);
    _writeJobTemplate(b, options);
    return b.take();
  }

  /// Job Template 属性写入（Print-Job / Validate-Job / Create-Job 三处共用
  /// 单一来源，0.6 防漂移）。RFC 8011 §4.2.1.1：job template 属性位于请求
  /// **Group 2（Job Template Attributes）**。统一语义：null = 不下发该属性
  /// （RFC 8011 §5.2 job template 默认值语义）。
  static void _writeJobTemplate(_Builder b, PrintOptions options) {
    b.attr(tagInteger, 'copies', options.copies);
    if (options.media != null) {
      b.attr(tagKeyword, 'media', options.media!);
    }
    if (options.colorMode != null) {
      b.attr(tagKeyword, 'print-color-mode', options.colorMode!);
    }
    if (options.duplex != null) {
      b.attr(tagKeyword, 'sides', options.duplex!);
    }
    // 分辨率（RFC 8011 §5.1.16 resolution 线语法：cross+feed+unit 9 字节）。
    final res = options.resolution;
    if (res != null) {
      b.attr(tagResolution, 'printer-resolution', res);
    }
    // 打印质量（RFC 8011 §5.2.13 type2 enum；0.7.1 新增）。
    if (options.printQuality != null) {
      b.attr(tagEnum, 'print-quality', options.printQuality!);
    }
  }

  /// Create-Job（RFC 8011 §4.2.4，op 0x0005，RECOMMENDED）：无文档数据的
  /// Job Creation，后续以 Send-Document 逐文档提交。§4.2.4 明确：
  /// Client does not supply "document-format"/"compression"（每文档属性，
  /// 由 Send-Document 按文档下发）；job template 属性仍随本请求提供。
  static Uint8List buildCreateJob({
    required String printerUri,
    required int requestId,
    String userName = 'ipp_print',
    String jobName = 'ipp_print-document',
    PrintOptions options = const PrintOptions(),
  }) {
    final b = _Builder(opCreateJob, requestId)
      ..attr(tagCharset, 'attributes-charset', 'utf-8')
      ..attr(tagLanguage, 'attributes-natural-language', 'en')
      ..attr(tagUri, 'printer-uri', printerUri.toString())
      ..attr(tagName, 'requesting-user-name', userName)
      ..attr(tagName, 'job-name', jobName);
    // ipp-attribute-fidelity 与 Print-Job 同构：§4.2.4 的排除清单只含
    // document-name / document-format / compression / document-natural-
    // language 四个每文档属性，fidelity 不在其列；job template 值随本
    // 请求提供，保真语义同样适用（0.6 审计补齐，与 Validate-Job 修复同类）。
    if (options.fidelity != null) {
      b.attr(tagBoolean, 'ipp-attribute-fidelity',
          options.fidelity == PrintFidelity.exact);
    }
    b.group(tagJobGroup);
    _writeJobTemplate(b, options);
    return b.take();
  }

  /// Send-Document（RFC 8011 §4.3.1，op 0x0006）：向既有作业追加文档。
  /// §4.3.1.1：printer-uri + job-id REQUIRED；**last-document（boolean）
  /// Client MUST supply**；document-format MAY 按文档提供；文档数据在
  /// end-of-attributes 之后（Group 2: Document Data）。
  static Uint8List buildSendDocument({
    required String printerUri,
    required int jobId,
    required int requestId,
    required bool lastDocument,
    String? documentFormat,
    String userName = 'ipp_print',
  }) {
    final b = _Builder(opSendDocument, requestId)
      ..attr(tagCharset, 'attributes-charset', 'utf-8')
      ..attr(tagLanguage, 'attributes-natural-language', 'en')
      ..attr(tagUri, 'printer-uri', printerUri.toString())
      ..attr(tagName, 'requesting-user-name', userName)
      ..attr(tagInteger, 'job-id', jobId)
      ..attr(tagBoolean, 'last-document', lastDocument);
    if (documentFormat != null) {
      b.attr(tagMime, 'document-format', documentFormat);
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
          : utf8.decode(data.sublist(i, i + nameLen), allowMalformed: true);
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
