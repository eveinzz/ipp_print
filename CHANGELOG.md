# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.7.4] — 2026-09-12

### Fixed

- **栅格路径静默吞掉打印份数（设 N 份只出 1 份）**。此前 `copies` 无论何值
  都原样下发；对流式光栅文档（`image/pwg-raster` 回退路径），后端**可以**回
  `successful-ok-ignored-or-substituted-attributes`（`0x0001`）并只印一份 ——
  而 `0x0001` 落在本包的成功区间内，于是宿主看到成功、用户只拿到 1 份，全程
  无告警。现栅格路径把份数实现在**文档层**：整份页序重复 `copies` 次
  （**collated**），下发属性固定为 `copies=1`（避免与硬件份数重复计数；
  `copies < 1` 归一为 1，绝不产出只含同步字的空文档）。

  判据（**通用，与机型/品牌/型号无关**，均为一手核对）：

  - **参考实现**：CUPS 对流式光栅 `image/*` 与 `application/vnd.cups-raster`
    **强制 `copies = 1`**，由上游过滤器预产副本（`cups/ppd-cache.c`
    `_cupsConvertOptions`，注释原文 "Multi-page image formats will have copies
    applied by the upstream filters"）。即「客户端预产份数」是参考实现的既定
    架构，不是某个驱动的怪癖。
  - **协议语义**：RFC 8011 §5.2.5 中单文档 `copies=N` 意为 N 份**完整副本**
    （collated Sets，§2.3.10），而非「逐页 N 次」；故客户端预产必须整份重复
    页序 —— 重复单页会得到 uncollated（错序）结果。
  - **合规底线**：PWG 5100.14 *IPP Everywhere* Table 8 将 `copies` 列为
    **REQUIRED** Job Template 属性，§9.3 要求支持 image/jpeg 或
    application/pdf/openxps 的打印机必须支持之。声明支持却静默忽略属不合规，
    客户端兜底是这类后端上唯一仍然正确的做法。
  - **真机佐证（仅佐证，不构成判据）**：EPSON L3250（2026-09-12）自报
    `copies-supported: 1..99` 且把 `copies` 列入
    `job-creation-attributes-supported`，实操对 `copies≥2` 的 Print-Job 与
    Validate-Job **一律**回 `0x0001`（Unsupported Attributes 组列出 `copies`），
    作业计数 `impressions=1`；其 PPD 亦声明 `*cupsManualCopies: True`
    （CUPS PPD 扩展：printer does not support copy generation in hardware）。
    现象与上述三条判据完全一致。

### Added

- `test/copies_test.dart`：份数端到端锚点 5 例 —— `copies=2` → 页序重复 2 次
  且属性 `copies=1`；`copies=1` → 与修复前逐字节一致；`copies=0`/负值 →
  归一为 1；默认 ticket → 单份；PDF 直投 `copies=2` → 属性原样为 2。
  属性值由**独立线格式步进器**读取（不依赖被测解析代码）。敏感性验证：
  还原旧实现 → 其中 2 例转红。全量 **187 例**通过（原 182 + 5）。

### Changed

- 栅格路径下发的 `copies` 属性**语义变更**：由「原样传递用户值」改为
  「恒为 1，份数已体现在文档字节中」。对宿主 API 无影响（`PrintTicket` /
  `PrintOptions` 入参不变），但**抓包可见**属性值变化 —— 这是修复本身的要求。

## [0.7.3] — 2026-09-12

发现层**资源路径策略单源化**：两条发现通道（`multicast_dns` / 原生 Bonjour）
对「TXT `rp` 缺失或为空」给出同一判定 —— **跳过该实例，绝不造路径**。此前
两者相反（原生兜底 `/ipp/print`），属同契约双实现漂移（本项目头号缺陷源）。

### Changed

