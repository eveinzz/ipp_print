import 'dart:async' show TimeoutException;
import 'dart:io' show SocketException, HandshakeException;
import 'dart:typed_data';

import 'capability/capability.dart';
import 'capability/capability_validator.dart';
import 'discovery/native_bonjour_discovery.dart' show defaultPlatformDiscovery;
import 'document/document_format_negotiator.dart';
import 'document/print_document.dart';
import 'ipp/ipp_client.dart';
import 'ipp/ipp_log.dart';
import 'job/print_job.dart';
import 'models.dart';
import 'pwg/pwg_raster_encoder.dart';

part 'ipp_print_jobs.dart';

/// 诊断日志：仅 DEBUG 输出，前缀与原生层一致，release 零开销。
/// （统一实现在 [ippLog]，本函数保留旧名以兼容既有调用方。）
void ippProbeLog(String message) => ippLog(message);

/// Facade：插件唯一入口。
///
/// 职责边界（见 README）：发现 + 分类 + 传输；无 UI、无持久化、
/// 不接管 airPrint 级机型（交还系统打印面板）。
class IppPrint {
  IppPrint({PrinterDiscovery? discovery, IppClient? client, int dpi = 300})
      : _discovery = discovery ?? defaultPlatformDiscovery(),
        _client = client ?? IppClient(),
        _dpi = dpi;

  final PrinterDiscovery _discovery;
  final IppClient _client;
  final int _dpi;
  final _encoder = const PwgRasterEncoder();

  /// Job Engine（0.6）：submit / monitor / getJob / cancel 职责拆分的
  /// 实现宿主（懒构造；实现见 ipp_print_jobs.dart part）。
  late final _jobs = _JobEngine(this);

  /// 发现局域网打印机（全量平铺，含不可直连的机型）。
  Future<List<DiscoveredPrinter>> discover({
    Duration timeout = const Duration(seconds: 5),
  }) =>
      _discovery.discover(timeout: timeout);

  /// 手动直连端点（0.7）：发现不到 ≠ 不能打印。
  ///
  /// 适用 mDNS 被网络策略屏蔽 / 跨网段 / 已知地址直连的场景。URI 本身即
  /// IPP endpoint 存在性的用户断言——[probe] 与 [print]/[submit] 的 TXT
  /// 分类否定门对该端点豁免，能力判定交给实时查询 + 协商器终审
  /// （probe 驱动：先 [probe] 得 ready/unsupported/offline，再打印）。
  ///
  /// 解析规则（诚实解析，不猜）：
  /// - scheme 白名单 ipp / ipps / http / https，其余抛 [IppPrintException]；
  /// - `secure` = ipps/https（传输加密）；逻辑 scheme 恒 ipp/ipps；
  /// - 缺省端口：ipp/ipps = 631（RFC 2910/7472 IPP 标准端口）、
  ///   http/https = 80/443（HTTP 标准）；显式端口原样采用；
  /// - 空路径 → `/`（根端点合法，可达性交协商器裁决）；
  /// - 带 query/fragment 或缺 host → 拒绝（端点语义有歧义，不猜）。
  ///
  /// [name] 为宿主侧显示名，缺省 `Manual · host:port`；返回的
  /// [DiscoveredPrinter] 与发现产物同构（可进 probe/print/submit/monitor）。
  DiscoveredPrinter addEndpoint(Uri uri, {String? name}) {
    const transportSchemes = {'ipp': false, 'ipps': true,
      'http': false, 'https': true};
    final scheme = uri.scheme.toLowerCase();
    if (!transportSchemes.containsKey(scheme)) {
      throw IppPrintException(
          'addEndpoint: unsupported scheme "$scheme" '
          '(expected ipp / ipps / http / https)');
    }
    if (uri.host.isEmpty) {
      throw const IppPrintException(
          'addEndpoint: URI has no host (e.g. ipp://192.168.1.50:631/ipp/print)');
    }
    if (uri.query.isNotEmpty || uri.fragment.isNotEmpty) {
      throw const IppPrintException(
          'addEndpoint: query/fragment are not part of an IPP endpoint URI');
    }
    final secure = transportSchemes[scheme]!;
    final port = uri.port != 0
        ? uri.port
        : switch (scheme) {
            'http' => 80,
            'https' => 443,
            _ => 631, // ipp / ipps：RFC 2910/7472 IPP 标准端口
          };
    final path = uri.path.isEmpty ? '/' : uri.path;
    final host = uri.host;
    return DiscoveredPrinter(
      name: name ?? 'Manual · $host:$port',
      host: host,
      port: port,
      resourcePath: path,
      secure: secure,
      manualEndpoint: true,
    );
  }

