# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
  true，RFC 8011 §5.2.2）与 `printer-resolution`（resolution 线语法 9 字节，
  RFC 8011 §5.1.14）；缺省均不下发，既有作业字节零变化。

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
  inferred. New value-syntax decoders: resolution (RFC 8011 §5.1.14),
  rangeOfInteger (§5.1.15), boolean (§5.1.12).
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
