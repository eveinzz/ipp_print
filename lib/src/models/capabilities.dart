/// 能力域模型：probe 结果、完整能力自报、Validate-Job 结构化结果。
///
/// 全部字段来自打印机对协议查询的确定性自报，缺失 = null/空，禁止推断。
library;

import 'printer_identity.dart';

/// probe() 的完整结果：能力 + 协商出的打印能力（介质等）。
class PrinterInfo {
  const PrinterInfo({
    required this.capability,
    this.mediaSupported = const <String>[],
    this.documentFormats = const <String>[],
    this.state,
    this.makeModel,
    this.colorModesSupported = const <String>[],
    this.colorModeDefault,
    this.sidesSupported = const <String>[],
    this.sidesDefault,
    this.resolutionsSupported = const <String>[],
    this.resolutionDefault,
  });

  /// 综合能力等级（TXT 与 IPP 双源交叉验证后的结论）。
  final PrinterCapability capability;

  /// 打印机声明支持的介质名（PWG 5101.1 自描述名，如 `iso_a4_210x297mm`）。
  final List<String> mediaSupported;

  /// 打印机声明支持的文档 MIME 格式。
  final List<String> documentFormats;

  /// IPP printer-state（idle/processing/stopped；RFC 8011 §5.4.11）。
  final String? state;

  /// 厂商与型号描述（`printer-make-and-model`）。
  final String? makeModel;

  /// 打印机声明支持的色彩模式（`print-color-mode-supported`）。
  ///
  /// 供宿主 UI 生成可选项：**只允许展示该列表内的取值**
  /// （能力只来自 IPP 确定性字段，禁止推断）。空 = 未声明。
  final List<String> colorModesSupported;

  /// 打印机默认色彩模式（`print-color-mode-default`）；null = 未声明。
  final String? colorModeDefault;

  /// 打印机声明支持的双面模式（`sides-supported`）。
  /// 空 = 未声明（此时仅 `one-sided` 安全）。
  final List<String> sidesSupported;

  /// 打印机默认双面模式（`sides-default`）；null = 未声明。
  final String? sidesDefault;

  /// 打印机声明支持的分辨率（`printer-resolution-supported`，格式化
  /// `横x纵单位`，如 `360x360dpi`；RFC 8011 §5.1.16 resolution 语法）。
  ///
  /// 供宿主在栅格化前协商 dpi：**下发值应取自该列表**（否则属请求
  /// 打印机做未声明之事，宽容机型接受、严格机型可能拒收或异常渲染）。
  /// 空 = 未声明。
  final List<String> resolutionsSupported;

  /// 打印机默认分辨率（`printer-resolution-default`）；null = 未声明。
  final String? resolutionDefault;

  /// 是否可由本包直连打印。
  bool get isDirectPrintable => capability == PrinterCapability.ippDirect;
}

/// 打印机完整能力模型（0.3 Capability Engine）。
///
/// **全部字段来自打印机对 Get-Printer-Attributes 的确定性自报**
/// （RFC 8011 §6.2：响应中不出现 = 不支持）；解析一律 lenient——
/// 打印机截断/省略任何属性时对应字段为 null/空，绝不推断补值。
/// 数据源：[IppPrint.inspect]（完整 `fullCapabilityAttributeSet`）。
class PrinterCapabilities {
  const PrinterCapabilities({
    this.name,
    this.info,
    this.makeModel,
    this.urisSupported = const <String>[],
    this.state,
    this.stateReasons = const <String>[],
    this.isAcceptingJobs,
    this.documentFormats = const <String>[],
    this.documentFormatDefault,
    this.mediaSupported = const <String>[],
    this.mediaReady = const <String>[],
    this.colorModesSupported = const <String>[],
    this.colorModeDefault,
    this.sidesSupported = const <String>[],
    this.sidesDefault,
    this.resolutionsSupported = const <String>[],
    this.resolutionDefault,
    this.copiesMin,
    this.copiesMax,
    this.finishingsSupported = const <int>[],
    this.printQualitiesSupported = const <int>[],
    this.printQualityDefault,
    this.ippVersionsSupported = const <String>[],
    this.operationsSupported = const <int>[],
    this.jobCreationAttributesSupported = const <String>[],
    this.uriAuthenticationSupported = const <String>[],
    this.uriSecuritySupported = const <String>[],
  });