- **原生 Bonjour 路径不再兜底 `/ipp/print`**：`rp` 缺失/为空 ⇒ 跳过实例。
  规范依据（一手核对）：Apple *Bonjour Printing Specification* v1.2.1 Table 2
  给 `rp` 的默认值是空串，且「值等于默认值的键 MAY 省略」→ `rp` **可被合法
  省略**；PWG 5100.14 *IPP Everywhere* p.22 则要求打印机 **MUST** 提供 `rp`
  → 省略者必然不是合规设备，其真实路径无从得知。CUPS 参考实现亦从不据 `rp`
  推导路径（`backend/dnssd.c`、`cups/dnssd.c`、`cups/dest.c`、`backend/ipp.c`、
  `cups/http.c` 对 `"rp"` 零命中），macOS 把路径解析推迟到连接期，故「多数
  AirPrint 打印机资源路径为 ipp/print」（Apple WWDC 2016 S725）不足以支撑对
  **省略 `rp` 的子集**下断言。造路径 = 把「未知」写成「已知」：设备会出现在
  列表里，却在打印时以难以归因的错误失败。
- **影响面**：仅限「广播 IPP 但不广播 `rp`」的非合规设备。真机实测（EPSON
  L3250，2026-09-12）TXT 含 `rp=ipp/print`，行为不变。代价可逆 —— 此类设备
  仍可用 `IppPrint.addEndpoint` 显式添加（手动端点即用户的断言，模型对其有
  明文豁免）。

### Fixed

- **原生路径 TXT 键未归一小写**：`NetService.dictionary(fromTXTRecord:)` 保留
  线路原样大小写，而 Swift 侧用字面量 `"rp"` 抽取、Dart 侧原样透传 —— 大写
  `RP=` 的**合法**设备会抽取失败（RFC 6763 §6.2 规定 TXT 键大小写不敏感）。
  现 Dart 侧统一归一小写，同时满足 `DiscoveredPrinter.txt` 明文声明的「小写
  键」契约（此前该契约在原生路径可被违反）。

### Added

- `test/discovery_rp_policy_test.dart`：**跨路径契约锚点** —— 把同一条线路
  TXT 记录同时喂给两条路径，逐格断言「跳过 / 路径」判定一致（无 TXT / 空值 /
  规范形态 / 带前导斜杠 / 大写键 / 有 TXT 但无 `rp`）＋策略单源真值表。
- `lib/src/discovery/resource_path.dart`：策略单源（内核内部，不进 barrel）。
- 原生路径新增锚点 4 例：`rp` 缺失 → 跳过 / `rp` 空串 → 跳过 / 大写 `RP=`
  → 解析出真实路径（值刻意区别于旧兜底，旧行为必然给错）/ 键归一小写。
- 双 README 诚实清单第 6 条改写：由「两条通道严格度不同」改为「绝不造资源
  路径」+ 大小写不敏感说明。

**敏感性验证**：临时还原 `native_bonjour_discovery.dart` 旧行为 → 新增锚点
6 例转红，恢复后全绿。

## [0.7.2] — 2026-09-12

对外文档与版本链的**真实性收口**（CORE FREEZE 内的「正确性 / 测试 / 文档」
变更，无公共 API 增删）。触发：0.7.1 全链审计报告（P0=0，问题集中在对外
文档失真、版本链无单一真相源、多处引用错误）。

### Added

- **公共导出面锚点** `test/public_api_test.dart`：43 个公共类型经 barrel 的
  编译期导出断言 + 3 个扩展方法入口 + `lib/src` 导出闭包静态闸（6 个内部
  文件显式登记理由）+ `inspect()` 解析与超时错误映射 + `validateTicket()`
  Facade 出口 + 10s 挂起防御锚点计数闸。（此前 17 个测试文件**全部** import
  `src/` 内部路径，barrel 导出面回归在测试层完全不可见。）
- **版本串单一真相源** `lib/src/version.dart` + `test/version_consistency_test.dart`：
  User-Agent 改为引用常量；测试断言常量 == pubspec == 两个 podspec。
- CI 新增两道门：`dart format --set-exit-if-changed lib test`；pubspec 与
  两个 podspec 的版本一致性比对（独立于测试文件，防测试被误改后失守）。

### Fixed

