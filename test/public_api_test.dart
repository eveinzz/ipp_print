import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

// 产品符号**只**经公共 barrel 引用（本文件的编译期断言即由此成立）；
// 下方 ipp_wire_fixtures.dart 是测试工装（假客户端 / 手工线格式构造器），
// 不构成产品 API 面。
import 'package:ipp_print/ipp_print.dart';
import 'package:test/test.dart';

import 'ipp_wire_fixtures.dart';

/// 公共导出面与 Facade 锚点（0.7.2 补，此前为 0）。
///
/// 补锚点理由：17 个既有测试文件**全部** import
/// `package:ipp_print/src/...` 内部路径，无一 import 公共 barrel —— 导出面
/// 回归（新公共类型漏挂 barrel）在测试层完全不可见，只有宿主 App 才会踩到。
///
/// 本文件给三层保证：
/// 1. **编译期**：全部公共类型经 barrel 引用，任一漏出 barrel 即编译失败；
/// 2. **静态闸**：`lib/src` 下每个实现文件都必须在 barrel 的导出闭包内
///    （例外只有显式登记的 6 个内部文件，各自注明理由）；
/// 3. **行为**：`IppPrint.inspect()` 的解析与超时错误映射、
///    `IppPrint.validateTicket()` 的 Facade 出口。
void main() {
  test('公共符号经 barrel 全部可达（编译期导出面断言）', () {
    // 只要本文件能编译，即证明下列符号都由 lib/ipp_print.dart 导出。
    final surface = <Type>[
      // Facade 与作业
      IppPrint, PrintJob,
      // 发现
      PrinterDiscovery, MDnsPrinterDiscovery, NativeBonjourDiscovery,
      BonjourNativeApi, MethodChannelBonjourApi, DiscoveredPrinter,
      PrinterCapability, PrinterProbeStatus,
      // 分类与装配
      CapabilityClassifier, InstanceRecords, RecordAssembler,
      // 文档管线与编码
      PrintDocument, DocumentFormatNegotiator, DocumentDecision,
      DocumentEncoder, PwgRasterEncoder,
      // 能力模型与票据
      PrinterInfo, PrinterCapabilities, PrintValidationResult, PrintTicket,
      PrintFidelity, PrintOptions, PdfRasterizer, RasterPage, PrintProgress,
      PrintStage,
      // IPP 传输与报文
      IppClient, IppJobSummary, IppJobState, IppCodec, IppResponse, IppGroup,
      IppValue, IppResolution, PrinterAttributes,
      // 异常轴
      IppPrintException, IppStatusException, IppJobTimeoutException,
      IppUnsupportedException, IppTransientException, IppErrorCategory,
    ];
    expect(surface, hasLength(greaterThan(40)));

    // 刻意缺席：CapabilityValidator 不经 barrel 导出（0.5 起定位为 Facade
    // 实现细节，宿主唯一门径是 IppPrint.validateTicket，下方有锚点）。
  });

  test('扩展方法经 barrel 可达（PrinterInspect / PrinterValidate）', () {
    final client = IppClient();
    // 三个入口均为扩展方法：能取到 tear-off 即证明扩展已随 barrel 导出。
    expect(client.getPrinterCapabilities, isNotNull);
    expect(client.getPrinterAttributes, isNotNull);
    expect(client.validateJob, isNotNull);
  });

  test('lib/src 实现文件都在 barrel 导出闭包内（内部文件显式登记）', () {
    final reachable = _exportClosure();
    final all = Directory('lib/src')
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => f.path)
        .where((p) => p.endsWith('.dart'))
        .toSet();
    expect(all, hasLength(greaterThan(20)), reason: '扫描结果异常（测试工作目录应为包根）');

    final orphans = all.difference(reachable).difference(_internalOnly);
    expect(orphans, isEmpty,
        reason: '新增实现文件未挂入 lib/ipp_print.dart；'
            '若确为内部实现，请连同理由登记进 _internalOnly');
  });

  test('挂起防御：四处 10s 上界锚点均在（probe / inspect / validateJob / print）', () {
    final source = File('lib/src/ipp_print_core.dart').readAsStringSync() +
        File('lib/src/ipp_print_jobs.dart').readAsStringSync();
    final hits = RegExp(r'\.timeout\(const Duration\(seconds: 10\)\)')
        .allMatches(source);
    expect(hits.length, greaterThanOrEqualTo(4),
        reason: '10s 挂起防御少了一处（半开 TCP 下无限等待是已验证的真实故障模式）');
  });

  group('IppPrint.inspect（能力引擎 Facade 层）', () {
    test('解析打印机自报能力；未声明的属性如实为空（不推断）', () async {
      final client = FakeQueueClient()
        ..enqueue(
          IppCodec.opGetPrinterAttributes,
          resp(0, 0x04, [
            ..._name('printer-make-and-model', 'EPSON L3250 Series'),
            ...kw('document-format-supported', 'image/pwg-raster'),
            ...kwMore('application/pdf'),
            ...enumAttr('print-quality-default', 4),
          ]),
        );
      final caps = await IppPrint(discovery: _StubDiscovery(), client: client)
          .inspect(testPrinter());

      expect(caps.makeModel, 'EPSON L3250 Series');
      expect(caps.documentFormats, ['image/pwg-raster', 'application/pdf']);
      expect(caps.printQualityDefault, 4);
      // 未出现在响应里的属性：空/null（lenient，缺≠支持）。
      expect(caps.mediaSupported, isEmpty);
      expect(caps.name, isNull);
      expect(client.operations, [IppCodec.opGetPrinterAttributes]);
    });

    test('超时被包装为 IppPrintException（挂起防御的错误映射）', () async {
      final ipp = IppPrint(
        discovery: _StubDiscovery(),
        client: _TimeoutIppClient(),
      );
      await expectLater(
        ipp.inspect(testPrinter()),
        throwsA(isA<IppPrintException>()
            .having((e) => e.message, 'message', contains('timed out'))),
      );
    });
  });

  test('IppPrint.validateTicket：CapabilityValidator 唯一公共门径（零网络）', () {
    final ipp = IppPrint(discovery: _StubDiscovery());
    final result = ipp.validateTicket(
      ticket: const PrintTicket(colorMode: 'color', printQuality: 5),
      capabilities: const PrinterCapabilities(
        colorModesSupported: ['monochrome'],
        printQualitiesSupported: [3, 4],
      ),
    );
    expect(result.valid, isFalse);
    expect(result.unsupportedAttributes, ['print-color-mode', 'print-quality']);
    expect(result.statusCode, 0x0000);
  });
}

