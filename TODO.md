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

### 0.3.2 — Consistency & Honesty Sweep（已交付，2026-09-11）

触发：外部复核报告逐条源码级核实。**证实并修复 3 项；证伪 1 项**：
「公共 API 不闭环」不成立（`PrinterCapabilities`/`inspect()`/`validateJob()`/
`resolutionsSupported` 均已实现、已导出、92/92 通过）。

- [x] **版本号链收口**：`ios/macos` podspec 停在 0.2.0（外部报告证实）
  → 统一升至 0.3.2，与 pubspec/CHANGELOG 对齐。
- [x] **probe 诚实性收紧**：删除 `formats.isEmpty ||` 逃逸口——
  `document-format-supported` 缺失（空集）→ 降级 unsupported，
  与「缺≠支持」「不推断」纪律及文件头双源规则一致（附回归锚点测试）。
- [x] **PrintOptions 残留默认值收口（BREAKING）**：`media`/`duplex`
  硬默认 `iso_a4_210x297mm`/`one-sided`（会实际下发）→ 默认 null 不下发，
  与 colorMode 统一「null = 打印机默认」语义；两条逐字节金标改为显式
  全量构造（线格式不变，全属性路径锚点保留）。
- [x] `vendorOnly` 注释精确化：语义是「本包不可达」（无可直连栅格路径），
  而非「仅厂商私有」——仅声明 IPP+PDF 的设备同样归此类。

### 0.4.0 — Document Pipeline（已交付，2026-09-11；遗留项处置见下）

核心目标：**让 `ipp_print` 自己决定「怎么打印」。**

- [x] **models.dart 拆分**（406 行越线 → models/ 四域文件 + barrel，
  最长 209 行；全量回归零破坏）。
- [x] `PrintDocument`（bytes + mimeType + 可选 name）与
  `DocumentFormatNegotiator`（无状态纯函数）：声明集含文档 MIME →
  **直投原格式**（免栅格化，保矢量）；否则含 `image/pwg-raster` →
  转 PWG 栅格；否则抛异常——**缺≠支持，绝不推断**。
  真机锚点：L3250 声明集 `[octet-stream, pwg-raster, escpr]` 不含
  PDF（2026-09-11 inspect），PDF 文档必走栅格回退路径（测试锚定）。
- [x] `DocumentEncoder` 抽象 + `PwgRasterEncoder` 挂入体系
  （只抽象不重写，规范金标测试原样保留）。
- [x] 文档格式事实基线（IPP Everywhere v1.1 §6 一手条款，PWG 5100.14-2020
  p.42 已核验原文）：PWG Raster = MUST（全机型）；JPEG = 彩色机 MUST /
  单色机 SHOULD；**PDF = 仅 SHOULD**——PDF 直投必须机会主义（运行时查证，
  L3250 未实测）；§6 未列入 URF（Apple 体系，非 IPP Everywhere 成员）。
- [x] 底层通用 `print(document, …)` 集成协商器与编码器（TDD，6 例新测试）：
  声明集由内核**实时** Get-Printer-Attributes 获取（10s 限时，不用宿主缓存）；
  直投分支 document-format 取打印机声明原样；栅格回退分支仅支持 PDF 源
  （非 PDF 无编码器 → 如实拒绝）；`printPdf()` 转调 `print()`，行为增强为
  「声明集权威下发 document-format」（原硬编码 pwg-raster，多一次查询）。
- [x] 能力模型升级（外部复核采纳项）：`enum PrinterCapability`（4 值）
  → 结构化能力集（protocol/document/coverage 维度），路由从「设备属于
  哪一类」改为「具备哪些能力」——仅声明 IPP+PDF 的设备不应被整包拒绝。
  **（0.5.0 以「Gate 事实化」实质完成并取代原形式：print/submit 仅拒
  unknown，vendorOnly/airPrint 一律放行至实时能力查询 + 协商器终审；
  结构化能力集即 Contract v1 的 `PrinterCapabilities`（24 项确定性
  自报属性）+ `DocumentFormatNegotiator` 事实驱动路由。4 值 enum 仅保留
  TXT 否定门职责，不再承担路由。）**
- [x] Typed value layer（三方终版评估采纳项，经源码核实为真实缺口）：
  现 `IppValue` 仅 tag+raw+`asString`/`asInt`，boolean/rangeOfInteger/
  resolution 为 inspect 内定制解码——需上收为泛型类型层并补
  dateTime（0x31）/collection（0x34 系列）/text-vs-name 语义区分，
  否则 `media-col-database`/`media-size-supported` 将退化为手工解 raw bytes。
  **（主体 0.5.0 交付：`asBool`/`asRange`/`asResolution`/`asKeyword` +
  `IppResolution`，inspect 定制解码全部上收。剩余 dateTime/collection/
  text-vs-name 三语法**显式降级至 0.8.x 候选**（见下）——内核当前
  消费路径（documentFormats/media/colorMode/sides/resolution/copies）
  无 collection 属性消费点，无场景牵引不做；CORE FREEZE 后按
  additive-only 准入。）**