- **`monitor()` 超时改为硬上界**：deadline 判定提至循环首。此前它只在查询
  成功分支判定，瞬态异常分支（`continue`）绕过它——设备持续不可达时实际
  耗时 = `timeout + 重试退避`，且抛 `SocketException` 而非文档承诺的
  `IppJobTimeoutException`。新增瞬态路径锚点（敏感性已验证：还原旧行为该
  用例转红；修复后耗时 < 30ms 即收口）。
- **双 README 边界清单 2 条与实现相反**（对外失真，**低估**能力会劝退目标
  用户）：①「不支持 PDF 直投」→ 0.4/0.5 已实现机会主义直投（声明集命中即
  原样提交）；②「分辨率协商尚未实现，不发送 `printer-resolution`」→ 0.5 起
  已下发。两条均改为与实现一致的表述，并补 2 条此前未披露的诚实条目
  （两条发现通道的 `rp` 策略与超时语义不对称）。
- **「Pure Dart, zero Flutter dependencies」为半真声明** → 改为准确表述
  （协议内核纯 Dart；包整体是 Flutter 插件，Facade 级测试需 `flutter test`，
  纯 `dart test` 只能加载协议内核子集）。
- **RFC 错引更正**：端口 631 的出处 `RFC 8010 §4.1` → **§5**。一手核验：
  §4.1 标题为 "Printer URI, Job URI, and Job ID"（与端口无关）；§5
  "IPP URI Schemes" 原文载 "port 631 is the IANA-assigned well-known port
  for the 'ipp' and 'ipps' schemes"；§4 章首另载 Printer MUST support
  631。⚠️ 该错引由 0.7.1 的引用审计轮引入，且该轮声称「全部对一手文本
  核验」——本版一并回改 0.7.0 / 0.7.1 条目内的同一错引（记录不应保留已知
  错误），并新增一条流程约定：引用改动必须附原文片段（见 TODO.md）。
- `example/main.dart` 定义了 `FakeDiscovery` 却未注入 → `printers.first`
  运行即抛 `StateError`（而其文件头注释与 README 都称「离线可跑」）。改为
  注入，并精确化注释（假发现层离线，probe 仍真的发包给假端点）。
- podspec `s.version` `0.5.0` → `0.7.2`（同类漂移第二次复发，现由闸守住）。
- 文档注释失真 2 处：`IppValue.values()` 注释自称「返回第一个组」而实现是
  跨全部组拼接；PWG 编码器注释称同步字「由调用方 printPdf 写入」，实际写入
  点是 `_prepareSubmission`。

### Notes

- README 测试徽章由手写数字（停在 `77`，实测已 164 例）改为**动态 CI 徽章**：
  数字徽章已漂移三次，改为结构上不可漂移的 CI 状态徽章。
- 双 README「26 standard attributes」精确化为「请求 26 个属性 → 解析为 27 个
  能力字段」（两个数字都对，同名易混）。

## [0.7.1] — 2026-09-12

CORE FREEZE 下的协议正确性补齐：print-quality（准入唯一标准 = IPP 内核
本身缺失的协议能力）。

### Added

- **`print-quality` job template 属性（RFC 8011 §5.2.13，type2 enum，
  RECOMMENDED）**：`PrintOptions` / `PrintTicket` 新增 `printQuality`
  （null = 不下发，既有作业字节零变化；原始 enum 值透出——Table 12 标准
  值 3=draft / 4=normal / 5=high，厂商扩展值原样下发，与 finishings 同
  纪律）；Print-Job / Validate-Job / Create-Job 经 `_writeJobTemplate`
  单一来源同构下发。
- `PrinterCapabilities.printQualitiesSupported` / `printQualityDefault`
  （inspect 请求集 24 → 26 属性；lenient 解析，缺失 = 空/null 不推断）。
- `CapabilityValidator` 本地预检补 print-quality ∈ 声明集校验
  （声明缺失跳过，缺≠不支持）。
- 测试锚点 8 例（wire 三操作同构 / inspect 解析 / validator / 往返），
  敏感性验证：停用下发路径 → 2 例线格式锚点转红。

### Fixed

- 测试 fixture resolution 值 tag 0x35（textWithLanguage）→ 0x32
  （resolution，RFC 8010 Table 1）——解析器 tag 无关，锚点弱化而非断裂。
