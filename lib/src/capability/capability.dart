import 'dart:io' show InternetAddress;

import '../models.dart';

/// 确定性能力分类器：只依据打印机自报字段，任何分支都有记录依据。
class CapabilityClassifier {
  const CapabilityClassifier._();

  /// 解析 mDNS TXT 原始字节（`key=value` 串，key 归一为小写）。
  static Map<String, String> parseTxtBytes(List<int> raw) {
    final text = String.fromCharCodes(raw);
    final result = <String, String>{};
    for (final pair in text.split('\x00')) {
      if (pair.isEmpty) continue;
      final eq = pair.indexOf('=');
      if (eq < 0) continue;
      result[pair.substring(0, eq).toLowerCase()] = pair.substring(eq + 1);
    }
    return result;
  }

  /// 按如下优先级分级（RFC 8011 / Apple AirPrint 规约）：
  /// 1. 有 `URF=` 键或 pdl 含 `image/urf` → airPrint；
  /// 2. pdl 含 `image/pwg-raster` → ippDirect；
  /// 3. pdl 非空（仅厂商私有格式）→ vendorOnly；
  /// 4. 其余 → unknown。
  static PrinterCapability classify(Map<String, String> txt) {
    // 防御式归一：允许调用方传入未归一键（如手写构造的 TXT，键 'URF'）。
    final lower = {
      for (final e in txt.entries) e.key.toLowerCase(): e.value,
    };
    final pdl = (lower['pdl'] ?? '').toLowerCase();
    final urf = lower['urf'] ?? '';
    if (urf.isNotEmpty || pdl.contains('image/urf')) {
      return PrinterCapability.airPrint;
    }
    if (pdl.contains('image/pwg-raster')) {
      return PrinterCapability.ippDirect;
    }
    if (pdl.isNotEmpty) {
      return PrinterCapability.vendorOnly;
    }
    return PrinterCapability.unknown;
  }
}

/// mDNS 单实例记录组（由发现层逐字段填充，组装器消费）。
class InstanceRecords {
  const InstanceRecords({
    required this.instanceName,
    this.srvTarget,
    this.srvPort,
    this.txtRaw,
    this.ipv4,
    this.secure = false,
  });

  final String instanceName;
  final String? srvTarget;
  final int? srvPort;
  final List<int>? txtRaw;
  final InternetAddress? ipv4;

  /// 该实例是否来自 `_ipps._tcp` 广播（决定传输通道与逻辑 scheme）。
  final bool secure;
}

/// 纯函数组装器：把同实例的 PTR/SRV/TXT/A 记录组装配为 [DiscoveredPrinter]。
/// 可离线单测，不触碰网络。
class RecordAssembler {
  const RecordAssembler({this.requireIpv4 = false});

  /// 宿主环境（iOS）在无 IPv4 时也可用主机名解析，故默认不强制。
  final bool requireIpv4;

  /// 返回 null 表示记录不完整（缺少 SRV 或资源路径），该实例应被跳过。
  DiscoveredPrinter? assemble(InstanceRecords r) {
    final target = r.srvTarget;
    final port = r.srvPort;
    if (target == null || port == null) return null;
    final txt = r.txtRaw == null
        ? const <String, String>{}
        : CapabilityClassifier.parseTxtBytes(r.txtRaw!);
    final rp = txt['rp'];
    if (rp == null || rp.isEmpty) return null;
    final rawHost = r.ipv4?.address ?? target;
    final host = rawHost.endsWith('.') ? rawHost.substring(0, rawHost.length - 1) : rawHost;
    if (host.isEmpty) return null;
    if (requireIpv4 && r.ipv4 == null) return null;
    return DiscoveredPrinter(
      name: r.instanceName,
      host: host,
      port: port,
      resourcePath: rp.startsWith('/') ? rp : '/$rp',
      uuid: txt['uuid'],
      secure: r.secure,
      txt: txt,
    );
  }
}
