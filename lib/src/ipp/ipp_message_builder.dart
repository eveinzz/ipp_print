part of 'ipp_message.dart';

/// IPP 请求构造器（RFC 8010 §3.1.4 线编码）。
///
/// 自 ipp_message.dart 拆出（单文件 ≤400 行纪律；0.5 加 fidelity /
/// printer-resolution 后预留 0.6 Job Engine 增量空间）。
class _Builder {
  _Builder(this.operation, this.requestId) : _body = BytesBuilder();

  final int operation;
  final int requestId;
  final BytesBuilder _body;
  int _currentGroup = -1;
  String? _lastName;

  _Builder group(int tag) {
    _flushName();
    _currentGroup = tag;
    _body.addByte(tag);
    return this;
  }

  /// RFC 8010 §3.1.4 编码序：value-tag → name-len → name → value-len
  /// → value。value-tag 必须在 name 之前。
  _Builder attr(int tag, String name, Object value) {
    if (_currentGroup < 0) group(IppCodec.tagOperationGroup);
    if (tag == IppCodec.tagCharset || tag == IppCodec.tagLanguage) {
      _flushName();
    }
    _body.addByte(tag);
    _writeName(name);
    _writeValue(value, asInteger: tag == IppCodec.tagInteger || tag == IppCodec.tagEnum);
    _lastName = name;
    return this;
  }

  /// 同名多值：首个用 attr()，后续值走 tag + 零长度名（RFC 8010 §3.1.5）。
  _Builder attrOrValue(int tag, String name, Object value) {
    if (_lastName != name) return attr(tag, name, value);
    _body.addByte(tag);
    _body
      ..addByte(0)
      ..addByte(0);
    _writeValue(value, asInteger: tag == IppCodec.tagInteger || tag == IppCodec.tagEnum);
    return this;
  }

  void _flushName() => _lastName = null;

  void _writeName(String name) {
    // RFC 8011：attributes-charset=utf-8，属性名按 UTF-8 编码
    //（0.4.1 修复：原 codeUnits 为 UTF-16 码元直写，非 ASCII 名即坏字节）。
    final nb = Uint8List.fromList(utf8.encode(name));
    _body.addByte((nb.length >> 8) & 0xFF);
    _body.addByte(nb.length & 0xFF);
    _body.add(nb);
  }

  void _writeValue(Object value, {required bool asInteger}) {
    final Uint8List vb;
    if (value is bool) {
      // RFC 8011 §5.1.12：boolean 语法；线编码恒 1 字节（0x00/0x01）。
      vb = Uint8List(1)..[0] = value ? 1 : 0;
    } else if (value is (int, int, int)) {
      // RFC 8011 §5.1.16：resolution 语法；cross(int32)+feed(int32)+unit
      // 1 字节（3=dpi / 4=dpcm），共 9 字节。
      vb = Uint8List(9);
      final bd = ByteData.sublistView(vb);
      bd.setInt32(0, value.$1, Endian.big);
      bd.setInt32(4, value.$2, Endian.big);
      vb[8] = value.$3;
    } else if (asInteger && value is int) {
      vb = Uint8List(4)
        ..buffer.asByteData().setInt32(0, value, Endian.big);
    } else {
      // RFC 8011：文本类值（text/name/keyword/uri…）按 UTF-8 编码。
      // （0.4.1 修复：原 codeUnits 对非 ASCII 值（如中文 job-name）编出坏字节。）
      vb = Uint8List.fromList(utf8.encode(value.toString()));
    }
    _body.addByte((vb.length >> 8) & 0xFF);
    _body.addByte(vb.length & 0xFF);
    _body.add(vb);
  }

  Uint8List take() {
    final head = ByteData(8);
    head.setUint8(0, IppCodec.versionMajor);
    head.setUint8(1, IppCodec.versionMinor);
    head.setUint16(2, operation, Endian.big);
    head.setUint32(4, requestId, Endian.big);
    final out = BytesBuilder()
      ..add(head.buffer.asUint8List())
      ..add(_body.takeBytes())
      ..addByte(IppCodec.tagEndOfAttributes);
    return out.toBytes();
  }
}
