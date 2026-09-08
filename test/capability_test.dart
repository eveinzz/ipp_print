import 'dart:io';

import 'package:ipp_print/src/capability/capability.dart';
import 'package:ipp_print/src/models.dart';
import 'package:test/test.dart';

void main() {
  group('CapabilityClassifier.parseTxtBytes', () {
    test('解析 key=value 并以 \\0 分隔，键归一为小写', () {
      const raw = 'rp=ipp/print\x00pdl=image/pwg-raster\x00';
      final txt = CapabilityClassifier.parseTxtBytes(raw.codeUnits);
      expect(txt['rp'], 'ipp/print');
      expect(txt['pdl'], 'image/pwg-raster');
    });

    test('无 = 的段被忽略', () {
      final txt = CapabilityClassifier.parseTxtBytes('junk\x00rp=ipp/print'.codeUnits);
      expect(txt.containsKey('junk'), isFalse);
      expect(txt['rp'], 'ipp/print');
    });
  });

  group('CapabilityClassifier.classify（判据全部来自一手广播记录）', () {
    test('Epson L3250 实测 TXT（无 URF、含 pwg-raster）→ ippDirect', () {
      final txt = CapabilityClassifier.parseTxtBytes(
        'ty=EPSON L3250 Series\x00rp=ipp/print\x00'
        'pdl=application/octet-stream,image/pwg-raster,application/vnd.epson.escpr\x00'
        'uuid=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxbc32'.codeUnits,
      );
      expect(CapabilityClassifier.classify(txt), PrinterCapability.ippDirect);
    });

    test('有 URF 键 → airPrint（即使同时声明 pwg-raster）', () {
      final txt = CapabilityClassifier.parseTxtBytes(
        'URF=DM3\x00pdl=application/octet-stream,image/urf,image/pwg-raster'
            .codeUnits,
      );
      expect(CapabilityClassifier.classify(txt), PrinterCapability.airPrint);
    });

    test('无 URF 且 pdl 含 image/urf → airPrint', () {
      final txt = CapabilityClassifier.parseTxtBytes(
          'pdl=application/pdf,image/urf'.codeUnits);
      expect(CapabilityClassifier.classify(txt), PrinterCapability.airPrint);
    });

    test('仅厂商私有格式 → vendorOnly', () {
      final txt = CapabilityClassifier.parseTxtBytes(
          'pdl=application/vnd.epson.escpr'.codeUnits);
      expect(CapabilityClassifier.classify(txt), PrinterCapability.vendorOnly);
    });

    test('缺 pdl → unknown', () {
      expect(CapabilityClassifier.classify(const {}),
          PrinterCapability.unknown);
    });

    test('未归一键（手写 TXT）→ classify 内部防御式归一', () {
      expect(CapabilityClassifier.classify(const {'URF': 'DM3'}),
          PrinterCapability.airPrint);
    });

    test('URF 空值不构成 AirPrint 判据', () {
      expect(CapabilityClassifier.classify(const {'urf': ''}),
          PrinterCapability.unknown);
    });

    test('pdl 值大小写不敏感', () {
      expect(
          CapabilityClassifier.classify(
              const {'pdl': 'IMAGE/PWG-RASTER'}),
          PrinterCapability.ippDirect);
    });
  });

  group('RecordAssembler', () {
    const assembler = RecordAssembler();

    test('完整记录 → DiscoveredPrinter（rp 自动补斜杠，target 去尾点）', () {
      final p = assembler.assemble(InstanceRecords(
        instanceName: 'EPSON L3250 Series',
        srvTarget: 'EPSONBCAA32.local.',
        srvPort: 631,
        txtRaw: 'rp=ipp/print\x00uuid=abc'.codeUnits,
        ipv4: InternetAddress('192.168.0.106'),
      ));
      expect(p, isNotNull);
      expect(p!.host, '192.168.0.106');
      expect(p.resourcePath, '/ipp/print');
      expect(p.uuid, 'abc');
      expect(p.ippUri.toString(),
          'ipp://192.168.0.106:631/ipp/print');
      expect(p.httpUri.scheme, 'http');
    });

    test('缺 rp → 跳过（返回 null）', () {
      final p = assembler.assemble(InstanceRecords(
        instanceName: 'x',
        srvTarget: 'h.local',
        srvPort: 631,
        txtRaw: 'ty=model'.codeUnits,
      ));
      expect(p, isNull);
    });

    test('缺 SRV → 跳过（返回 null）', () {
      final p = assembler.assemble(InstanceRecords(
        instanceName: 'x',
        txtRaw: 'rp=ipp/print'.codeUnits,
      ));
      expect(p, isNull);
    });

    test('无 IPv4 时回退 SRV target 作 host（去尾点）', () {
      final p = assembler.assemble(InstanceRecords(
        instanceName: 'Epson',
        srvTarget: 'EPSONBCAA32.local.',
        srvPort: 631,
        txtRaw: 'rp=ipp/print'.codeUnits,
      ));
      expect(p!.host, 'EPSONBCAA32.local');
    });

    test('rp 已带前导斜杠时保持原样', () {
      final p = assembler.assemble(InstanceRecords(
        instanceName: 'x',
        srvTarget: 'h.local',
        srvPort: 631,
        txtRaw: 'rp=/ipp/print'.codeUnits,
      ));
      expect(p!.resourcePath, '/ipp/print');
    });

    test('无 UUID → identity 回退到 实例名@host:port', () {
      final p = assembler.assemble(InstanceRecords(
        instanceName: 'Epson',
        srvTarget: 'h.local',
        srvPort: 631,
        txtRaw: 'rp=ipp/print'.codeUnits,
        ipv4: InternetAddress('192.168.0.106'),
      ));
      expect(p!.identity, 'Epson@192.168.0.106:631');
    });

    test('有 UUID → identity 即 UUID（跨 IP 变化稳定）', () {
      final p = assembler.assemble(InstanceRecords(
        instanceName: 'Epson',
        srvTarget: 'h.local',
        srvPort: 631,
        txtRaw: 'rp=ipp/print\x00uuid=u-123'.codeUnits,
        ipv4: InternetAddress('192.168.0.106'),
      ));
      expect(p!.identity, 'u-123');
    });
  });
}
