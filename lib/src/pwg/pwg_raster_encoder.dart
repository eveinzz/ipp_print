import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../models.dart';

/// PWG-raster（PWG 5102.4）页编码器。
///
/// 页头为规范 Table 1 的 **1796 octet**（cups_page_header2_t 线格式，
/// 网络字节序；含打印机解行必需的 cupsWidth/cupsHeight/cupsBitsPerPixel/
/// cupsBytesPerLine/cupsColorSpace 等字段）——早期 36 字节简写头使
/// 打印机以垃圾字段解行，实测 EPSON L3250 对真实内容回
/// 0x411 request-value-too-long。
///
/// 页位图（PWG 5102.4 §4.4）：每行以 **1 octet 行重复计数**（count-1，
/// 1–256 行相同折叠）开头，随后为该行的 PackBits-like 游程编码
/// （像素粒度，详见 [packBits]）。
///
/// 同步字 "RaS2" 为**文件级**（规范 Figure 1：sync + N 页），只在文档
/// 开头出现一次——由调用方（printPdf）写入，[encodePage] 不含。
class PwgRasterEncoder {
  const PwgRasterEncoder({this.dpi = 300});

  /// PoC 固定 300dpi（见 README 边界 4）。
  final int dpi;

  /// "RaS2" = PWG Raster v2 同步字（文件级，仅出现一次）。
  static const int magic = 0x52615332;

  /// 页头大小：规范 Table 1 的 1796 octet。
  static const int pageHeaderSize = 1796;

  /// ColorSpace 枚举 19 = 24-bit sRGB（参照 ppm2pwg 的 PwgRgb24）。
  static const int colorSpaceRgb24 = 19;

  static const int _bitsPerColor = 8;

  /// PWG Raster 同步字的 4 字节大端表示（文档开头写一次）。
  Uint8List get syncWordBytes =>
      Uint8List(4)..buffer.asByteData().setUint32(0, magic, Endian.big);

  Uint8List encodePage(RasterPage page) {
    final out = BytesBuilder(copy: false)
      ..add(_buildHeader(page));
    final rows = _runLengthRows(page);
    for (final run in rows) {
      // 行重复计数：1 octet（count-1，1–256 行）——规约 §4.4。
      assert(run.$1 >= 1 && run.$1 <= 256);
      out.addByte(run.$1 - 1);
      out.add(packBits(run.$2));
    }
    return out.toBytes();
  }

  /// 规范 Table 1 的 1796 octet 页头（cups_page_header2_t 线格式）。
  ///
  /// 字段偏移按 CUPS raster.h 的 cups_page_header2_t 顺序核算：
  /// 4×64B 字符串 + 逐个 4B 整数/浮点字段（无对齐填充）。
  Uint8List _buildHeader(RasterPage page) {
    final h = ByteData(pageHeaderSize);
    void u32(int off, int v) => h.setUint32(off, v, Endian.big);
    void f32(int off, double v) => h.setFloat32(off, v, Endian.big);

    // MediaClass/MediaColor/MediaType/OutputType[64]：空串（全 0）。
    u32(256, 0); // AdvanceDistance
    u32(260, 0); // AdvanceMedia
    u32(264, 0); // Collate
    u32(268, 0); // CutMedia
    u32(272, 0); // Duplex
    u32(276, dpi); // HWResolution[0]（xdpi）
    u32(280, dpi); // HWResolution[1]（ydpi）
    u32(284, 0); // ImagingBoundingBox[0]
    u32(288, 0);
    u32(292, 0);
    u32(296, 0);
    u32(300, 0); // InsertSheet
    u32(304, 0); // Jog
    u32(308, 0); // LeadingEdge
    u32(312, 0); // Margins[0]
    u32(316, 0); // Margins[1]
    u32(320, 0); // ManualFeed
    u32(324, 0); // MediaPosition
    u32(328, 0); // MediaWeight
    u32(332, 0); // MirrorPrint
    u32(336, 0); // NegativePrint
    u32(340, 0); // NumCopies
    u32(344, 0); // Orientation
    u32(348, 0); // OutputFaceUp
    u32(352, 0); // PageSize[0]（0 = 使用默认纸张）
    u32(356, 0); // PageSize[1]
    u32(360, 0); // Separations
    u32(364, 0); // TraySwitch
    u32(368, 0); // Tumble
    u32(372, page.width); // cupsWidth
    u32(376, page.height); // cupsHeight
    u32(380, 0); // cupsMediaType
    u32(384, _bitsPerColor); // cupsBitsPerColor = 8
    u32(388, _bitsPerColor * 3); // cupsBitsPerPixel = 24
    u32(392, page.width * 3); // cupsBytesPerLine（解行必需）
    u32(396, 0); // cupsColorOrder = CUPS_ORDER_CHUNKED
    u32(400, colorSpaceRgb24); // cupsColorSpace = sRGB-8
    u32(404, 0); // cupsCompression（0 = none；压缩在行级 PackBits）
    u32(408, 0); // cupsRowCount
    u32(412, 0); // cupsRowFeed
    u32(416, 0); // cupsRowStep
    u32(420, 3); // cupsNumColors
    f32(424, 1.0); // cupsBorderlessScalingFactor
    f32(428, 0.0); // cupsPageSize[0]
    f32(432, 0.0); // cupsPageSize[1]
    f32(436, 0.0); // cupsImagingBBox[0..3]
    f32(440, 0.0);
    f32(444, 0.0);
    f32(448, 0.0);
    // cupsInteger[16] @452：cupsPrintQuality（idx 8）置 4（normal），
    // 其余 0；cupsReal[16] @516、cupsString[16][64] @580 全 0；
    // cupsMarkerType/cupsRenderingIntent/cupsPageSizeName[64] 空。
    u32(452 + 8 * 4, 4);
    return h.buffer.asUint8List();
  }

