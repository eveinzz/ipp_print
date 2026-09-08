import 'dart:typed_data';

import '../models.dart';

/// PWG-raster（PWG 5102.4）页编码器。
///
/// 页头为 36 字节、9 个大端 uint32：
/// magic("RaS2") | width | height | bitsPerColor | colorSpace
/// | dpiX | dpiY | duplex | tumble；
/// 随后逐"行组"编码：4 字节大端行程计数 + 该行 RGB 字节，
/// 相邻完全相同的行合并为一次行程（规约允许且打印机普遍依赖）。
class PwgRasterEncoder {
  const PwgRasterEncoder({this.dpi = 300});

  /// PoC 固定 300dpi（见 README 边界 4）。
  final int dpi;

  /// "RaS2" = PWG Raster v2 magic。
  static const int magic = 0x52615332;

  /// ColorSpace 枚举 19 = 24-bit sRGB（参照 ppm2pwg 的 PwgRgb24）。
  static const int colorSpaceRgb24 = 19;

  static const int _bitsPerColor = 8;

  Uint8List encodePage(RasterPage page) {
    final header = ByteData(36);
    header.setUint32(0, magic, Endian.big);
    header.setUint32(4, page.width, Endian.big);
    header.setUint32(8, page.height, Endian.big);
    header.setUint32(12, _bitsPerColor, Endian.big);
    header.setUint32(16, colorSpaceRgb24, Endian.big);
    header.setUint32(20, dpi, Endian.big);
    header.setUint32(24, dpi, Endian.big);
    header.setUint32(28, 0, Endian.big); // duplex
    header.setUint32(32, 0, Endian.big); // tumble

    final rows = _runLengthRows(page);
    final out = BytesBuilder(copy: false)
      ..add(header.buffer.asUint8List());
    for (final run in rows) {
      final count = ByteData(4)..setUint32(0, run.$1, Endian.big);
      out.add(count.buffer.asUint8List());
      out.add(run.$2);
    }
    return out.toBytes();
  }

  /// 把逐行像素折叠为 (行程数, 行字节) 序列。
  List<(int, Uint8List)> _runLengthRows(RasterPage page) {
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
      while (row + count < page.height) {
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
