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
  Facade 出口 `IppPrint.validateTicket`。**定位澄清（0.7.2）**：
  `CapabilityValidator` **不进公共 barrel**——它不是宿主 API，宿主唯一门径
  是本 Facade 出口（`test/public_api_test.dart` 已把该例外显式登记并锚定该
  出口）；文件头「契约冻结 v1 对象」指的是**出参** `PrintValidationResult`
  这一契约对象（已导出），校验器本身是实现细节。
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

### 0.7.1 — print-quality（封板后首个协议正确性补丁，2026-09-12）

准入依据：CORE FREEZE「IPP 内核本身缺失的协议能力」。RFC 8011 §5.2.13
（type2 enum，RECOMMENDED；Table 12：'3'=draft / '4'=normal / '5'=high）；
§5.2.12/§5.2.13 Note：与 `printer-resolution` 冲突时 Printer SHOULD 以
`print-quality` 为准——仅下发分辨率等于把输出质量决定权让给打印机默认。

- [x] `print-quality` 下发（`PrintOptions`/`PrintTicket.printQuality`，
  null 不下发既有作业字节零变化，原始 enum 值透出与 finishings 同纪律）
  + inspect 请求集 24 → 26（`print-quality-supported`/`-default`）+
  CapabilityValidator 本地预检 + wire/解析/校验/往返 8 例锚点
  （敏感性验证：停用下发 → 2 例线格式锚点转红）。
- 同轮收口（验收审计发现）：测试 fixture resolution 值 tag 0x35
  （textWithLanguage）→ 0x32（resolution，RFC 8010 Table 1，解析器
  tag 无关故锚点弱化而非断裂）；引用残留 5 处（端口出处 RFC 2910/7472
  → RFC 8010 §5 / RFC 7472 ×2；resolution 节号 §5.1.14 → §5.1.16
  注释 ×3）；UA 版本串漂移复发（0.6 → 0.7）。
  （端口出处原记为 §4.1 属错引，0.7.2 按一手原文更正为 §5。）

### 0.7.4 — Copies Semantics on the Raster Path（已交付，2026-09-12）

准入依据：CORE FREEZE 允许的「修 BUG / 协议正确性 / 测试 / 文档」。触发：
宿主反馈「`PrintTicket(copies: 2)` 实际只印 1 份」—— 全链审计确认为真实缺陷。

**缺陷**：`copies` 无论何值都原样下发。对流式光栅文档，后端**可以**回
`successful-ok-ignored-or-substituted-attributes`（`0x0001`）并只印一份；而
`0x0001` 落在 `isSuccessful`（`statusCode <= 0x00FF`）区间内 → 宿主收到成功、
用户只得到 1 份，**全程无告警**。

**修复**：栅格路径把份数实现在**文档层** —— 整份页序重复 `copies` 次
（collated），下发属性固定 `copies=1`（防与硬件份数重复计数）；`copies < 1`
归一为 1（RFC 8011 §5.2.5 下界为 1，否则会产出只含同步字的空文档）。

判据（**通用，与机型/品牌/型号无关**，均为一手核对）：
1. **参考实现**：CUPS 对流式光栅 `image/*` 与 `application/vnd.cups-raster`
   **强制 `copies = 1`**，由上游过滤器预产副本（`cups/ppd-cache.c`
   `_cupsConvertOptions`，注释原文 "Multi-page image formats will have copies
   applied by the upstream filters"）⇒「客户端预产份数」是参考实现的既定架构，
   不是某个驱动的怪癖。
2. **协议语义**：RFC 8011 §5.2.5 中单文档 `copies=N` 意为 N 份**完整副本**
   （collated Sets，§2.3.10）⇒ 预产必须整份重复页序；重复单页会得到
   uncollated（错序）结果。
