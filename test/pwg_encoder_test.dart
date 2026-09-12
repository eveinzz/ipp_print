import 'dart:typed_data';

import 'package:ipp_print/src/models.dart';
import 'package:ipp_print/src/pwg/pwg_raster_encoder.dart';
import 'package:test/test.dart';

/// 独立参照实现（非被测代码）：按 PWG 5102.4 Table 1 / CUPS
/// raster.h 手工拼装 1796 octet 页头与行组。
///
/// 行组 = 1 octet 行重复计数（count-1，1-256 行）+ 该行 PackBits-like
/// 游程编码（重复像素头 = count-1；非重复头 = 257-count；粒度 = 像素）。

/// 独立生成 1796 页头期望字节（仅填被测关键字段，其余恒 0）。
List<int> _expectedHeader({
  required int width,
  required int height,
  required int bytesPerLine,
  int dpi = 300,
}) {
  final out = List<int>.filled(1796, 0, growable: true);
  void u32(int off, int v) {
    out[off] = (v >> 24) & 0xFF;
    out[off + 1] = (v >> 16) & 0xFF;
    out[off + 2] = (v >> 8) & 0xFF;
    out[off + 3] = v & 0xFF;
  }

  // float 1.0 的网络字节序 = 0x3F800000
  const f1 = [0x3F, 0x80, 0x00, 0x00];

  void f32(int off, double v) {
    final b = ByteData(4)..setFloat32(0, v, Endian.big);
    out.setRange(off, off + 4, b.buffer.asUint8List());
  }

  u32(276, dpi); // HWResolution[0]
  u32(280, dpi); // HWResolution[1]
  // PageSize[2]（点）：显式页尺寸 = 像素 × 72 / dpi（不交打印机默认裁决）
  u32(352, (width * 72 / dpi).round());
  u32(356, (height * 72 / dpi).round());
  u32(372, width); // cupsWidth
  u32(376, height); // cupsHeight
  u32(384, 8); // cupsBitsPerColor
  u32(388, 24); // cupsBitsPerPixel
  u32(392, bytesPerLine); // cupsBytesPerLine
  u32(400, 19); // cupsColorSpace = sRGB-8
  u32(420, 3); // cupsNumColors
  out.setRange(424, 428, f1); // cupsBorderlessScalingFactor = 1.0
  f32(428, width * 72 / dpi); // cupsPageSize[0]
  f32(432, height * 72 / dpi); // cupsPageSize[1]
  u32(452 + 8 * 4, 4); // cupsInteger[8] = PrintQuality normal
  return out;
}

/// 独立手拼一行 PackBits 期望字节（显式逐 run 给出，不调用被测代码）。
List<int> _packed(List<List<int>> runs) => [for (final r in runs) ...r];

List<int> _expectedPage({
  required int width,
  required int height,
  required List<(int count, List<int> packedRow)> runs,
  int dpi = 300,
}) {
  final out = _expectedHeader(
    width: width,
    height: height,
    bytesPerLine: width * 3,
    dpi: dpi,
  );
  for (final (count, packedRow) in runs) {
    out.add(count - 1); // 行重复计数：1 octet
    out.addAll(packedRow);
  }
  return out;
}

RasterPage _page(int width, int height, List<int> rgb) =>
    RasterPage(width: width, height: height, bytes: Uint8List.fromList(rgb));

const _red = [255, 0, 0];
const _blue = [0, 0, 255];