- 引用残留清扫：端口出处 RFC 2910/7472 → RFC 8010 §5 / RFC 7472
  （2 处）；resolution 节号 §5.1.14 → §5.1.16（3 处注释）。
  （本条原记为「RFC 8010 §4.1」，属错引——§4.1 的实际标题是
  "Printer URI, Job URI, and Job ID"，631 出自 §5 "IPP URI Schemes"；
  0.7.2 按一手原文回改。）
- User-Agent `ipp_print/0.6` → `ipp_print/0.7`（0.7.0 期间漂移复发）。

## [0.7.0] — 2026-09-11

Access & CORE FREEZE：补最后一个入口缺口（手动直连），内核封板。

### Added

- **`IppPrint.addEndpoint(Uri)`** 手动直连端点（发现不到 ≠ 不能打印）：
  mDNS 被屏蔽 / 跨网段 / 已知地址场景。URI 本身即 IPP endpoint 存在性的
  用户断言——`probe` / `print` / `submit` 的 TXT 分类否定门对该端点豁免，
  能力判定仍交实时查询 + 协商器终审（probe 驱动，manual 不放松 ready 判据）。
  解析诚实：scheme 白名单 ipp/ipps/http/https；缺省端口按 RFC 8010 §5 /
  RFC 7472
  （ipp/ipps = 631）与 HTTP 标准（80/443）；空路径 → `/`；带 query/fragment
  或缺 host → 拒绝（端点语义有歧义，不猜）。
- `DiscoveredPrinter.manualEndpoint` 标志位（发现产物恒 false，豁免不外溢）。
- example 补 addEndpoint 用法展示。

### Notes

- **⛔ CORE FREEZE 条款随本版生效**：Contract v2 = Printer /
  PrinterCapabilities / PrintDocument / DocumentRoute / PrintTicket /
  PrintValidationResult / PrintJob；0.7.x 只允许修 BUG、协议正确性、兼容性、
  性能、测试、平台适配；新 API 准入唯一标准 = IPP 内核本身缺失的协议/设备
  能力，上层 UI/产品需求永不构成准入理由。流式发现 / Diagnostics /
  NWBrowser / NsdManager 移入 0.8.x+ 候选（additive-only，永不阻塞上层）。
- 发布决策保留 `publish_to: none`：GitHub 开源已就绪（MIT LICENSE + example
  + 双 README），pub.dev 发布待作者另行拍板。

## [0.6.0] — 2026-09-11

Job Engine：作业语义成为内核契约；submit / monitor / cancel 职责拆分。

### Added

- **`PrintJob`**（不可变作业快照，Contract v2 成员）：job-id + job-state
  （RFC 8011 §5.3.7 七态 + unknown）+ `job-state-reasons`（§5.3.8，原始
  keyword 透传，`media-jam` ≠ `printer-stopped` 的作业级语义）+ 目标
  打印机寻址上下文。
- **submit / monitor / getJob / cancel 职责拆分**：`IppPrint.submit()`
  （gate → 实时协商 → 编码 → Print-Job，返回打印机应答快照）、
  `monitor()`（轮询 Get-Job-Attributes 的 `Stream<PrintJob>`，终态关流、
  超时抛 `IppJobTimeoutException`、瞬态故障有界吸收）、`getJob()`、
  `cancel(PrintJob)`。`print()` 进度流（`PrintStage`）完全向后兼容，
  与 `submit()` 共享 gate→协商→编码单一来源 `_prepareSubmission`（防双入口漂移）。
- **`Create-Job` + `Send-Document`**（RFC 8011 §4.2.4/§4.3.1，opportunistic）：
  线格式 `buildCreateJob`（无 document-format）/`buildSendDocument`
  （last-document 为 Client MUST）与 `IppClient.createJob`/`sendDocument`；
  无上层场景牵引，仅内核能力补全（做成即测）。
- `IppClient.getJob()`：单作业快照查询（job-id / job-state /
  job-state-reasons / job-name）；`IppJobSummary.stateReasons` 字段
  （Get-Jobs / Print-Job 响应同步透出）。

### Fixed

