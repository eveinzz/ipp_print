/// 核心领域模型：打印机、能力分级、打印选项、栅格页与异常体系。
///
/// 所有能力判定必须来自打印机广播/协议响应的确定性字段，禁止推断。
library;

import 'dart:typed_data';

/// 打印能力等级（确定性判定）。
///
/// 判据来源：mDNS TXT 记录的 `URF=` 键与 `pdl=` 键。
enum PrinterCapability {
  /// 支持 AirPrint（有 URF 键或 pdl 含 image/urf）：应交还系统打印面板。
  airPrint,

  /// 无 AirPrint 但声明 image/pwg-raster：可走本包 IPP 直连。
  ippDirect,

  /// 无可直连的栅格路径：pdl 非空但不含 image/pwg-raster（厂商私有
  /// 格式如 application/vnd.epson.escpr，或仅声明 PDF/JPEG 等非栅格
  /// 格式）。本包当前仅传输 PWG 栅格，此类设备不可直连——注意语义
  /// 是「本包不可达」而非「仅厂商私有」（TODO 0.4 能力图方向）。
  vendorOnly,

  /// 广播缺少可判定字段。
  unknown,
}

/// 单台打印机的探测状态机。
enum PrinterProbeStatus { unknown, probing, ready, unsupported, offline }

/// 打印机发现抽象（端口）：发现层可替换/伪造，供测试与平台扩展。
abstract class PrinterDiscovery {
  Future<List<DiscoveredPrinter>> discover({
    Duration timeout = const Duration(seconds: 5),
  });
}

/// mDNS 发现的一台打印机（原始记录的规范化封装）。
class DiscoveredPrinter {
  DiscoveredPrinter({
    required this.name,
    required this.host,
    required this.port,
    required this.resourcePath,
    this.uuid,
    this.secure = false,
    Map<String, String>? txt,
  })  : txt = Map.unmodifiable(txt ?? const <String, String>{}),
        assert(resourcePath.startsWith('/'), 'resourcePath must start with /');

  /// mDNS 实例名（含机型，如 "EPSON L3250 Series"）。
  final String name;

  /// 打印机 UUID（TXT `UUID=` 键；跨 IP 变化识别同一台设备的稳定键）。
  final String? uuid;

  /// SRV 记录的 target 主机名。
  final String host;

  /// SRV 记录端口（IPP 通常 631）。
  final int port;

  /// TXT `rp=` 记录的资源路径（以 / 开头，如 `/ipp/print`）。
  final String resourcePath;

  /// 原始 TXT 键值（小写键，值原样）。
  final Map<String, String> txt;

  /// 传输是否加密（该实例来自 `_ipps._tcp` 广播）。
  ///
  /// 同一 UUID 同时广播 `_ipp` 与 `_ipps` 时，发现层保留明文实例
  /// （见 [PrinterDiscovery] 实现的去重偏好）。
  final bool secure;

  /// 逻辑 IPP URI 字符串（保序，用于 printer-uri 属性；RFC 8011 §4.1.5
  /// 要求 scheme 恒为 ipp/ipps 逻辑 scheme，与 HTTP 传输通道无关）。
  /// Uri.toString 会把 host 归一为小写，破坏与广播记录的一致性，故不用。
  String get ippUriString => '${secure ? 'ipps' : 'ipp'}://$host:$port$resourcePath';

  /// HTTP 传输地址字符串（保序；secure 时走 https）。
  String get httpUriString =>
      '${secure ? 'https' : 'http'}://$host:$port$resourcePath';

  /// 逻辑 IPP URI（按 RFC 8011 用于 printer-uri 属性）。
  Uri get ippUri => Uri(
      scheme: secure ? 'ipps' : 'ipp', host: host, port: port,
      path: resourcePath);

  /// HTTP 传输地址（IPP over HTTP(S) 的 POST 端点）。
  Uri get httpUri => Uri(
      scheme: secure ? 'https' : 'http', host: host, port: port,
      path: resourcePath);

  /// 稳定身份键：优先 UUID，回退到 实例名@host:port。
  String get identity => uuid ?? '$name@$host:$port';

