import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/services/update_checker.dart';
import 'package:selfmusic/services/update_service.dart';

void main() {
  group('版本比较', () {
    test('按点分段数值比较，忽略 v 前缀与构建号', () {
      expect(compareVersions('1.0.3', '1.0.2'), greaterThan(0));
      expect(compareVersions('1.0.2', '1.0.3'), lessThan(0));
      expect(compareVersions('1.0.3', '1.0.3'), 0);
      expect(compareVersions('1.0.3+6', '1.0.3+5'), 0, reason: '构建号不参与');
      expect(compareVersions('v1.0.4', '1.0.3'), greaterThan(0));
      expect(compareVersions('1.0', '1.0.0'), 0, reason: '缺失段按 0 补齐');
      expect(compareVersions('1.0.10', '1.0.9'), greaterThan(0),
          reason: '不能按字符串比');
      expect(compareVersions('1.1.0-beta.1', '1.0.9'), greaterThan(0),
          reason: '预发布后缀不参与');
      expect(compareVersions('1.0.4+6', '1.0.4'), 0);
    });

    test('isNewerVersion 严格大于', () {
      expect(isNewerVersion('1.0.4', '1.0.3'), isTrue);
      expect(isNewerVersion('1.0.3', '1.0.3'), isFalse);
      expect(isNewerVersion('1.0.2', '1.0.3'), isFalse);
    });
  });

  group('发布解析', () {
    // 与 Gitea / GitHub releases 接口同字段结构（精简）。
    final sample = [
      {
        'tag_name': '1.0.2',
        'name': 'release_1.0.2+4',
        'body': '旧版本',
        'html_url': 'https://example.test/1.0.2',
        'draft': false,
        'prerelease': false,
        'assets': [
          {
            'name': 'SelfMusic_1.0.2_windows_x64_release.zip',
            'browser_download_url': 'https://example.test/win-1.0.2.zip',
          },
        ],
      },
      {
        'tag_name': '1.0.3',
        'name': 'release_1.0.3+5',
        'body': '### 修复\r\n1. 鸿蒙无法导出日志',
        'html_url': 'https://example.test/1.0.3',
        'draft': false,
        'prerelease': false,
        'assets': [
          {
            'name': 'SelfMusic_1.0.3_android_arm64_release.apk',
            'browser_download_url': 'https://example.test/android-arm64.apk',
          },
          {
            'name': 'SelfMusic_1.0.3_android_x64_release.apk',
            'browser_download_url': 'https://example.test/android-x64.apk',
          },
          {
            'name': 'SelfMusic_1.0.3_windows_x64_release.zip',
            'browser_download_url': 'https://example.test/win.zip',
          },
          {
            'name': 'SelfMusic_1.0.3_linux_x64_release.tar.gz',
            'browser_download_url': 'https://example.test/linux.tar.gz',
          },
          {
            'name': 'SelfMusic_1.0.3_ohos_arm64_release.app',
            'browser_download_url': 'https://example.test/ohos.app',
          },
        ],
      },
    ];

    test('取版本号最高的发布', () {
      final info = parseLatestRelease(sample)!;
      expect(info.tag, '1.0.3');
      expect(info.versionLabel, '1.0.3');
      expect(info.body, contains('鸿蒙'));
      expect(info.pageUrl, 'https://example.test/1.0.3');
      expect(info.assets, hasLength(5));
    });

    test('过滤草稿与预发布', () {
      final list = [
        ...sample,
        {
          'tag_name': '9.9.9',
          'draft': false,
          'prerelease': true,
          'assets': const [],
        },
        {
          'tag_name': '8.8.8',
          'draft': true,
          'prerelease': false,
          'assets': const [],
        },
      ];
      expect(parseLatestRelease(list)!.tag, '1.0.3');
    });

    test('JSON 字符串与异常结构', () {
      expect(parseLatestRelease(const []) , isNull);
      expect(parseLatestRelease(null), isNull);
      expect(parseLatestRelease('not json'), isNull);
      expect(parseLatestRelease({'message': 'Not Found'}), isNull);
      expect(parseLatestRelease('[]'), isNull);
    });
  });

  group('下载链接选择', () {
    List<ReleaseAsset> assetsOf(Map<String, String> byName) => [
          for (final e in byName.entries)
            ReleaseAsset(name: e.key, url: e.value),
        ];

    ReleaseInfo releaseWith(Map<String, String> byName) => ReleaseInfo(
          tag: '1.0.3',
          name: 'n',
          body: '',
          pageUrl: 'https://example.test/page',
          assets: assetsOf(byName),
        );

    test('按平台匹配资产', () {
      final release = releaseWith({
        'SelfMusic_1.0.3_windows_x64_release.zip': 'u-win',
        'SelfMusic_1.0.3_linux_x64_release.tar.gz': 'u-linux',
        'selfmusic_1.0.3_android_arm64_release.apk': 'u-android',
      });
      expect(selectDownloadUrl(release, platform: 'windows', abi: 'x64'),
          'u-win');
      expect(selectDownloadUrl(release, platform: 'linux', abi: 'x64'),
          'u-linux');
      expect(selectDownloadUrl(release, platform: 'android', abi: 'arm64'),
          'u-android');
    });

    test('同平台多 ABI 按架构细分', () {
      final release = releaseWith({
        'selfmusic_android_arm64_release.apk': 'u-arm64',
        'selfmusic_android_x64_release.apk': 'u-x64',
      });
      expect(selectDownloadUrl(release, platform: 'android', abi: 'arm64'),
          'u-arm64');
      expect(selectDownloadUrl(release, platform: 'android', abi: 'x64'),
          'u-x64');
      expect(selectDownloadUrl(release, platform: 'android', abi: 'mips'),
          'u-arm64', reason: '架构不明时取第一个平台匹配');
    });

    test('无平台匹配返回 null（调用方回退发布页）', () {
      final release = releaseWith({'selfmusic_1.0.3_android.apk': 'u'});
      expect(selectDownloadUrl(release, platform: 'windows', abi: 'x64'),
          isNull);
    });

    test('鸿蒙识别 .app / .hap / ohos', () {
      final release = releaseWith({
        'SelfMusic_1.0.3_ohos_arm64_release.app': 'u-app',
      });
      expect(selectDownloadUrl(release, platform: 'ohos', abi: 'arm64'),
          'u-app');
    });
  });

  group('延后天数', () {
    test('随机落在 3~7 天且覆盖端点', () {
      final seen = <int>{};
      final random = Random(7);
      for (var i = 0; i < 500; i++) {
        final days = pickSnoozeDays(random);
        expect(days, inInclusiveRange(kUpdateSnoozeMinDays, kUpdateSnoozeMaxDays));
        seen.add(days);
      }
      expect(seen, containsAll([3, 4, 5, 6, 7]));
    });
  });
}