/// barrel 未导出、经显式登记的内部实现文件（新增项必须写清理由）。
const _internalOnly = <String>{
  // part 文件：由所属库聚合，不可（也不应）单独 export。
  'lib/src/ipp_print_jobs.dart',
  'lib/src/ipp/ipp_client_inspect.dart',
  'lib/src/ipp/ipp_client_validate.dart',
  'lib/src/ipp/ipp_client_wire_log.dart',
  'lib/src/ipp/ipp_job_models.dart',
  'lib/src/ipp/ipp_message_builder.dart',
  'lib/src/ipp/ipp_message_parser.dart',
  // 实现细节：CapabilityValidator 仅经 Facade 出口可达（0.5 契约定位）。
  'lib/src/capability/capability_validator.dart',
  // 调试日志：内核内部诊断通道，非宿主 API。
  'lib/src/ipp/ipp_log.dart',
  // 发现层资源路径策略单源：两条发现通道**内部**共用（供 capability 与
  // native_bonjour 同时 import），非宿主 API；导出它只会给公共面添噪声。
  'lib/src/discovery/resource_path.dart',
  // 版本常量：供内核内部（User-Agent）与测试使用；CORE FREEZE 下不新增
  // 公共面，故不进 barrel。
  'lib/src/version.dart',
};

/// 从 `lib/ipp_print.dart` 出发，沿 `export '...'` 求可导出文件的闭包。
Set<String> _exportClosure() {
  final exportRegExp = RegExp("export '([^']+)'");
  final reachable = <String>{};
  final pending = <String>['lib/ipp_print.dart'];
  while (pending.isNotEmpty) {
    final file = pending.removeLast();
    if (!reachable.add(file)) continue;
    for (final match
        in exportRegExp.allMatches(File(file).readAsStringSync())) {
      pending.add(_resolve(file, match.group(1)!));
    }
  }
  return reachable;
}

/// 解析 export 的相对路径（手写规范化，避免为一条断言引入 path 依赖）。
String _resolve(String fromFile, String relative) {
  final segments = fromFile.split('/')..removeLast();
  for (final segment in relative.split('/')) {
    if (segment == '..') {
      segments.removeLast();
    } else if (segment != '.' && segment.isNotEmpty) {
      segments.add(segment);
    }
  }
  return segments.join('/');
}

/// tag 0x42 nameWithoutLanguage 属性（与 ipp_client_test 的 make-and-model
/// 锚点同 tag，避免 tag 相关性引入假否定）。
List<int> _name(String name, String value) {
  final nameBytes = name.codeUnits;
  final valueBytes = value.codeUnits;
  return [
    0x42,
    (nameBytes.length >> 8) & 0xFF,
    nameBytes.length & 0xFF,
    ...nameBytes,
    (valueBytes.length >> 8) & 0xFF,
    valueBytes.length & 0xFF,
    ...valueBytes,
  ];
}

/// 不产生任何打印机的发现层（Facade 构造需要，测例不触碰发现路径）。
class _StubDiscovery implements PrinterDiscovery {
  @override
  Future<List<DiscoveredPrinter>> discover({
    Duration timeout = const Duration(seconds: 5),
  }) async =>
      const <DiscoveredPrinter>[];
}

/// 查询挂起（永不返回）的客户端：用于锚定超时的错误映射。
class _TimeoutIppClient extends IppClient {
  @override
  Future<IppResponse> post(Uri httpEndpoint, Uint8List ippBody) async =>
      throw TimeoutException('simulated hang');
}