- **`ipp-attribute-fidelity` 组归属（线格式缺陷）**：RFC 8011 §4.2.1.1
  将其定义为 **Group 1 操作属性**，原实现误写入 Group 2 job template 组
  （0.5.0 引入；默认不下发故现网未触发）。现于操作属性组下发，并锚定
  组归属回归测试。
- **Validate-Job 同构性**：`buildValidateJob` 补齐 fidelity /
  printer-resolution 镜像下发（原与 Print-Job 不同构，违反 §4.2.3
  「同构校验」语义）；job template 属性改由三处共用 `_writeJobTemplate`
  单一来源（Print-Job / Validate-Job / Create-Job，防漂移）。
- **Create-Job 保真语义**：`buildCreateJob` 补 `ipp-attribute-fidelity`
  同构下发（§4.2.4 排除清单仅四个每文档属性，fidelity 不在其列；
  job template 值随本请求提供，保真语义同样适用——验收审计补齐，
  与 Validate-Job 修复同类）。
- `submitJob` 返回值升级为 `IppJobSummary`（job-id / job-state /
  job-state-reasons——RFC 8011 §4.2.1.2 三者均为响应 REQUIRED；缺失
  如实 unknown/空集，不推断）。
- User-Agent 版本串 `ipp_print/0.3` → `ipp_print/0.6`（0.4/0.5 期间漂移）。

## [0.5.0] — 2026-09-11

Print Core Foundation（契约冻结 v1）：作业语义层成为可长期依赖的契约。

### Added

- **`PrintTicket`**（作业语义模型：media / colorMode / sides / resolution /
  copies + `PrintFidelity`）；`print()` 以 `ticket:` 参数接收（原 `options:`
  参数保留于 `printPdf`，经 `PrintTicket.fromOptions` 桥接）。
- **`CapabilityValidator`**（本地预检，零网络请求）：ticket 值 ∉ 声明能力 →
  结构化 `PrintValidationResult` + 未支持属性名列表；与 Validate-Job
  （设备级终审）双层并存；能力缺失字段跳过（缺≠不支持）。
  Facade 出口：`IppPrint.validateTicket(...)`。
- **`IppErrorCategory`** 分类轴（ipp / unsupported / job / network / generic）：
  新增 `IppUnsupportedException`；`IppTransientException` 迁入统一异常体系。
  网络层平台异常（SocketException 等）保持原样透出，不二次包装。
- **Typed IPP Value 基础层**：`IppValue.asBool` / `asRange` / `asResolution`
  （+ `IppResolution`，keyword 形态 `360x360dpi`）——inspect 定制解码上收。
- `print()` 线格式新增：`ipp-attribute-fidelity`（fidelity=exact 时下发
  true，RFC 8011 §4.2.1.1）与 `printer-resolution`（resolution 线语法 9 字节，
  RFC 8011 §5.1.16）；缺省均不下发，既有作业字节零变化。

### Changed

- **Capability Gate 事实化重构**：`print()` 仅拒绝 TXT `unknown`（无 IPP
  证据）；airPrint / ippDirect / vendorOnly 均放行至实时能力查询 + 协商器
  终审——**仅声明 IPP+PDF 的设备不再被整包拒绝**（PDF 直投经协商器天然
  可达）。`probe()` 的 vendorOnly 同样改为实时 IPP 交叉验证（不再凭 TXT
  盲判 unsupported）；airPrint 保持免查询快路径。

### Internal

- `ipp_message.dart` 拆分 `_Builder` 至 `ipp_message_builder.dart`（≤400 行
  纪律，预留 0.6 Job Engine 增量空间）。

## [0.4.1] — 2026-09-11

### Fixed

- **UTF-8 correctness (RFC 8011 `attributes-charset=utf-8`)**: attribute
  names and text values were encoded with `String.codeUnits` (UTF-16 code
  units written raw), and responses decoded with `String.fromCharCodes` —
  non-ASCII values (e.g. a Chinese `job-name`, or a Chinese
  `printer-info` returned by the printer) produced corrupt bytes in both
  directions. Encoding now goes through `utf8.encode`; decoding through
  `utf8.decode(allowMalformed: true)` (lenient — vendor mojibake becomes
  replacement characters instead of an exception). ASCII behavior is
  byte-identical; golden wire tests unchanged.