3. **合规底线**：PWG 5100.14 *IPP Everywhere* Table 8 将 `copies` 列为
   **REQUIRED** Job Template 属性，§9.3 要求支持 image/jpeg 或
   application/pdf/openxps 的打印机必须支持之 ⇒ 收下却静默忽略属不合规，
   客户端兜底是这类后端上唯一仍然正确的做法。
4. **真机佐证（仅佐证，不构成判据）**：EPSON L3250（2026-09-12）自报
   `copies-supported: 1..99` 且把 copies 列入 `job-creation-attributes-supported`，
   实操对 `copies≥2` 的 Print-Job 与 Validate-Job **一律**回 `0x0001`
   （Unsupported Attributes 组列出 copies），`impressions=1`；其 PPD 声明
   `*cupsManualCopies: True`。现象与判据 1–3 预测一致。

- [x] `_prepareSubmission` 栅格分支改为「先逐页收页块 → 整份页序重复 copies 次
  → 同步字仍只在文档开头出现一次」；新增 `_withCopies` 归一下发属性。
- [x] 锚点 `test/copies_test.dart` 5 例（属性值由**独立线格式步进器**读取，
  不依赖被测解析代码）；**敏感性验证**：还原旧实现 → 2 例转红。全量
  **187 例**绿（原 182 + 5），analyze 零告警，`dart format` 零差异。
- [x] 双 README：Job options `copies` 行改写 + 诚实清单第 8 条新增。
- [x] 版本 0.7.3 → 0.7.4（pubspec / 双 podspec / `version.dart` 四处一致，
  由既有版本链闸保证）。

**本轮显式不做（理由留档）**：