  /// 探测单台打印机：TXT 分类 + IPP 查询交叉验证，映射为状态机。
  ///
  /// 交叉验证规则（双源确定性，0.5 起事实驱动）：TXT 判 ippDirect /
  /// vendorOnly 均发起实时 IPP 查询，以 `document-format-supported` 是否
  /// 含 image/pwg-raster 定 ready——vendorOnly 不再凭 TXT 盲判 unsupported
  /// （TXT pdl 可能过时/截断，声明集权威 = 打印机当下自报）。
  /// **缺失（空集）同样降级**——「没有声明能力」≠「支持能力」
  /// （document-format-supported 是 RFC 8011 REQUIRED 打印机描述属性，
  /// 声明集为空即非 conformant 打印机，按未声明处理绝不推断）。
  /// airPrint 级保持免查询快路径（宿主应交还系统打印面板）。
  /// 0.7：manualEndpoint（[addEndpoint]）豁免 unknown 否定门——
  /// 端点存在性由用户断言，一律走下方实时查询。
  Future<PrinterProbeStatus> probe(
    DiscoveredPrinter printer, {
    void Function(PrinterInfo info)? onInfo,
  }) async {
    final txtCapability = CapabilityClassifier.classify(printer.txt);
    if (!printer.manualEndpoint &&
        txtCapability == PrinterCapability.unknown) {
      return PrinterProbeStatus.unsupported;
    }
    if (txtCapability == PrinterCapability.airPrint) {
      onInfo?.call(PrinterInfo(capability: txtCapability));
      return PrinterProbeStatus.ready;
    }
    try {
      ippProbeLog('probe ${printer.name} -> ${printer.httpUriString}');
      // 挂起防御：HttpClient 的 connectionTimeout 不覆盖 DNS 解析与
      // 慢响应体，整机探测限时 10s（超时按无应答=offline 处理）。
      final attrs = await _client
          .getPrinterAttributes(printer)
          .timeout(const Duration(seconds: 10));
      final formats = attrs.documentFormats;
      final ok = formats
          .any((f) => f.toLowerCase().contains('pwg-raster'));
      ippProbeLog('probe ${printer.name}: $ok formats=$formats');
      final info = PrinterInfo(
        capability: ok ? PrinterCapability.ippDirect : PrinterCapability.vendorOnly,
        mediaSupported: attrs.mediaSupported,
        documentFormats: formats,
        state: attrs.state,
        makeModel: attrs.makeModel,
        colorModesSupported: attrs.colorModesSupported,
        colorModeDefault: attrs.colorModeDefault,
        sidesSupported: attrs.sidesSupported,
        sidesDefault: attrs.sidesDefault,
        resolutionsSupported: attrs.resolutionsSupported,
        resolutionDefault: attrs.resolutionDefault,
      );
      onInfo?.call(info);
      return ok ? PrinterProbeStatus.ready : PrinterProbeStatus.unsupported;
    } on TimeoutException {
      // 无应答（DNS 挂起/慢响应/静默丢包）：如实记 offline，绝不让
      // await 挂起令条目永久停留「探测中」。
      ippProbeLog('probe ${printer.name}: TIMEOUT (10s) -> offline');
      return PrinterProbeStatus.offline;
    } on SocketException catch (e) {
      ippProbeLog('probe ${printer.name}: offline ($e)');
      return PrinterProbeStatus.offline;
    } on IppPrintException catch (e) {
      ippProbeLog('probe ${printer.name}: unsupported ($e)');
      return PrinterProbeStatus.unsupported;
    }
  }

  /// 能力引擎（0.3）：完整能力集查询——「这台机器究竟能干什么」。
  ///
  /// 返回 [PrinterCapabilities]（文档/介质/色彩/双面/分辨率/份数/作业/
  /// 安全，全部来自打印机自报，缺失即 null/空）。与 [probe] 的区别：
  /// probe 面向「可否直连」的状态机判定（8 属性集），inspect 面向
  /// 宿主 UI 的全量能力展示与 0.4 格式协商的数据源。
  /// 整机限时 10s（同 probe 挂起防御），超时抛 [IppPrintException]。
  Future<PrinterCapabilities> inspect(DiscoveredPrinter printer) async {
    ippProbeLog('inspect ${printer.name} -> ${printer.httpUriString}');
    try {
      return await _client
          .getPrinterCapabilities(printer)
          .timeout(const Duration(seconds: 10));
    } on TimeoutException {
      ippProbeLog('inspect ${printer.name}: TIMEOUT (10s)');
      throw const IppPrintException('inspect: timed out after 10s');
    }
  }

