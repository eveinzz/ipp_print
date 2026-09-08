/// Minimal usage example for ipp_print.
///
/// Real discovery requires a LAN with broadcasting printers, so this example
/// injects a fake [PrinterDiscovery] and a fake [PdfRasterizer] to show the
/// full API surface offline. In a real app you would use
/// `MDnsPrinterDiscovery()` and a `PdfRasterizer` backed by the `printing`
/// package's `rasterPdf`.
library;

import 'dart:typed_data';

import 'package:ipp_print/ipp_print.dart';

class FakeDiscovery implements PrinterDiscovery {
  @override
  Future<List<DiscoveredPrinter>> discover({
    Duration timeout = const Duration(seconds: 5),
  }) async =>
      [
        DiscoveredPrinter(
          name: 'EPSON L3250 Series',
          host: '192.168.0.106',
          port: 631,
          resourcePath: '/ipp/print',
          txt: {
            'rp': 'ipp/print',
            'pdl':
                'application/octet-stream,image/pwg-raster,'
                    'application/vnd.epson.escpr',
          },
        ),
      ];
}

class FakeRasterizer implements PdfRasterizer {
  @override
  Stream<RasterPage> rasterize(List<int> pdfBytes, {int dpi = 300}) async* {
    yield RasterPage(
      width: 2480, // 210 mm at 300 dpi
      height: 3508, // 297 mm at 300 dpi
      bytes: Uint8List(2480 * 3508 * 3),
    );
  }
}

Future<void> main() async {
  final ipp = IppPrint();

  // 1. Discover every broadcasting printer on the LAN.
  final printers = await ipp.discover(timeout: const Duration(seconds: 5));
  for (final p in printers) {
    final capability = CapabilityClassifier.classify(p.txt);
    // airPrint  -> hand over to the system print panel
    // ippDirect -> printable via this package
    // vendorOnly/unknown -> guide user to vendor app / PDF export
    print('${p.name}: $capability (${p.ippUriString})');
  }

  // 2. Probe the chosen printer for negotiated capabilities.
  final printer = printers.first;
  final status = await ipp.probe(printer);
  print('probe: $status');

  // 3. Print a PDF via IPP direct connection (ippDirect only).
  if (status == PrinterProbeStatus.ready) {
    final pdfBytes = await loadPdf();
    await for (final progress in ipp.printPdf(
      pdfBytes: pdfBytes,
      printer: printer,
      rasterizer: FakeRasterizer(), // real app: PrintingRasterizer()
    )) {
      print(
          '${progress.stage}${progress.page != null ? ' p${progress.page}' : ''}');
    }
  }
}

Future<List<int>> loadPdf() async =>
    // e.g. read bytes produced by the host app's PDF export pipeline.
    [0x25, 0x50, 0x44, 0x46];
