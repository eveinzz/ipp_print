// 原生 Bonjour 发现适配器（iOS/macOS）。
//
// 为什么不用 multicast_dns：iOS 14+ 对原始 UDP socket 的组播收发要求
// `com.apple.developer.networking.multicast` 特批 entitlement；而系统
// Bonjour 框架（mDNSResponder 守护进程代收组播）豁免该权限，仅需
// 标准的「本地网络」授权（Info.plist 已声明）。
//
// 结构：[BonjourNativeApi] 端口可伪造（纯 package:test）；
// [MethodChannelBonjourApi] 是唯一的通道绑定壳；组装/去重逻辑在
// Dart 侧，与 MDnsPrinterDiscovery 的 identity 去重偏好一致。
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../ipp/ipp_log.dart';
import '../models.dart';
import 'mdns_discovery.dart' show MDnsPrinterDiscovery;
import 'resource_path.dart';

/// 原生浏览端口（供测试伪造；生产绑定 MethodChannel）。
abstract class BonjourNativeApi {
  Future<List<Map<Object?, Object?>>> browse({
    required List<String> serviceTypes,
    required Duration timeout,
  });
}

/// MethodChannel 绑定壳：唯一触达原生的一层。
class MethodChannelBonjourApi implements BonjourNativeApi {
  const MethodChannelBonjourApi([
    this._channel = const MethodChannel('ipp_print/bonjour'),
  ]);

  final MethodChannel _channel;

  @override
  Future<List<Map<Object?, Object?>>> browse({
    required List<String> serviceTypes,
    required Duration timeout,
  }) async {
    final raw = await _channel.invokeMethod<List<dynamic>>(
      'discover',
      <String, Object?>{
        'serviceTypes': serviceTypes,
        'timeoutMs': timeout.inMilliseconds,
      },
    );
    return (raw ?? const <dynamic>[]).cast<Map<Object?, Object?>>();
  }
}

/// Apple 平台的 PrinterDiscovery：原生 Bonjour 浏览 + Dart 侧组装。
class NativeBonjourDiscovery implements PrinterDiscovery {
  NativeBonjourDiscovery({BonjourNativeApi? api})
      : _api = api ?? const MethodChannelBonjourApi();

  final BonjourNativeApi _api;

  /// 与 MDnsPrinterDiscovery 相同的浏览集（省略 `.local` 后缀，
  /// 由原生侧补全域；`_universal._sub` 子类型由 NSNetServiceBrowser
  /// 不支持，靠 _ipp/_ipps 双广播已覆盖）。
  static const List<String> serviceTypes = <String>[
    '_ipp._tcp',
    '_ipps._tcp',
  ];

  @override
  Future<List<DiscoveredPrinter>> discover({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final items = await _api.browse(
      serviceTypes: serviceTypes,
      timeout: timeout,
    );
    ippLog('native browse -> ${items.length} item(s)');
    final out = <String, DiscoveredPrinter>{};
    for (final item in items) {
      final printer = _assemble(item);
      if (printer == null) {
        ippLog('native item skipped (missing key fields): $item');
        continue;
      }
      // 与 MDnsPrinterDiscovery 一致：同一 UUID 双广播保留明文实例。
      final key = printer.identity;
      final existing = out[key];
      if (existing == null || (existing.secure && !printer.secure)) {
        out[key] = printer;
      }
    }
    return out.values.toList(growable: false);
  }

  /// 原生记录 → [DiscoveredPrinter]；`name`/`host`/`port` 或**资源路径**
  /// 缺失即跳过（返回 null），不猜。
  ///
  /// 资源路径走 [resolveResourcePath] —— 与 `multicast_dns` 路径（
  /// `RecordAssembler.assemble`）**共用同一单源策略**。0.7.3 之前此处兜底
  /// `/ipp/print`，而 `multicast_dns` 路径同时丢弃：同一契约两份实现各自
  /// 演化（本项目头号缺陷源）。兜底之所以撤掉：Apple WWDC 2016 S725 的
  /// 「多数 AirPrint 打印机资源路径为 ipp/print」说的是打印机整体，不足以
  /// 支撑对**省略 rp 的子集**下断言，而 CUPS 参考实现从不据 `rp` 推导路径。
  ///
  /// TXT 键归一小写：原生侧 `NetService.dictionary(fromTXTRecord:)` 保留线路
  /// 原样大小写，而 RFC 6763 §6.2 规定键大小写不敏感、`DiscoveredPrinter.txt`
  /// 亦明文声明小写键。故**不能**只依赖原生侧用字面量 `"rp"` 抽出的便利字段。
  DiscoveredPrinter? _assemble(Map<Object?, Object?> item) {
    final name = item['name'];
    final host = item['host'];
    final port = item['port'];
    if (name is! String || host is! String || port is! int) return null;
    final txtRaw = item['txt'];
    final txt = txtRaw is Map
        ? <String, String>{
            for (final e in txtRaw.entries)
              e.key.toString().toLowerCase(): e.value.toString(),
          }
        : const <String, String>{};
    // 优先已归一的 TXT 原值（大小写不敏感），回退原生侧抽取的便利字段。
    final rp =
        txt['rp'] ?? (item['rp'] is String ? item['rp'] as String : null);
    final path = resolveResourcePath(rp);
    if (path == null) return null;
    return DiscoveredPrinter(
      name: name,
      host: host,
      port: port,
      resourcePath: path,
      uuid: item['uuid'] is String ? item['uuid'] as String : null,
      secure: item['secure'] == true,
      txt: txt,
    );
  }
}

/// 平台默认发现层工厂：Apple 走原生 Bonjour，其余维持 multicast_dns。
PrinterDiscovery defaultPlatformDiscovery() {
  if (Platform.isIOS || Platform.isMacOS) return NativeBonjourDiscovery();
  return MDnsPrinterDiscovery();
}
