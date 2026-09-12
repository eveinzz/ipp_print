import 'dart:typed_data';

import 'package:ipp_print/src/ipp/ipp_client.dart';
import 'package:ipp_print/src/ipp/ipp_message.dart';
import 'package:ipp_print/src/models.dart';

/// Job Engine 测试共享工装（自 job_engine_test.dart 拆出，400 行纪律）：
/// 假客户端、手工 IPP 线格式构造器与常用响应 fixture。
/// 手工构造响应刻意独立于被测代码的编码路径（解析锚点更硬）。

/// 可注入假 IppClient：按 operation-id 从队列弹响应（支持同 op 多次应答，
/// 供 monitor 轮询序列），并支持一次性异常注入（瞬态吸收锚点）。
class FakeQueueClient extends IppClient {
  final queues = <int, List<Uint8List>>{};
  final exceptions = <int, List<Object>>{};
  final operations = <int>[];
  final bodies = <Uint8List>[];

  void enqueue(int op, Uint8List response) =>
      queues.putIfAbsent(op, () => []).add(response);

  void enqueueThrow(int op, Object error) =>
      exceptions.putIfAbsent(op, () => []).add(error);

  @override
  Future<IppResponse> post(Uri httpEndpoint, Uint8List ippBody) async {
    final op = (ippBody[2] << 8) | ippBody[3];
    operations.add(op);
    bodies.add(ippBody);
    final exQ = exceptions[op];
    if (exQ != null && exQ.isNotEmpty) throw exQ.removeAt(0);
    final q = queues[op];
    if (q == null || q.isEmpty) {
      throw IppPrintException('unexpected op 0x${op.toRadixString(16)}');
    }
    return IppCodec.parseResponse(q.removeAt(0));
  }
}

/// 手工构造 IPP 响应（状态码 + 单属性组 + 属性字节）。
Uint8List resp(int status, int groupTag, List<int> attrs) {
  List<int> attr(int tag, String name, List<int> value) {
    final nb = name.codeUnits;
    return [
      tag,
      (nb.length >> 8) & 0xFF,
      nb.length & 0xFF,
      ...nb,
      (value.length >> 8) & 0xFF,
      value.length & 0xFF,
      ...value,
    ];
  }

  List<int> s(String v) => v.codeUnits;
  return Uint8List.fromList([
    0x01, 0x01, (status >> 8) & 0xFF, status & 0xFF, 0, 0, 0, 1, //
    0x01,
    ...attr(0x47, 'attributes-charset', s('utf-8')),
    ...attr(0x48, 'attributes-natural-language', s('en')),
    groupTag,
    ...attrs,
    0x03,
  ]);
}

List<int> kw(String name, String value) {
  final nb = name.codeUnits;
  final vb = value.codeUnits;
  return [
    0x44,
    (nb.length >> 8) & 0xFF,
    nb.length & 0xFF,
    ...nb,
    (vb.length >> 8) & 0xFF,
    vb.length & 0xFF,
    ...vb,
  ];
}

/// 同名多值的后续值（零长度名，RFC 8010 §3.1.5）。
List<int> kwMore(String value) {
  final vb = value.codeUnits;
  return [
    0x44,
    0x00,
    0x00,
    (vb.length >> 8) & 0xFF,
    vb.length & 0xFF,
    ...vb,
  ];
}

/// type2 enum 值（value-tag 0x23；print-quality/finishings 等的载体）。
List<int> enumAttr(String name, int v) {
  final nb = name.codeUnits;
  return [
    0x23,
    (nb.length >> 8) & 0xFF,
    nb.length & 0xFF,
    ...nb,
    0x00,
    0x04,
    (v >> 24) & 0xFF,
    (v >> 16) & 0xFF,
    (v >> 8) & 0xFF,
    v & 0xFF,
  ];
}

/// 同名多值的后续 enum 值（零长度名，RFC 8010 §3.1.5）。
List<int> enumMore(int v) => [
      0x23,
      0x00,
      0x00,
      0x00,
      0x04,
      (v >> 24) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 8) & 0xFF,
      v & 0xFF,
    ];

List<int> intAttr(String name, int v) {
  final nb = name.codeUnits;
  return [
    0x21,
    (nb.length >> 8) & 0xFF,
    nb.length & 0xFF,
    ...nb,
    0x00,
    0x04,
    (v >> 24) & 0xFF,
    (v >> 16) & 0xFF,
    (v >> 8) & 0xFF,
    v & 0xFF,
  ];
}

/// 声明集仅含 application/pdf 的打印机（直投路径）。
final printerPdf = resp(0, 0x04, [
  ...kw('document-format-supported', 'application/pdf'),
]);

/// 声明集含 image/pwg-raster（+pdf）的打印机——probe ready 判据
/// （0.5 裁决：document-format-supported 须含 pwg-raster 才可栅格回退）。
final printerPwgPdf = resp(0, 0x04, [
  ...kw('document-format-supported', 'image/pwg-raster'),
  ...kwMore('application/pdf'),
]);

/// Print-Job 应答：job-id=42，processing，reason=job-incoming。
final jobSubmitted = resp(0, 0x02, [
  ...intAttr('job-id', 42),
  ...intAttr('job-state', 5), // processing
  ...kw('job-state-reasons', 'job-incoming'),
]);

Uint8List jobSnapshot({int state = 3, List<String> reasons = const []}) {
  final attrs = <int>[
    ...intAttr('job-id', 42),
    ...intAttr('job-state', state),
    if (reasons.isNotEmpty) ...kw('job-state-reasons', reasons.first),
    for (final r in reasons.skip(1)) ...kwMore(r),
  ];
  return resp(0, 0x02, attrs);
}

/// 返回属性 [name] 所在属性组的组 tag（找不到返回 -1）。
/// 独立线格式步进器，用于锚定 RFC 8011 §4.2.1.1 的组归属。
int groupOf(List<int> body, String name) {
  var i = 8; // version(2) + op(2) + request-id(4)
  var group = -1;
  final nb = name.codeUnits;
  while (i < body.length) {
    final tag = body[i++];
    if (tag == 0x03) break; // end-of-attributes
    if (tag <= 0x0F) {
      group = tag;
      continue;
    }
    final nameLen = (body[i] << 8) | body[i + 1];
    i += 2;
    final isTarget = nameLen == nb.length;
    var hit = isTarget;
    for (var j = 0; j < nameLen; j++) {
      if (body[i + j] != (j < nb.length ? nb[j] : -1)) hit = false;
    }
    i += nameLen;
    final valueLen = (body[i] << 8) | body[i + 1];
    i += 2 + valueLen;
    if (isTarget && hit) return group;
  }
  return -1;
}

DiscoveredPrinter testPrinter() => DiscoveredPrinter(
      name: 'EPSON L3250 Series',
      host: '127.0.0.1',
      port: 1,
      resourcePath: '/ipp/print',
      txt: {'pdl': 'application/pdf', 'rp': 'ipp/print'},
    );
