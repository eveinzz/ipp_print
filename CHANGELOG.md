# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
