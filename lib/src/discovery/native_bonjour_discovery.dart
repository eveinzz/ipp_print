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

import '../models.dart';
import 'mdns_discovery.dart' show MDnsPrinterDiscovery;

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
    final out = <String, DiscoveredPrinter>{};
    for (final item in items) {
      final printer = _assemble(item);
      if (printer == null) continue;
      // 与 MDnsPrinterDiscovery 一致：同一 UUID 双广播保留明文实例。
      final key = printer.identity;
      final existing = out[key];
      if (existing == null || (existing.secure && !printer.secure)) {
        out[key] = printer;
      }
    }
    return out.values.toList(growable: false);
  }

  /// 原生记录 → [DiscoveredPrinter]（缺关键字段即跳过，不猜）。
  DiscoveredPrinter? _assemble(Map<Object?, Object?> item) {
    final name = item['name'];
    final host = item['host'];
    final port = item['port'];
    if (name is! String || host is! String || port is! int) return null;
    final rp = item['rp'];
    final txtRaw = item['txt'];
    final txt = txtRaw is Map
        ? txtRaw.map((k, v) => MapEntry(k.toString(), v.toString()))
        : const <String, String>{};
    final path = rp is String && rp.isNotEmpty
        ? (rp.startsWith('/') ? rp : '/$rp')
        : '/ipp/print';
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
