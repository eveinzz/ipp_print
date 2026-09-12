/// 发现层资源路径策略（**单源**：两条发现通道共用）。
///
/// 为什么单独成文件：同一契约存在两份独立实现（`multicast_dns` 路径的
/// `RecordAssembler.assemble` 与原生 Bonjour 路径的 `_assemble`），中间没有
/// 任何同步机制 —— 这正是本项目的头号缺陷源（同契约双实现漂移）。策略收敛到
/// 此一处，并由 `test/discovery_rp_policy_test.dart` 对两条路径同时断言。
///
/// 规范依据（0.7.3 一手核对，出处留档于 CHANGELOG）：
/// - Apple *Bonjour Printing Specification* v1.2.1 Table 2：`rp` 的默认值为
///   空串，且「值等于默认值的键 MAY 省略」→ **`rp` 可被合法省略**；
/// - PWG 5100.14 *IPP Everywhere* p.22：打印机 **MUST** 提供 `rp`
///   → 省略 `rp` 的设备必然不是 IPP Everywhere / AirPrint 合规设备；
/// - RFC 6763 §6.2：TXT 键大小写不敏感（故读取前必须归一小写）。
library;

/// TXT `rp` 值 → 资源路径；**返回 null 表示路径未知，调用方必须跳过该实例**。
///
/// 为什么「未知即跳过」而不是兜底 `/ipp/print`：Apple 规范只给 `rp` 规定了
/// 默认值（空串），**没有**规定空路径对应哪个 HTTP 端点；CUPS 参考实现亦从不
/// 依据 `rp` 推导路径（`backend/dnssd.c`、`cups/dnssd.c`、`cups/dest.c` 等
/// 文件对 `"rp"` 零命中），macOS 把路径解析推迟到连接期。因此在 `rp` 缺失时
/// 填一个具体路径，是把「未知」写成「已知」：设备会出现在列表里，却在打印时
/// 以难以归因的错误失败。跳过则诚实，且代价可逆 —— 用户仍可用
/// `IppPrint.addEndpoint` 显式给出路径（手动端点本身即用户的断言，模型对其
/// 有明文豁免）。
///
/// 归一：完整 URI 路径须以 `/` 开头；Apple 规范要求 `rp` 的值 MUST NOT 以
/// 斜杠开头，故无前导斜杠时补一个。
String? resolveResourcePath(String? rawRp) {
  if (rawRp == null || rawRp.isEmpty) return null;
  return rawRp.startsWith('/') ? rawRp : '/$rawRp';
}
