import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ipp_print/ipp_print.dart';
import 'package:test/test.dart';

import 'ipp_wire_fixtures.dart';

/// 调试日志锚点。
///
/// 锚定三类不可回归的日志契约：
/// 1. 传输层请求/响应成对记录（算子名由**报文头部**读出，不依赖被测解析），
///    失败路径（HTTP 非 200）同样留响应行；
/// 2. Unsupported Attributes 组出现时**必须逐个列出被忽略属性名**——属性名
///    只能来自组，状态码本身不携带；状态码按 RFC 8011 §4.1.7 必须带组却未带
///    时，另发缺组提示；
/// 3. 打印管线的协商结论 / 份数语义 / 作业号与终态。
///
/// 捕获方式：`ZoneSpecification.print`——`ippLog` 经 `print` 输出，故捕获的是
/// **真实输出通道**，不是为测试另建的接口（否则锚点会假绿）。
///
/// 传输层刻意用**真实本地 HTTP 服务器**驱动：`FakeQueueClient` 覆写了
/// `post()`，在它身上传输层日志根本不会执行——用它做锚点等于什么都没锚。
void main() {
  test('传输层：请求与响应成对记录（算子名 / 字节数 / IPP 状态 / 耗时）', () async {
    final captured = await _exchange(jobSubmitted);
    final logs = captured.logs;
    expect(captured.requestBytes, isNotNull);

    final sent = logs.where((l) => l.contains('-> Print-Job')).toList();
    expect(sent, hasLength(1), reason: '请求行缺失或算子名读错');
    expect(sent.single, contains('bytes=${captured.requestBytes!.length}'));
    expect(sent.single, contains('/ipp/print'));

    final received = logs.where((l) => l.contains('<- HTTP 200')).toList();
    expect(received, hasLength(1), reason: '响应行缺失');
    expect(received.single, contains('ipp=successful-ok'));
    expect(received.single, contains('Print-Job'));
    expect(received.single, contains('bytes=${jobSubmitted.length}'));
    expect(received.single, contains('elapsed='));
  });

  test('传输层失败：HTTP 非 200 也留响应行，不留「有请求无响应」的日志空洞', () async {
    final body = resp(0x0507, 0x01, const <int>[]);
    final logs = (await _exchange(body, httpStatus: 500)).logs;

    expect(logs.where((l) => l.contains('-> Print-Job')), hasLength(1));
    final failed = logs.where((l) => l.contains('<- HTTP 500')).toList();
    expect(failed, hasLength(1), reason: '失败路径缺响应行');
    expect(failed.single, contains('Print-Job'));
    expect(failed.single, contains('bytes=${body.length}'));
    expect(failed.single, contains('transport failure'));
  });

  test('被忽略属性：Unsupported Attributes 组必须逐个列出（份数缺陷的取证线）', () async {
    // 0x0001 + Unsupported 组列 copies —— 与真机 EPSON L3250 对 copies≥2 的
    // 回应同形；当时宿主侧没有任何输出，故无从归因。
    final ignored = resp(0x0001, 0x05, [...intAttr('copies', 2)]);
    final logs = (await _exchange(ignored)).logs;

    expect(logs.where((l) => l.contains('ipp=successful-ok-ignored')),
        hasLength(1));
    final warn =
        logs.where((l) => l.contains('ignored or substituted:')).toList();
    expect(warn, hasLength(1), reason: 'Unsupported 组出现却无告警');
    expect(warn.single, contains('copies'));
    expect(warn.single, contains('Print-Job'));
    expect(warn.single, contains('RFC 8011 §4.1.7'));
    expect(warn.single, contains('nothing else reports this'),
        reason: '0x0001 落在成功区间，须点明「不另有渠道报告」');
    expect(
        logs.where((l) => l.contains('with no Unsupported Attributes group')),
        isEmpty,
        reason: '组已给出，不应同时发缺组提示');
  });

  test('告警由组驱动：0x0001 无组时不列属性名，但明示打印机未按 §4.1.7 给组', () async {
    final noGroup = resp(0x0001, 0x01, const <int>[]);
    final logs = (await _exchange(noGroup)).logs;

    expect(logs.where((l) => l.contains('ipp=successful-ok-ignored')),
        hasLength(1));
    expect(logs.where((l) => l.contains('ignored or substituted:')), isEmpty,
        reason: '属性名只能来自组——状态码本身不携带属性名');
    final notice =
        logs.where((l) => l.contains('with no Unsupported Attributes group'));
    expect(notice, hasLength(1),
        reason: 'RFC 8011 §4.1.7 规定该状态码必须带组，缺失即属性名不可知');
    expect(notice.single, contains('RFC 8011 §4.1.7'));
  });

  test('状态码名称取自 RFC 8011 Appendix B.1（手校，防凭记忆写错）', () async {
    // 这三条是最易记错的取值：not-found 0x0406、not-possible 0x0404、busy 0x0507。
    final notFound = (await _exchange(resp(0x0406, 0x01, const <int>[]))).logs;
    expect(notFound.where((l) => l.contains('ipp=client-error-not-found')),
        hasLength(1));
    final busy = (await _exchange(resp(0x0507, 0x01, const <int>[]))).logs;
    expect(
        busy.where((l) => l.contains('ipp=server-error-busy')), hasLength(1));
    final notPossible =
        (await _exchange(resp(0x0404, 0x01, const <int>[]))).logs;
    expect(
        notPossible.where((l) => l.contains('ipp=client-error-not-possible')),
        hasLength(1));
  });

  test('管线：协商结论 / 份数语义（collated + 下发 1）/ 作业号与终态', () async {
    final client = FakeQueueClient()
      ..enqueue(IppCodec.opGetPrinterAttributes, _printerPwgOnly)
      ..enqueue(IppCodec.opPrintJob, jobSubmitted)
      ..enqueue(
        IppCodec.opGetJobAttributes,
        jobSnapshot(state: 9, reasons: ['job-completed-successfully']),
      );
    final ipp = IppPrint(discovery: _StubDiscovery(), client: client);

    final logs = await _capturedLogs(() async {
      await ipp
          .print(
            document: PrintDocument(
              bytes: const [1, 2, 3],
              mimeType: 'application/pdf',
              name: 'logging-test',
            ),
            printer: testPrinter(),
            rasterizer: _OnePageRasterizer(),
            ticket: const PrintTicket(copies: 2),
            jobTimeout: const Duration(seconds: 5),
          )
          .drain<void>();
    });

    expect(
      logs.where((l) => l.contains('negotiation -> image/pwg-raster '
          '(raster fallback)')),
      hasLength(1),
      reason: '协商结论未记录——「为何走了栅格回退」将不可归因',
    );
    final raster = logs
        .where((l) => l.contains('raster: pages=1 copies=2 (collated)'))
        .toList();
    expect(raster, hasLength(1), reason: '份数语义未记录');
    expect(raster.single, contains('sending copies=1'));
    expect(logs.where((l) => l.contains('job 42 submitted')), hasLength(1));
    expect(
      logs.where((l) => l.contains('job 42 reached terminal state: completed')),
      hasLength(1),
    );
  });
}

