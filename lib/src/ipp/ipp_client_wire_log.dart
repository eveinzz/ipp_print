part of 'ipp_client.dart';

/// 线路层日志：请求/响应成对记录 + 被忽略属性告警。
///
/// **落点依据**：`IppClient.post()` 是全部 IPP 请求的唯一咽喉
/// （Print-Job / Validate-Job / Create-Job / Send-Document / Cancel-Job /
/// Get-Job-Attributes / Get-Jobs / Get-Printer-Attributes），故成对日志与
/// 被忽略属性告警各只需一处，天然覆盖全部算子，不存在「某算子漏记」的漂移面。
///
/// 算子名从**报文头部**读出（RFC 8010 §3.1.1：version 2 字节 + operation-id
/// 2 字节，大端），故无需改动 `post()` 的公共签名——公共面零变更。
///
/// 无运行期分级（守 `TODO.md`「DEBUG log 给开发者」），故不设 verbosity 开关；
/// 轮询期间每 2s 一次的 Get-Job-Attributes 会逐次成对输出，这是刻意行为
/// —— 作业卡住时正是最需要这条线索的场合。

/// 报文头部的 operation-id；不足 4 字节回负值（可辨识的「未知」，不猜成任何
/// 合法算子）。
int _opCodeOf(Uint8List body) =>
    body.length < 4 ? -1 : (body[2] << 8) | body[3];

/// 操作码 → 名称。未登记者如实回 `op-0x????`，不可解析回 `unknown-op`。
String _opNameOf(int op) => switch (op) {
      IppCodec.opPrintJob => 'Print-Job',
      IppCodec.opValidateJob => 'Validate-Job',
      IppCodec.opCreateJob => 'Create-Job',
      IppCodec.opSendDocument => 'Send-Document',
      IppCodec.opCancelJob => 'Cancel-Job',
      IppCodec.opGetJobAttributes => 'Get-Job-Attributes',
      IppCodec.opGetJobs => 'Get-Jobs',
      IppCodec.opGetPrinterAttributes => 'Get-Printer-Attributes',
      _ =>
        op < 0 ? 'unknown-op' : 'op-0x${op.toRadixString(16).padLeft(4, '0')}',
    };

/// IPP 状态码 → 名称（**仅日志可读性**，不参与任何控制流；未列入者如实回
/// `0x????`，绝不因未列入而改变行为）。
///
/// 取值逐条出自 **RFC 8011 Appendix B.1**（B.1.2 successful / B.1.4 client
/// error / B.1.5 server error）；列入项限定为本包实际可能遭遇者。
String _statusNameOf(int code) => switch (code) {
      0x0000 => 'successful-ok',
      0x0001 => 'successful-ok-ignored-or-substituted-attributes',
      0x0002 => 'successful-ok-conflicting-attributes',
      0x0400 => 'client-error-bad-request',
      0x0401 => 'client-error-forbidden',
      0x0402 => 'client-error-not-authenticated',
      0x0403 => 'client-error-not-authorized',
      0x0404 => 'client-error-not-possible',
      0x0405 => 'client-error-timeout',
      0x0406 => 'client-error-not-found',
      0x040a => 'client-error-document-format-not-supported',
      0x040b => 'client-error-attributes-or-values-not-supported',
      0x040e => 'client-error-conflicting-attributes',
      0x0500 => 'server-error-internal-error',
      0x0501 => 'server-error-operation-not-supported',
      0x0502 => 'server-error-service-unavailable',
      0x0503 => 'server-error-version-not-supported',
      0x0505 => 'server-error-temporary-error',
      0x0506 => 'server-error-not-accepting-jobs',
      0x0507 => 'server-error-busy',
      0x0508 => 'server-error-job-canceled',
      0x0509 => 'server-error-multiple-document-jobs-not-supported',
      _ => '0x${code.toRadixString(16).padLeft(4, '0')}',
    };

/// RFC 8011 §4.1.7：这四个状态码下，打印机**必须**在响应中带上 Unsupported
/// Attributes 组（MUST，非 SHOULD）。缺失即属打印机不合规，且被忽略的属性
/// 变得无从得知——这是「收下却静默忽略」最需要被看见的一种形态。
bool _requiresUnsupportedGroup(int code) =>
    code == 0x0001 || code == 0x0002 || code == 0x040b || code == 0x040e;

/// 请求发出前记录：算子名、目标端点、请求体字节数。
void _logWireRequest(Uri uri, Uint8List body) {
  ippLog('-> ${_opNameOf(_opCodeOf(body))} '
      '${uri.scheme}://${uri.host}:${uri.port}${uri.path} '
      'bytes=${body.length}');
}

/// 响应收到后记录。`httpStatus` 是 **HTTP** 层状态码，`parsed.statusCode`
/// 是 **IPP** 层状态码——两者不同层级，分别标注以免误读。端点一并记录：宿主
/// 可并发探测多台打印机，响应行若不带端点便无法归因。
///
/// 附带**被忽略属性告警**：响应里出现 Unsupported Attributes 组（RFC 8010
/// delimiter tag 0x05）就列出属性名。告警由**组**驱动而非由状态码驱动——
/// RFC 8011 §4.1.7 规定该组可随四个状态码出现，客户端据组取证才不丢信息。
void _logWireResponse(Uri uri, int httpStatus, Uint8List requestBody,
    Uint8List responseBody, DateTime started, IppResponse parsed) {
  final op = _opNameOf(_opCodeOf(requestBody));
  ippLog('<- HTTP $httpStatus ipp=${_statusNameOf(parsed.statusCode)} $op '
      '@${uri.host}:${uri.port} request-id=${parsed.requestId} '
      'bytes=${responseBody.length} '
      'elapsed=${DateTime.now().difference(started).inMilliseconds}ms');
  final ignored = parsed.groupByTag(IppCodec.tagUnsupportedGroup);
  if (ignored == null) {
    if (_requiresUnsupportedGroup(parsed.statusCode)) {
      ippLog('! $op answered ${_statusNameOf(parsed.statusCode)} with no '
          'Unsupported Attributes group — RFC 8011 §4.1.7 requires one for '
          'this status, so which attributes were ignored is unknown');
    }
    return;
  }
  if (ignored.attributes.isEmpty) return;
  final silent = parsed.isSuccessful
      ? '; the status is in the success range, so nothing else reports this'
      : '';
  ippLog('! $op ignored or substituted: ${ignored.attributes.keys.join(', ')} '
      '(RFC 8011 §4.1.7) — not used as sent$silent');
}

/// 传输层失败（HTTP 非 200）的响应侧记录。
///
/// 与成功路径同格式，故日志里「有请求行、无响应行」只可能意味着请求真的没
/// 有返回，不会被「失败不记」混淆。
void _logWireFailure(Uri uri, int httpStatus, Uint8List requestBody,
    Uint8List responseBody, DateTime started) {
  ippLog('<- HTTP $httpStatus ${_opNameOf(_opCodeOf(requestBody))} '
      '@${uri.host}:${uri.port} bytes=${responseBody.length} '
      'elapsed=${DateTime.now().difference(started).inMilliseconds}ms '
      '— transport failure, body not parsed as IPP');
}