### Changed

- `IppJobState.fromCode` maps unknown `job-state` values to the new
  `IppJobState.unknown` instead of silently guessing `pending`; a
  Get-Job-Attributes response missing `job-state` also yields `unknown`
  ("not declared" ≠ "supported"). `unknown` is non-terminal, so
  `waitForTerminalState` keeps polling — no misjudgment.
- Added GitHub Actions CI (analyze + test on stable Flutter).

## [0.4.0] — 2026-09-11

### Added

- **Document Pipeline skeleton**:
  - `PrintDocument` (bytes + mimeType + optional name) — the pipeline input;
  - `DocumentFormatNegotiator` — stateless pure-function routing: if the
    printer's declared `document-format-supported` contains the document
    MIME → passthrough (keeps vector/text); else if it contains
    `image/pwg-raster` → raster fallback; else throws — "not declared"
    ≠ "supported", never inferred. Real-device anchor: EPSON L3250
    declares `[octet-stream, pwg-raster, escpr]` (no PDF), so a PDF
    document must take the raster fallback (test-anchored);
  - `DocumentEncoder` abstraction with `PwgRasterEncoder` as the first
    member (interface only, no rewrite — golden-format tests unchanged);
  - `models.dart` split into `models/` domain files (identity /
    capabilities / print options / exceptions) behind a compatible barrel;
  - **`IppPrint.print(document, …)`** — the pipeline's general entry point:
    the kernel queries `document-format-supported` live (10 s guard) and
    routes via the negotiator — declared MIME → passthrough (document bytes
    submitted verbatim, vector/text preserved); else `image/pwg-raster`
    → raster fallback (PDF documents only, injected `PdfRasterizer`);
    else throws. `job-name` comes from `PrintDocument.name`;
  - `printPdf()` is now a convenience wrapper around `print()`: the
    submitted `document-format` comes from the printer's live declaration
    set instead of a hardcoded `image/pwg-raster` (adds one
    Get-Printer-Attributes round-trip; PWG wire format unchanged).

## [0.3.2] — 2026-09-11

### Fixed

- **Version sync**: iOS/macOS podspecs were still at `0.2.0` while pubspec
  and CHANGELOG said `0.3.x` — both podspecs now track the package version.

### Changed

- **BREAKING** `PrintOptions`: `media` and `duplex` no longer default to
  `iso_a4_210x297mm` / `one-sided` (which were silently sent to the printer);
  they now default to `null` = attribute omitted, printer applies its own
  `media-default` / `sides-default` — same semantics `colorMode` already had
  since 0.3.0. Pass explicit values to keep the previous behavior.
- **probe() honesty tightening**: a response whose
  `document-format-supported` is missing (empty set) now downgrades to
  `unsupported` instead of being treated as PWG-raster-capable — "not
  declared" ≠ "supported"; the attribute is RFC 8011 REQUIRED for printers,
  an empty set means non-conformant and is never inferred around.

## [0.3.1] — 2026-09-11

### Added

- **Resolution negotiation data source**: the probe request set now includes
  `printer-resolution-supported` / `-default` (10 attributes), surfaced on
  `PrinterInfo` as `resolutionsSupported` / `resolutionDefault`. Real-printer
  context (EPSON L3250, 2026-09): the host previously rasterized at a
  hard-coded 300 dpi that is **not** in the printer's declared set
  (`360x360dpi`, `1440x720dpi`) — lenient printers accept it, strict ones may
  reject or mis-render. Hosts should pick the closest declared symmetric dpi.
- **`printPdf(dpi: …)`**: per-call dpi override for the PWG page header
  (`cupsHWResolution` / `PageSize` scaling); `null` (default) keeps the
  constructor value.

### Fixed

- `PrinterCapabilities.name` documentation: real-device finding — EPSON
  returns the URI path fragment (`ipp/print`) as `printer-name`; it must
  never be used as a UI display name (use the mDNS instance name or
  `printer-info`).

## [0.3.0] — 2026-09-11

### Added