  /// PWG 5102.4 §4.4 的 PackBits-like 游程编码（与 CUPS raster-stream.c
  /// 的 cups_raster_write 逐句对齐）。
  ///
  /// 关键：比较与编码以**像素**为单位（bpp 字节一组；sRGB-24 时 bpp=3），
  /// 解码端按 bpp 分组解释——按 octet 分组会产生语义错位（实测
  /// EPSON L3250 回 0x411 request-value-too-long）。
  ///
  /// - 重复像素 run（2–127）：头 = count-1 + 1 个像素；
  /// - 尾部孤立像素：头 0x00 + 1 个像素（= 重复 1 次）；
  /// - 非重复像素 run（2–128）：头 = 257-count + count×bpp 字节；
  /// - 头 0x00 语义 = 1 个像素（重复 1 次），与解码端一致。
  static Uint8List packBits(Uint8List data, {int bpp = 3}) {
    assert(data.length % bpp == 0);
    final out = BytesBuilder();
    final n = data.length ~/ bpp; // 像素数
    var i = 0; // 当前像素索引
    while (i < n) {
      final start = i;
      i++; // ptr = start 的下一像素
      if (i == n) {
        // 尾部单像素（CUPS：ptr == pend）。
        out.addByte(0);
        out.add(data.sublist(start * bpp, n * bpp));
        break;
      }
      if (_pxEq(data, start, i, bpp)) {
        // 重复像素序列：count 从 2 起，至多 127（CUPS count < 128），
        // 且重复序列不吞最后一像素（i < n-1，对应 CUPS ptr < plast）。
        var count = 2;
        while (count < 128 && i < n - 1 && _pxEq(data, i, i + 1, bpp)) {
          count++;
          i++;
        }
        out.addByte(count - 1);
        out.add(data.sublist(i * bpp, i * bpp + bpp));
        i++;
      } else {
        // 非重复像素序列：count 从 1 起，至多 128，遇相邻重复即断。
        var count = 1;
        while (count < 128 && i < n - 1 && !_pxEq(data, i, i + 1, bpp)) {
          count++;
          i++;
        }
        // 末尾修正（CUPS）：ptr 已达最后一像素且未满 128 时计入。
        if (i >= n - 1 && count < 128 && i < n) {
          count++;
          i++;
        }
        out.addByte((257 - count) & 0xFF);
        out.add(data.sublist(start * bpp, start * bpp + count * bpp));
      }
    }
    return out.toBytes();
  }

  /// 第 a/b 两个像素（各 bpp 字节）是否同值。
  static bool _pxEq(Uint8List data, int a, int b, int bpp) {
    final ao = a * bpp;
    final bo = b * bpp;
    for (var k = 0; k < bpp; k++) {
      if (data[ao + k] != data[bo + k]) return false;
    }
    return true;
  }

  /// 测试可见：暴露行组折叠结果（供规范金标样本逐行比对）。
  @visibleForTesting
  List<(int, Uint8List)> runLengthRowsForTest(RasterPage page) =>
      _runLengthRows(page);

  /// 把逐行像素折叠为 (行程数, 行字节) 序列。
  ///
  /// 行重复计数上限 256（1 octet 编码，规约 §4.4）；超长同色区
  /// （如 300dpi A4 空白边）拆分为多个行组。
  List<(int, Uint8List)> _runLengthRows(RasterPage page) {    const maxRepeat = 256;
    final stride = page.width * 3;
    final runs = <(int, Uint8List)>[];
    var row = 0;
    while (row < page.height) {
      final line = Uint8List.sublistView(
        page.bytes,
        row * stride,
        (row + 1) * stride,
      );
      var count = 1;
      while (row + count < page.height && count < maxRepeat) {
        final next = Uint8List.sublistView(
          page.bytes,
          (row + count) * stride,
          (row + count + 1) * stride,
        );
        if (!_bytesEqual(line, next)) break;
        count++;
      }
      runs.add((count, Uint8List.fromList(line)));
      row += count;
    }
    return runs;
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
