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
- [ ] **彩色打印默认值** —— 真机验证（EPSON L3250 彩色机型）出纸为黑白。
  代码级根因：`PrintOptions.colorMode` 默认 `'monochrome'`（models.dart），
  经 `buildPrintJob` 以 job 属性 `print-color-mode` 显式下发，打印机遵照执行。
  目标：支持彩色则默认彩色，仅单色则黑白。路径：`Get-Printer-Attributes` 增加
  `print-color-mode-supported` 请求并解析（`color`/`auto`/`monochrome`），
  默认策略 `含 color → color，含 auto → auto，否则 monochrome`
  （IPP `print-color-mode` job template attribute，PWG 5107.3）；
  `auto` 在入门机型上的实际行为需真机验证，禁止想当然。
- [ ] **TLS 正路径测试** —— 用 `HttpServer.bindSecure` 起自签 TLS 服务器，
  验证 `acceptSelfSignedTls` 的接受路径（现有测试只覆盖「连明文应握手失败」
  的负路径）。

## P3

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
