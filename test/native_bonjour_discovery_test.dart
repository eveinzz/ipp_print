// 原生 Bonjour 发现适配器测试（纯 package:test，端口伪造，不触网）。
//
// 锚点：记录组装字段映射 / identity 去重偏好（明文优先）/
// 关键字段缺失跳过不猜 / 通道错误如实传播。
import 'package:ipp_print/src/discovery/native_bonjour_discovery.dart';
import 'package:test/test.dart';

class _FakeApi implements BonjourNativeApi {
  _FakeApi(this.items, {this.error});

  final List<Map<Object?, Object?>> items;
  final Object? error;
  List<String>? lastTypes;
  Duration? lastTimeout;

  @override
  Future<List<Map<Object?, Object?>>> browse({
    required List<String> serviceTypes,
    required Duration timeout,
  }) async {
    lastTypes = serviceTypes;
    lastTimeout = timeout;
    if (error != null) throw error!;
    return items;
  }
}

Map<Object?, Object?> _rec({
  String name = 'EPSON L3250 Series',
  String host = '192.168.0.106',
  int port = 631,
  String? rp = 'ipp/print',
  String? uuid = 'uuid-l3250',
  bool secure = false,
  Map<String, String>? txt,
}) =>
    {
      'name': name,
      'host': host,
      'port': port,
      if (rp != null) 'rp': rp,
      if (uuid != null) 'uuid': uuid,
      'secure': secure,
      'txt': txt ?? {'pdl': 'image/pwg-raster', 'rp': 'ipp/print'},
    };

void main() {
  test('组装：字段映射正确，rp 补根斜杠，TXT 透传', () async {
    final api = _FakeApi([_rec()]);
    final printers = await NativeBonjourDiscovery(api: api).discover();

    expect(api.lastTypes, ['_ipp._tcp', '_ipps._tcp']);
    expect(printers, hasLength(1));
    final p = printers.single;
    expect(p.name, 'EPSON L3250 Series');
    expect(p.host, '192.168.0.106');
    expect(p.port, 631);
    expect(p.resourcePath, '/ipp/print');
    expect(p.uuid, 'uuid-l3250');
    expect(p.secure, false);
    expect(p.txt['pdl'], 'image/pwg-raster');
  });

  test('去重：同 UUID 双广播（_ipp + _ipps）保留明文实例', () async {
    final api = _FakeApi([
      _rec(secure: true, txt: {'pdl': 'image/pwg-raster'}),
      _rec(secure: false),
    ]);
    final printers = await NativeBonjourDiscovery(api: api).discover();

    expect(printers, hasLength(1));
    expect(printers.single.secure, false);
    expect(printers.single.identity, 'uuid-l3250');
  });

  test('缺关键字段（host/port）即跳过，不猜不崩', () async {
    final api = _FakeApi([
      {'name': 'broken'},
      _rec(name: 'OK'),
    ]);
    final printers = await NativeBonjourDiscovery(api: api).discover();

    expect(printers, hasLength(1));
    expect(printers.single.name, 'OK');
  });

  test('rp 缺失 → 默认 /ipp/print，不凭空造厂商路径', () async {
    final api = _FakeApi([_rec(rp: null)]);
    final printers = await NativeBonjourDiscovery(api: api).discover();

    expect(printers.single.resourcePath, '/ipp/print');
  });

  test('原生通道错误如实传播（宿主呈现 discoveryError，不静默伪装空态）', () async {
    final api = _FakeApi(const [], error: StateError('permission'));
    expect(
      NativeBonjourDiscovery(api: api).discover(),
      throwsStateError,
    );
  });
}
