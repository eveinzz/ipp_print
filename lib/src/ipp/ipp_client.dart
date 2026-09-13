import 'dart:io';
import 'dart:typed_data';

import '../models.dart';
import '../version.dart';
import 'ipp_log.dart';
import 'ipp_message.dart';

part 'ipp_client_inspect.dart';
part 'ipp_client_validate.dart';
part 'ipp_client_wire_log.dart';

/// job-state 枚举（RFC 8011 §5.3.7 / IPP Guide：3 pending、4 pending-held、
/// 5 processing、6 processing-stopped、7 canceled、8 aborted、9 completed）。
enum IppJobState {
  unknown(-1),
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

  /// 未知值如实映射 [unknown]（0.4.1 修复：原 orElse→pending 属静默猜测，
  /// 违反「缺≠支持、绝不推断」纪律）；unknown 非终态，轮询方继续查询。
  static IppJobState fromCode(int code) => IppJobState.values
      .firstWhere((s) => s.code == code, orElse: () => IppJobState.unknown);
}

/// Get-Jobs / Get-Job-Attributes / Print-Job 响应的单个作业摘要。
class IppJobSummary {
  const IppJobSummary({
    required this.jobId,
    required this.jobState,
    this.jobName,
    this.userName,
    this.stateReasons = const <String>[],
  });

  final int jobId;
  final IppJobState jobState;

  /// job-name（作业提交时的名字）。
  final String? jobName;

  /// job-originating-user-name（提交者）。
  final String? userName;

