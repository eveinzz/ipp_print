// 原生 Bonjour 发现适配器测试（纯 package:test，端口伪造，不触网）。
//
// 锚点：记录组装字段映射 / identity 去重偏好（明文优先）/
// 关键字段缺失跳过不猜 / 资源路径策略（缺失即跳过，不造假路径）/
// TXT 键大小写不敏感（RFC 6763 §6.2）与键归一小写契约 /
// 通道错误如实传播。
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

  test('rp 缺失 → 跳过，不造假路径（两条通道同解，见 discovery_rp_policy_test）', () async {
    final api = _FakeApi([
      _rec(rp: null, txt: {'pdl': 'image/pwg-raster'}),
    ]);
    final printers = await NativeBonjourDiscovery(api: api).discover();

    expect(printers, isEmpty);
  });

  test('rp 为空串 → 跳过（Apple 规范里 rp 的默认值即空串，等同缺失）', () async {
    final api = _FakeApi([
      _rec(rp: '', txt: {'pdl': 'image/pwg-raster'}),
    ]);
    expect(await NativeBonjourDiscovery(api: api).discover(), isEmpty);
  });

  test('TXT 键大小写不敏感：大写 RP= 也能解析出真实路径', () async {
    // 原生侧 NetService.dictionary 保留线路原样大小写，Swift 抽取只认字面量
    // "rp" → 大写键时便利字段必缺。此处 rp 值刻意与旧兜底 /ipp/print 不同，
    // 故旧行为（造路径）会给出错误结果而非碰巧正确。
    final api = _FakeApi([
      _rec(rp: null, txt: {'pdl': 'image/pwg-raster', 'RP': 'ipp/queue'}),
    ]);
    final printers = await NativeBonjourDiscovery(api: api).discover();

    expect(printers.single.resourcePath, '/ipp/queue');
  });

  test('TXT 键归一为小写（DiscoveredPrinter.txt 契约）', () async {
    final api = _FakeApi([
      _rec(txt: {'PDL': 'image/pwg-raster', 'rp': 'ipp/print'}),
    ]);
    final txt = (await NativeBonjourDiscovery(api: api).discover()).single.txt;

    expect(txt.keys, contains('pdl'));
    expect(txt.keys, isNot(contains('PDL')));
  });

  test('原生通道错误如实传播（宿主呈现 discoveryError，不静默伪装空态）', () async {
    final api = _FakeApi(const [], error: StateError('permission'));
    expect(
      NativeBonjourDiscovery(api: api).discover(),
      throwsStateError,
    );
  });
}