void main() {
  const encoder = PwgRasterEncoder();

  group('packBits（像素粒度，bpp=3；官方 bpp=1 样例向量）', () {
    test('官方样例向量（bpp=1）：3 个非重复 octet -> 0xFE + 3 octets', () {
      // PWG 5102.4 §4.4.1：0xFE.8F.78.F7（头 257-3 = 0xFE）
      expect(
          PwgRasterEncoder.packBits(Uint8List.fromList([0x8F, 0x78, 0xF7]),
              bpp: 1),
          [0xFE, 0x8F, 0x78, 0xF7]);
    });

    test('官方样例向量（bpp=1）：重复 3 octets -> 0x02 + 1 octet', () {
      expect(
          PwgRasterEncoder.packBits(Uint8List.fromList([0x77, 0x77, 0x77]),
              bpp: 1),
          [0x02, 0x77]);
    });

    test('单像素行 -> 头 0x00 + 1 像素（尾部单像素）', () {
      expect(
          PwgRasterEncoder.packBits(Uint8List.fromList(_red)), [0x00, ..._red]);
    });

    test('两个相同像素 -> 重复 run 头 count-1 = 0x01', () {
      expect(PwgRasterEncoder.packBits(Uint8List.fromList([..._red, ..._red])),
          [0x01, ..._red]);
    });

    test('两个不同像素（行尾）-> 字面量 2：头 257-2 = 0xFF', () {
      expect(
        PwgRasterEncoder.packBits(Uint8List.fromList([..._red, ..._blue])),
        [0xFF, ..._red, ..._blue],
      );
    });

    test('三个互异像素（行尾）-> 字面量 3：头 257-3 = 0xFE', () {
      final row = [1, 2, 3, 4, 5, 6, 7, 8, 9];
      expect(
        PwgRasterEncoder.packBits(Uint8List.fromList(row)),
        [0xFE, ...row],
      );
    });

    test('重复与字面量交替（混合贪心）', () {
      // 红,红,蓝,蓝,蓝 -> 重复2 红（0x01）+ 重复3 蓝（0x02）
      final row = [..._red, ..._red, ..._blue, ..._blue, ..._blue];
      expect(
        PwgRasterEncoder.packBits(Uint8List.fromList(row)),
        [0x01, ..._red, 0x02, ..._blue],
      );
    });

    test('孤立像素夹在重复之间 -> 头 0x00 语义（重复 1 次）', () {
      final row = [..._red, ..._red, ..._blue, ..._red, ..._red];
      // 蓝 为孤立字面量 count=1：头 0x00（语义 = 单像素，CUPS 允许）
      expect(
        PwgRasterEncoder.packBits(Uint8List.fromList(row)),
        [0x01, ..._red, 0x00, ..._blue, 0x01, ..._red],
      );
    });

    test('重复 128 上限（CUPS count<128 退出时 count=128）后接单像素', () {
      final row = [for (var i = 0; i < 129; i++) ..._red];
      // 前 128 像素重复（头 0x7F）+ 剩余 1 像素（头 0x00）
      expect(
        PwgRasterEncoder.packBits(Uint8List.fromList(row)),
        [0x7F, ..._red, 0x00, ..._red],
      );
    });

    test('压缩有效性：全白行远小于裸行', () {
      final white = List<int>.filled(2480 * 3, 255);
      final packed = PwgRasterEncoder.packBits(Uint8List.fromList(white));
      expect(packed.length, lessThan(white.length ~/ 16),
          reason: '全白行应折叠为极少 run（2480px -> 20 runs）');
    });
  });

  group('PWG 5102.4 §4.4 官方金标样本', () {
    // 规范 §4.4.2 Figure 3：8x8 24-bit sRGB 样本（87 octets 全文）。
    // 白=W FF.FF.FF，黄=Y FF.FF.00，蓝=B 00.00.FF，绿=G 00.FF.00，红=R FF.00.00。
    Uint8List specImage() {
      const w = [0xFF, 0xFF, 0xFF], y = [0xFF, 0xFF, 0x00];
      const b = [0x00, 0x00, 0xFF], g = [0x00, 0xFF, 0x00];
      const r = [0xFF, 0x00, 0x00];
      final rows = <List<int>>[
        [...w, ...y, ...y, ...y, ...w, ...w, ...w, ...w],
        [...y, ...b, ...y, ...w, ...w, ...w, ...g, ...w],
        [...y, ...y, ...w, ...w, ...w, ...g, ...g, ...g],
        [...y, ...y, ...y, ...w, ...w, ...w, ...g, ...w],
        [...w, ...y, ...y, ...y, ...w, ...w, ...w, ...w],
        [...w, ...w, ...w, ...w, ...w, ...w, ...w, ...w],
        [...r, ...r, ...r, ...r, ...r, ...r, ...r, ...r],
        [...r, ...r, ...r, ...r, ...r, ...r, ...r, ...r],
      ];
      return Uint8List.fromList([for (final row in rows) ...row]);
    }

    // 规范原文逐行给出的期望编码；行首首个 octet 是行组重复计数（由
    // encodePage 写出），packBits 期望从第二个 octet 起。
    const expectedRows = <List<int>>[
      [0x00, 0xFF, 0xFF, 0xFF, 0x02, 0xFF, 0xFF, 0x00, 0x03, 0xFF, 0xFF, 0xFF],
      [
        0xFE,
        0xFF,
        0xFF,
        0x00,
        0x00,
        0x00,
        0xFF,
        0xFF,
        0xFF,
        0x00,
        0x02,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0x00,
        0xFF,
        0x00,
        0xFF,
        0xFF,
        0xFF
      ],
      [0x01, 0xFF, 0xFF, 0x00, 0x02, 0xFF, 0xFF, 0xFF, 0x02, 0x00, 0xFF, 0x00],
      [
        0x02,
        0xFF,
        0xFF,
        0x00,
        0x02,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0x00,
        0xFF,
        0x00,
        0xFF,
        0xFF,
        0xFF
      ],
      [0x00, 0xFF, 0xFF, 0xFF, 0x02, 0xFF, 0xFF, 0x00, 0x03, 0xFF, 0xFF, 0xFF],
      [0x07, 0xFF, 0xFF, 0xFF],
      [0x07, 0xFF, 0x00, 0x00],
      [0x07, 0xFF, 0x00, 0x00],
    ];

    test('§4.4.2 8x8 24-bit sRGB：行编码逐行等于规范金标', () {
      final encoder = const PwgRasterEncoder();
      final page = RasterPage(width: 8, height: 8, bytes: specImage());
      final rows = encoder.runLengthRowsForTest(page);
      // 行 0..5 各自成组（count=1），行 6-7 相同成组（count=2）→ 7 个行组。
      expect(rows.length, 7);
      var rowIdx = 0;
      for (var g = 0; g < rows.length; g++) {
        final (count, packed) = rows[g];
        expect(count, g == 6 ? 2 : 1, reason: '行组 $g 重复计数');
        final lineRuns = PwgRasterEncoder.packBits(packed);
        expect(lineRuns, expectedRows[rowIdx], reason: '行 $rowIdx 逐字节金标');
        rowIdx += count;
      }
    });
  });

  group('encodePage（1796 页头 + 行组金标）', () {
    test('syncWordBytes 为 "RaS2"（文件级，一次）', () {
      expect(encoder.syncWordBytes, [0x52, 0x61, 0x53, 0x32]);
    });

    test('页头 1796 octet；cupsWidth/Height/BytesPerLine/ColorSpace 就位', () {
      final out = encoder.encodePage(_page(2, 1, [..._red, ..._blue]));
      expect(out.length, greaterThan(1796));
      final head = out.sublist(0, 1796);
      int u32(int off) =>
          (head[off] << 24) |
          (head[off + 1] << 16) |
          (head[off + 2] << 8) |
          head[off + 3];
      expect(u32(372), 2, reason: 'cupsWidth');
      expect(u32(376), 1, reason: 'cupsHeight');
      expect(u32(384), 8, reason: 'cupsBitsPerColor');
      expect(u32(388), 24, reason: 'cupsBitsPerPixel');
      expect(u32(392), 6, reason: 'cupsBytesPerLine = width * 3');
      expect(u32(400), 19, reason: 'cupsColorSpace = sRGB-8');
      expect(u32(276), 300, reason: 'HWResolution xdpi');
      // 头内不再包含 sync word（sync 由调用方在文档级写入）
      expect(head.sublist(0, 4), isNot([0x52, 0x61, 0x53, 0x32]));
    });

    test('纯红 2x2：两行相同 -> 单行组 count=2（金标字节比对）', () {
      final row = [..._red, ..._red];
      final page = _page(2, 2, [...row, ...row]);
      final expected = _expectedPage(
        width: 2,
        height: 2,
        runs: [
          (
            2,
            _packed([
              [0x01, ..._red]
            ])
          ),
        ],
      );
      expect(encoder.encodePage(page), expected);
    });

    test('红/蓝两行不同 -> 两个行组 count=1（金标字节比对）', () {
      final redRow = [..._red, ..._red];
      final blueRow = [..._blue, ..._blue];
      final page = _page(2, 2, [...redRow, ...blueRow]);
      final expected = _expectedPage(
        width: 2,
        height: 2,
        runs: [
          (
            1,
            _packed([
              [0x01, ..._red]
            ])
          ),
          (
            1,
            _packed([
              [0x01, ..._blue]
            ])
          ),
        ],
      );
      expect(encoder.encodePage(page), expected);
    });

    test('自定义 dpi 写入页头（金标字节比对）', () {
      final encoder600 = PwgRasterEncoder(dpi: 600);
      final page = _page(1, 1, _red);
      final expected = _expectedPage(
        width: 1,
        height: 1,
        runs: [
          (
            1,
            _packed([
              [0x00, ..._red]
            ])
          ),
        ],
        dpi: 600,
      );
      expect(encoder600.encodePage(page), expected);
    });

    test('连续相同行合并计数正确（3 行相同 -> count=3）', () {
      final row = [..._red, ..._red];
      final page = _page(2, 3, [...row, ...row, ...row]);
      final expected = _expectedPage(width: 2, height: 3, runs: [
        (
          3,
          _packed([
            [0x01, ..._red]
          ])
        ),
      ]);
      expect(encoder.encodePage(page), expected);
    });

    test('行折叠上限 256：257 行相同拆为 256+1 两个行组（对抗性种子）', () {
      final page = _page(1, 257, [
        for (var i = 0; i < 257; i++) ..._red,
      ]);
      final packedRow = _packed([
        [0x00, ..._red]
      ]);
      final expected = _expectedPage(
        width: 1,
        height: 257,
        runs: [(256, packedRow), (1, packedRow)],
      );
      expect(encoder.encodePage(page), expected);
    });

    test('零高度页：仅页头 1796 字节、无行组（对抗性种子）', () {
      final out = encoder
          .encodePage(RasterPage(width: 1, height: 0, bytes: Uint8List(0)));
      expect(out.length, 1796);
    });

    test('奇数宽度 1px 行程正确（边界种子）', () {
      final page = _page(1, 2, [..._red, ..._red]);
      // 单像素行：PackBits = 尾部单像素（头 0x00 + 1 像素）
      final packedRow = _packed([
        [0x00, ..._red]
      ]);
      final expected =
          _expectedPage(width: 1, height: 2, runs: [(2, packedRow)]);
      expect(encoder.encodePage(page), expected);
    });

    test('页头显式页尺寸：像素 × 72 / dpi（回归锚点）', () {
      // 此前 PageSize[0]/[1] = 0（交打印机默认纸张裁决），介质解析
      // 不一致的打印机会裁切/缩放位图（用户实测「只显示一半」类表现）。
      // 500×707@300dpi → 120.0 × 169.68 pt。
      final out = encoder.encodePage(_page(500, 707, Uint8List(500 * 707 * 3)));
      final h = ByteData.sublistView(out);
      expect(h.getUint32(352, Endian.big), 120); // 500 × 72 / 300
      expect(h.getUint32(356, Endian.big), 170); // 707 × 72 / 300 ≈ 169.68
      expect(h.getFloat32(428, Endian.big), closeTo(120.0, 0.01));
      expect(h.getFloat32(432, Endian.big), closeTo(169.68, 0.01));
    });
  });
}
