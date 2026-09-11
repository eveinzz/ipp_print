/// 文档编码器抽象（0.4 Document Pipeline）。
///
/// 设计纪律：**只抽象不重写**——现有 [PwgRasterEncoder] 按规范金标
/// 锚定（1796 字节头 / RaS2 / PackBits），是最先挂入本体系的成员；
/// 后续 DocumentEncoder 实现同样只做「已有能力的接口化」。
library;

/// 把 [PrintDocument]（或栅格页流）转换为某个目标 IPP document-format
/// 的编码器。目标格式即协商器（DocumentFormatNegotiator）选定的
/// `documentFormat`。
abstract interface class DocumentEncoder {
  /// 本编码器产出的目标格式（IANA MIME，如 `image/pwg-raster`）。
  String get documentFormat;
}
