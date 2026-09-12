/// 本地能力预检器（0.5 契约冻结 v1 对象）。
///
/// 双层校验体系的第一层：本地快速判定 ticket 值是否在打印机声明能力内，
/// 零网络请求；第二层 [IppPrint.validateJob]（Validate-Job）向设备终审
/// 「此刻收不收」。两层语义不同、并存互补。
///
/// 纪律：能力缺失（声明集为空 / 字段 null）的字段**跳过检查**——
/// 「缺≠不支持」，绝不推断。
library;

import '../models.dart';

/// 能力校验器（无状态纯函数）。
class CapabilityValidator {
  const CapabilityValidator._();

  /// 校验 [ticket] 各字段 ∈ [capabilities] 对应声明集。
  ///
  /// 返回 [PrintValidationResult]：valid=false 时 [PrintValidationResult
  /// .unsupportedAttributes] 列出未通过的 job template 属性名
  /// （media / print-color-mode / sides / printer-resolution / copies /
  /// print-quality）。
  /// statusCode 恒 0x0000（本地预检无设备应答）。
  static PrintValidationResult validate({
    required PrintTicket ticket,
    required PrinterCapabilities capabilities,
  }) {
    final unsupported = <String>[];
    final media = ticket.media;
    if (media != null &&
        capabilities.mediaSupported.isNotEmpty &&
        !_contains(capabilities.mediaSupported, media)) {
      unsupported.add('media');
    }
    final colorMode = ticket.colorMode;
    if (colorMode != null &&
        capabilities.colorModesSupported.isNotEmpty &&
        !_contains(capabilities.colorModesSupported, colorMode)) {
      unsupported.add('print-color-mode');
    }
    final sides = ticket.sides;
    if (sides != null &&
        capabilities.sidesSupported.isNotEmpty &&
        !_contains(capabilities.sidesSupported, sides)) {
      unsupported.add('sides');
    }
    final resolution = ticket.resolution;
    if (resolution != null &&
        capabilities.resolutionsSupported.isNotEmpty &&
        !_contains(capabilities.resolutionsSupported, resolution)) {
      unsupported.add('printer-resolution');
    }
    final copies = ticket.copies;
    if (copies != null &&
        capabilities.copiesMin != null &&
        capabilities.copiesMax != null &&
        (copies < capabilities.copiesMin! ||
            copies > capabilities.copiesMax!)) {
      unsupported.add('copies');
    }
    final printQuality = ticket.printQuality;
    if (printQuality != null &&
        capabilities.printQualitiesSupported.isNotEmpty &&
        !capabilities.printQualitiesSupported.contains(printQuality)) {
      unsupported.add('print-quality');
    }
    return PrintValidationResult(
      valid: unsupported.isEmpty,
      statusCode: 0x0000,
      unsupportedAttributes: unsupported,
    );
  }

  /// 大小写不敏感成员判定（厂商实现各异，L3250 MIME 教训同源）。
  static bool _contains(List<String> declared, String value) =>
      declared.any((v) => v.toLowerCase() == value.toLowerCase());
}
