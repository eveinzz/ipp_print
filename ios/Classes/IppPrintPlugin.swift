import Flutter
import UIKit

/// ipp_print 原生 Bonjour 发现（iOS）。
///
/// 用 NSNetServiceBrowser（mDNSResponder 系统守护进程代收组播，
/// 豁免组播 entitlement，仅需标准「本地网络」授权），返回已解析的
/// 名称/地址/端口/TXT，供 Dart 侧组装 DiscoveredPrinter。
public class IppPrintPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "ipp_print/bonjour", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(IppPrintPlugin(), channel: channel)
  }

  private var job: DiscoverJob?

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "discover":
      guard let args = call.arguments as? [String: Any],
            let types = args["serviceTypes"] as? [String] else {
        result(FlutterError(code: "bad_args", message: "serviceTypes required", details: nil))
        return
      }
      let timeoutMs = args["timeoutMs"] as? Int ?? 5000
      // 串行化：新发现开始前结束上一个任务，避免浏览器资源叠加。
      job?.finish()
      let j = DiscoverJob(types: types, timeoutMs: timeoutMs, result: result)
      job = j
      j.start()
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// 单次发现任务：浏览 → 逐台解析 → 超时汇聚回 Dart（发现层不抛错）。
final class DiscoverJob: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
  private let types: [String]
  private let timeoutMs: Int
  private let result: FlutterResult
  private var browsers: [NetServiceBrowser] = []
  private var resolved: [[String: Any]] = []
  private var finished = false

  init(types: [String], timeoutMs: Int, result: @escaping FlutterResult) {
    self.types = types
    self.timeoutMs = timeoutMs
    self.result = result
  }

  func start() {
    for rawType in types {
      let type = rawType.hasSuffix(".") ? rawType : rawType + "."
      let browser = NetServiceBrowser()
      browser.delegate = self
      browser.search(forServicesOfType: type, inDomain: "local.")
      browsers.append(browser)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) { [weak self] in
      self?.finish()
    }
  }

  /// 停止浏览并回传当前已汇聚结果；幂等（finish 后回调全部丢弃）。
  func finish() {
    guard !finished else { return }
    finished = true
    browsers.forEach { $0.stop() }
    result(resolved)
  }

  // MARK: - NetServiceBrowserDelegate

  func netServiceBrowser(_ browser: NetServiceBrowser,
                         didFind service: NetService,
                         moreComing: Bool) {
    guard !finished else { return }
    let secure = isSecureBrowser(browser)
    objc_setAssociatedObject(service, &kSecureKey, secure, .OBJC_ASSOCIATION_RETAIN)
    service.delegate = self
    service.resolve(withTimeout: min(5.0, Double(timeoutMs) / 1000.0))
  }

  private func isSecureBrowser(_ browser: NetServiceBrowser) -> Bool {
    guard let idx = browsers.firstIndex(of: browser), idx < types.count else { return false }
    return types[idx].hasPrefix("_ipps")
  }

  // MARK: - NetServiceDelegate

  func netServiceDidResolveAddress(_ sender: NetService) {
    guard !finished else { return }
    let secure = (objc_getAssociatedObject(sender, &kSecureKey) as? Bool) ?? false
    var item: [String: Any] = [
      "name": sender.name,
      "port": Int(sender.port),
      "secure": secure,
    ]
    item["host"] = Self.ipv4(from: sender.addresses ?? []) ?? sender.hostName ?? ""
    if let txtData = sender.txtRecordData() {
      let dict = NetService.dictionary(fromTXTRecord: txtData)
      var txt: [String: String] = [:]
      for (k, v) in dict {
        txt[k] = String(data: v, encoding: .utf8) ?? ""
      }
      item["txt"] = txt
      if let rp = txt["rp"] { item["rp"] = rp }
      if let uuid = txt["uuid"] { item["uuid"] = uuid }
    }
    resolved.append(item)
  }

  func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
    // 解析失败：跳过该实例，不回错误（发现层不抛错约定）。
  }

  /// sockaddr 数据数组 → 首个 IPv4 点分串；无则 nil（Dart 回退主机名）。
  private static func ipv4(from addresses: [Data]) -> String? {
    for data in addresses {
      let bytes = [UInt8](data)
      // struct sockaddr: sa_len(1) sa_family(1) ... IPv4: len=16, AF_INET=2
      if bytes.count >= 8, bytes[1] == 2 {
        return bytes[4...7].map { String($0) }.joined(separator: ".")
      }
    }
    return nil
  }
}

private var kSecureKey: UInt8 = 0
