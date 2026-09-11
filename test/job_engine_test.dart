import 'dart:io';
import 'dart:typed_data';

import 'package:ipp_print/src/document/print_document.dart';
import 'package:ipp_print/src/ipp/ipp_client.dart';
import 'package:ipp_print/src/ipp/ipp_message.dart';
import 'package:ipp_print/src/ipp_print_core.dart';
import 'package:ipp_print/src/job/print_job.dart';
import 'package:ipp_print/src/models.dart';
import 'package:test/test.dart';

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

/// 手工构造 IPP 响应（独立于被测代码的编码路径）。
Uint8List _resp(int status, int groupTag, List<int> attrs) {
  List<int> attr(int tag, String name, List<int> value) {
    final nb = name.codeUnits;
    return [
      tag,
      (nb.length >> 8) & 0xFF, nb.length & 0xFF, ...nb,
      (value.length >> 8) & 0xFF, value.length & 0xFF, ...value,
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

List<int> _kw(String name, String value) {
  final nb = name.codeUnits;
  final vb = value.codeUnits;
  return [
    0x44,
    (nb.length >> 8) & 0xFF, nb.length & 0xFF, ...nb,
    (vb.length >> 8) & 0xFF, vb.length & 0xFF, ...vb,
  ];
}

/// 同名多值的后续值（零长度名，RFC 8010 §3.1.5）。
List<int> _kwMore(String value) {
  final vb = value.codeUnits;
  return [
    0x44, 0x00, 0x00,
    (vb.length >> 8) & 0xFF, vb.length & 0xFF, ...vb,
  ];
}

List<int> _int(String name, int v) {
  final nb = name.codeUnits;
  return [
    0x21,
    (nb.length >> 8) & 0xFF, nb.length & 0xFF, ...nb,
    0x00, 0x04, (v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF,
  ];
}

final _printerPdf = _resp(0, 0x04, [
  ..._kw('document-format-supported', 'application/pdf'),
]);

final _jobSubmitted = _resp(0, 0x02, [
  ..._int('job-id', 42),
  ..._int('job-state', 5), // processing
  ..._kw('job-state-reasons', 'job-incoming'),
]);

Uint8List _jobSnapshot({int state = 3, List<String> reasons = const []}) {
  final attrs = <int>[
    ..._int('job-id', 42),
    ..._int('job-state', state),
    if (reasons.isNotEmpty) ..._kw('job-state-reasons', reasons.first),
    for (final r in reasons.skip(1)) ..._kwMore(r),
  ];
  return _resp(0, 0x02, attrs);
}

/// 返回属性 [name] 所在属性组的组 tag（找不到返回 -1）。
/// 独立线格式步进器，用于锚定 RFC 8011 §4.2.1.1 的组归属。
int _groupOf(List<int> body, String name) {
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

DiscoveredPrinter _printer() => DiscoveredPrinter(
      name: 'EPSON L3250 Series',
      host: '127.0.0.1',
      port: 1,
      resourcePath: '/ipp/print',
      txt: {'pdl': 'application/pdf', 'rp': 'ipp/print'},
    );

void main() {
  group('RFC 8011 §4.2.1.1 线格式组归属（0.6 修复锚点）', () {
    Uint8List build(PrintOptions o) => IppCodec.buildPrintJob(
          printerUri: 'ipp://p:631/ipp/print',
          documentFormat: 'application/pdf',
          requestId: 1,
          options: o,
        );

    test('ipp-attribute-fidelity 位于 Group 1 操作属性组（0.6 修复：原误入 Group 2）',
        () {
      final body = build(const PrintOptions(fidelity: PrintFidelity.exact));
      expect(_groupOf(body, 'ipp-attribute-fidelity'), 0x01);
    });

    test('copies 等 job template 属性位于 Group 2（RFC 8011 §4.2.1.1 本就正确）',
        () {
      final body = build(const PrintOptions(copies: 2));
      expect(_groupOf(body, 'copies'), 0x02);
    });

    test('Validate-Job 与 Print-Job 同构：fidelity 同步在操作属性组下发', () {
      final body = IppCodec.buildValidateJob(
        printerUri: 'ipp://p:631/ipp/print',
        documentFormat: 'application/pdf',
        requestId: 1,
        options: const PrintOptions(fidelity: PrintFidelity.exact),
      );
      expect(_groupOf(body, 'ipp-attribute-fidelity'), 0x01);
    });

    test('Validate-Job 与 Print-Job 同构：printer-resolution 同步下发（9 字节）',
        () {
      final body = IppCodec.buildValidateJob(
        printerUri: 'ipp://p:631/ipp/print',
        documentFormat: 'application/pdf',
        requestId: 1,
        options: const PrintOptions(resolution: (360, 360, 3)),
      );
      expect(_groupOf(body, 'printer-resolution'), 0x02);
      expect(
        String.fromCharCodes(body),
        contains('printer-resolution'),
      );
    });

    test('Validate-Job 缺省不下发 fidelity/resolution（作业模板默认值语义）', () {
      final body = IppCodec.buildValidateJob(
        printerUri: 'ipp://p:631/ipp/print',
        documentFormat: 'application/pdf',
        requestId: 1,
      );
      final s = String.fromCharCodes(body);
      expect(s, isNot(contains('ipp-attribute-fidelity')));
      expect(s, isNot(contains('printer-resolution')));
    });
  });

  group('Create-Job / Send-Document 线格式（RFC 8011 §4.2.4/§4.3.1）', () {
    test('buildCreateJob：op=0x0005，无 document-format，job template 在 Group 2',
        () {
      final body = IppCodec.buildCreateJob(
        printerUri: 'ipp://p:631/ipp/print',
        requestId: 7,
        options: const PrintOptions(copies: 2),
      );
      expect((body[2] << 8) | body[3], IppCodec.opCreateJob);
      final s = String.fromCharCodes(body);
      expect(s, contains('job-name'));
      expect(s, contains('copies'));
      // §4.2.4：Create-Job 不携带 document-format（每文档属性）。
      expect(s, isNot(contains('document-format')));
      expect(_groupOf(body, 'copies'), 0x02);
      // 无文档数据：end-of-attributes 之后无字节。
      expect(body.last, 0x03);
    });

    test('buildSendDocument：op=0x0006，job-id + last-document（MUST），数据尾随',
        () {
      final body = IppCodec.buildSendDocument(
        printerUri: 'ipp://p:631/ipp/print',
        jobId: 42,
        requestId: 8,
        lastDocument: true,
        documentFormat: 'application/pdf',
      );
      expect((body[2] << 8) | body[3], IppCodec.opSendDocument);
      final s = String.fromCharCodes(body);
      expect(s, contains('job-id'));
      expect(s, contains('last-document'));
      expect(s, contains('document-format'));
      expect(_groupOf(body, 'last-document'), 0x01);
      // last-document = true：boolean 线格式 1 字节 0x01。
      // （名字后为 value-len 2 字节，随后即值字节。）
      final i = s.indexOf('last-document');
      expect(body[i + 'last-document'.length + 2], 0x01);
      // 文档数据追加在 end-of-attributes 之后。
      expect(body.last, 0x03);
    });
  });

  group('IppClient Job Engine（submit 摘要 / create / send / getJob）', () {
    late FakeQueueClient client;

    setUp(() => client = FakeQueueClient());

    test('submitJob 返回作业快照（job-id + job-state + job-state-reasons）', () async {
      client.enqueue(0x0002, _jobSubmitted);
      final s = await client.submitJob(
        _printer(),
        document: Uint8List.fromList([1, 2, 3]),
        documentFormat: 'application/pdf',
      );
      expect(s.jobId, 42);
      expect(s.jobState, IppJobState.processing);
      expect(s.stateReasons, ['job-incoming']);
    });

    test('createJob → job-id；sendDocument(last: true) 成功且请求含文档数据',
        () async {
      client.enqueue(
        0x0005,
        _resp(0, 0x02, [..._int('job-id', 42), ..._int('job-state', 4)]),
      );
      client.enqueue(0x0006, _resp(0, 0x01, const []));
      final jobId = await client.createJob(_printer());
      expect(jobId, 42);
      await client.sendDocument(
        _printer(),
        jobId: jobId,
        document: Uint8List.fromList([9, 9, 9]),
        lastDocument: true,
      );
      expect(client.operations, [IppCodec.opCreateJob, IppCodec.opSendDocument]);
      final send = client.bodies[1];
      expect(send.sublist(send.length - 3), [9, 9, 9]);
    });

    test('getJob 返回含 job-state-reasons 多值的快照', () async {
      client.enqueue(
        0x0009,
        _jobSnapshot(state: 9, reasons: [
          'job-completed-successfully',
          'resources-are-not-ready',
        ]),
      );
      final s = await client.getJob(_printer(), 42);
      expect(s.jobId, 42);
      expect(s.jobState, IppJobState.completed);
      expect(s.stateReasons,
          ['job-completed-successfully', 'resources-are-not-ready']);
    });
  });

  group('Job Engine Facade（submit / monitor / getJob / cancel）', () {
    late FakeQueueClient client;
    late IppPrint ipp;

    setUp(() {
      client = FakeQueueClient();
      ipp = IppPrint(client: client);
    });

    PrintJob? submittedJob;

    Future<PrintJob> submitPdf() async {
      client.enqueue(0x000B, _printerPdf);
      client.enqueue(0x0002, _jobSubmitted);
      final job = await ipp.submit(
        document: PrintDocument(
          bytes: Uint8List.fromList([1, 2, 3]),
          mimeType: 'application/pdf',
        ),
        printer: _printer(),
      );
      submittedJob = job;
      return job;
    }

    test('submit：门→协商→提交，返回 PrintJob 快照（documentFormat 来自声明集）',
        () async {
      final job = await submitPdf();
      expect(job.jobId, 42);
      expect(job.state, IppJobState.processing);
      expect(job.stateReasons, ['job-incoming']);
      expect(job.documentFormat, 'application/pdf');
      expect(job.isTerminal, isFalse);
      expect(client.operations, [0x000B, 0x0002]);
    });

    test('monitor：逐快照产出，终态后关流', () async {
      await submitPdf();
      client.enqueue(0x0009, _jobSnapshot(state: 3));
      client.enqueue(0x0009, _jobSnapshot(state: 5));
      client.enqueue(0x0009, _jobSnapshot(state: 9));
      final snapshots =
          await ipp.monitor(submittedJob!, interval: const Duration(milliseconds: 1))
              .toList();
      expect(snapshots.map((s) => s.state).toList(), [
        IppJobState.pending,
        IppJobState.processing,
        IppJobState.completed,
      ]);
      expect(snapshots.last.isTerminal, isTrue);
    });

    test('monitor：SocketException 瞬态被吸收（有界容错）', () async {
      await submitPdf();
      client.enqueueThrow(0x0009, const SocketException('reset'));
      client.enqueue(0x0009, _jobSnapshot(state: 9));
      final snapshots =
          await ipp.monitor(submittedJob!, interval: const Duration(milliseconds: 1))
              .toList();
      expect(snapshots, hasLength(1));
      expect(snapshots.single.state, IppJobState.completed);
    });

    test('monitor：超时抛 IppJobTimeoutException（终态不误判）', () async {
      await submitPdf();
      // 恒 pending：预排足量非终态快照，确保在超时判定前不耗尽。
      for (var i = 0; i < 60; i++) {
        client.enqueue(0x0009, _jobSnapshot(state: 3));
      }
      await expectLater(
        ipp
            .monitor(
              submittedJob!,
              interval: const Duration(milliseconds: 1),
              timeout: const Duration(milliseconds: 25),
            )
            .toList(),
        throwsA(isA<IppJobTimeoutException>()),
      );
    });

    test('getJob 返回刷新快照；cancel(PrintJob) 走 Cancel-Job', () async {
      await submitPdf();
      client.enqueue(0x0009, _jobSnapshot(state: 6, reasons: ['job-canceled-by-user']));
      final refreshed = await ipp.getJob(_printer(), 42);
      expect(refreshed.state, IppJobState.processingStopped);
      expect(refreshed.stateReasons, ['job-canceled-by-user']);

      client.enqueue(0x0008, _resp(0, 0x01, const []));
      await ipp.cancel(submittedJob!);
      expect(client.operations.last, IppCodec.opCancelJob);
    });
  });
}
