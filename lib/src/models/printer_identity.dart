/// 发现与身份域模型：能力分级、探测状态机、发现抽象与规范化打印机。
///
/// 所有能力判定必须来自打印机广播的确定性字段，禁止推断。
library;

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
    this.manualEndpoint = false,
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

  /// 是否为手动直连端点（0.7 [addEndpoint] 产出；发现层恒为 false）。
  ///
  /// 语义：URI 本身即 IPP endpoint 存在性的**用户断言**——TXT 分类门
  /// （unknown 否定）对其豁免，能力判定交给 probe / print 的实时查询 +
  /// 协商器终审（probe 驱动）。豁免仅此一处，不外溢到发现打印机。
  final bool manualEndpoint;

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
