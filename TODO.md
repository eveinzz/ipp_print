# TODO / Roadmap

Prioritized future work for `ipp_print`. Completed items are recorded in
[CHANGELOG.md](CHANGELOG.md).

## P1

- [ ] **`ipps://` (TLS) transport** — direct connection for printers advertising
  only `_ipps._tcp` (no `_ipp._tcp`), including a self-signed certificate
  policy. Basis: IPP Guide Ch. 1 (HTTPS as the encryption channel).
- [ ] **`Cancel-Job` / `Get-Jobs`** — job management operations
  (IPP Guide Appendix A: job-id + requesting-user-name).

## P2

- [ ] **`job-state-reasons` passthrough** — surface reasons such as
  `media-jam`, `document-format-error` to the host app
  (IANA IPP Registrations).
- [ ] **`Validate-Job` pre-check** and the `Create-Job` + `Send-Document`
  multi-document path (IPP Guide Ch. 1).
- [ ] **Resolution / color / duplex negotiation** — expose
  `printer-resolution-supported`, `print-color-mode-supported`,
  `sides-supported` as a data source for host UIs (removes the fixed
  300 dpi / sRGB-8 limitation).

## P3

- [ ] **Basic / Digest authentication** — negotiated from
  `uri-authentication-supported` (IPP Guide Ch. 2).
- [ ] **HTTP 426 Upgrade handling** — plaintext → TLS upgrade path
  (RFC 8011 / IPP Everywhere).
- [ ] **Model-layer directory split** — if `lib/src/models.dart` grows past
  ~400 lines, split into `models/printer.dart` / `models/options.dart` /
  `models/exceptions.dart` with unchanged public API.
