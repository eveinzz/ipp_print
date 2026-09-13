part of 'ipp_message.dart';

/// IPP 响应解析（RFC 8010 §3.1.1.2 线结构的逆运算）。
///
/// 自 [IppCodec.parseResponse] 的**实现体**搬出（行数治理：单文件 ≤400 行
/// 纪律）。part 文件不能续写 class 成员，故实现落为顶层函数，
/// `IppCodec.parseResponse` 保留一行委托——**公共签名与行为零变更**。
///
/// 解析保持 lenient：属性名按 allowMalformed 解码（厂商实现的坏字节按替换符
/// 处理，绝不抛）；只有**结构性**缺陷（长度越界、无名值）才抛
/// [IppPrintException]，与「合法但不认识的值如实透传」的纪律互补。
IppResponse _parseIppResponse(Uint8List data) {
  if (data.length < 8) {
    throw const IppPrintException('IPP response too short');
  }
  final bd = ByteData.sublistView(data);
  final statusCode = bd.getUint16(2, Endian.big);
  final requestId = bd.getUint32(4, Endian.big);
  var i = 8;
  var group = IppGroup(IppCodec.tagOperationGroup);
  final groups = <IppGroup>[group];
  String? lastName;
  void require(int needed) {
    if (i + needed > data.length) {
      throw const IppPrintException('truncated IPP response');
    }
  }

  while (i < data.length) {
    final tag = data[i++];
    if (tag == IppCodec.tagEndOfAttributes) break;
    if (tag <= 0x0F) {
      group = IppGroup(tag);
      groups.add(group);
      lastName = null;
      continue;
    }
    require(2);
    final nameLen = bd.getUint16(i, Endian.big);
    i += 2;
    require(nameLen);
    final name = nameLen == 0
        ? lastName
        : utf8.decode(data.sublist(i, i + nameLen), allowMalformed: true);
    i += nameLen;
    require(2);
    final valueLen = bd.getUint16(i, Endian.big);
    i += 2;
    require(valueLen);
    final raw = Uint8List.sublistView(data, i, i + valueLen);
    i += valueLen;
    if (name == null) {
      throw const IppPrintException('IPP attribute value without name');
    }
    lastName = name;
    group.add(name, IppValue(tag, raw));
  }
  return IppResponse(
    statusCode: statusCode,
    requestId: requestId,
    groups: groups,
  );
}
