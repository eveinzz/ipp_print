/// 打印票据：作业的语义模型（0.5 契约冻结 v1 核心对象）。
///
/// 上层（Universal Print App / 宿主）只理解 [PrintTicket]，不理解
/// IPP keyword；[PrintOptions] 保留为传输便利层（与 Validate-Job /
/// buildPrintJob 对接），两者经 [toOptions] / [fromOptions] 互转。
library;

import 'print_options.dart';

/// 打印票据（media/colorMode/sides/resolution/copies + fidelity）。
///
/// 统一语义与 [PrintOptions] 一致：null = 不下发该属性，打印机应用
/// 自身默认值（RFC 8011 §5.2 job template 默认值语义）；显式取值须为
/// 打印机 `xxx-supported` 声明集成员（[IppPrint.validateTicket] 本地
/// 预检 + Validate-Job 设备终审双层把关）。
class PrintTicket {
  const PrintTicket({
    this.media,
    this.colorMode,
    this.sides,
    this.resolution,
    this.copies,
    this.fidelity,
  });

  /// 从传输便利层构造（printPdf 旧调用方的迁移路径）。
  factory PrintTicket.fromOptions(PrintOptions o) => PrintTicket(
        media: o.media,
        colorMode: o.colorMode,
        sides: o.duplex,
        resolution: o.resolution == null
            ? null
            : _resolutionToKeyword(o.resolution!),
        copies: o.copies,
        fidelity: o.fidelity,
      );

  /// PWG 介质自描述名（job 属性 `media`；null = 打印机默认）。
  final String? media;

  /// 色彩模式（`print-color-mode`；null = 打印机默认）。
  final String? colorMode;

  /// 双面模式（`sides`：one-sided/two-sided-long-edge 等；null = 默认）。
  final String? sides;

  /// 打印分辨率（`printer-resolution`，PWG keyword 形态如 `360x360dpi`；
  /// null = 打印机默认。取值须来自 resolutionsSupported 协商结果）。
  final String? resolution;

  /// 打印份数（`copies`；null = 打印机默认，等效 1）。
  final int? copies;

  /// 属性保真语义（`ipp-attribute-fidelity`；null = 尽力打印）。
  final PrintFidelity? fidelity;

  /// 转传输便利层（print() 内部下发路径）。resolution 由 keyword 形态
  /// 解析为线格式 record；非法 keyword 抛 [ArgumentError]（程序员错误）。
  PrintOptions toOptions() => PrintOptions(
        copies: copies ?? 1,
        media: media,
        colorMode: colorMode,
        duplex: sides,
        fidelity: fidelity,
        resolution: resolution == null ? null : _parseResolution(resolution!),
      );
}

/// `360x360dpi` / `1440x720dpcm` keyword → `(cross, feed, unit)` record。
final RegExp _resolutionPattern = RegExp(r'^(\d+)x(\d+)(dpi|dpcm)$');

(int, int, int) _parseResolution(String keyword) {
  final m = _resolutionPattern.firstMatch(keyword);
  if (m == null) {
    throw ArgumentError.value(
        keyword, 'resolution', 'expected `<cross>x<feed>dpi|dpcm`');
  }
  return (
    int.parse(m.group(1)!),
    int.parse(m.group(2)!),
    m.group(3) == 'dpi' ? 3 : 4,
  );
}

/// record → PWG keyword 形态（`360x360dpi`）。
String _resolutionToKeyword((int, int, int) r) =>
    '${r.$1}x${r.$2}${r.$3 == 3 ? 'dpi' : 'dpcm'}';
