import 'dart:io';
import 'dart:typed_data';

import '../models.dart';
import 'ipp_message.dart';

/// Get-Printer-Attributes 的解析结果。
class PrinterAttributes {
  const PrinterAttributes({
    this.mediaSupported = const <String>[],
    this.documentFormats = const <String>[],
    this.state,
    this.makeModel,
  });

  final List<String> mediaSupported;
  final List<String> documentFormats;
  final String? state;
  final String? makeModel;

  /// IPP printer-state 枚举 → 可读状态。
  static String? stateFromEnum(int? v) => switch (v) {
        3 => 'idle',
        4 => 'processing',
        5 => 'stopped',
        _ => null,
      };
}

/// job-state 枚举（RFC 8011 §5.3.7 / IPP Guide：3 pending、4 pending-held、
/// 5 processing、6 processing-stopped、7 canceled、8 aborted、9 completed）。
enum IppJobState {
  pending(3),
  pendingHeld(4),
  processing(5),
  processingStopped(6),
  canceled(7),
  aborted(8),
  completed(9);

  const IppJobState(this.code);
  final int code;

  bool get isTerminal =>
      this == canceled || this == aborted || this == completed;

  static IppJobState fromCode(int code) => IppJobState.values
      .firstWhere((s) => s.code == code, orElse: () => IppJobState.pending);
}

/// HTTP 传输层瞬态故障（5xx）：可由轮询逻辑重试吸收。
class IppTransientException extends IppPrintException {
  const IppTransientException(super.message);
}

/// IPP 传输客户端：POST application/ipp 到打印机 631 端口（明文通道）。
class IppClient {
  IppClient({HttpClient? httpClient})
      : _http = httpClient ??
            (HttpClient()
              ..connectionTimeout = const Duration(seconds: 8)
              // IPP 是局域网直连协议：显式绕过环境 HTTP 代理（沙盒/公司
              // 代理会把 631 端口请求转成 502/拒绝）。打印机不经代理。
              ..findProxy = (uri) => 'DIRECT');

  final HttpClient _http;
  var _requestId = 0;

  int get _nextRequestId => _requestId = (_requestId + 1) & 0x7FFFFFFF;

  Future<IppResponse> post(Uri httpEndpoint, Uint8List ippBody) async {
    final request = await _http.postUrl(httpEndpoint);
    request.headers.set(HttpHeaders.contentTypeHeader, 'application/ipp');
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    request.headers.set(HttpHeaders.userAgentHeader, 'ipp_print/0.1');
    request.headers.contentLength = ippBody.length;
    request.add(ippBody);
    final response = await request.close();
    final body = await _collect(response);
    if (response.statusCode >= 500) {
      // 服务器侧瞬态故障：交由轮询重试吸收，不视为协议错误。
      throw IppTransientException(
          'HTTP ${response.statusCode} from ${httpEndpoint.host}');
    }
    if (response.statusCode != HttpStatus.ok) {
      throw IppPrintException(
          'HTTP ${response.statusCode} from ${httpEndpoint.host}');
    }
    return IppCodec.parseResponse(body);
  }

  Future<PrinterAttributes> getPrinterAttributes(DiscoveredPrinter p) async {
    final res = await post(
      p.httpUri,
      IppCodec.buildGetPrinterAttributes(
        printerUri: p.ippUriString,
        requestId: _nextRequestId,
      ),
    );
    _ensureSuccess(res, 'Get-Printer-Attributes');
    final printerGroup = res.groups
        .where((g) => g.tag == IppCodec.tagPrinterGroup)
        .toList(growable: false);
    final g = printerGroup.isEmpty ? null : printerGroup.first;
    return PrinterAttributes(
      mediaSupported: _keywords(g, 'media-supported'),
      documentFormats: _keywords(g, 'document-format-supported'),
      state: PrinterAttributes.stateFromEnum(_enumOf(g, 'printer-state')),
      makeModel: g?.attributes['printer-make-and-model']?.first.asString,
    );
  }

  /// 提交 Print-Job，返回打印机分配的 job-id。
  Future<int> submitJob(
    DiscoveredPrinter p, {
    required Uint8List document,
    required String documentFormat,
    PrintOptions options = const PrintOptions(),
    String jobName = 'ipp_print-document',
  }) async {
    final body = BytesBuilder(copy: false)
      ..add(IppCodec.buildPrintJob(
        printerUri: p.ippUriString,
        documentFormat: documentFormat,
        requestId: _nextRequestId,
        jobName: jobName,
        options: options,
      ))
      ..add(document);
    final res = await post(p.httpUri, body.toBytes());
    _ensureSuccess(res, 'Print-Job');
    final jobId = res.firstValue('job-id')?.asInt;
    if (jobId == null) {
      throw const IppPrintException('Print-Job response missing job-id');
    }
    return jobId;
  }

  /// 查询任务状态枚举。
  Future<IppJobState> getJobState(DiscoveredPrinter p, int jobId) async {
    final res = await post(
      p.httpUri,
      IppCodec.buildGetJobAttributes(
        printerUri: p.ippUriString,
        jobId: jobId,
        requestId: _nextRequestId,
      ),
    );
    _ensureSuccess(res, 'Get-Job-Attributes');
    final code = res.firstValue('job-state')?.asInt;
    return IppJobState.fromCode(code ?? IppJobState.pending.code);
  }

  /// 轮询到终态或超时（终态含 completed/aborted/canceled）。
  ///
  /// 瞬态故障（网络抖动/HTTP 5xx）在 [maxTransientErrors] 次内被吸收，
  /// 超限或持久性错误立即抛出。
  Future<IppJobState> waitForTerminalState(
    DiscoveredPrinter p,
    int jobId, {
    Duration interval = const Duration(seconds: 2),
    Duration timeout = const Duration(minutes: 5),
    int maxTransientErrors = 3,
  }) async {
    final deadline = DateTime.now().add(timeout);
    var state = IppJobState.pending;
    var transientErrors = 0;
    while (DateTime.now().isBefore(deadline)) {
      try {
        state = await getJobState(p, jobId);
        transientErrors = 0;
      } on SocketException {
        if (++transientErrors > maxTransientErrors) rethrow;
        await Future<void>.delayed(interval);
        continue;
      } on IppTransientException {
        if (++transientErrors > maxTransientErrors) rethrow;
        await Future<void>.delayed(interval);
        continue;
      }
      if (state.isTerminal) return state;
      await Future<void>.delayed(interval);
    }
    throw IppJobTimeoutException(jobId, 'not terminal within timeout');
  }

  void _ensureSuccess(IppResponse res, String op) {
    if (!res.isSuccessful) {
      throw IppStatusException(res.statusCode, '$op failed');
    }
  }

  List<String> _keywords(IppGroup? g, String name) => [
        for (final v in g?.attributes[name] ?? const <IppValue>[]) v.asString,
      ];

  int? _enumOf(IppGroup? g, String name) {
    final values = g?.attributes[name];
    if (values == null || values.isEmpty) return null;
    return values.first.asInt;
  }

  static Future<Uint8List> _collect(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.toBytes();
  }
}