  /// job-state-reasons（RFC 8011 §5.3.8，1setOf keyword，如 `media-jam` /
  /// `job-incoming` / `job-completed-successfully`）：作业级透传，
  /// 上层错误页语义必需；原始 keyword 不做解释映射（缺 = 空集）。
  final List<String> stateReasons;
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
    final started = DateTime.now();
    _logWireRequest(httpEndpoint, ippBody);
    var (status, body) = await _postOnce(httpEndpoint, ippBody);
    if (status == HttpStatus.upgradeRequired && httpEndpoint.scheme == 'http') {
      // TLS-only 打印机（如 EPSON L3250）：明文端点回 426 Upgrade Required，
      // 要求升级 TLS。按 RFC 2817 精神换 https 同端口重试一次
      // （打印机证书普遍自签，已由 acceptSelfSignedTls 放行）。
      ippLog('426 Upgrade Required -> retrying over TLS on the same port');
      final upgraded = httpEndpoint.replace(scheme: 'https');
      (status, body) = await _postOnce(upgraded, ippBody);
    }
    if (status != HttpStatus.ok) {
      _logWireFailure(httpEndpoint, status, ippBody, body, started);
      // HTTP 5xx 属服务器侧瞬态故障，交由轮询重试吸收；其余为传输层错误。
      if (status >= 500) {
        throw IppTransientException('HTTP $status from ${httpEndpoint.host}');
      }
      throw IppPrintException('HTTP $status from ${httpEndpoint.host}');
    }
    final parsed = IppCodec.parseResponse(body);
    _logWireResponse(httpEndpoint, status, ippBody, body, started, parsed);
    return parsed;
  }

  /// 发送一次请求并收取原始响应（状态码与体；解析与错误判定交 [post]）。
  Future<(int, Uint8List)> _postOnce(
      Uri httpEndpoint, Uint8List ippBody) async {
    final request = await _http.postUrl(httpEndpoint);
    request.headers.set(HttpHeaders.contentTypeHeader, 'application/ipp');
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    // 版本串单一真相源：lib/src/version.dart（0.7.2 起不再就地手写，
    // 历史漂移：0.3→0.6→0.7 三次手改三次落后）。
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'ipp_print/$ippPrintVersion',
    );
    request.headers.contentLength = ippBody.length;
    request.add(ippBody);
    final response = await request.close();
    final body = await _collect(response);
    return (response.statusCode, body);
  }

  /// 提交 Print-Job，返回打印机应答的作业快照。
  ///
  /// RFC 8011 §4.2.1.2：job-id / job-state / job-state-reasons 均为响应
  /// REQUIRED 属性；缺失按「不推断」纪律如实 unknown / 空集。
  Future<IppJobSummary> submitJob(
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
    return IppJobSummary(
      jobId: jobId,
      jobState: _stateOf(res),
      stateReasons: [
        for (final v in res.values('job-state-reasons')) v.asString,
      ],
    );
  }

  /// Create-Job（RFC 8011 §4.2.4）：无文档数据的 Job Creation，返回
  /// 打印机分配的 job-id；后续以 [sendDocument] 逐文档提交。
  Future<int> createJob(
    DiscoveredPrinter p, {
    PrintOptions options = const PrintOptions(),
    String jobName = 'ipp_print-document',
    String userName = 'ipp_print',
  }) async {
    final res = await post(
      p.httpUri,
      IppCodec.buildCreateJob(
        printerUri: p.ippUriString,
        requestId: _nextRequestId,
        jobName: jobName,
        options: options,
        userName: userName,
      ),
    );
    _ensureSuccess(res, 'Create-Job');
    final jobId = res.firstValue('job-id')?.asInt;
    if (jobId == null) {
      throw const IppPrintException('Create-Job response missing job-id');
    }
    return jobId;
  }

  /// Send-Document（RFC 8011 §4.3.1）：向 [createJob] 建立的作业追加文档。
  /// [lastDocument] 为 RFC 8011 §4.3.1.1 的 Client MUST 属性——置 true
  /// 结束文档流，打印机随即调度作业；[documentFormat] MAY 按文档提供。
  Future<void> sendDocument(
    DiscoveredPrinter p, {
    required int jobId,
    required Uint8List document,
    required bool lastDocument,
    String? documentFormat,
  }) async {
    final body = BytesBuilder(copy: false)
      ..add(IppCodec.buildSendDocument(
        printerUri: p.ippUriString,
        jobId: jobId,
        requestId: _nextRequestId,
        lastDocument: lastDocument,
        documentFormat: documentFormat,
      ))
      ..add(document);
    final res = await post(p.httpUri, body.toBytes());
    _ensureSuccess(res, 'Send-Document');
  }

  /// 查询单个作业快照（Get-Job-Attributes；0.6 Job Engine 数据源）。
  ///
  /// 返回 job-id / job-state / job-state-reasons / job-name；响应无 job 组
  /// → 抛 [IppPrintException]；缺 job-state → 如实 [IppJobState.unknown]
  /// （0.4.1 纪律：不再猜 pending）。
  Future<IppJobSummary> getJob(DiscoveredPrinter p, int jobId) async {
    final res = await post(
      p.httpUri,
      IppCodec.buildGetJobAttributes(
        printerUri: p.ippUriString,
        jobId: jobId,
        requestId: _nextRequestId,
      ),
    );
    _ensureSuccess(res, 'Get-Job-Attributes');
    IppGroup? jobGroup;
    for (final g in res.groups) {
      if (g.tag == IppCodec.tagJobGroup) {
        jobGroup = g;
        break;
      }
    }
    if (jobGroup == null) {
      throw const IppPrintException(
          'Get-Job-Attributes response has no job group');
    }
    final stateCode = _intOf(jobGroup, 'job-state');
    return IppJobSummary(
      jobId: _intOf(jobGroup, 'job-id') ?? jobId,
      jobState: stateCode == null
          ? IppJobState.unknown
          : IppJobState.fromCode(stateCode),
      jobName: _stringOf(jobGroup, 'job-name'),
      stateReasons: [
        for (final v
            in jobGroup.attributes['job-state-reasons'] ?? const <IppValue>[])
          v.asString,
      ],
    );
  }

  /// 响应中 job-state 的 lenient 解码（缺 → unknown，绝不猜 pending）。
  static IppJobState _stateOf(IppResponse res) {
    final code = res.firstValue('job-state')?.asInt;
    return code == null ? IppJobState.unknown : IppJobState.fromCode(code);
  }

  /// 查询任务状态枚举。
  ///
  /// 与 [getJob] 的分工（非冗余，勿合并）：本方法面向**轮询容错**——
  /// lenient 解析（firstValue 跨组找 job-state，响应无 job 组也不抛），
  /// 异常形态交 [waitForTerminalState] 的瞬态吸收处理；[getJob] 面向
  /// **契约快照**——严格要求 job 组，缺失即抛 [IppPrintException]。
  /// 两者共用 [IppCodec.buildGetJobAttributes] 单一报文来源（防线格式漂移）。
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
    // 缺失/未知 job-state 如实 unknown（0.4.1：不再猜 pending）。
    return code == null ? IppJobState.unknown : IppJobState.fromCode(code);
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
        stateReasons: [
          for (final v
              in g.attributes['job-state-reasons'] ?? const <IppValue>[])
            v.asString,
        ],
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
