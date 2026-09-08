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

  /// 仅厂商私有格式（如 application/vnd.epson.escpr）：本包不传输。
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

  /// 是否可由本包直连打印。
  bool get isDirectPrintable => capability == PrinterCapability.ippDirect;
}

/// 打印选项（只收录 IPP 标准属性，字段随所选打印机协商结果生成）。
class PrintOptions {
  const PrintOptions({
    this.copies = 1,
    this.media = 'iso_a4_210x297mm',
    this.colorMode = 'monochrome',
    this.duplex = 'one-sided',
  });

  /// 打印份数（job 属性 `copies`，integer）。
  final int copies;

  /// PWG 介质自描述名（job 属性 `media`；取值应来自
  /// [PrinterInfo.mediaSupported]，否则打印机可能拒绝）。
  final String media;

  /// 色彩模式（job 属性 `print-color-mode`：monochrome/color）。
  final String colorMode;

  /// 双面模式（job 属性 `sides`：one-sided/two-sided-long-edge 等）。
  final String duplex;
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