  /// Validate-Job 预检（RFC 8011 §4.2.3）：提交大文档前先问打印机
  /// 「这个 Job 你能不能处理」。返回 [PrintValidationResult]；
  /// 打印机不支持该操作时返回 client-error-operation-not-supported
  /// （valid=false），宿主可回退为直接提交。
  ///
  /// 整机限时 10s（同 [probe]/[inspect] 挂起防御——半开 TCP 连接下
  /// 无限等待是 probe 阶段验证过的真实故障模式），超时抛
  /// [IppPrintException]。
  Future<PrintValidationResult> validateJob(
    DiscoveredPrinter printer, {
    required String documentFormat,
    PrintOptions options = const PrintOptions(),
    String jobName = 'ipp_print-document',
  }) async {
    ippProbeLog('validateJob ${printer.name} -> ${printer.httpUriString}');
    try {
      return await _client
          .validateJob(
            printer,
            documentFormat: documentFormat,
            options: options,
            jobName: jobName,
          )
          .timeout(const Duration(seconds: 10));
    } on TimeoutException {
      ippProbeLog('validateJob ${printer.name}: TIMEOUT (10s)');
      throw const IppPrintException('validateJob: timed out after 10s');
    }
  }

  /// 通用文档打印（0.4 Document Pipeline 核心入口）：协商 → 直投 /
  /// PWG 栅格回退 → 提交 → 等待终态。
  ///
  /// 0.5 起 Gate 事实化：TXT 分类仅否定 `unknown`（无 IPP 证据），
  /// 其余分类交由实时能力查询 + 协商器终审（详见方法内注释）。
  ///
  /// [ticket] 为作业语义模型（0.5 契约对象；null 字段 = 打印机默认），
  /// 内部经 [PrintTicket.toOptions] 转传输层下发。
  ///
  /// 路由决策由 [DocumentFormatNegotiator] 依打印机**此刻实时自报**的
  /// `document-format-supported` 作出（不使用宿主缓存的 probe 结果——
  /// 声明集权威必须是当下查询，宿主缓存可能过时）：
  /// 1. 声明集含 [PrintDocument.mimeType] → **直投**原格式（免栅格化，
  ///    保矢量与文本层；`document-format` 取打印机声明原样）；
  /// 2. 否则声明集含 `image/pwg-raster` → 栅格回退：[rasterizer] 必须注入
  ///    且文档须为 PDF（现管线唯一栅格化路径；非 PDF 文档无对应编码器，
  ///    如实拒绝不假装能处理）；
  /// 3. 否则抛 [IppUnsupportedException]（缺≠支持，绝不推断）。
  ///
  /// `job-name` 取 [PrintDocument.name]，缺省 `ipp_print-document`。
  /// 能力查询限时 10s（同 [probe] 挂起防御），作业终态限时 [jobTimeout]。
  /// 进度流：直投 = sending → waitingPrinter → done（页数未知，如实不填）；
  /// 栅格回退 = rasterizing → encoding… → sending → waitingPrinter → done。
  ///
  /// 0.6 起 gate → 协商 → 编码整段与 [submit] 共用单一来源
  /// `_prepareSubmission`（防双入口漂移）。
  Stream<PrintProgress> print({
    required PrintDocument document,
    required DiscoveredPrinter printer,
    PdfRasterizer? rasterizer,
    PrintTicket ticket = const PrintTicket(),
    Duration jobTimeout = const Duration(minutes: 5),
    int? dpi,
  }) async* {
    await for (final ev in _prepareSubmission(
      _client,
      encoder: _encoder,
      defaultDpi: _dpi,
      document: document,
      printer: printer,
      ticket: ticket,
      rasterizer: rasterizer,
      dpi: dpi,
    )) {
      if (ev is PrintProgress) {
        yield ev;
        continue;
      }
      final p = ev as _PreparedSubmission;
      yield* _submitAndAwait(
        _client,
        printer,
        bytes: p.bytes,
        documentFormat: p.documentFormat,
        options: p.options,
        jobName: p.jobName,
        jobTimeout: jobTimeout,
        pageCount: p.pageCount,
      );
    }
  }

  /// 提交作业但不等待终态（0.6 Job Engine）：gate → 实时协商 → 编码 →
  /// Print-Job，返回含打印机应答快照（job-id / job-state /
  /// job-state-reasons，RFC 8011 §4.2.1.2 REQUIRED）的 [PrintJob]。
  /// 后续以 [monitor] 轮询状态、[cancel] 取消、[getJob] 单查。
  ///
  /// [onProgress] 可选接收栅格回退路径的 rasterizing/encoding 进度
  /// （直投路径无编码进度；语义同 [print] 的前段事件流）。
  /// 其余语义（门/协商/编码/限时）与 [print] 完全一致。
  Future<PrintJob> submit({
    required PrintDocument document,
    required DiscoveredPrinter printer,
    PdfRasterizer? rasterizer,
    PrintTicket ticket = const PrintTicket(),
    int? dpi,
    void Function(PrintProgress progress)? onProgress,
  }) =>
      _jobs.submit(
        document: document,
        printer: printer,
        rasterizer: rasterizer,
        ticket: ticket,
        dpi: dpi,
        onProgress: onProgress,
      );

