/// 文档格式协商：只依据打印机自报的 `document-format-supported` 决定
/// 「直投原格式」还是「转 PWG 栅格」。
///
/// 规范依据（事实基线，TODO 0.4）：IPP Everywhere v1.1 §6——
/// PWG Raster = MUST（全机型）；JPEG = 彩色机 MUST / 单色机 SHOULD；
/// **PDF = 仅 SHOULD**（直投必须机会主义，运行时查证声明集）。
library;

import 'package:ipp_print/src/document/print_document.dart';
import 'package:ipp_print/src/models.dart';

/// 协商决策结果。
class DocumentDecision {
  const DocumentDecision({
    required this.passthrough,
    required this.documentFormat,
  });

  /// true = [PrintDocument.bytes] 可原样提交（打印机声明了该 MIME）；
  /// false = 文档需经 [DocumentEncoder] 转换为 [documentFormat] 后提交。
  final bool passthrough;

  /// 提交 IPP 作业时使用的 `document-format` 取值（取自打印机声明集，
  /// 大小写保持打印机原样）。
  final String documentFormat;
}

/// 无状态纯函数协商器：输入文档 MIME + 打印机声明集，输出路由决策。
///
/// 决策规则（确定性，按序）：
/// 1. 声明集含文档 MIME（大小写不敏感）→ **直投原格式**（免栅格化，
///    保矢量与文本层；PDF 直投的机会主义路径即此）；
/// 2. 否则声明集含 `image/pwg-raster` → 转 PWG 栅格（MUST 级兜底）；
/// 3. 否则抛 [IppPrintException]——**缺≠支持**，绝不推断。
class DocumentFormatNegotiator {
  const DocumentFormatNegotiator();

  /// PWG 栅格 MIME（IPP Everywhere v1.1 §6 对 Printer 的 MUST 要求）。
  static const String pwgRaster = 'image/pwg-raster';

  DocumentDecision negotiate({
    required PrintDocument document,
    required List<String> printerFormats,
  }) {
    final mime = document.mimeType.toLowerCase();
    for (final f in printerFormats) {
      if (f.toLowerCase() == mime) {
        return DocumentDecision(passthrough: true, documentFormat: f);
      }
    }
    for (final f in printerFormats) {
      if (f.toLowerCase() == pwgRaster) {
        return DocumentDecision(passthrough: false, documentFormat: f);
      }
    }
    throw IppPrintException(
      'no viable document route: printer declares '
      '$printerFormats, document is ${document.mimeType}',
    );
  }
}