- **Capability Engine (`inspect()`)**: full standard capability query —
  `Get-Printer-Attributes` now requests the `fullCapabilityAttributeSet`
  (24 printer description/status/template attributes: identity, state,
  `printer-state-reasons`, `printer-is-accepting-jobs`, document formats,
  media, color, sides, resolutions, `copies-supported` (rangeOfInteger),
  finishings, IPP versions, operations, job-creation attributes, URI
  security) and parses them leniently into the new `PrinterCapabilities`
  model — every field comes from deterministic printer self-reporting
  (RFC 8011 §6.2), missing attributes stay null/empty, nothing is
  inferred. New value-syntax decoders: resolution (RFC 8011 §5.1.16),
  rangeOfInteger (§5.1.14), boolean (§5.1.12).
- **Validate-Job preflight (`validateJob()`)**: operation 0x0004
  (RFC 8011 §4.2.3, CUPS ipp.h cross-checked) with the structured
  `PrintValidationResult` — `valid` + the printer's Unsupported
  Attributes group (tag 0x05) surfaced by name, so hosts can ask
  "can you print this job?" before submitting megabytes of document data.
- **Color/duplex capability negotiation**: `Get-Printer-Attributes` now
  requests `print-color-mode-supported` / `-default` and
  `sides-supported` / `-default` (default request set: 4 → 8 attributes),
  and `probe()` surfaces them on `PrinterInfo` as `colorModesSupported`,
  `colorModeDefault`, `sidesSupported`, `sidesDefault` — so host UIs can
  offer **only the values the printer declares support for**.
- Debug diagnostics (`ippLog`, `ippProbeLog`, `#if DEBUG` only): discovery
  lifecycle (`register` / `discover start` / `didFind` / `resolved` with the
  resolved host / `didNotResolve` / `didNotSearch` / finish summary) and
  probe outcomes, so real-device debugging is no longer a black box.
- HTTP 426 (`Upgrade Required`) auto-upgrade: a plaintext `ipp://` POST
  rejected with 426 by a TLS-only printer is retried once over `https://`
  on the same port (RFC 2817 spirit). Real-printer verified on the
  TLS-only EPSON L3250.

### Changed

- **`discover()` browses the three service types in parallel** instead of
  sequentially: worst-case wall time drops from 3×timeout to ≈ one window;
  cross-type results merge by printer identity (plaintext instance
  preferred, `mergeDedup` unit-tested).
- User-Agent string updated to `ipp_print/0.3`.

### Fixed

- **`getJobs` no longer silently fabricates dirty job rows**: groups
  missing `job-id` / `job-state` are skipped and logged instead of being
  reported as job 0 / pending, which masked parse anomalies.
- **Job-template attributes are now uniformly omit-when-null**:
  `PrintOptions.media` and `PrintOptions.duplex` are nullable (defaults
  unchanged), and `Print-Job` omits `media` / `print-color-mode` / `sides`
  when null so the printer applies its own `*-default` (RFC 8011 §5.2).
  Previously `media`/`sides` were always sent, which forced a hard-coded A4
  media even when the document was laid out for another paper size.
- **Native discovery: resolved `NetService` was not retained** — the
  delegate callback's service was released by ARC as soon as the browser
  delegate method returned, silently cancelling `resolve` (with no
  `didNotResolve` callback). Resolving services are now strongly retained
  and released on completion/failure. Real-device verified: 2 found →
  2 resolved.
- **Probe hang guard**: `Get-Printer-Attributes` during probe is bounded
  by a 10 s timeout; `TimeoutException`/`SocketException` map to
  `offline`, `IppPrintException` maps to `unsupported` (previously a
  half-open TCP connection could hang the probe indefinitely).
- **PWG-raster encoder rewritten to the normative wire format**
  (PWG 5102.4 §4 / CUPS `raster.h` + `raster-stream.c`, verified against
  the primary sources):
  - page header expanded from a 36-byte shorthand to the full
    **1796-octet `cups_page_header2_t` line format** (the missing
    `cupsBytesPerLine` etc. made the printer mis-decode row data —
    real printer returned `0x0411 client-error-document-format-error`);
  - `RaS2` sync word moved to **file level** (once per document, §4 /
    Figure 1) — it is not part of `encodePage`;
  - PackBits-like run encoding confirmed at **pixel granularity**
    (bpp = 3 for sRGB-24) with row groups (1-octet row repeat count,
    1–256 rows), matching CUPS `cups_raster_write` line by line;
  - encoder is now validated **byte-for-byte against the spec's own
    §4.4.2 sample bitmap** in addition to the existing golden tests.
