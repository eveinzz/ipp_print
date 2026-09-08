import 'package:multicast_dns/multicast_dns.dart';

import '../capability/capability.dart';
import '../models.dart';

/// mDNS 打印机发现适配器（发现层唯一有状态/联网组件，保持薄）。
///
/// 同时浏览 `_ipp._tcp` 与 `_ipps._tcp`，按 [DiscoveredPrinter.identity]
/// 去重。记录组装逻辑全部在 [RecordAssembler]（纯函数，可离线测试）。
class MDnsPrinterDiscovery implements PrinterDiscovery {
  MDnsPrinterDiscovery({RecordAssembler? assembler})
      : _assembler = assembler ?? const RecordAssembler();

  final RecordAssembler _assembler;

  /// 浏览的服务类型：`_ipp._tcp` / `_ipps._tcp` 覆盖全部 IPP 广播；
  /// `_universal._sub._ipp._tcp` 是 Apple AirPrint 推荐浏览的 universal
  /// 子类型（对 _ipp._tcp 漏收 PTR 的实例提供第二次捕获机会），重叠由
  /// [DiscoveredPrinter.identity] 去重吸收。
  static const List<String> serviceTypes = <String>[
    '_ipp._tcp.local',
    '_ipps._tcp.local',
    '_universal._sub._ipp._tcp.local',
  ];

  /// 在 [timeout] 内浏览局域网并返回去重后的打印机列表。
  @override
  Future<List<DiscoveredPrinter>> discover({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final client = MDnsClient();
    final printers = <String, DiscoveredPrinter>{};
    try {
      await client.start();
      for (final serviceType in serviceTypes) {
        await for (final ptr in client.lookup<PtrResourceRecord>(
          ResourceRecordQuery.serverPointer(serviceType),
          timeout: timeout,
        )) {
          final printer = await _resolveInstance(
            client,
            ptr.domainName,
            timeout,
            secure: serviceType == '_ipps._tcp.local',
          );
          if (printer == null) continue;
          // 去重偏好：同一 UUID 双广播（_ipp + _ipps）时保留明文实例，
          // 避免不必要的 TLS 开销与自签证书问题（RFC 6763 同名服务合并）。
          final existing = printers[printer.identity];
          if (existing == null || (existing.secure && !printer.secure)) {
            printers[printer.identity] = printer;
          }
        }
      }
    } finally {
      client.stop();
    }
    return printers.values.toList(growable: false);
  }

  Future<DiscoveredPrinter?> _resolveInstance(
    MDnsClient client,
    String fullName,
    Duration timeout, {
    bool secure = false,
  }) async {
    // SRV 与 TXT 并行查询（A 记录依赖 SRV target，只能在其后）。
    final srvFuture = _first<SrvResourceRecord>(
      client.lookup<SrvResourceRecord>(
        ResourceRecordQuery.service(fullName),
        timeout: timeout,
      ),
    );
    final txtFuture = _first<TxtResourceRecord>(
      client.lookup<TxtResourceRecord>(
        ResourceRecordQuery.text(fullName),
        timeout: timeout,
      ),
    );
    final srv = await srvFuture;
    if (srv == null) return null;
    final pair = await Future.wait(<Future<ResourceRecord?>>[
      txtFuture,
      _first<IPAddressResourceRecord>(
        client.lookup<IPAddressResourceRecord>(
          ResourceRecordQuery.addressIPv4(srv.target),
          timeout: timeout,
        ),
      ),
    ]);
    final txt = pair[0] as TxtResourceRecord?;
    final ip = pair[1] as IPAddressResourceRecord?;
    return _assembler.assemble(
      InstanceRecords(
        instanceName: _instanceNameOf(fullName),
        srvTarget: srv.target,
        srvPort: srv.port,
        txtRaw: txt?.text.codeUnits,
        ipv4: ip?.address,
        secure: secure,
      ),
    );
  }

  /// 取流首条记录；空流/出错一律返回 null（发现层不抛异常）。
  Future<T?> _first<T extends ResourceRecord>(Stream<T> stream) async {
    try {
      return await stream.first;
    } on StateError {
      return null;
    } on Exception {
      return null;
    }
  }

  /// "EPSON L3250 Series._ipp._tcp.local" → "EPSON L3250 Series"。
  static String _instanceNameOf(String fullName) {
    final dot = fullName.indexOf('.');
    return dot < 0 ? fullName : fullName.substring(0, dot);
  }
}
