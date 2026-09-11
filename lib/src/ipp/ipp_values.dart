/// IPP 报文解析模型（RFC 8010 §3.1.1.2 结构的 Dart 映射）。
///
/// 从 ipp_message.dart 拆出（单文件 ≤400 行纪律）；经 ipp_message.dart
/// 再导出，既有导入路径不受影响。
library;

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

  /// 返回第一个组里（含跨组首个匹配）名为 [name] 的值列表。
  List<IppValue> values(String name) => [
        for (final g in groups)
          ...g.attributes[name] ?? const <IppValue>[],
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
  String get asString => String.fromCharCodes(raw);

  /// integer/enum 值解码（非 4 字节抛 [IppPrintException]）。
  int get asInt {
    if (raw.length != 4) {
      throw IppPrintException('integer/enum value must be 4 bytes, '
          'got ${raw.length}');
    }
    return ByteData.sublistView(raw).getInt32(0, Endian.big);
  }
}
