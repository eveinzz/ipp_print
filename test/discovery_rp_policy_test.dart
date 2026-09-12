// 资源路径策略的**跨路径契约锚点**（0.7.3）。
//
// 存在理由：同一契约有两份独立实现 —— multicast_dns 路径的
// `RecordAssembler.assemble` 与原生 Bonjour 路径的 `_assemble` —— 中间没有
// 任何同步机制。这是本项目记录在案的头号缺陷源（同契约双实现漂移）。
// 本文件把**同一条线路 TXT 记录**同时喂给两条路径，逐格断言「跳过 / 路径」
// 判定完全一致；任一实现单边漂移即转红。
//
// 用例「大写键」刻意让 rp 值与旧兜底 `/ipp/print` 不同：旧行为下两条路径会
// 给出不同结果（原生造路径 vs mDNS 读到真值），正是漂移的实锤。
import 'package:ipp_print/src/capability/capability.dart';
import 'package:ipp_print/src/discovery/native_bonjour_discovery.dart';
import 'package:ipp_print/src/discovery/resource_path.dart';
import 'package:test/test.dart';

/// 一条线路 TXT 记录（键保持原样大小写；空值形如 `rp=`）。
const _wireCases = <Map<String, String>>[
  <String, String>{}, // 完全无 TXT
  <String, String>{'rp': ''}, // rp 空值
  <String, String>{'rp': 'ipp/print'}, // 规范形态（值 MUST NOT 以斜杠开头）
  <String, String>{'rp': '/ipp/print'}, // 已带前导斜杠
  <String, String>{'RP': 'ipp/queue'}, // 大写键（RFC 6763 §6.2 大小写不敏感）
  <String, String>{'pdl': 'image/pwg-raster'}, // 有 TXT 但无 rp
];

/// mDNS 路径：走纯函数组装器。
String? _mdnsPath(Map<String, String> txt) {
  final raw = txt.entries.map((e) => '${e.key}=${e.value}').join('\x00');
  final printer = const RecordAssembler().assemble(
    InstanceRecords(
      instanceName: 'EPSON L3250 Series',
      srvTarget: 'printer.local.',
      srvPort: 631,
      txtRaw: raw.codeUnits,
    ),
  );
  return printer?.resourcePath;
}

/// 原生路径：忠实模拟原生侧组装 —— `item['txt']` 是原样字典，而 `item['rp']`
/// 只在字典里存在**字面量小写** `"rp"` 时才被抽出（Swift 侧 `txt["rp"]` 行为）。
Future<String?> _nativePath(Map<String, String> txt) async {
  final item = <Object?, Object?>{
    'name': 'EPSON L3250 Series',
    'host': '192.168.0.106',
    'port': 631,
    'secure': false,
    'txt': txt,
    if (txt.containsKey('rp')) 'rp': txt['rp'],
  };
  final printers =
      await NativeBonjourDiscovery(api: _SingleItemApi(item)).discover();
  return printers.isEmpty ? null : printers.single.resourcePath;
}

class _SingleItemApi implements BonjourNativeApi {
  _SingleItemApi(this.item);

  final Map<Object?, Object?> item;

  @override
  Future<List<Map<Object?, Object?>>> browse({
    required List<String> serviceTypes,
    required Duration timeout,
  }) async =>
      <Map<Object?, Object?>>[item];
}

void main() {
  test('单源真值表：缺失/空串 ⇒ null；无前导斜杠则补上', () {
    expect(resolveResourcePath(null), isNull);
    expect(resolveResourcePath(''), isNull);
    expect(resolveResourcePath('ipp/print'), '/ipp/print');
    expect(resolveResourcePath('/ipp/print'), '/ipp/print');
  });

  test('两条发现路径对同一线路 TXT 逐格同解（不漂移）', () async {
    for (final txt in _wireCases) {
      expect(await _nativePath(txt), _mdnsPath(txt),
          reason: 'TXT=$txt 时原生路径与 mDNS 路径判定不一致');
    }
  });

  test('约定结果：有可用 rp 才给出路径，否则一律跳过（不造路径）', () async {
    final resolved = <String?>[];
    for (final txt in _wireCases) {
      resolved.add(await _nativePath(txt));
    }
    expect(resolved, <String?>[
      null, // 完全无 TXT
      null, // rp 空值（Apple 规范里 rp 的默认值，等同缺失）
      '/ipp/print',
      '/ipp/print',
      '/ipp/queue', // 大写键也须解析出真实值
      null, // 有 TXT 但无 rp
    ]);
  });
}
