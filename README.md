# ipp_print

无 UI 的 IPP 直连打印内核包。**定位单一：发现 + 分类 + 传输；展示与交互全部留给宿主 App。**

## 背景与动机

本项目（格间）导出 PDF 后走 `printing` 包打印，其 iOS 能力上界 = AirPrint。
实测（2026-09-08 审计，见根目录 `.workbuddy/memory/2026-09-08.md`）：
Epson L3250 等"仅 IPP + PWG-raster、无 URF"的打印机在 iOS 系统打印面板
**永远不可见**，用户面对的是无法恢复的空白面板。本包填补该空洞：
用 App 自身完成 mDNS 发现、确定性能力分类与 IPP 传输。

## 架构（分层，依赖单向向下）

```
Facade API  discover() / probe() / printPdf() → 进度流
   ├── 发现层    multicast_dns 浏览 _ipp/_ipps · UUID 去重 · 超时
   ├── 能力分类器 TXT(URF=/pdl=) → airPrint | ippDirect | vendorOnly   （确定性，非推断）
   ├── IPP 客户端 Get-Printer-Attributes / Print-Job / Get-Job-Attributes（RFC 8011）
   └── PWG 编码   PdfRasterizer(注入接口) → PwgRasterEncoder
```

- 纯 Dart，零 Flutter 依赖 → 协议层可用金标字节样张离线单测；
- PDF 栅格化是平台能力，通过 `PdfRasterizer` 接口**注入**（宿主 App 用
  `printing.rasterPdf` 实现），插件本体不绑定任何渲染实现。

## 实施计划

| Phase | 内容 | 验收锚点 |
|---|---|---|
| P0 | 模型 + 能力分类器 | `test/capability_test.dart` |
| P1 | 发现层（纯函数组装器 + mDNS 适配） | `test/record_assembler_test.dart` |
| P2 | PWG-raster 编码器（RaS2 头 + 行程行） | `test/pwg_encoder_test.dart`（金标字节） |
| P3 | IPP 报文编解码 + HTTP 传输客户端 | `test/ipp_message_test.dart`、`test/ipp_client_test.dart`（本地假 IPP 服务器） |
| P4 | Facade + 管线 + 状态机 | `test/facade_test.dart` |

## 验收门槛（与根 AGENTS.md 同源）

- `flutter analyze`（包内）零告警；
- `dart test`（包内，纯 Dart 包用 dart test；flutter_test 的 flutter_tester
  加载器对本包不适用）全绿；
- 单文件 ≤400 行；
- 能力判定只允许来自 TXT 记录的确定性字段，禁止"猜"。

## 引用出处（实现决策 ← 标准条款对照）

发布 pub.dev 前，所有协议行为必须能回溯到以下权威来源（社区实现仅作
对照参考，不作为依据）：

| 实现决策 | 标准依据 | 条款 |
|---|---|---|
| 报文字节序 tag→name-len→name→value-len→value | RFC 2910 (IPP/1.1 Encoding) | §3.1.1 |
| 同名多值 = tag + 零长度名 | RFC 2910 | §3.1.4.2 |
| 请求必含 attributes-charset / attributes-natural-language / printer-uri | RFC 8011 (IPP/1.1 Model) | §4.1.4、Appendix A |
| job-state 值域 3–9（pending/pending-held/processing/processing-stopped/canceled/aborted/completed） | RFC 8011 / IPP Guide | §5.3.7 |
| printer-state 值域 3–5（idle/processing/stopped） | RFC 8011 | §5.4.12 |
| PWG-raster 页头（RaS2, 36B, sRGB-8=19） | PWG 5102.4 | - |
| 介质自描述名 `iso_a4_210x297mm` | PWG 5101.1 (Media Names) | - |
| 发现浏览 `_ipp._tcp` / `_ipps._tcp` / `_universal._sub._ipp._tcp` | RFC 6763 (DNS-SD) + Apple AirPrint 规约 | - |
| 本地网络权限（iOS 探测需声明） | Apple TN3179 | - |
| TXT 键 `rp`/`pdl`/`UUID`/`ty` | PWG 5101.2 (Bonjour Printing Spec) | - |
| printer-uri 用 `ipp://` 逻辑 URI、HTTP POST `application/ipp` | IPP Guide (istopwg) | Ch.1 |
| 查询 `media-supported` / `document-format-supported` 能力 | IPP Guide | Ch.2 |

参考网址：RFC 2910/8011（IETF）、PWG 5101.1/5101.2/5102.4（ftp.pwg.org）、
<https://istopwg.github.io/ipp/ippguide.html>、IANA IPP Registrations
（<https://www.iana.org/assignments/ipp-registrations/>）、Apple TN3179。
HPInc/jipp（HP 官方 Java IPP 库）与 istopwg 指南作为能力清单核对基准。

## 边界（诚实清单，持续维护）

1. **仅发现 mDNS 广播设备**：USB 直连、离线、不发广播的打印机不可见（与系统面板同限）。
2. **传输通道为明文 ipp://:631**：仅广播 `_ipps` 无 `_ipp` 的机型不可用；自签 TLS 证书校验问题回避（L3250 双广播，实测可用）。
3. **不支持 PDF 直投机型**：仅当打印机 `pdl` 声明 `image/pwg-raster` 才走直连（分类器保证不会误投）。
4. **PoC 固定 300dpi / sRGB-8**：分辨率/色彩协商未实现（`printer-resolution` 属性未发送）。
5. **AirPrint 级机型不接管**：分类为 airPrint 的设备交还系统面板，本包不做降级替换。
6. **Android 复用**：API 平台中立，但 Android 系统打印服务已覆盖多数场景，接入与否待数据决策。

## Roadmap（发布 pub.dev 前的分阶段目标）

| 优先级 | 事项 | 依据 |
|---|---|---|
| P1 | ipps://（TLS）支持：对 `_ipps`-only 机型以 `HttpClient` + 自签证书策略直连（IPP Guide Ch.1：HTTPS 即加密通道） | 边界 2 |
| P1 | `Cancel-Job`、`Get-Jobs`（IPP Guide Appendix A：job-id + requesting-user-name） | 服务管理完整性 |
| P2 | `job-state-reasons` 透传（media-jam/document-format-error 等，IANA 注册表） | 诊断体验 |
| P2 | `Validate-Job` 预检、`Create-Job`+`Send-Document` 多文档路径 | IPP Guide Ch.1 |
| P2 | `printer-resolution` / 彩色 / 双面能力协商 UI 数据源（`printer-resolution-supported` 等） | 边界 4 |
| P3 | Basic/Digest 认证（`uri-authentication-supported` 协商） | IPP Guide Ch.2 |
| P3 | HTTP 426 Upgrade 响应处理（IPP Everywhere 明文→TLS 升级） | RFC 8011 |

### 模型层演进说明

当前领域模型集中在单一 `lib/src/models.dart`（约 180 行，含端口定义与
异常体系），符合"单文件 ≤400 行"约束。若后续增长超限，演进路径为
`models/` 目录化（printer.dart / options.dart / exceptions.dart），在
`lib/ipp_print.dart` 统一导出，对外 API 不变——发布前完成即可。

## 集成方式（宿主侧，待批准后实施）

```yaml
dependencies:
  ipp_print:
    path: packages/ipp_print
```

App 层提供 `PdfRasterizer` 适配器（基于 `printing.rasterPdf`）并按
「格间」设计语言实现兜底面板（能力徽章列表 + 选项协商 + 进度）。
