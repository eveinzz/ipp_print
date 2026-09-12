/// IPP 报文解析模型（RFC 8010 §3.1.1.2 结构的 Dart 映射）。
///
/// 从 ipp_message.dart 拆出（单文件 ≤400 行纪律）；经 ipp_message.dart
/// 再导出，既有导入路径不受影响。
library;

import 'dart:convert';
import 'dart:typed_data';

import '../models.dart';

/// 解析后的 IPP 响应。
class IppResponse {
  const IppResponse({
    required this.statusCode,
    required this.requestId,
    required this.groups,
  });

  final int statusCode;
  final int requestId;
  final List<IppGroup> groups;

  bool get isSuccessful => statusCode >= 0x0000 && statusCode <= 0x00FF;

  /// 返回**全部属性组**中名为 [name] 的值（按组序拼接；同名属性出现在
  /// 多个组时全部返回，即跨组可见而非只取首个匹配）。
  List<IppValue> values(String name) => [
        for (final g in groups) ...g.attributes[name] ?? const <IppValue>[],
      ];

  IppValue? firstValue(String name) {
    for (final g in groups) {
      final v = g.attributes[name];
      if (v != null && v.isNotEmpty) return v.first;
    }
    return null;
  }

  /// 第一个 tag 为 [tag] 的属性组（如 unsupported 组 0x05，RFC 8011
  /// §4.2.3：Validate-Job 响应组 2 即为 Unsupported Attributes）。
  IppGroup? groupByTag(int tag) {
    for (final g in groups) {
      if (g.tag == tag) return g;
    }
    return null;
  }
}

/// 解析后的一个属性组（operation/job/printer/unsupported 组之一）。
class IppGroup {
  IppGroup(this.tag);

  /// 组分隔 tag（0x01 operation / 0x02 job / 0x04 printer / 0x05 unsupported）。
  final int tag;

  /// 组内属性：同名多值时列表按序追加（RFC 8010 §3.1.3）。
  final Map<String, List<IppValue>> attributes = {};

  /// 同名追加即多值（RFC 8010：后续值零长度名）。
  void add(String name, IppValue value) =>
      attributes.putIfAbsent(name, () => <IppValue>[]).add(value);
}

/// 单个属性值（保留原始字节 + value-tag，按需解码）。
class IppValue {
  const IppValue(this.tag, this.raw);

  /// value-tag（0x21 integer / 0x23 enum / 0x44 keyword / 0x47 charset …）。
  final int tag;

  /// 原始值字节（大端；integer/enum 恒 4 字节）。
  final Uint8List raw;

  /// 文本类值（keyword/uri/charset/name/mime 等）解码。
  ///
  /// RFC 8011：attributes-charset=utf-8，文本类值按 UTF-8 解码
  /// （0.4.1 修复：原 fromCharCodes 对中文等多字节值产生 mojibake）。
  /// allowMalformed：厂商实现各异的坏字节按替换符宽容处理，绝不抛。
  String get asString => utf8.decode(raw, allowMalformed: true);

  /// integer/enum 值解码（非 4 字节抛 [IppPrintException]）。
  int get asInt {
    if (raw.length != 4) {
      throw IppPrintException('integer/enum value must be 4 bytes, '
          'got ${raw.length}');
    }
    return ByteData.sublistView(raw).getInt32(0, Endian.big);
  }

  /// boolean 值解码（RFC 8011 §5.1.12，线编码恒 1 字节；0.5 上收自
  /// inspect 定制解码）。非 1 字节抛 [IppPrintException]。
  bool get asBool {
    if (raw.length != 1) {
      throw IppPrintException(
          'boolean value must be 1 byte, got ${raw.length}');
    }
    return raw[0] != 0;
  }

  /// rangeOfInteger 值解码（RFC 8011 §5.1.14，两个 int32：低、高）。
  /// 非 8 字节抛 [IppPrintException]。
  (int, int) get asRange {
    if (raw.length != 8) {
      throw IppPrintException(
          'rangeOfInteger value must be 8 bytes, got ${raw.length}');
    }
    final bd = ByteData.sublistView(raw);
    return (bd.getInt32(0, Endian.big), bd.getInt32(4, Endian.big));
  }

  /// resolution 值解码（RFC 8011 §5.1.16，9 字节）。
  /// 非 9 字节或未知单位抛 [IppPrintException]。
  IppResolution get asResolution {
    if (raw.length != 9) {
      throw IppPrintException(
          'resolution value must be 9 bytes, got ${raw.length}');
    }
    final bd = ByteData.sublistView(raw);
    final unit = raw[8];
    if (unit != IppResolution.dpi && unit != IppResolution.dpcm) {
      throw IppPrintException('unknown resolution unit $unit');
    }
    return IppResolution(
      cross: bd.getInt32(0, Endian.big),
      feed: bd.getInt32(4, Endian.big),
      unit: unit,
    );
  }
}

/// resolution 语法解码结果（RFC 8011 §5.1.16）。
class IppResolution {
  const IppResolution({
    required this.cross,
    required this.feed,
    required this.unit,
  });

  static const int dpi = 3;
  static const int dpcm = 4;

  /// 横向分辨率（cross feed direction）。
  final int cross;

  /// 纵向分辨率（main feed direction）。
  final int feed;

  /// 单位（3=dpi / 4=dpcm，原始 enum 值）。
  final int unit;

  bool get isDpi => unit == dpi;
  bool get isDpcm => unit == dpcm;

  /// PWG keyword 形态（`360x360dpi`），与 `printer-resolution-supported`
  /// 的既有字符串表示一致。
  String get asKeyword => '${cross}x$feed${isDpi ? 'dpi' : 'dpcm'}';
}