  /// 监听作业状态流（0.6 Job Engine）：按 [interval] 轮询
  /// Get-Job-Attributes，产出 [PrintJob] 快照；终态快照产出后正常关流；
  /// 超时抛 [IppJobTimeoutException]。瞬态故障（网络抖动 / HTTP 5xx /
  /// TLS 握手抖动）在 [maxTransientErrors] 次内吸收（语义同
  /// [IppClient.waitForTerminalState]）。
  Stream<PrintJob> monitor(
    PrintJob job, {
    Duration interval = const Duration(seconds: 2),
    Duration timeout = const Duration(minutes: 5),
    int maxTransientErrors = 3,
  }) =>
      _jobs.monitor(
        job,
        interval: interval,
        timeout: timeout,
        maxTransientErrors: maxTransientErrors,
      );

  /// 单查作业快照（Get-Job-Attributes）。
  Future<PrintJob> getJob(DiscoveredPrinter printer, int jobId) =>
      _jobs.getJob(printer, jobId);

  /// 取消作业（Cancel-Job；[PrintJob.printer] + [PrintJob.jobId] 寻址）。
  Future<void> cancel(PrintJob job) => _jobs.cancel(job);

  /// PDF → 栅格 → PWG → IPP 直连打印（便利 API：等价于以
  /// `mimeType: 'application/pdf'` 调用 [print]）。
  ///
  /// 0.4 起内部转调 [print]：document-format 不再硬编码
  /// `image/pwg-raster`，而是取自打印机实时声明集（协商后的栅格回退路径）；
  /// 会先发起一次 Get-Printer-Attributes 查询（10s 限时）。
  ///
  /// [rasterizer] 由宿主 App 注入（如基于 printing.rasterPdf 的适配器），
  /// 插件本体不绑定渲染实现。
  ///
  /// [dpi] 覆盖构造时的默认 dpi（0.3.1）：栅格化与 PWG 页头
  /// `cupsHWResolution` / `PageSize` 换算随之改变。**取值应来自
  /// `PrinterInfo.resolutionsSupported` 的协商结果**——300dpi 并非
  /// 所有打印机声明支持（L3250 实测声明 360x360 / 1440x720），宽容
  /// 机型接受、严格机型可能拒收或异常渲染；null（默认）沿用构造值。
  Stream<PrintProgress> printPdf({
    required List<int> pdfBytes,
    required DiscoveredPrinter printer,
    required PdfRasterizer rasterizer,
    PrintOptions options = const PrintOptions(),
    Duration jobTimeout = const Duration(minutes: 5),
    int? dpi,
  }) {
    return print(
      document: PrintDocument(bytes: pdfBytes, mimeType: 'application/pdf'),
      printer: printer,
      rasterizer: rasterizer,
      ticket: PrintTicket.fromOptions(options),
      jobTimeout: jobTimeout,
      dpi: dpi,
    );
  }

  /// 作业票据本地预检（0.5 CapabilityValidator 的 Facade 出口）：
  /// ticket 值 ∉ 打印机声明能力 → 结构化 invalid + 未支持属性名列表，
  /// 纯本地判定不产生网络请求。与 [validateJob]（设备级终审）双层并存：
  /// 本地预检拦「声明集就没有的值」，Validate-Job 问「这台机器此刻收不收」。
  /// 能力缺失（空声明集）的字段跳过检查——缺≠不支持，绝不推断。
  PrintValidationResult validateTicket({
    required PrintTicket ticket,
    required PrinterCapabilities capabilities,
  }) =>
      CapabilityValidator.validate(
          ticket: ticket, capabilities: capabilities);

  /// 取消指定作业（透传 [IppClient.cancelJob]）。
  Future<void> cancelJob(DiscoveredPrinter printer, int jobId) =>
      _client.cancelJob(printer, jobId);

  /// 查询作业队列（透传 [IppClient.getJobs]，参数语义见其文档）。
  Future<List<IppJobSummary>> getJobs(
    DiscoveredPrinter printer, {
    bool myJobs = false,
    String whichJobs = 'not-completed',
    List<String>? requestedAttributes,
  }) =>
      _client.getJobs(
        printer,
        myJobs: myJobs,
        whichJobs: whichJobs,
        requestedAttributes: requestedAttributes,
      );
}
