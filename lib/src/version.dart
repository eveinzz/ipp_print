/// 版本号单一真相源（0.7.2 治理收口）。
///
/// 背景：`pubspec.yaml` / 两个 podspec / User-Agent 曾各自手写版本串，
/// 同类漂移**已复发两次**（0.3.2 修 podspec 停在 0.2.0；0.7.1 修 UA
/// 停在 0.6）——根因是「发布时手改多处」，而非某一次疏忽。故规定：
///
/// - **对外声明的版本串只能来自本常量**（当前唯一消费点：User-Agent，
///   见 `ipp/ipp_client.dart`）；禁止就地再写一次字面量；
/// - 发布新版本仍然要改三处（`pubspec.yaml`、本文件、两个 podspec）——
///   闸**不消除手工步骤，只保证漂移必然被发现**：
///   1. `test/version_consistency_test.dart`（本地与 CI 都跑）；
///   2. `.github/workflows/ci.yml` 的 version-consistency 步骤（独立于
///      测试文件复核，测试被误改时仍能拦住）。
library;

/// 当前包版本，必须与 `pubspec.yaml` 的 `version:` 严格一致。
const String ippPrintVersion = '0.7.5';
