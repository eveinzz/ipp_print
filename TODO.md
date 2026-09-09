# TODO / Roadmap（对内）

`ipp_print` 的分阶段计划。已完成事项记录在 [CHANGELOG.md](CHANGELOG.md)，
对外文档见 [README.md](README.md) / [README.zh-CN.md](README.zh-CN.md)。

## P1

- [x] **`ipps://`（TLS）传输** —— 支持「仅广播 `_ipps._tcp`（无 `_ipp._tcp`）」的机型直连，
  含自签证书策略。依据：RFC 7472（IPP over HTTPS 传输绑定与 `ipps` URI scheme）。对应 README 边界 2。
  ✅ 0.1.0：`DiscoveredPrinter.secure` + `IppClient(acceptSelfSignedTls)`，
  同 UUID 双广播去重保留明文实例。
- [x] **`Cancel-Job` / `Get-Jobs`** —— 作业管理操作
  （IPP Guide Appendix A：job-id + requesting-user-name）。
  ✅ 0.1.0：`IppClient.cancelJob/getJobs` + `IppJobSummary`；实施中修复
  Get-Job-Attributes 操作码错写为 0x000A 的协议 Bug（正解 0x0009）。

## P2

- [ ] **`job-state-reasons` 透传** —— 将 `media-jam`、`document-format-error`
  等原因透出给宿主 App（IANA IPP Registrations）。
- [ ] **`Validate-Job` 预检** 与 `Create-Job` + `Send-Document` 多文档路径
  （IPP Guide Ch.1）。
- [ ] **分辨率 / 彩色 / 双面能力协商** —— 透出 `printer-resolution-supported`、
  `print-color-mode-supported`、`sides-supported` 作为宿主 UI 数据源
  （解除固定 300 dpi / sRGB-8 的限制）。
- [x] **彩色打印默认值（通用 IPP 语义，非单一机型）** ——
  ✅ 已实施「不下发」方案：`PrintOptions.colorMode` 改为可空（null 默认），
  null 时 `buildPrintJob` 不下发 `print-color-mode`，打印机使用自己的
  `print-color-mode-default`（RFC 8011 §5.2；L3250 实测 default=auto）。
  显式指定时才下发；回归锚点测试已固化。原根因：默认 `'monochrome'`
  显式覆盖了打印机默认行为。
  规范依据（PWG 5107.3/5100.13 §6.2.27，IANA 登记为 type2 keyword）：
  取值全集 8 个：`auto` / `auto-monochrome` / `bi-level` / `color` /
  `highlight` / `monochrome` / `process-bi-level` / `process-monochrome`；
  `auto` = 打印机按文档内容自动选彩色/单色。
  待办余项：若后续 UI 需要显式色彩选择，仅当 `print-color-mode-supported`
  含该值时下发（能力只来自 IPP 确定性字段，禁止推断）。
  样本数据（仅单一样本，不作为设计依据）：EPSON L3250 实测
  `print-color-mode-default=auto`、`supported=[color, monochrome,
  auto-monochrome, process-monochrome, auto]`、
  `pwg-raster-document-type-supported=[sgray_8, srgb_8]`。
- [ ] **TLS 正路径测试** —— 用 `HttpServer.bindSecure` 起自签 TLS 服务器，
  验证 `acceptSelfSignedTls` 的接受路径（现有测试只覆盖「连明文应握手失败」
  的负路径）。

## P3

- [ ] **评估发现层迁移 `NSNetServiceBrowser` → `NWBrowser`（Network.framework）** ——
  现状（iOS 26.2 SDK 头文件一手核实）：`NSNetServiceBrowser` 处于**软弃用**
  （`API_DEPRECATED("Use nw_browser_t in Network framework instead",
  ios(2.0, API_TO_BE_DEPRECATED), macos(10.2, API_TO_BE_DEPRECATED))`；
  `Availability.h` 官方语义：将在「即将到来的版本」正式弃用，**未分配版本号、
  无移除时间表、当前无编译器警告**；watchOS 不可用——本插件不涉及）。
  继任者 `nw_browser_t`/`NWBrowser` 可用性 **iOS 13.0 / macOS 10.15+**
  （`Network.framework/Headers/browser.h`）。
  影响范围：插件最低部署目标需从 **iOS 12.0 / macOS 10.14**（podspec 现值）
  抬升至 iOS 13.0 / macOS 10.15。功能面等价（Bonjour 服务浏览/解析），
  迁移属「编译警告预案」而非功能需求，**无时间压力**。
  触发条件：Apple 公布正式弃用版本号（编译警告出现）或最低部署目标抬升决策。
- [ ] **Basic / Digest 认证** —— 按 `uri-authentication-supported` 协商
  （IPP Guide Ch.2）。
- [x] **HTTP 426 Upgrade 处理** —— 明文 → TLS 升级路径
  （RFC 8011 / IPP Everywhere）。
  ✅ 0.2：`IppClient.post` 明文遇 426 自动以 `https` 同端口重试一次
  （真机 EPSON L3250 验证）。
- [ ] **模型层目录化** —— 若 `lib/src/models.dart` 超过约 400 行，
  拆为 `models/printer.dart` / `models/options.dart` / `models/exceptions.dart`，
  对外 API 不变。
- [ ] **`getJobs` 缺失属性不静默** —— 当前 job 组缺 `job-id`/`job-state`
  时静默取 0/pending，可能掩盖解析异常；改为跳过脏组或透出可空字段。
- [ ] **`discover()` 耗时上限** —— 顺序浏览 3 类服务型最坏 3×timeout
  （默认 15s）；改为并行浏览或单窗口聚合，控制发现耗时。
- [ ] **清理冗余调用** —— `printerUri.toString()`（String 上是 no-op）
  等零成本卫生项。

## 工程纪律（内部约定）

- 验收门槛：`flutter analyze` 零告警 + `dart test` 全绿 + 单文件 ≤400 行；
- 能力判定只允许来自 TXT/IPP 确定性字段，禁止推断；
- 发布日操作：移除 `publish_to: none` → `dart pub publish`（当前保持禁发防误发布）。