- **直投路径不下压份数**：客户端无从在 PDF 负载内预产副本，`copies` 交打印机
  RIP 按 RFC 8011 §5.2.5 处理（CUPS 的 `copies=1` 分支同样只覆盖 image/* 与
  CUPS raster）。**两条路径刻意不对称**，已登记入 README 诚实清单第 8 条。
- **`0x0001` 仍视为成功**：属 0.7.0 封板的 `isSuccessful` 契约（`0x0000`–
  `0x00FF` 均为成功类）。改为失败会破坏「打印机忽略某属性但仍正常出纸」的
  合法语义（RFC 8011 §5.2 明确允许 Printer 以 `0x0001` 响应替换属性）。
  本缺陷的根因是份数可被**静默**忽略，已在文档层根治。若宿主需感知「哪些属性
  被忽略」，应经 `0x0001` 响应的 Unsupported Attributes 组**告警**而非报错 ——
  列 0.8.x+ 候选，本包不改封板契约。
- **真机侧诚实边界**：出纸实证期间打印机缺纸
  （`printer-alert=inputMediaSupplyEmpty` → 后续提交 `0x0507 server-error-busy`），
  判别性实验（1 页 + `copies=1` → 应为 1 张）**未能执行**。测试作业已由本包
  经 Cancel-Job（op `0x0008`）取消（job 60 → `job-canceled-by-user`），队列
  已清空。修复正确性由**规范判据 + 线格式锚点**支撑，**不声称出纸验证**。

### 0.7.3 — Discovery Resource-Path Policy（已交付，2026-09-12）

准入依据：CORE FREEZE 允许的「正确性 / 测试 / 文档」。触发：0.7.2 遗留的
待拍板项 —— 两条发现通道对「TXT `rp` 缺失」的处理相反。

**决策（决策权委派，0.7.3）**：统一为「`rp` 缺失/为空 ⇒ 跳过实例，**绝不造
路径**」（审计报告第 7 节所述 A 语义），而非「两条路径都兜底 `/ipp/print`」。

判据（三条，均可复核）：
1. `resourcePath` 是「该打印机在此路径可用」的**断言**。`rp` 缺失时填一个具体
   路径，是把「未知」写成「已知」——与 0.7.2 收口的「能力虚报」同类，只是从
   文档层挪到了代码层。
2. `/ipp/print` **缺乏对「省略 rp 子集」的规范支撑**：Apple WWDC 2016 S725
   的「多数 AirPrint 打印机路径为 ipp/print」说的是打印机整体；CUPS 参考实现
   从不据 `rp` 推导路径（5 个源文件零命中）；macOS 把路径解析推迟到连接期。
3. **代价可逆**：库有 `addEndpoint` 显式入口（手动端点即用户断言），「不猜」
   不等于永久失去该设备。

- [x] 策略单源 `lib/src/discovery/resource_path.dart`（内核内部，不进 barrel），
  两条通道共用 —— 消除本项目头号缺陷源（同契约双实现漂移）在本轴上的再现。
- [x] 原生路径撤掉 `/ipp/print` 兜底；TXT 键归一小写（RFC 6763 §6.2 +
  `DiscoveredPrinter.txt` 的「小写键」契约，后者此前在原生路径可被违反）。
- [x] 跨路径契约锚点 `test/discovery_rp_policy_test.dart`（同一条线路 TXT 同时
  驱动两条路径，逐格断言一致）+ 原生路径 4 例；**敏感性验证**：旧行为下
  6 例转红。
- [x] 双 README 诚实清单第 6 条改写；版本 0.7.2 → 0.7.3（pubspec / 双 podspec /
  `version.dart` 四处一致，由既有闸保证）。
- [x] 审计报告第 7 节追加决策记录。

**本轮显式不做（理由留档）**：

- 0.7.2 的其余「显式不做」项（`DocumentEncoder` 真接入 / mDNS 全局 deadline /
  直投零拷贝 / 426 TLS 记忆化 / PWG 5102.4 金标出处归档）**状态不变**。
- `rp` 值为纯空白（如 `" "`）仍会产出 `'/ '` 这类路径：未观测到的边角；加
  `trim()` 属**未经验证的行为选择**，按「不加未验证行为」纪律不动。
- **真机侧诚实边界**：本机局域网只有 EPSON L3250（TXT 含 `rp`），「省略 `rp`」
  分支**无真机可验**；该分支行为由规范原文 + 合成锚点支撑，**不声称真机验证**。

### 0.7.2 — Documentation & Version Truthfulness（已交付，2026-09-12）

准入依据：CORE FREEZE 允许的「正确性 / 测试 / 文档」——无公共 API 增删。
触发：0.7.1 全链审计（P0=0；问题全部落在**对外文档失真 / 版本链无单一
真相源 / 引用错引**三类治理缺口，而非协议实现）。

- [x] 双 README 边界清单 2 条**与实现相反**（「不支持 PDF 直投」「分辨率协商
  尚未实现」）→ 改为与实现一致；补 2 条此前未披露的诚实条目（两条发现通道的
  `rp` 策略 / 超时语义不对称）。
- [x] 「Pure Dart, zero Flutter dependencies」半真声明 → 精确化（协议内核纯
  Dart；包整体是 Flutter 插件，Facade 级测试需 `flutter test`）。
- [x] RFC 错引更正：端口 631 出处 `RFC 8010 §4.1` → **§5**（一手核验，见下
  「引用纪律」）；并回改 0.7.0 / 0.7.1 条目内的同一错引。
- [x] 版本单一真相源：`lib/src/version.dart` + UA 派生 + `0.5.0` podspec →
  `0.7.2`；闸 = `test/version_consistency_test.dart` + CI version-consistency。
- [x] 公共导出面锚点 `test/public_api_test.dart`（43 类型编译期断言 + 导出闭包
  静态闸 + `inspect()` 解析/超时映射 + `validateTicket()` 出口）。
- [x] `monitor()` 超时硬上界修复（deadline 提至循环首）+ 瞬态路径锚点。
- [x] `dart format` 全量收敛 + CI 格式门。
- [x] 文档注释失真 2 处（`IppValue.values()` 跨组语义、PWG 同步字写入点）。
- [x] `example/main.dart` 注入 `FakeDiscovery`（原为定义未注入，运行即抛
  `StateError`，与注释/README 的「离线可跑」承诺相反）。

**本轮显式不做（记录理由，防遗忘；均需拍板或各自锚点）**：

- `rp` 缺失策略两路径对齐（Apple 路径「猜 `/ipp/print`」→ 与 mDNS 一致的
  丢弃）：**属用户可见行为变更**（iOS 可见打印机集合会变），与「安全优先」
  冲突，需显式拍板；现状已写入双 README 诚实清单第 6 条。
  （**0.7.3 已拍板并交付**：统一为「跳过」，理由见上方 0.7.3 段。）
- `DocumentEncoder` 真接入（需 `encode()` 接口细化）：属 0.8.x additive 提案
  （见下），不在补丁版动接口。
- mDNS 全局 deadline（收敛最坏耗时 `10s × N`）：本轮仅文档披露（第 7 条）。
- 直投零拷贝（`bytes is Uint8List` 直接透出）与 426 TLS 升级记忆化：纯性能项，
  各自需锚点，留待下轮。
- PWG 5102.4 金标向量出处归档缺口（审计 P2-9）：`test/pwg_encoder_test.dart`
  引用 §4.4.1 样例向量与 §4.4.2 Figure 3 的 87-octet 样本，但**未归档取自哪
  一版规范**；本次离线取不到 PWG 5102.4 原文，故金标数值本身未对一手文本复核
  （编码逻辑经逐字节演算 + CUPS `raster.h` 常量核对判定正确）。**待办**：网络
  可达时补一次一手核对，回填「规范版本 + 日期 + 页/图号」。

### 0.8.x+ — 候选增强（封板后，additive-only）

- [ ] `IppValue` 补齐 IPP 值语法：`dateTime`（0x31，RFC 8011 §5.1.15）、
  `collection`（RFC 8010 §3.1.6–3.1.7：0x34 begCollection / 0x37
  endCollection / 0x4a memberAttrName，RFC 8011 §5.1.17——
  `media-col-database` / `media-size-supported` 的载体）、text-vs-name
  （0x41 textWithoutLanguage vs 0x42 nameWithoutLanguage；WithLanguage
  变体 0x35/0x36 为 octetString 形态，RFC 8010 Table 5）
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

---

## 工程纪律（内部约定，跨版本有效）

- 验收门槛：`flutter analyze` 零告警 + 全量测试绿 + 单文件 ≤400 行；
- 能力判定只允许来自 TXT/IPP 确定性字段，禁止推断；
- 协议行为改动必须有规范一手出处（RFC/PWG/IANA/Apple 官方文档）并同步
  README 标准对照表；
- **引用纪律（0.7.2 新增）**：任何 RFC/PWG/IANA/Apple 条款引用，必须同时留存
  **章节标题 + 原文片段**，不得只写节号——0.7.1 的「引用审计轮」自称「全部
  对一手文本核验」，却把端口 631 的出处写成 §4.1（实为 §5；§4.1 的标题是
  "Printer URI, Job URI, and Job ID"）。**引用审计不得自证已核验而无片段
  支撑**；
- **版本纪律（0.7.2 新增）**：对外版本串只能来自 `lib/src/version.dart` 常量；
  发布时三处同改（pubspec / version.dart / 两个 podspec），漂移由
  `test/version_consistency_test.dart` + CI 步骤发现。README 徽章一律用动态
  CI 徽章——手写数字徽章已漂移三次（77 → 164），不再复用；
- **格式门（0.7.2 新增）**：提交前 `dart format lib test`；CI 有
  `dart format --output=none --set-exit-if-changed lib test` 门；
- **新增锚点必做敏感性验证**：临时还原旧行为，确认新用例转红。0.7.2 实测：
  `monitor()` 瞬态超时锚点在旧行为下转红（`git stash` 单文件后单跑该例）；
- 真机验证记录注明机型与日期（如 EPSON L3250，2026-09-08 出纸验证）；
- 发布日操作：移除 `publish_to: none` → `dart pub publish`（当前保持禁发防误发布）。
