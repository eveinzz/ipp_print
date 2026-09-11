import 'package:ipp_print/src/discovery/mdns_discovery.dart';
import 'package:ipp_print/src/models.dart';
import 'package:test/test.dart';

DiscoveredPrinter _p(String uuid, {bool secure = false, String name = 'P'}) =>
    DiscoveredPrinter(
      name: name,
      host: 'h.local',
      port: 631,
      resourcePath: '/ipp/print',
      uuid: uuid,
      secure: secure,
    );

void main() {
  group('MDnsPrinterDiscovery.mergeDedup（并行浏览结果合并，0.3）', () {
    test('同一 UUID 双广播（_ipp + _ipps）保留明文实例', () {
      final merged = MDnsPrinterDiscovery.mergeDedup([
        [_p('u1', secure: true)],
        [_p('u1')],
      ]);
      expect(merged, hasLength(1));
      expect(merged.single.secure, isFalse);
    });

    test('先明文后 TLS：明文已占位则不被覆盖', () {
      final merged = MDnsPrinterDiscovery.mergeDedup([
        [_p('u1')],
        [_p('u1', secure: true)],
      ]);
      expect(merged, hasLength(1));
      expect(merged.single.secure, isFalse);
    });

    test('不同 UUID 全保留（跨设备不去重）', () {
      final merged = MDnsPrinterDiscovery.mergeDedup([
        [_p('u1'), _p('u2', name: 'Q')],
        [_p('u3', name: 'R')],
      ]);
      expect(merged.map((p) => p.identity), containsAll(['u1', 'u2', 'u3']));
      expect(merged, hasLength(3));
    });

    test('空分支合并为空列表（无打印机时不抛异常）', () {
      expect(MDnsPrinterDiscovery.mergeDedup([const [], const []]), isEmpty);
    });
  });
}
