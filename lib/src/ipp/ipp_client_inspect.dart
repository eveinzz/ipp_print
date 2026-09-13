part of 'ipp_client.dart';

/// Get-Printer-Attributes 的解析结果（probe 兼容模型，0.2 起留存）。
class PrinterAttributes {
  const PrinterAttributes({
    this.mediaSupported = const <String>[],
    this.documentFormats = const <String>[],
    this.state,
    this.makeModel,
    this.colorModesSupported = const <String>[],
    this.colorModeDefault,
    this.sidesSupported = const <String>[],
    this.sidesDefault,
    this.resolutionsSupported = const <String>[],
    this.resolutionDefault,
  });

  final List<String> mediaSupported;
  final List<String> documentFormats;
  final String? state;
  final String? makeModel;

  /// `print-color-mode-supported`（PWG 5107.3 §6.2.27 取值全集：auto /
  /// auto-monochrome / bi-level / color / highlight / monochrome /
  /// process-bi-level / process-monochrome）。空 = 打印机未声明。
  final List<String> colorModesSupported;

  /// `print-color-mode-default`；null = 未声明。
  final String? colorModeDefault;

  /// `sides-supported`（one-sided / two-sided-long-edge /
  /// two-sided-short-edge）。空 = 打印机未声明。
  final List<String> sidesSupported;

  /// `sides-default`；null = 未声明。
  final String? sidesDefault;

  /// `printer-resolution-supported`（0.3.1 分辨率协商数据源；空 = 未声明）。
  final List<String> resolutionsSupported;

  /// `printer-resolution-default`；null = 未声明。
  final String? resolutionDefault;

  /// IPP printer-state 枚举 → 可读状态。
  static String? stateFromEnum(int? v) => switch (v) {
        3 => 'idle',
        4 => 'processing',
        5 => 'stopped',
        _ => null,
      };
}

extension PrinterInspect on IppClient {
  /// probe 路径：解析 probe 兼容的 10 属性集（0.3.1 加分辨率协商数据源）。
  Future<PrinterAttributes> getPrinterAttributes(DiscoveredPrinter p) async {
    final res = await post(
      p.httpUri,
      IppCodec.buildGetPrinterAttributes(
        printerUri: p.ippUriString,
        requestId: _nextRequestId,
      ),
    );
    _ensureSuccess(res, 'Get-Printer-Attributes');
    final g = _printerGroupOf(res);
    return PrinterAttributes(
      mediaSupported: _keywords(g, 'media-supported'),
      documentFormats: _keywords(g, 'document-format-supported'),
      state: PrinterAttributes.stateFromEnum(_enumOf(g, 'printer-state')),
      makeModel: _stringOf(g, 'printer-make-and-model'),
      colorModesSupported: _keywords(g, 'print-color-mode-supported'),
      colorModeDefault: _stringOf(g, 'print-color-mode-default'),
      sidesSupported: _keywords(g, 'sides-supported'),
      sidesDefault: _stringOf(g, 'sides-default'),
      resolutionsSupported: _resolutions(g, 'printer-resolution-supported'),
      resolutionDefault: _resolutionText(g, 'printer-resolution-default'),
    );
  }

