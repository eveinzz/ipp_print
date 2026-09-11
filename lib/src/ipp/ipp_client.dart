import 'dart:io';
import 'dart:typed_data';

import '../models.dart';
import 'ipp_log.dart';
import 'ipp_message.dart';

part 'ipp_client_inspect.dart';
part 'ipp_client_validate.dart';

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

/// Get-Jobs 返回的单个作业摘要。
class IppJobSummary {
  const IppJobSummary({
    required this.jobId,
    required this.jobState,
    this.jobName,
    this.userName,
  });

  final int jobId;
  final IppJobState jobState;

  /// job-name（作业提交时的名字）。
  final String? jobName;

  /// job-originating-user-name（提交者）。
  final String? userName;
}

/// HTTP 传输层瞬态故障（5xx）：可由轮询逻辑重试吸收。
class IppTransientException extends IppPrintException {
  const IppTransientException(super.message);
}

/// IPP 传输客户端：POST application/ipp 到打印机 631 端口
/// （明文 ipp:// 或 TLS ipps:// 通道，由 [DiscoveredPrinter.secure] 决定）。
class IppClient {
  /// [acceptSelfSignedTls]：打印机证书普遍为自签（行业常态，无公共 CA
  /// 体系），TLS 通道默认接受非受信证书——加密即目的，不做身份强校验。
  /// 设为 false 则仅接受系统信任链证书（严格模式，多数打印机将握手失败）。
  IppClient({HttpClient? httpClient, bool acceptSelfSignedTls = true})
      : _http = httpClient ?? _createClient(acceptSelfSignedTls);

  static HttpClient _createClient(bool acceptSelfSignedTls) {
    final c = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      // IPP 是局域网直连协议：显式绕过环境 HTTP 代理（沙盒/公司代理会把
      // 631 端口请求转成 502/拒绝）。打印机不经代理。
      ..findProxy = (uri) => 'DIRECT';
    if (acceptSelfSignedTls) {
      c.badCertificateCallback = (cert, host, port) => true;
    }
    return c;
  }

  final HttpClient _http;
  var _requestId = 0;

  int get _nextRequestId => _requestId = (_requestId + 1) & 0x7FFFFFFF;

  Future<IppResponse> post(Uri httpEndpoint, Uint8List ippBody) async {
    var (status, body) = await _postOnce(httpEndpoint, ippBody);
    if (status == HttpStatus.upgradeRequired && httpEndpoint.scheme == 'http') {
      // TLS-only 打印机（如 EPSON L3250）：明文端点回 426 Upgrade Required，
      // 要求升级 TLS。按 RFC 2817 精神换 https 同端口重试一次
      // （打印机证书普遍自签，已由 acceptSelfSignedTls 放行）。
      final upgraded = httpEndpoint.replace(scheme: 'https');
      (status, body) = await _postOnce(upgraded, ippBody);
    }
    if (status >= 500) {
      // 服务器侧瞬态故障：交由轮询重试吸收，不视为协议错误。
      throw IppTransientException(
          'HTTP $status from ${httpEndpoint.host}');
    }
    if (status != HttpStatus.ok) {
      throw IppPrintException('HTTP $status from ${httpEndpoint.host}');
    }
    return IppCodec.parseResponse(body);
  }

  /// 发送一次请求并收取原始响应（状态码与体；解析与错误判定交 [post]）。
  Future<(int, Uint8List)> _postOnce(Uri httpEndpoint, Uint8List ippBody) async {
    final request = await _http.postUrl(httpEndpoint);
    request.headers.set(HttpHeaders.contentTypeHeader, 'application/ipp');
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    request.headers.set(HttpHeaders.userAgentHeader, 'ipp_print/0.3');
    request.headers.contentLength = ippBody.length;
    request.add(ippBody);
    final response = await request.close();
    final body = await _collect(response);
    return (response.statusCode, body);
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

  /// 取消作业（RFC 8011 §4.3.3）。作业不存在时打印机回
  /// client-error-not-found → 抛 [IppStatusException]。
  Future<void> cancelJob(DiscoveredPrinter p, int jobId) async {
    final res = await post(
      p.httpUri,
      IppCodec.buildCancelJob(
        printerUri: p.ippUriString,
        jobId: jobId,
        requestId: _nextRequestId,
      ),
    );
    _ensureSuccess(res, 'Cancel-Job');
  }

  /// 查询作业队列（RFC 8011 §4.2.6 Get-Jobs）。
  ///
  /// [whichJobs]：'not-completed'（默认，活动队列）或 'completed'。
  /// [myJobs]：true 时只返回 requesting-user-name 对应用户的作业。
  /// [requestedAttributes]：请求的作业属性集；null 则省略（默认 all）。
  Future<List<IppJobSummary>> getJobs(
    DiscoveredPrinter p, {
    bool myJobs = false,
    String whichJobs = 'not-completed',
    List<String>? requestedAttributes,
  }) async {
    final res = await post(
      p.httpUri,
      IppCodec.buildGetJobs(
        printerUri: p.ippUriString,
        requestId: _nextRequestId,
        myJobs: myJobs,
        whichJobs: whichJobs,
        requestedAttributes: requestedAttributes,
      ),
    );
    _ensureSuccess(res, 'Get-Jobs');
    // 脏组防御：缺 job-id / job-state 的组不满足 IppJobSummary 契约，
    // 静默补 0/pending 会掩盖解析异常——跳过并记录（TODO 0.3 项）。
    final summaries = <IppJobSummary>[];
    for (final g in res.groups.where((g) => g.tag == IppCodec.tagJobGroup)) {
      final jobId = _intOf(g, 'job-id');
      final stateCode = _intOf(g, 'job-state');
      if (jobId == null || stateCode == null) {
        ippLog('getJobs: skip dirty group (job-id=$jobId, '
            'job-state=$stateCode, keys=${g.attributes.keys.toList()})');
        continue;
      }
      summaries.add(IppJobSummary(
        jobId: jobId,
        jobState: IppJobState.fromCode(stateCode),
        jobName: _stringOf(g, 'job-name'),
        userName: _stringOf(g, 'job-originating-user-name'),
      ));
    }
    return summaries;
  }

  /// 轮询到终态或超时（终态含 completed/aborted/canceled）。
  ///
  /// 瞬态故障（网络抖动 / HTTP 5xx / ipps 通道 TLS 握手抖动）在
  /// [maxTransientErrors] 次内被吸收，超限或持久性错误立即抛出。
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
      } on HandshakeException {
        // ipps 打印机的 TLS 握手瞬时失败与网络抖动同性质：可重试吸收。
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

  static Future<Uint8List> _collect(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.toBytes();
  }
}
