import 'dart:io';
import 'dart:typed_data';

import 'package:ipp_print/src/document/print_document.dart';
import 'package:ipp_print/src/ipp/ipp_client.dart';
import 'package:ipp_print/src/ipp/ipp_message.dart';
import 'package:ipp_print/src/ipp_print_core.dart';
import 'package:ipp_print/src/job/print_job.dart';
import 'package:ipp_print/src/models.dart';
import 'package:test/test.dart';

import 'ipp_wire_fixtures.dart';

/// IppClient Job Engine 与 Facade（submit / monitor / getJob / cancel）
/// 行为锚点。线格式锚点见 job_engine_test.dart。
void main() {
  group('IppClient Job Engine（submit 摘要 / create / send / getJob）', () {
    late FakeQueueClient client;

    setUp(() => client = FakeQueueClient());

    test('submitJob 返回作业快照（job-id + job-state + job-state-reasons）',
        () async {
      client.enqueue(0x0002, jobSubmitted);
      final s = await client.submitJob(
        testPrinter(),
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
        resp(0, 0x02, [...intAttr('job-id', 42), ...intAttr('job-state', 4)]),
      );
      client.enqueue(0x0006, resp(0, 0x01, const []));
      final jobId = await client.createJob(testPrinter());
      expect(jobId, 42);
      await client.sendDocument(
        testPrinter(),
        jobId: jobId,
        document: Uint8List.fromList([9, 9, 9]),
        lastDocument: true,
      );
      expect(
          client.operations, [IppCodec.opCreateJob, IppCodec.opSendDocument]);
      final send = client.bodies[1];
      expect(send.sublist(send.length - 3), [9, 9, 9]);
    });

    test('getJob 返回含 job-state-reasons 多值的快照', () async {
      client.enqueue(
        0x0009,
        jobSnapshot(state: 9, reasons: [
          'job-completed-successfully',
          'resources-are-not-ready',
        ]),
      );
      final s = await client.getJob(testPrinter(), 42);
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
      client.enqueue(0x000B, printerPdf);
      client.enqueue(0x0002, jobSubmitted);
      final job = await ipp.submit(
        document: PrintDocument(
          bytes: Uint8List.fromList([1, 2, 3]),
          mimeType: 'application/pdf',
        ),
        printer: testPrinter(),
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
      client.enqueue(0x0009, jobSnapshot(state: 3));
      client.enqueue(0x0009, jobSnapshot(state: 5));
      client.enqueue(0x0009, jobSnapshot(state: 9));
      final snapshots = await ipp
          .monitor(submittedJob!,
              interval: const Duration(milliseconds: 1))
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
      client.enqueue(0x0009, jobSnapshot(state: 9));
      final snapshots = await ipp
          .monitor(submittedJob!,
              interval: const Duration(milliseconds: 1))
          .toList();
      expect(snapshots, hasLength(1));
      expect(snapshots.single.state, IppJobState.completed);
    });

    test('monitor：超时抛 IppJobTimeoutException（终态不误判）', () async {
      await submitPdf();
      // 恒 pending：预排足量非终态快照，确保在超时判定前不耗尽。
      for (var i = 0; i < 60; i++) {
        client.enqueue(0x0009, jobSnapshot(state: 3));
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
      client.enqueue(
        0x0009,
        jobSnapshot(state: 6, reasons: ['job-canceled-by-user']),
      );
      final refreshed = await ipp.getJob(testPrinter(), 42);
      expect(refreshed.state, IppJobState.processingStopped);
      expect(refreshed.stateReasons, ['job-canceled-by-user']);

      client.enqueue(0x0008, resp(0, 0x01, const []));
      await ipp.cancel(submittedJob!);
      expect(client.operations.last, IppCodec.opCancelJob);
    });
  });
}