### 0.4.1 — Protocol & Contract Correctness（已交付，2026-09-11）

触发：三方 ZIP 全量源码审计报告（2026-09-11）——UTF-8 缺陷经源码逐行核实为真；
job-state 猜测与 CI 缺失同轮证实。0.4 交付后的协议正确性收口。

- [x] **UTF-8 编码契约修复（RFC 8011 attributes-charset=utf-8）**：
  `codeUnits`（UTF-16 码元直写）/`fromCharCodes` → `utf8.encode` /
  `utf8.decode(allowMalformed: true)`（中文 job-name 出线、中文
  printer-info 入线双向修复；ASCII 行为字节级不变，金标原样）。
  测试锚点：中文 job-name 线格式金标 + 旧缺陷指纹负断言 + 中文值解码 +
  坏字节宽容不抛。mDNS TXT latin1 往返**不在**本次范围（RFC 6763 TXT
  键值恒 ASCII，无损）。
- [x] `IppJobState.unknown`：`fromCode` 未知值 / 响应缺 `job-state` →
  unknown（原 orElse→pending 属静默猜测，违反不推断纪律）；unknown 非终态，
  `waitForTerminalState` 继续轮询不误判。
- [x] GitHub Actions CI（analyze + test，stable Flutter 3.35.0）。
- 外部佐证归档：Capability Gate 与 PDF 直投的冲突（TXT pdl 无 pwg-raster
  → vendorOnly → print() 门拒绝）为**已知已跟踪项**——修复依赖下方能力
  模型升级，不单独立项。
- 0.5 PrintTicket 设计注记（本报告采纳）：RFC 8011 `ipp-attribute-fidelity`
  语义——`valid=true` ≠ 属性完全保真（非保真模式下打印机可忽略/替换
  不支持值）；PrintTicket 应含 fidelity/strictness 维度
  （L3250 jobCreationAttrs 确声明 ipp-attribute-fidelity 可提交）。

### 0.5.0 — Print Core Foundation（契约冻结 v1，已交付 2026-09-11）

核心目标：**定义上层可长期依赖的打印语义层。**（0.4.1 归档的 Gate 冲突在本版解决）

- [x] Capability Gate 重构：`print()` 仅拒绝 TXT `unknown`（无 IPP 证据），
  其余分类放行至实时能力查询 + 协商器终审——仅声明 IPP+PDF 的设备不再
  被整包拒绝；`probe()` vendorOnly 同改实时交叉验证（airPrint 保持快路径）。
- [x] `PrintTicket` 显式建模（media/colorMode/sides/resolution/copies +
  fidelity 维度，见 0.4.1 注记）；`PrintOptions` 保留为便利/兼容层
  （`PrintTicket.fromOptions` 桥接），fidelity / printer-resolution 线格式
  同步补齐（缺省不下发，既有作业字节零变化）。
- [x] `CapabilityValidator` 本地预检：ticket 值 ∉ capabilities → 结构化
  `PrintValidationResult`，与 Validate-Job（设备级终审）双层并存；
  Facade 出口 `IppPrint.validateTicket`。
- [x] `DocumentRoute` 契约化确认：0.4 的 `DocumentDecision`
  （passthrough/documentFormat）即类型化路由出参，随本版冻结为契约对象。
- [x] Structured Error 分类轴：`IppErrorCategory`（ipp/unsupported/job/
  network/generic）+ `IppUnsupportedException`；网络层平台异常原样透出
  不二次包装。
- [x] Typed IPP Value 基础层：boolean/rangeOfInteger/resolution 上收为
  `IppValue.asBool/asRange/asResolution`（+ `IppResolution`）。
- P1（不阻塞冻结）：dateTime(0x31)/collection(0x34) 解码——等真实机型
  media-col 需求触发（L3250 级 keyword 介质表已够）。

### 0.6.0 — Job Engine（已交付，2026-09-11）

核心目标：**作业语义成为内核契约。**

- [x] `PrintJob` 对象模型（8 态 lifecycle）：状态/进度/取消统一出口；
  `print()` 进度流（PrintStage）保持向后兼容（print 与 submit 共享
  gate→协商→编码单一来源 `_prepareSubmission`，防双入口漂移）。
- [x] `job-state-reasons` 作业级透传（`media-jam` ≠ `printer-stopped`，
  上层错误页语义必需；printer 级已由 inspect 透出）。
- [x] submit / monitor / cancel 职责拆分 + `Get-Jobs` 作业查询
  （getJobs 0.3 已有，本版补单作业 `getJob` 快照）。
