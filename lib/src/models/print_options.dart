/// 打印域模型：作业选项、栅格页、栅格化注入接口、进度事件。
library;

import 'dart:typed_data';

/// 打印选项（只收录 IPP 标准属性，字段随所选打印机协商结果生成）。
///
/// **统一语义：null = 不下发该属性**，由打印机应用自身默认值
/// （RFC 8011 §5.2 job template 默认值语义）。三个可空字段
/// （[media] / [colorMode] / [duplex]）同此规则——宿主无法从打印机
/// 声明能力中确定取值时，应传 null 而不是猜一个值。
class PrintOptions {
  const PrintOptions({
    this.copies = 1,
    this.media,
    this.colorMode,
    this.duplex,
  });

  /// 打印份数（job 属性 `copies`，integer）。
  final int copies;

  /// PWG 介质自描述名（job 属性 `media`）。
  ///
  /// 取值应来自 [PrinterInfo.mediaSupported]（打印机声明为准确），
  /// 否则打印机可能拒绝；null（默认）= 不下发，打印机使用自己的
  /// `media-default`。
  final String? media;

  /// 色彩模式（job 属性 `print-color-mode`）。
  ///
  /// null（默认）= **不下发该属性**，打印机使用自己的
  /// `print-color-mode-default`（RFC 8011 job template 默认值语义，
  /// PWG 5107.3/5100.13 §6.2.27；典型 default 为 `auto`，即按文档内容
  /// 自动选彩色/单色）。显式指定时取值须为 `print-color-mode-supported`
  /// 的成员（全集：auto/auto-monochrome/bi-level/color/highlight/
  /// monochrome/process-bi-level/process-monochrome）。
  final String? colorMode;

  /// 双面模式（job 属性 `sides`：one-sided/two-sided-long-edge 等）。
  ///
  /// null = 不下发，打印机使用自己的 `sides-default`；显式指定时取值
  /// 须为 `sides-supported` 的成员。
  final String? duplex;
}

/// 一页栅格位图（24 位 sRGB，逐行无填充 RGBRGB...）。
class RasterPage {
  const RasterPage({
    required this.width,
    required this.height,
    required this.bytes,
  }) : assert(bytes.length == width * height * 3);

  /// 像素宽（非物理毫米；由 dpi 换算）。
  final int width;

  /// 像素高。
  final int height;

  /// 逐行 RGB 字节，长度恒为 `width * height * 3`。
  final Uint8List bytes;
}

/// PDF 栅格化注入接口：插件不绑定渲染实现，宿主 App 提供
/// （例如基于 printing 包 rasterPdf 的适配器）。
abstract class PdfRasterizer {
  Stream<RasterPage> rasterize(List<int> pdfBytes, {int dpi});
}

/// 打印进度事件。
class PrintProgress {
  const PrintProgress(this.stage, {this.page, this.pageCount, this.jobId});

  final PrintStage stage;
  final int? page;
  final int? pageCount;

  /// IPP 作业号（`waitingPrinter` / `done` 阶段可用，供宿主取消作业）。
  final int? jobId;
}

enum PrintStage { rasterizing, encoding, sending, waitingPrinter, done }
