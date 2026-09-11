# ipp_print Technical Roadmap / Architecture Specification

> 对内文档。本文件是 `ipp_print` 的版本路线图与架构规约（2026-09 课题定稿）。
> 已发布变更见 [CHANGELOG.md](CHANGELOG.md)；对外文档见 [README.md](README.md)
> / [README.zh-CN.md](README.zh-CN.md)。

## 定位（不可动摇）

**Headless IPP printing engine for Dart/Flutter —— 无 UI、协议级、能力感知、可诊断的
IPP 打印内核。** 未来的 Universal Print App 在其之上组合其它协议适配器
（`raw_print`/`label_print` 等），两层严格分离。

```text
Universal Print App（UI/文件/预览/历史/UX）
        │
Print Core（设备选择 / 能力归一 / 格式路由 / Ticket / 诊断 / 编排）
        │
   ipp_print（本包：IPP/IPPS + Bonjour/DNS-SD + PWG Raster + PDF/JPEG + Job + Diagnostics）
```

### 架构第一原则（永久保留）

1. **能力只来自打印机自报的确定性字段**（TXT / `xxx-supported` / `xxx-default`），
   禁止推断。规范依据：RFC 8011 §6.2（Printer 响应中不出现该属性 = 不支持该特性）、
   §4（客户端供不支持值，Printer MUST reject）。
2. **每个 API 增加前必问**：这是「IPP 打印内核」的职责，还是「Universal Print App」
   的职责？前者进本包，后者坚决留在上层。
3. **不做清单**：UI、PDF 编辑器、文件管理器、相册、账号体系、用户打印历史、
   品牌专用 UI、ESC/POS/ZPL/TSPL/RAW 9100/LPR/蓝牙/USB（独立适配器包，永不入内）。

### 版本能力基线（业界语境）

Mopria 官方数据（2026-09 核验）：超过 1.2 亿台认证打印机、10,000+ 型号，
其标准已内嵌于 Android 打印框架与 Windows IPP Class Driver 生态——
**标准化协议路线是行业主流而非边缘**。本包不做「支持任意打印机」，
只做「尽可能完整实现 IPP 标准能力，并正确解释打印机实际声明的能力」。

---

## 版本路线

### 0.3.0 — Capability Engine（已交付：92/92 插件测试全绿，analyze 零告警）

核心目标：**让 `ipp_print` 真正理解一台 IPP Printer。**

- [x] `Get-Printer-Attributes` 请求集完整化：默认 4 属性 → 标准能力集
  （printer-state / printer-state-reasons / printer-is-accepting-jobs /
  document-format-supported/-default / media-supported / media-ready /
  print-color-mode-supported/-default / sides-supported/-default /
  printer-resolution-supported/-default / copies-supported /
  printer-make-and-model / printer-name / printer-info /
  printer-uri-supported / ipp-versions-supported /
  uri-authentication-supported / uri-security-supported /
  job-creation-attributes-supported / operations-supported）。
  解析一律 lenient（缺失 = null/空），入门机截断响应不致崩溃。
- [x] `PrinterCapabilities` 能力模型（文档/介质/色彩/双面/分辨率/份数/作业/安全），
  与 `PrinterAttributes` 并存过渡，`probe()` API 不变。
- [x] `IppPrint.inspect()` —— 返回「这台机器究竟能干什么」（能力 + 状态 + 安全）。
- [x] `Validate-Job`（操作码 0x0004）+ `PrintValidationResult`
  （valid / invalid + unsupported-attributes 组透出），提交大文档前先问打印机。
- [x] `discover()` 三类服务并行浏览（消除顺序 3×timeout 最坏情况）。
- [x] `getJobs` 脏组防御：缺 `job-id`/`job-state` 的组跳过并记录日志，不再静默 0/pending。
- 诚实边界：`media-col-database`/`media-size-supported` 为复杂集合，0.3 仅透出原始
  keyword 级（`media-supported`），结构化解析留待后续版本。
  （`copies-supported` 已按 rangeOfInteger 配对解析为 `copiesMin`/`copiesMax`。）

### 0.3.1 — Resolution Negotiation（已交付，2026-09-11）

触发：真机能力侦察（L3250，24 属性全量自报）发现 App 固定 300dpi
**不在**打印机声明集 `[360x360dpi, 1440x720dpi]` 内——宽容机型接受、
严格机型可能拒收/异常渲染。