- [x] `Create-Job` + `Send-Document` 多文档（opportunistic：L3250 声明
  op 5/6——本版做成即测：线格式 + client 端到端锚点，无 facade 多文档入口）。
- 交付时一并修复（验收审计发现）：`ipp-attribute-fidelity` 组归属
  （RFC 8011 §4.2.1.1 Group 1 操作属性，原误入 Group 2）；Validate-Job
  同构性（补 fidelity/printer-resolution 镜像，job template 属性三处共用
  `_writeJobTemplate`）；`submitJob` 返回升级 `IppJobSummary`
  （§4.2.1.2 REQUIRED 三件套）；UA 版本串漂移 0.3→0.6。

### 0.7.0 — Access & CORE FREEZE（内核封板）

核心目标：**补最后一个入口缺口，然后停止抽象。**

- [x] `addEndpoint(Uri)` 手动连接（发现不到 ≠ 不能打印；绕过 TXT 分类门的
  probe 驱动能力路径）——zitie 真实场景（mDNS 失效网络）与 Universal
  Print App 兜底共用。**manual 不放松 ready 判据**（仅声明 pdf 仍如实
  unsupported，判据豁免仅限 TXT 分类否定门——测试锚点已固化）。
- [x] 开源发布就绪清单：LICENSE（MIT， eveinzz）/ example（含 addEndpoint
  展示）/ 双 README 终审（特性清单 + Roadmap 封板状态）/
  发布决策（**保留 `publish_to: none`**，pub.dev 发布待作者另行拍板）。
- [x] **⛔ CORE FREEZE 条款（随 0.7.0 生效）**：
  - Contract v2 = Printer / PrinterCapabilities / PrintDocument /
    DocumentRoute / PrintTicket / PrintValidationResult / PrintJob；
  - 0.7.x 只允许：修 BUG、协议正确性、兼容性、性能、测试、平台适配；
  - 新 API 准入唯一标准：**IPP 内核本身缺失的协议/设备能力**——
    上层 UI/产品需求永不构成准入理由；
  - 流式发现、Diagnostics、NWBrowser/NsdManager 迁移（双触发条件保留）
    全部移入 0.8.x+ 候选，additive-only 演进，永不阻塞上层。

### 0.8.x+ — 候选增强（封板后，additive-only）

- [ ] `IppValue` 补齐 IPP 值语法：`dateTime`（0x31，RFC 8011 §5.1.13）、
  `collection`（0x34 begCollection / 0x35 endCollection /
  0x36 valueCollection / 0x37 memberName，§5.1.16——`media-col-database` /
  `media-size-supported` 的载体）、text-vs-name（0x41/0x45 vs 0x42/0x46）
  语义区分。准入条件：内核出现真实消费路径（如 media-col 打印），
  无场景牵引不做（0.7.0 封板裁决的遗留项显式迁移）。
- [ ] `Stream<PrinterDiscoveryEvent>` 流式发现（printerAdded/Updated/Removed；
  iOS 侧 delegate 强持有模型——ARC 教训在长驻监听场景会放大）。
- [ ] `IppPrint.diagnose()` → `DiagnosticReport`：Discovery/DNS-SD/Network/TLS/
  IPP/Capability/Document 分层组合 + `IppDiagnosticCode` 枚举。
  （降级理由：组合能力而非内核能力，上层可基于 0.7 契约自行拼装。）
  原则：**DEBUG log 给开发者，DiagnosticReport 给产品**。仍然无 UI。
- [ ] iOS/macOS → `NWBrowser` 迁移评估（**双触发条件保留**：Apple 公布正式弃用
  版本号（编译警告出现）或最低部署目标抬升决策落地。事实基线：
  `NSNetServiceBrowser` = 软弃用（`API_TO_BE_DEPRECATED`，无时间表）；
  `nw_browser_t` 需 iOS 13.0 / macOS 10.15+，现 podspec 12.0/10.14）。
- [ ] Android 原生适配决策项：`NsdManager`（走系统服务、免 MulticastLock，
  同 Bonjour 豁免逻辑）替代「宿主自理 MulticastLock」——需新增 android/
  原生模块，属产品决策。
- [ ] Typed Value collection 深化（`media-col-database` 等，真实机型触发时）。

---

## 工程纪律（内部约定，跨版本有效）

- 验收门槛：`flutter analyze` 零告警 + 全量测试绿 + 单文件 ≤400 行；
- 能力判定只允许来自 TXT/IPP 确定性字段，禁止推断；
- 协议行为改动必须有规范一手出处（RFC/PWG/IANA/Apple 官方文档）并同步
  README 标准对照表；
- 真机验证记录注明机型与日期（如 EPSON L3250，2026-09-08 出纸验证）；
- 发布日操作：移除 `publish_to: none` → `dart pub publish`（当前保持禁发防误发布）。
