# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Debug diagnostics (`ippLog`, `ippProbeLog`, `#if DEBUG` only): discovery
  lifecycle (`register` / `discover start` / `didFind` / `resolved` with the
  resolved host / `didNotResolve` / `didNotSearch` / finish summary) and
  probe outcomes, so real-device debugging is no longer a black box.
- HTTP 426 (`Upgrade Required`) auto-upgrade: a plaintext `ipp://` POST
  rejected with 426 by a TLS-only printer is retried once over `https://`
  on the same port (RFC 2817 spirit). Real-printer verified on the
  TLS-only EPSON L3250.

### Fixed

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