  /// `printer-name`（必返属性，RFC 8011 §5.4.4；null = 打印机未按请求返回）。
  ///
  /// ⚠️ 真机事实（L3250，2026-09）：EPSON 返回 URI 路径片段 `ipp/print`
  /// 而非人类可读名——厂商实现各异，**不可当 UI 显示名**；显示名应使用
  /// mDNS 实例名（[DiscoveredPrinter.name]）或 `printer-info`。
  final String? name;

  /// `printer-info`（人类可读描述）。
  final String? info;

  /// `printer-make-and-model`（厂商与型号）。
  final String? makeModel;

  /// `printer-uri-supported`（该端点可用的逻辑 IPP URI 列表）。
  final List<String> urisSupported;

  /// `printer-state`（idle/processing/stopped；RFC 8011 §5.4.11）。
  final String? state;

  /// `printer-state-reasons`（如 `media-jam`、`toner-empty`；RFC 8011 §5.4.12）。
  final List<String> stateReasons;

  /// `printer-is-accepting-jobs`（boolean；null = 未声明）。
  final bool? isAcceptingJobs;

  /// `document-format-supported`（0.4 格式协商的数据源）。
  final List<String> documentFormats;

  /// `document-format-default`。
  final String? documentFormatDefault;

  /// `media-supported`（PWG 5101.1 自描述介质名全集）。
  final List<String> mediaSupported;

  /// `media-ready`（当前已就绪的介质，如各纸盒实装的纸张）。
  final List<String> mediaReady;

  /// `print-color-mode-supported`（PWG 5107.3 §6.2.27 八值子集）。
  final List<String> colorModesSupported;

  /// `print-color-mode-default`。
  final String? colorModeDefault;

  /// `sides-supported`（one-sided / two-sided-*-edge）。
  final List<String> sidesSupported;

  /// `sides-default`。
  final String? sidesDefault;

  /// `printer-resolution-supported`（格式化 `横x纵单位`，如 `600x600dpi`；
  /// resolution 语法 = cross(int32)+feed(int32)+unit(3=dpi/4=dpcm)，RFC 8011
  /// §5.1.16）。
  final List<String> resolutionsSupported;

  /// `printer-resolution-default`（同上格式；null = 未声明）。
  final String? resolutionDefault;

  /// `copies-supported`（rangeOfInteger 下界；null = 未声明）。
  final int? copiesMin;

  /// `copies-supported`（rangeOfInteger 上界；null = 未声明）。
  final int? copiesMax;

  /// `finishings-supported`（1setOf type2 **enum**，RFC 8011 §5.2.6：
  /// 3=none、4=staple…；原始 enum 值，不猜测映射语义）。
  final List<int> finishingsSupported;

  /// `print-quality-supported`（1setOf type2 **enum**，RFC 8011 §5.2.13：
  /// 3=draft、4=normal、5=high；原始 enum 值，厂商扩展原样透出）。
  final List<int> printQualitiesSupported;

  /// `print-quality-default`（原始 enum 值；null = 未声明）。
  final int? printQualityDefault;

  /// `ipp-versions-supported`（如 `1.1`）。
  final List<String> ippVersionsSupported;

  /// `operations-supported`（IANA 操作码原始 enum 值，如 0x0002=Print-Job）。
  final List<int> operationsSupported;

  /// `job-creation-attributes-supported`（哪些 job 属性可随作业提交）。
  final List<String> jobCreationAttributesSupported;

  /// `uri-authentication-supported`（none/basic/digest/…，与 uris 一一对应）。
  final List<String> uriAuthenticationSupported;

  /// `uri-security-supported`（none/tls，与 uris 一一对应）。
  final List<String> uriSecuritySupported;
}

/// Validate-Job 的结构化结果（RFC 8011 §4.2.3）。
///
/// [valid] = 打印机返回成功状态码（同构 Print-Job 会被接受）；
/// [unsupportedAttributes] 为响应 Unsupported Attributes 组（组 2）中
/// 打印机声明无法支持的属性名——打印机接受作业但会忽略这些取值，
/// 宿主可据此调整 ticket 或提示用户。
class PrintValidationResult {
  const PrintValidationResult({
    required this.valid,
    required this.statusCode,
    this.unsupportedAttributes = const <String>[],
  });

  /// true = 打印机明确接受同构作业（可放心提交文档数据）。
  final bool valid;

  /// 原始 IPP status-code（成功区间 0x0000–0x00FF）。
  final int statusCode;

  /// 打印机不支持的属性名（来自 Unsupported Attributes 组）。
  final List<String> unsupportedAttributes;
}
