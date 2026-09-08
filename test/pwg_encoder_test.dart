import 'dart:typed_data';

import 'package:ipp_print/src/models.dart';
import 'package:ipp_print/src/pwg/pwg_raster_encoder.dart';
import 'package:test/test.dart';

/// 独立参照实现（非被测代码）：按 PWG 5102.4 手工拼装期望字节。
List<int> _expectedPage({
  required int width,
  required int height,
  required List<(int count, List<int> row)> runs,
  int dpi = 300,
}) {
  final out = <int>[];
  void u32(int v) => out.addAll([
        (v >> 24) & 0xFF,
        (v >> 16) & 0xFF,
        (v >> 8) & 0xFF,
        v & 0xFF,
      ]);
  u32(0x52615332); // "RaS2"
  u32(width);
  u32(height);
  u32(8); // bits per color
  u32(19); // sRGB-8
  u32(dpi);
  u32(dpi);
  u32(0); // duplex
  u32(0); // tumble
  for (final (count, row) in runs) {
    u32(count);
    out.addAll(row);
  }
  return out;
}

RasterPage _page(int width, int height, List<int> rgb) =>
    RasterPage(width: width, height: height, bytes: Uint8List.fromList(rgb));

void main() {
  const encoder = PwgRasterEncoder();

  test('magic 为 "RaS2"（0x52615332）', () {
    final out = encoder.encodePage(_page(1, 1, [0, 0, 0]));
    expect(out.sublist(0, 4), [0x52, 0x61, 0x53, 0x32]);
  });

  test('纯红 2x2：两行相同 → 单次行程 count=2（金标字节比对）', () {
    final red = [255, 0, 0, 255, 0, 0];
    final page = _page(2, 2, [...red, ...red]);
    final expected = _expectedPage(
      width: 2,
      height: 2,
      runs: [(2, red)],
    );
    expect(encoder.encodePage(page), expected);
  });

  test('红/蓝两行不同 → 两次行程 count=1（金标字节比对）', () {
    final red = [255, 0, 0, 255, 0, 0];
    final blue = [0, 0, 255, 0, 0, 255];
    final page = _page(2, 2, [...red, ...blue]);
    final expected = _expectedPage(
      width: 2,
      height: 2,
      runs: [(1, red), (1, blue)],
    );
    expect(encoder.encodePage(page), expected);
  });

  test('自定义 dpi 写入页头（金标字节比对）', () {
    final encoder600 = PwgRasterEncoder(dpi: 600);
    final black = [0, 0, 0];
    final page = _page(1, 1, black);
    final expected = _expectedPage(
      width: 1,
      height: 1,
      runs: [(1, black)],
      dpi: 600,
    );
    expect(encoder600.encodePage(page), expected);
  });

  test('连续相同行合并计数正确（3 行相同 → count=3）', () {
    final gray = [128, 128, 128, 128, 128, 128];
    final page = _page(2, 3, [...gray, ...gray, ...gray]);
    final expected = _expectedPage(width: 2, height: 3, runs: [(3, gray)]);
    expect(encoder.encodePage(page), expected);
  });

  test('零高度页：仅页头 36 字节、无行程（对抗性种子）', () {
    final out = encoder.encodePage(
        RasterPage(width: 1, height: 0, bytes: Uint8List(0)));
    expect(out.length, 36);
  });

  test('奇数宽度 1px 行程正确（边界种子）', () {
    final px = [10, 20, 30];
    final page = _page(1, 2, [...px, ...px]);
    final expected = _expectedPage(width: 1, height: 2, runs: [(2, px)]);
    expect(encoder.encodePage(page), expected);
  });
}