  @override
  String toString() => 'DiscoveredPrinter($name, $host:$port$resourcePath)';
}

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
  /// `横x纵单位`，如 `360x360dpi`；RFC 8011 §5.1.14 resolution 语法）。
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
  /// §5.1.14）。
  final List<String> resolutionsSupported;

  /// `printer-resolution-default`（同上格式；null = 未声明）。
  final String? resolutionDefault;

  /// `copies-supported`（rangeOfInteger 下界；null = 未声明）。
  final int? copiesMin;

  /// `copies-supported`（rangeOfInteger 上界；null = 未声明）。
  final int? copiesMax;

  /// `finishings-supported`（1setOf type2 **enum**，RFC 8011 §5.2.3：
  /// 3=none、4=staple…；原始 enum 值，不猜测映射语义）。
  final List<int> finishingsSupported;

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

/// 打印选项（只收录 IPP 标准属性，字段随所选打印机协商结果生成）。
///
/// **统一语义：null = 不下发该属性**，由打印机应用自身默认值
/// （RFC 8011 §5.2 job template 默认值语义）。三个可空字段
/// （[media] / [colorMode] / [duplex]）同此规则——宿主无法从打印机
/// 声明能力中确定取值时，应传 null 而不是猜一个值。
class PrintOptions {
  const PrintOptions({
    this.copies = 1,
    this.media,
    this.colorMode,
    this.duplex,
  });

  /// 打印份数（job 属性 `copies`，integer）。
  final int copies;

  /// PWG 介质自描述名（job 属性 `media`）。
  ///
  /// 取值应来自 [PrinterInfo.mediaSupported]（打印机声明为准确），
  /// 否则打印机可能拒绝；null（默认）= 不下发，打印机使用自己的
  /// `media-default`。
  final String? media;

  /// 色彩模式（job 属性 `print-color-mode`）。
  ///
  /// null（默认）= **不下发该属性**，打印机使用自己的
  /// `print-color-mode-default`（RFC 8011 job template 默认值语义，
  /// PWG 5107.3/5100.13 §6.2.27；典型 default 为 `auto`，即按文档内容
  /// 自动选彩色/单色）。显式指定时取值须为 `print-color-mode-supported`
  /// 的成员（全集：auto/auto-monochrome/bi-level/color/highlight/
  /// monochrome/process-bi-level/process-monochrome）。
  final String? colorMode;

  /// 双面模式（job 属性 `sides`：one-sided/two-sided-long-edge 等）。
  ///
  /// null = 不下发，打印机使用自己的 `sides-default`；显式指定时取值
  /// 须为 `sides-supported` 的成员。
  final String? duplex;
}

/// 一页栅格位图（24 位 sRGB，逐行无填充 RGBRGB...）。
class RasterPage {
  const RasterPage({
    required this.width,
    required this.height,
    required this.bytes,
  }) : assert(bytes.length == width * height * 3);

  /// 像素宽（非物理毫米；由 dpi 换算）。
  final int width;

  /// 像素高。
  final int height;

  /// 逐行 RGB 字节，长度恒为 `width * height * 3`。
  final Uint8List bytes;
}

/// PDF 栅格化注入接口：插件不绑定渲染实现，宿主 App 提供
/// （例如基于 printing 包 rasterPdf 的适配器）。
abstract class PdfRasterizer {
  Stream<RasterPage> rasterize(List<int> pdfBytes, {int dpi});
}

/// 打印进度事件。
class PrintProgress {
  const PrintProgress(this.stage, {this.page, this.pageCount, this.jobId});

  final PrintStage stage;
  final int? page;
  final int? pageCount;

  /// IPP 作业号（`waitingPrinter` / `done` 阶段可用，供宿主取消作业）。
  final int? jobId;
}

enum PrintStage { rasterizing, encoding, sending, waitingPrinter, done }

/// 统一异常基类。
class IppPrintException implements Exception {
  const IppPrintException(this.message);
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// IPP 服务端返回错误状态码（status 不在 0x0000~0x00FF 成功区间）。
class IppStatusException extends IppPrintException {
  // 非 const：消息里包含运行时插值与方法调用。
  IppStatusException(this.statusCode, String message)
      : super('$message (IPP status 0x${statusCode.toRadixString(16)})');
  final int statusCode;
}

/// 打印任务未能在时限内到达终态。
class IppJobTimeoutException extends IppPrintException {
  const IppJobTimeoutException(this.jobId, String message)
      : super('job $jobId: $message');
  final int jobId;
}
