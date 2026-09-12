import 'dart:io';

import 'package:ipp_print/src/version.dart';
import 'package:test/test.dart';

/// 版本链一致性闸（0.7.2）。
///
/// 为什么需要闸：版本串此前在 `pubspec.yaml` / 两个 podspec / User-Agent
/// 四处各自手写，同类漂移**已复发两次**——0.3.2 修 podspec（停在 0.2.0）、
/// 0.7.1 修 UA（停在 0.6）。根因不是某次疏忽，而是「发布时手改多处」这一
/// 流程本身；故以自动化闸保证「漂移必然被发现」，而不是继续依赖自觉。
///
/// 第二道独立闸在 CI（`.github/workflows/ci.yml` 的 version-consistency
/// 步骤）：即使本文件被误改，CI 仍会拦住不一致的 podspec。
void main() {
  group('版本单一真相源（version.dart / pubspec / podspec ×2）', () {
    final pubspecVersion = _pubspecVersion();

    test('pubspec.yaml 的 version 可解析（闸前置条件）', () {
      expect(pubspecVersion, matches(RegExp(r'^\d+\.\d+\.\d+$')));
    });

    test('version.dart 常量 == pubspec.yaml version', () {
      expect(ippPrintVersion, pubspecVersion);
    });

    test('ios / macos podspec 的 s.version == pubspec version（历史漂移点）', () {
      for (final path in const [
        'ios/ipp_print.podspec',
        'macos/ipp_print.podspec',
      ]) {
        expect(_podspecVersion(path), pubspecVersion, reason: path);
      }
    });

    test('User-Agent 版本串派生自常量（禁止就地第二次手写）', () {
      final source = File('lib/src/ipp/ipp_client.dart').readAsStringSync();
      expect(source, contains(r'ipp_print/$ippPrintVersion'),
          reason: 'UA 必须引用 ippPrintVersion 常量');
      expect(RegExp(r"'ipp_print/\d").hasMatch(source), isFalse,
          reason: 'UA 不得硬编码版本字面量（历史漂移复发点）');
    });
  });
}

/// 读取 `pubspec.yaml` 的顶层 `version:`。
String _pubspecVersion() {
  final line = File('pubspec.yaml').readAsLinesSync().firstWhere(
      (l) => l.startsWith('version:'),
      orElse: () => fail('pubspec.yaml 缺少顶层 version:'));
  return line.substring('version:'.length).trim();
}

/// 读取 podspec 的 `s.version`。
String _podspecVersion(String path) {
  final match = RegExp(r"s\.version\s*=\s*'([^']+)'")
      .firstMatch(File(path).readAsStringSync());
  if (match == null) fail('$path: 未找到 s.version');
  return match.group(1)!;
}
