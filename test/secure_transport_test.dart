import 'package:ipp_print/src/capability/capability.dart';
import 'package:ipp_print/src/models.dart';
import 'package:test/test.dart';

/// P1 ipps/TLS：secure 标志的传播与 scheme 语义。
void main() {
  group('DiscoveredPrinter.secure scheme 语义', () {
    test('明文实例：ipp:// 逻辑 URI + http:// 传输端点', () {
      final p = DiscoveredPrinter(
        name: 'x',
        host: 'EPSONBCAA32.local',
        port: 631,
        resourcePath: '/ipp/print',
      );
      expect(p.secure, isFalse);
      expect(p.ippUriString, 'ipp://EPSONBCAA32.local:631/ipp/print');
      expect(p.httpUriString, 'http://EPSONBCAA32.local:631/ipp/print');
      expect(p.httpUri.scheme, 'http');
      expect(p.ippUri.scheme, 'ipp');
    });

    test('secure 实例：ipps:// 逻辑 URI + https:// 传输端点（host 保序）', () {
      final p = DiscoveredPrinter(
        name: 'x',
        host: 'EPSONBCAA32.local',
        port: 631,
        resourcePath: '/ipp/print',
        secure: true,
      );
      expect(p.secure, isTrue);
      expect(p.ippUriString, 'ipps://EPSONBCAA32.local:631/ipp/print');
      expect(p.httpUriString, 'https://EPSONBCAA32.local:631/ipp/print');
      expect(p.httpUri.scheme, 'https');
      expect(p.ippUri.scheme, 'ipps');
    });

    test('默认不启用 secure（向后兼容既有构造点）', () {
      final p = DiscoveredPrinter(
          name: 'x', host: 'h', port: 631, resourcePath: '/r');
      expect(p.secure, isFalse);
    });
  });

  group('RecordAssembler.secure 传播', () {
    const assembler = RecordAssembler();

    test('_ipps 实例记录 → DiscoveredPrinter.secure = true', () {
      final p = assembler.assemble(InstanceRecords(
        instanceName: 'x',
        srvTarget: 'x.local',
        srvPort: 631,
        txtRaw: 'rp=ipp/print\x00pdl=image/pwg-raster'.codeUnits,
        secure: true,
      ));
      expect(p, isNotNull);
      expect(p!.secure, isTrue);
      expect(p.ippUriString, startsWith('ipps://'));
    });

    test('_ipp 实例记录 → secure = false', () {
      final p = assembler.assemble(InstanceRecords(
        instanceName: 'x',
        srvTarget: 'x.local',
        srvPort: 631,
        txtRaw: 'rp=ipp/print\x00pdl=image/pwg-raster'.codeUnits,
      ));
      expect(p!.secure, isFalse);
    });

    test('能力分类不受 secure 影响（分类只看 TXT 的 URF/pdl）', () {
      final txt = CapabilityClassifier.parseTxtBytes(
          'rp=ipp/print\x00pdl=image/pwg-raster'.codeUnits);
      expect(CapabilityClassifier.classify(txt), PrinterCapability.ippDirect);
    });
  });
}
