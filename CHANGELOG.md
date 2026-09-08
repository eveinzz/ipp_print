# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- TLS transport (`ipps://`): printers advertising only `_ipps._tcp` are now
  directly printable; `DiscoveredPrinter.secure` selects the logical
  `ipps://` URI and the `https://` endpoint; self-signed certificates are
  accepted by default (`IppClient(acceptSelfSignedTls:)`), and discovery
  deduplication prefers the plaintext instance when a printer advertises
  both `_ipp._tcp` and `_ipps._tcp`.
- Job management: `Cancel-Job` (`IppClient.cancelJob`) and `Get-Jobs`
  (`IppClient.getJobs` → `List<IppJobSummary>`), exposed on the `IppPrint`
  facade, with boolean value encoding per RFC 8011 §5.1.22.

### Fixed

- **Operation id for Get-Job-Attributes was 0x000A (Get-Jobs' id); corrected
  to 0x0009** per the IANA IPP Operations registry / CUPS `ipp.h`
  cross-check. Regression-anchored in tests.

## [0.1.0] - 2026-09-08

### Added

- mDNS printer discovery (`_ipp._tcp`, `_ipps._tcp`,
  `_universal._sub._ipp._tcp`) with UUID-based deduplication
  (RFC 6763 / PWG 5101.2).
- Deterministic capability classification from mDNS TXT records
  (`URF=` / `pdl=`) into `airPrint` / `ippDirect` / `vendorOnly` / `unknown`.
- IPP 1.1 codec (RFC 2910 / RFC 8011): `Print-Job`,
  `Get-Printer-Attributes`, `Get-Job-Attributes`, with golden-byte tests
  against an independent reference implementation.
- IPP transport client over `dart:io` `HttpClient`
  (`POST application/ipp`, plaintext `ipp://:631`), with transient-fault
  tolerant job-state polling (RFC 8011 §5.3.7 job-state values).
- PWG-Raster encoder (PWG 5102.4): 36-byte RaS2 header + run-length rows,
  sRGB-8, golden-byte tests.
- Facade API: `discover` / `probe` / `printPdf` with a progress stream and
  an injectable `PdfRasterizer` interface (no Flutter dependency in the
  package core; rasterization is provided by the host, e.g. via
  `printing.rasterPdf`).