- [x] probe 请求集 8 → 10 属性（加 `printer-resolution-supported`/-default），
  `PrinterInfo.resolutionsSupported` / `resolutionDefault` 透出。
- [x] `printPdf(dpi: …)` per-call 覆盖（PWG 页头 `cupsHWResolution`/`PageSize`）。
- [x] 宿主协商（好字帖）：`resolvePrintDpi` 纯函数——只在**对称**声明项中取
  距 300 最近者；非 dpi 单位不换算不猜值；无声明回退 300。
- 真机数据同轮归档：`printer-name`=URI 路径片段（不可当显示名）；
  `media-ready`=[]（判纸只能用 `media-supported`）；16K 可命中
  `om_16k_195x270mm`；operations 覆盖插件全部 6 操作。

### 0.4.0 — Document Pipeline

核心目标：**让 `ipp_print` 自己决定「怎么打印」。**

- [ ] `PrintDocument`（bytes + mimeType）与 `DocumentFormatNegotiator`：
  读 `document-format-supported` → 选择最优格式 → 必要时转换 → 提交。
- [ ] 文档格式事实基线（IPP Everywhere v1.1 §6 一手条款）：
  PWG Raster = MUST（全机型）；JPEG = 彩色机 MUST / 单色机 SHOULD；
  **PDF = 仅 SHOULD**——PDF 直投必须机会主义（运行时查证，L3250 未实测）；
  URF 不属于 IPP Everywhere（Apple 体系）。
- [ ] PWG encoder 抽象为 `DocumentEncoder` 体系成员（现实现按规范金标锚定，只抽象不重写）。
- [ ] `printPdf()` 保留为便利 API；底层通用 `print(document, ticket)`。

### 0.5.0 — Print Ticket & Validation

- [ ] `PrintTicket` 显式建模（media/colorMode/sides/resolution/copies）+
  能力校验器：ticket 值 ∉ capabilities → 结构化 `PrintValidationResult`
  而非异常。`PrintOptions` 默认值语义退役（A4 默认不再成立）。

### 0.6.0 — Job Engine

- [ ] `Print-Job` / `Create-Job` + `Send-Document`（多文档）/ `Get-Job-Attributes`
  / `Get-Jobs` / `Cancel-Job` 统一为 `PrintJob` 对象模型（8 态 lifecycle）。
- [ ] `job-state-reasons` 透传（`media-jam` ≠ `printer-stopped`，产品语义必需）。

### 0.7.0 — Discovery Engine

- [ ] `Stream<PrinterDiscoveryEvent>` 流式发现（printerAdded/Updated/Removed；
  iOS 侧先落 delegate 强持有模型——ARC 教训在长驻监听场景会放大）。
- [ ] `addEndpoint(Uri)` 手动连接（发现不到 ≠ 不能打印；需绕过 TXT 分类门的
  probe 驱动能力路径）。
- [ ] iOS/macOS → `NWBrowser` 迁移评估（**双触发条件保留**：Apple 公布正式弃用
  版本号（编译警告出现）或最低部署目标抬升决策落地。事实基线：
  `NSNetServiceBrowser` = 软弃用（`API_TO_BE_DEPRECATED`，无时间表）；
  `nw_browser_t` 需 iOS 13.0 / macOS 10.15+，现 podspec 12.0/10.14）。
- [ ] Android 原生适配决策项：`NsdManager`（走系统服务、免 MulticastLock，
  同 Bonjour 豁免逻辑）替代「宿主自理 MulticastLock」——需新增 android/
  原生模块，属产品决策。

### 0.8.0 — Diagnostics Engine

- [ ] `IppPrint.diagnose()` → `DiagnosticReport`：Discovery/DNS-SD/Network/TLS/
  IPP/Capability/Document 分层结果 + `IppDiagnosticCode` 枚举。
  原则：**DEBUG log 给开发者，DiagnosticReport 给产品**。仍然无 UI。

---

## 工程纪律（内部约定，跨版本有效）

- 验收门槛：`flutter analyze` 零告警 + 全量测试绿 + 单文件 ≤400 行；
- 能力判定只允许来自 TXT/IPP 确定性字段，禁止推断；
- 协议行为改动必须有规范一手出处（RFC/PWG/IANA/Apple 官方文档）并同步
  README 标准对照表；
- 真机验证记录注明机型与日期（如 EPSON L3250，2026-09-08 出纸验证）；
- 发布日操作：移除 `publish_to: none` → `dart pub publish`（当前保持禁发防误发布）。
