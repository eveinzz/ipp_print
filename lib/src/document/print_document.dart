/// 待打印文档：字节 + 自描述 MIME 格式（0.4 Document Pipeline 的输入）。
library;

/// 待提交给 IPP 打印机的文档。
///
/// [mimeType] 是格式协商的键：只与打印机自报的
/// `document-format-supported` 比较（大小写不敏感），**绝不推断**——
/// 打印机未声明的格式不会成为协商结果。
class PrintDocument {
  const PrintDocument({
    required this.bytes,
    required this.mimeType,
    this.name,
  });

  /// 文档原始字节（如 PDF/JPEG 文件内容）。
  final List<int> bytes;

  /// 文档 MIME 类型（IANA media type，如 `application/pdf`、`image/jpeg`）。
  final String mimeType;

  /// 文档名（作 IPP `job-name` 用途之一；null = 由提交方给默认名）。
  final String? name;
}
