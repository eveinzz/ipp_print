import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ipp_print/src/ipp/ipp_client.dart';
import 'package:ipp_print/src/ipp/ipp_message.dart';
import 'package:ipp_print/src/models.dart';
import 'package:test/test.dart';

/// 本地假 IPP 服务器：真 HTTP 传输 + 假 IPP 响应（按 operation-id 路由）。
class FakeIppServer {
  FakeIppServer();

  ServerSocket? _server;
  final _requests = <Uint8List>[];

  List<Uint8List> get requests => _requests;

  Future<int> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handle);
    return _server!.port;
  }

  Future<void> stop() async {
    await _server?.close();
  }

  void _handle(Socket socket) {
    final buffer = BytesBuilder();
    late final StreamSubscription<Uint8List> sub;
    sub = socket.listen((data) {
      buffer.add(data);
      final bytes = buffer.toBytes();
      final headerEnd = _findHeaderEnd(bytes);
      if (headerEnd < 0) return;
      final contentLength = _contentLength(bytes, headerEnd);
      if (contentLength < 0) {
        socket.destroy();
        sub.cancel();
        return;
      }
      if (bytes.length < headerEnd + contentLength) return;
      final body = Uint8List.sublistView(
          bytes, headerEnd, headerEnd + contentLength);
      _requests.add(Uint8List.fromList(body));
      // 预排的原始 HTTP 响应优先（用于模拟 5xx/404 等传输层场景）。
      final raw = _pendingHttp.isEmpty ? null : _pendingHttp.removeAt(0);
      socket.add(raw ?? _respond(body));
      socket.destroy();
      sub.cancel();
    });
  }

  final _pendingHttp = <List<int>?>[];

  /// 预排原始 HTTP 响应；传 null 表示恢复正常的 IPP 路由。
  void enqueueHttp(List<int>? rawResponseOrNull) =>
      _pendingHttp.add(rawResponseOrNull);

  int _findHeaderEnd(List<int> bytes) {
    for (var i = 0; i + 3 < bytes.length; i++) {
      if (bytes[i] == 13 && bytes[i + 1] == 10 //
          &&
          bytes[i + 2] == 13 &&
          bytes[i + 3] == 10) {
        return i + 4;
      }
    }
    return -1;
  }

  int _contentLength(List<int> bytes, int headerEnd) {
    final header = String.fromCharCodes(bytes.sublist(0, headerEnd));
    final match =
        RegExp(r'Content-Length:\s*(\d+)', caseSensitive: false).firstMatch(
      header,
    );
    return match == null ? -1 : int.parse(match.group(1)!);
  }

  /// 按 IPP operation-id 路由：Print-Job / Get-Printer-Attributes /
  /// Get-Job-Attributes / Cancel-Job / Get-Jobs。
  List<int> _respond(Uint8List request) {
    final op = (request[2] << 8) | request[3];
    final ipp = switch (op) {
      IppCodec.opPrintJob => _printJobResponse(),
      IppCodec.opGetPrinterAttributes => _printerAttributesResponse(),
      IppCodec.opCancelJob => _cancelJobResponse(),
      IppCodec.opGetJobs => _getJobsResponse(),
      _ => _jobStateResponse(),
    };
    final head = 'HTTP/1.1 200 OK\r\n'
        'Content-Type: application/ipp\r\n'
        'Content-Length: ${ipp.length}\r\n'
        'Connection: close\r\n\r\n';
    return [...head.codeUnits, ...ipp];
  }
}

List<int> _attr(int tag, String name, List<int> value) {
  final nb = name.codeUnits;
  return [
    tag,
    (nb.length >> 8) & 0xFF, nb.length & 0xFF, ...nb,
    (value.length >> 8) & 0xFF, value.length & 0xFF, ...value,
  ];
}

List<int> _raw(int tag, List<int> value) {
  return [
    tag,
    0x00, 0x00, // 零长度名 = additional value
    (value.length >> 8) & 0xFF, value.length & 0xFF, ...value,
  ];
}