  /// 能力引擎（0.3）：以 [IppCodec.fullCapabilityAttributeSet] 请求
  /// 全量标准能力并解析为 [PrinterCapabilities]。
  ///
  /// 解析 lenient：打印机省略/截断任一属性时对应字段为 null/空，
  /// 绝不推断补值（能力只来自确定性自报，RFC 8011 §6.2）。
  Future<PrinterCapabilities> getPrinterCapabilities(
    DiscoveredPrinter p,
  ) async {
    final res = await post(
      p.httpUri,
      IppCodec.buildGetPrinterAttributes(
        printerUri: p.ippUriString,
        requestId: _nextRequestId,
        requestedAttributes: IppCodec.fullCapabilityAttributeSet,
      ),
    );
    _ensureSuccess(res, 'Get-Printer-Attributes');
    final g = _printerGroupOf(res);
    final copies = _rangeOf(g, 'copies-supported');
    return PrinterCapabilities(
      name: _stringOf(g, 'printer-name'),
      info: _stringOf(g, 'printer-info'),
      makeModel: _stringOf(g, 'printer-make-and-model'),
      urisSupported: _keywords(g, 'printer-uri-supported'),
      state: PrinterAttributes.stateFromEnum(_enumOf(g, 'printer-state')),
      stateReasons: _keywords(g, 'printer-state-reasons'),
      isAcceptingJobs: _boolOf(g, 'printer-is-accepting-jobs'),
      documentFormats: _keywords(g, 'document-format-supported'),
      documentFormatDefault: _stringOf(g, 'document-format-default'),
      mediaSupported: _keywords(g, 'media-supported'),
      mediaReady: _keywords(g, 'media-ready'),
      colorModesSupported: _keywords(g, 'print-color-mode-supported'),
      colorModeDefault: _stringOf(g, 'print-color-mode-default'),
      sidesSupported: _keywords(g, 'sides-supported'),
      sidesDefault: _stringOf(g, 'sides-default'),
      resolutionsSupported: _resolutions(g, 'printer-resolution-supported'),
      resolutionDefault: _resolutionText(g, 'printer-resolution-default'),
      copiesMin: copies?.$1,
      copiesMax: copies?.$2,
      finishingsSupported: _intsOf(g, 'finishings-supported'),
      printQualitiesSupported: _intsOf(g, 'print-quality-supported'),
      printQualityDefault: _intOf(g, 'print-quality-default'),
      ippVersionsSupported: _keywords(g, 'ipp-versions-supported'),
      operationsSupported: _intsOf(g, 'operations-supported'),
      jobCreationAttributesSupported:
          _keywords(g, 'job-creation-attributes-supported'),
      uriAuthenticationSupported: _keywords(g, 'uri-authentication-supported'),
      uriSecuritySupported: _keywords(g, 'uri-security-supported'),
    );
  }
}

IppGroup? _printerGroupOf(IppResponse res) {
  final printerGroup = res.groups
      .where((g) => g.tag == IppCodec.tagPrinterGroup)
      .toList(growable: false);
  return printerGroup.isEmpty ? null : printerGroup.first;
}

List<String> _keywords(IppGroup? g, String name) => [
      for (final v in g?.attributes[name] ?? const <IppValue>[]) v.asString,
    ];

/// 多值 integer/enum：out-of-band 项被**跳过**而非抛异常（RFC 8011
/// §5.1.1：`no-value`/`unknown` 是合法形态，不代表属性值损坏）。
List<int> _intsOf(IppGroup? g, String name) =>
    (g?.attributes[name] ?? const <IppValue>[])
        .map((v) => v.asIntOrNull)
        .whereType<int>()
        .toList(growable: false);

int? _enumOf(IppGroup? g, String name) {
  final values = g?.attributes[name];
  if (values == null || values.isEmpty) return null;
  return values.first.asIntOrNull;
}

int? _intOf(IppGroup? g, String name) {
  final values = g?.attributes[name];
  if (values == null || values.isEmpty) return null;
  return values.first.asIntOrNull;
}

String? _stringOf(IppGroup? g, String name) {
  final values = g?.attributes[name];
  if (values == null || values.isEmpty) return null;
  return values.first.asString;
}

/// boolean 语法：上收为 [IppValue.asBool]（0.5 Typed Value 层）。
bool? _boolOf(IppGroup? g, String name) {
  final values = g?.attributes[name];
  if (values == null || values.isEmpty) return null;
  return values.first.asBool;
}

/// rangeOfInteger 语法：上收为 [IppValue.asRange]（0.5 Typed Value 层）。
(int, int)? _rangeOf(IppGroup? g, String name) {
  final values = g?.attributes[name];
  if (values == null || values.isEmpty) return null;
  return values.first.asRange;
}

/// resolution 语法：上收为 [IppValue.asResolution]（0.5 Typed Value 层），
/// 输出 PWG keyword 形态字符串（`360x360dpi`）。
List<String> _resolutions(IppGroup? g, String name) => [
      for (final v in g?.attributes[name] ?? const <IppValue>[])
        v.asResolution.asKeyword,
    ];

String? _resolutionText(IppGroup? g, String name) {
  final values = g?.attributes[name];
  if (values == null || values.isEmpty) return null;
  return values.first.asResolution.asKeyword;
}
