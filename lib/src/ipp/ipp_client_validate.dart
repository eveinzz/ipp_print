part of 'ipp_client.dart';

extension PrinterValidate on IppClient {
  /// Validate-Job（RFC 8011 §4.2.3）：与 Print-Job 同构的请求（含
  /// document-format 与 job template 属性）但**不带文档数据**，用于在
  /// 提交大文档前确认「同构的 Job Creation 请求会不会被接受」。
  ///
  /// 返回 [PrintValidationResult]：
  /// - [PrintValidationResult.valid] = 打印机返回成功状态码；
  /// - 打印机接受但声明无法支持的属性，透出在
  ///   [PrintValidationResult.unsupportedAttributes]（Unsupported
  ///   Attributes 组，组 tag 0x05）。
  Future<PrintValidationResult> validateJob(
    DiscoveredPrinter p, {
    required String documentFormat,
    PrintOptions options = const PrintOptions(),
    String jobName = 'ipp_print-document',
  }) async {
    final res = await post(
      p.httpUri,
      IppCodec.buildValidateJob(
        printerUri: p.ippUriString,
        documentFormat: documentFormat,
        requestId: _nextRequestId,
        jobName: jobName,
        options: options,
      ),
    );
    final unsupported = <String>[
      ...?res
          .groupByTag(IppCodec.tagUnsupportedGroup)
          ?.attributes
          .keys,
    ];
    return PrintValidationResult(
      valid: res.isSuccessful,
      statusCode: res.statusCode,
      unsupportedAttributes: unsupported,
    );
  }
}