- Swift delegate method names for the current SDK
  (`netServiceBrowser(_:didFind:moreComing:)`,
  `searchForServices(ofType:)`, `TXTRecordData`), verified via
  `swiftc -typecheck` on both platforms.

## [0.2.0]

### Added

- **Native Bonjour discovery on iOS/macOS** (`NativeBonjourDiscovery`,
  `IppPrintPlugin`): browsing now goes through the system Bonjour
  framework (mDNSResponder), which is exempt from the iOS 14+ multicast
  entitlement that silently blocks raw-socket mDNS (`multicast_dns`).
  Discovery is routed by platform automatically (`defaultPlatformDiscovery`):
  Apple platforms use the native path, all others keep `multicast_dns`.
  Requires only the standard Local Network permission.
- TLS transport (`ipps://`): printers advertising only `_ipps._tcp` are now
  directly printable; `DiscoveredPrinter.secure` selects the logical
  `ipps://` URI and the `https://` endpoint; self-signed certificates are
  accepted by default (`IppClient(acceptSelfSignedTls:)`), and discovery
  deduplication prefers the plaintext instance when a printer advertises
  both `_ipp._tcp` and `_ipps._tcp`.
- Job management: `Cancel-Job` (`IppClient.cancelJob`) and `Get-Jobs`
  (`IppClient.getJobs` → `List<IppJobSummary>`), exposed on the `IppPrint`
  facade, with boolean value encoding per RFC 8011 §5.1.12.

### Changed

- Package converted from pure Dart to a Flutter plugin (adds native
  `ios/` and `macos/` pods); the IPP transport core remains pure Dart.

### Fixed

- **Operation id for Get-Job-Attributes was 0x000A (Get-Jobs' id); corrected
  to 0x0009** per the IANA IPP Operations registry / CUPS `ipp.h`
  cross-check. Regression-anchored in tests.
- **Job-state polling now absorbs transient TLS handshake failures**
  (`HandshakeException`) on `ipps://` printers, matching the existing
  tolerance for network flaps and HTTP 5xx; bounded by
  `maxTransientErrors`. Regression-anchored in tests.
- Standards citations corrected and upgraded: RFC 2910 → RFC 8010
  (§3.1.4 / §3.1.5, verified against the RFC text); printer-state clause
  §5.4.12 → §5.4.11; boolean clause §5.1.22 → §5.1.12; added RFC 7472
  (IPP over HTTPS / `ipps` URI scheme) and operation-code rows to the
  README standards mapping.

## [0.1.0] - 2026-09-08

### Added

- mDNS printer discovery (`_ipp._tcp`, `_ipps._tcp`,
  `_universal._sub._ipp._tcp`) with UUID-based deduplication
  (RFC 6763 / PWG 5101.2).
- Deterministic capability classification from mDNS TXT records
  (`URF=` / `pdl=`) into `airPrint` / `ippDirect` / `vendorOnly` / `unknown`.
- IPP 1.1 codec (RFC 8010 / RFC 8011): `Print-Job`,
  `Get-Printer-Attributes`, `Get-Job-Attributes`, with golden-byte tests
  against an independent reference implementation.
- IPP transport client over `dart:io` `HttpClient`
  (`POST application/ipp`, plaintext `ipp://:631`), with transient-fault
  tolerant job-state polling (RFC 8011 §5.3.7 job-state values).
- PWG-Raster encoder (PWG 5102.4) initial version: sRGB-8, golden-byte tests.
- Facade API: `discover` / `probe` / `printPdf` with a progress stream and
  an injectable `PdfRasterizer` interface (no Flutter dependency in the
  package core; rasterization is provided by the host, e.g. via
  `printing.rasterPdf`).