/// 对本地真实 HTTP 服务器发一次 Print-Job，返回捕获到的日志与请求体。
///
/// `httpStatus` 非 200 时 `post()` 必抛（失败不静默）；异常语义由
/// `ipp_client_test.dart` 锚定，此处只关心日志，故就地断言抛出与否。
Future<({List<String> logs, Uint8List? requestBytes})> _exchange(
  Uint8List response, {
  int httpStatus = 200,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final bodies = <Uint8List>[];
  server.listen((req) async {
    bodies.add(await _drain(req));
    req.response.statusCode = httpStatus;
    req.response.add(response);
    await req.response.close();
  });

  final request = IppCodec.buildPrintJob(
    printerUri: 'ipp://127.0.0.1:${server.port}/ipp/print',
    documentFormat: 'image/pwg-raster',
    requestId: 7,
    jobName: 'logging-test',
    options: const PrintOptions(),
  );
  final logs = await _capturedLogs(() async {
    try {
      await IppClient().post(
        Uri.parse('http://127.0.0.1:${server.port}/ipp/print'),
        request,
      );
      expect(httpStatus, 200, reason: '非 200 响应必须抛出，不得静默返回');
    } on IppPrintException {
      expect(httpStatus, isNot(200), reason: '200 响应不应抛出');
    }
  });
  await server.close(force: true);
  return (
    logs: logs,
    requestBytes: bodies.isEmpty ? null : bodies.single,
  );
}

Future<Uint8List> _drain(HttpRequest req) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in req) {
    builder.add(chunk);
  }
  return builder.toBytes();
}

/// 在捕获 `print` 的 Zone 中运行 [body]，返回全部输出行。
Future<List<String>> _capturedLogs(Future<void> Function() body) async {
  final lines = <String>[];
  await runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) => lines.add(line),
    ),
  );
  return lines;
}

/// 声明集**仅**含 image/pwg-raster（不含 pdf）→ 强制走栅格回退路径。
final _printerPwgOnly = resp(0, 0x04, [
  ...kw('document-format-supported', 'image/pwg-raster'),
]);

/// 单页假栅格化器（2×2 像素，RGB24）。
class _OnePageRasterizer implements PdfRasterizer {
  @override
  Stream<RasterPage> rasterize(List<int> pdfBytes, {int dpi = 300}) async* {
    yield RasterPage(width: 2, height: 2, bytes: Uint8List(12));
  }
}

/// 不产生任何打印机的发现层（Facade 构造需要）。
class _StubDiscovery implements PrinterDiscovery {
  @override
  Future<List<DiscoveredPrinter>> discover({
    Duration timeout = const Duration(seconds: 5),
  }) async =>
      const <DiscoveredPrinter>[];
}
