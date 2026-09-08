# TODO / Roadmap（对内）

`ipp_print` 的分阶段计划。已完成事项记录在 [CHANGELOG.md](CHANGELOG.md)，
对外文档见 [README.md](README.md) / [README.zh-CN.md](README.zh-CN.md)。

## P1

- [ ] **`ipps://`（TLS）传输** —— 支持「仅广播 `_ipps._tcp`（无 `_ipp._tcp`）」的机型直连，
  含自签证书策略。依据：IPP Guide Ch.1（HTTPS 即加密通道）。对应 README 边界 2。
- [ ] **`Cancel-Job` / `Get-Jobs`** —— 作业管理操作
  （IPP Guide Appendix A：job-id + requesting-user-name）。

## P2

- [ ] **`job-state-reasons` 透传** —— 将 `media-jam`、`document-format-error`
  等原因透出给宿主 App（IANA IPP Registrations）。
- [ ] **`Validate-Job` 预检** 与 `Create-Job` + `Send-Document` 多文档路径
  （IPP Guide Ch.1）。
- [ ] **分辨率 / 彩色 / 双面能力协商** —— 透出 `printer-resolution-supported`、
  `print-color-mode-supported`、`sides-supported` 作为宿主 UI 数据源
  （解除固定 300 dpi / sRGB-8 的限制）。

## P3

- [ ] **Basic / Digest 认证** —— 按 `uri-authentication-supported` 协商
  （IPP Guide Ch.2）。
- [ ] **HTTP 426 Upgrade 处理** —— 明文 → TLS 升级路径
  （RFC 8011 / IPP Everywhere）。
- [ ] **模型层目录化** —— 若 `lib/src/models.dart` 超过约 400 行，
  拆为 `models/printer.dart` / `models/options.dart` / `models/exceptions.dart`，
  对外 API 不变。

## 工程纪律（内部约定）

- 验收门槛：`flutter analyze` 零告警 + `dart test` 全绿 + 单文件 ≤400 行；
- 能力判定只允许来自 TXT/IPP 确定性字段，禁止推断；
- 发布日操作：移除 `publish_to: none` → `dart pub publish`（当前保持禁发防误发布）。