List<int> _s(String s) => s.codeUnits;
List<int> _i32(int v) =>
    [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

Uint8List _wrap(int status, List<int> groupTag, List<int> attrs) {
  final b = BytesBuilder()
    ..add([0x01, 0x01, (status >> 8) & 0xFF, status & 0xFF, 0, 0, 0, 1])
    ..addByte(0x01)
    ..add(_attr(0x47, 'attributes-charset', _s('utf-8')))
    ..add(_attr(0x48, 'attributes-natural-language', _s('en')))
    ..addByte(groupTag[0])
    ..add(attrs)
    ..addByte(0x03);
  return b.toBytes();
}

Uint8List _printJobResponse() => _wrap(
      0,
      [0x02],
      _attr(0x21, 'job-id', _i32(42)) + _attr(0x23, 'job-state', _i32(3)),
    );

Uint8List _printerAttributesResponse() => _wrap(
      0,
      [0x04],
      _attr(0x44, 'media-supported', _s('iso_a4_210x297mm')) +
          _raw(0x44, _s('na_letter_8.5x11in')) +
          _attr(0x44, 'document-format-supported', _s('image/pwg-raster')) +
          _attr(0x23, 'printer-state', _i32(3)) +
          _attr(0x42, 'printer-make-and-model', _s('EPSON L3250 Series')),
    );

Uint8List _jobStateResponse() => _wrap(
      0,
      [0x02],
      _attr(0x21, 'job-id', _i32(42)) + _attr(0x23, 'job-state', _i32(9)),
    );

/// Cancel-Job 成功响应：仅 operation 组（无 job 组返回）。
Uint8List _cancelJobResponse() => _wrap(0, [0x02], const <int>[]);

/// Get-Jobs 成功响应：两个作业组（模拟队列中两笔作业）。
Uint8List _getJobsResponse() {
  final b = BytesBuilder()
    ..add([0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 7])
    ..addByte(0x01)
    ..add(_attr(0x47, 'attributes-charset', _s('utf-8')))
    ..add(_attr(0x48, 'attributes-natural-language', _s('en')));
  void job(int id, int state, String name, String user) {
    b..addByte(0x02)
      ..add(_attr(0x21, 'job-id', _i32(id)))
      ..add(_attr(0x23, 'job-state', _i32(state)))
      ..add(_attr(0x42, 'job-name', _s(name)))
      ..add(_attr(0x42, 'job-originating-user-name', _s(user)));
  }

  job(42, 5, 'doc-a', 'alice');
  job(43, 9, 'doc-b', 'bob');
  b.addByte(0x03);
  return b.toBytes();
}

void main() {
  late FakeIppServer server;
  late IppClient client;
  late DiscoveredPrinter printer;
  late int port;

  setUp(() async {
    server = FakeIppServer();
    port = await server.start();
    client = IppClient();
    printer = DiscoveredPrinter(
      name: 'EPSON L3250 Series',
      host: '127.0.0.1',
      port: port,
      resourcePath: '/ipp/print',
      txt: {'pdl': 'image/pwg-raster', 'rp': 'ipp/print'},
    );
  });

  tearDown(() => server.stop());

  test('getPrinterAttributes：解析介质/格式/状态/型号', () async {
    final attrs = await client.getPrinterAttributes(printer);
    expect(attrs.mediaSupported,
        ['iso_a4_210x297mm', 'na_letter_8.5x11in']);
    expect(attrs.documentFormats, ['image/pwg-raster']);
    expect(attrs.state, 'idle');
    expect(attrs.makeModel, 'EPSON L3250 Series');
  });

  test('submitJob：返回打印机分配的 job-id，请求含文档数据', () async {
    final jobId = await client.submitJob(
      printer,
      document: Uint8List.fromList([1, 2, 3, 4]),
      documentFormat: 'image/pwg-raster',
    );
    expect(jobId, 42);
    final req = server.requests.single;
    expect(req[2] << 8 | req[3], IppCodec.opPrintJob);
    // 请求尾部应包含我们提交的文档字节
    final tail = req.sublist(req.length - 4);
    expect(tail, [1, 2, 3, 4]);
  });

  test('getJobState：轮询到 completed 终态', () async {
    final jobId = await client.submitJob(
      printer,
      document: Uint8List.fromList([9]),
      documentFormat: 'image/pwg-raster',
    );
    final state = await client.waitForTerminalState(
      printer,
      jobId,
      interval: const Duration(milliseconds: 10),
    );
    expect(state, IppJobState.completed);
    expect(server.requests.length, 2); // Print-Job + Get-Job-Attributes
  });

  test('打印机不可达 → SocketException（离线语义，供 probe 映射 offline）',
      () async {
    final bad = DiscoveredPrinter(
      name: 'x',
      host: '127.0.0.1',
      port: 1, // 无服务
      resourcePath: '/ipp/print',
    );
    await expectLater(
      client.getPrinterAttributes(bad),
      throwsA(isA<SocketException>()),
    );
  });

  test('HTTP 404 → IppPrintException（持久传输错误）', () async {
    const http404 = 'HTTP/1.1 404 Not Found\r\n'
        'Content-Length: 0\r\n\r\n';
    server.enqueueHttp(http404.codeUnits);
    await expectLater(
      client.getPrinterAttributes(printer),
      throwsA(isA<IppPrintException>()),
    );
  });

  test('cancelJob：发送 0x0008 请求且包含 job-id，成功后静默返回', () async {
    await client.cancelJob(printer, 42);
    final req = server.requests.single;
    expect(req[2] << 8 | req[3], IppCodec.opCancelJob);
    // 请求体含 job-id=42（integer 属性值）
    final s = String.fromCharCodes(req);
    expect(s.contains('job-id'), isTrue);
    expect(req, contains(42)); // _i32(42) 出现在报文中
  });

  test('cancelJob：作业不存在（client-error-not-found）→ IppStatusException',
      () async {
    server.enqueueHttp(
      _httpResponse(_wrap(0x0406, [0x02], const <int>[])),
    );
    await expectLater(
      client.cancelJob(printer, 999),
      throwsA(isA<IppStatusException>()),
    );
  });

  test('getJobs：解析两个作业组为摘要列表', () async {
    final jobs = await client.getJobs(printer);
    expect(jobs, hasLength(2));
    expect(jobs[0].jobId, 42);
    expect(jobs[0].jobState, IppJobState.processing);
    expect(jobs[0].jobName, 'doc-a');
    expect(jobs[0].userName, 'alice');
    expect(jobs[1].jobId, 43);
    expect(jobs[1].jobState, IppJobState.completed);
    expect(jobs[1].jobName, 'doc-b');
    // 请求应携带 Get-Jobs 操作码（0x000A）
    expect(server.requests.single[2] << 8 | server.requests.single[3],
        IppCodec.opGetJobs);
  });

  test('secure 打印机走 https 端点（ipps）——连接本地明文服务器应握手失败',
      () async {
    final securePrinter = DiscoveredPrinter(
      name: 'x',
      host: '127.0.0.1',
      port: port,
      resourcePath: '/ipp/print',
      secure: true,
    );
    // https 连明文端口 → TLS 握手层异常（绝不能按 IPP 明文解析成功）。
    await expectLater(
      client.getPrinterAttributes(securePrinter),
      throwsA(isA<Exception>()),
    );
  });
}

List<int> _httpResponse(List<int> ippBody) {
  const head = 'HTTP/1.1 200 OK\r\n'
      'Content-Type: application/ipp\r\n'
      'Content-Length: ';
  return [
    ...'$head${ippBody.length}\r\nConnection: close\r\n\r\n'.codeUnits,
    ...ippBody,
  ];
}

// _ippResponse 保留占位避免 lint unused —— 实际未被引用，删除。
