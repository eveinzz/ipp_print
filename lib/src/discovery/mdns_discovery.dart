import 'package:meta/meta.dart';
import 'package:multicast_dns/multicast_dns.dart';

import '../capability/capability.dart';
import '../ipp/ipp_log.dart';
import '../models.dart';

/// mDNS 打印机发现适配器（发现层唯一有状态/联网组件，保持薄）。
///
/// 同时浏览 `_ipp._tcp` 与 `_ipps._tcp`，按 [DiscoveredPrinter.identity]
/// 去重。记录组装逻辑全部在 [RecordAssembler]（纯函数，可离线测试）。
///
/// 诊断：**跳过必留原因**——「打印机没被发现」在 mDNS 轴上有三条互不相同的
/// 成因（缺 SRV target / TXT 无可用 rp / 查询异常），不留痕时三者输出完全
/// 一致，无从归因。异常记录后仍**不抛出**：本层契约是返回空集，不向上抛。
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
  ///
  /// 三类服务**并行**浏览（0.3）：最坏耗时从 顺序 3×timeout 降为
  /// ≈单窗口 timeout；各分支结果经 [mergeDedup] 按 identity 合并，
  /// 同 UUID 双广播（_ipp + _ipps）保留明文实例。
  @override
  Future<List<DiscoveredPrinter>> discover({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final client = MDnsClient();
    try {
      await client.start();
      final perType = await Future.wait(<Future<List<DiscoveredPrinter>>>[
        for (final serviceType in serviceTypes)
          _browseType(client, serviceType, timeout),
      ]);
      final merged = mergeDedup(perType);
      ippLog('mdns browse done: ${merged.length} printer(s) after dedup '
          '(raw per type: ${perType.map((l) => l.length).toList()})');
      return merged;
    } finally {
      client.stop();
    }
  }

  /// 单一服务类型的浏览与解析（PTR → SRV/TXT/A）。
  Future<List<DiscoveredPrinter>> _browseType(
    MDnsClient client,
    String serviceType,
    Duration timeout,
  ) async {
    final found = <DiscoveredPrinter>[];
    final secure = serviceType == '_ipps._tcp.local';
    await for (final ptr in client.lookup<PtrResourceRecord>(
      ResourceRecordQuery.serverPointer(serviceType),
      timeout: timeout,
    )) {
      final printer = await _resolveInstance(
        client,
        ptr.domainName,
        timeout,
        secure: secure,
      );
      if (printer != null) {
        ippLog('mdns $serviceType: + ${printer.name} ${printer.httpUriString}');
        found.add(printer);
      } else {
        // 跳过原因单源：resource_path.dart 的「无可用 rp ⇒ 跳过，绝不造路径」
        // 与「缺 SRV target」是仅有的两条拒绝路径，如实并列，不猜是哪条。
        ippLog('mdns $serviceType: - ${_instanceNameOf(ptr.domainName)} '
            'skipped (SRV missing, or TXT carries no usable rp)');
      }
    }
    return found;
  }

  /// 跨类型结果合并：按 [DiscoveredPrinter.identity] 去重，同一 UUID
  /// 双广播（_ipp + _ipps）时保留明文实例（避免不必要的 TLS 开销与
  /// 自签证书问题；RFC 6763 同名服务合并）。
  @visibleForTesting
  static List<DiscoveredPrinter> mergeDedup(
    Iterable<List<DiscoveredPrinter>> sources,
  ) {
    final printers = <String, DiscoveredPrinter>{};
    for (final printer in sources.expand((s) => s)) {
      final existing = printers[printer.identity];
      if (existing == null || (existing.secure && !printer.secure)) {
        printers[printer.identity] = printer;
      }
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
    if (srv == null) {
      ippLog('mdns $fullName: no SRV record -> cannot derive host/port');
      return null;
    }
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
    if (ip == null) {
      ippLog('mdns $fullName: no IPv4 A record for ${srv.target} '
          '(IPv6-only network, or the record did not arrive in the window)');
    }
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
  ///
  /// 异常在此记录后仍返回 null——否则超时与协议错误在输出上不可区分。
  Future<T?> _first<T extends ResourceRecord>(Stream<T> stream) async {
    try {
      return await stream.first;
    } on StateError {
      ippLog('mdns lookup: no $T record in the browse window');
      return null;
    } on Exception catch (e) {
      ippLog('mdns lookup error ($T): $e');
      return null;
    }
  }

  /// "EPSON L3250 Series._ipp._tcp.local" → "EPSON L3250 Series"。
  static String _instanceNameOf(String fullName) {
    final dot = fullName.indexOf('.');
    return dot < 0 ? fullName : fullName.substring(0, dot);
  }
}
