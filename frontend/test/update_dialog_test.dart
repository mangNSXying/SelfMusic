import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/services/update_checker.dart';
import 'package:selfmusic/services/update_service.dart';
import 'package:selfmusic/widgets/update_dialog.dart';

ReleaseInfo _release(String tag) => ReleaseInfo(
      tag: tag,
      name: 'release_$tag',
      body: '### 修复\r\n1. 播放页偶发卡顿',
      pageUrl: 'https://example.test/$tag',
      assets: [
        ReleaseAsset(
          name: 'SelfMusic_${tag}_windows_x64_release.zip',
          url: 'https://example.test/win.zip',
        ),
      ],
    );

void main() {
  Future<void> pumpDialog(
    WidgetTester tester, {
    required ReleaseInfo release,
    required void Function(UpdateDialogResult) onResult,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                final r = await showUpdateDialog(
                  context,
                  release: release,
                  currentVersion: '1.0.4',
                );
                onResult(r);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('弹窗展示版本号、当前版本与更新内容', (tester) async {
    UpdateDialogResult? result;
    await pumpDialog(tester,
        release: _release('1.0.5'), onResult: (r) => result = r);

    expect(find.text('发现新版本 1.0.5'), findsOneWidget);
    expect(find.text('当前版本 1.0.4'), findsOneWidget);
    expect(find.textContaining('播放页偶发卡顿'), findsOneWidget);

    // 四个按钮齐全。
    expect(find.widgetWithText(TextButton, '取消'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '之后提醒'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '不再提醒'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '更新'), findsOneWidget);
    expect(result, isNull);
  });

  testWidgets('点各按钮返回对应结果', (tester) async {
    for (final (label, expected) in [
      ('取消', UpdateDialogResult.dismiss),
      ('之后提醒', UpdateDialogResult.snooze),
      ('不再提醒', UpdateDialogResult.skipVersion),
      ('更新', UpdateDialogResult.openDownload),
    ]) {
      UpdateDialogResult? result;
      await pumpDialog(tester,
          release: _release('1.0.5'), onResult: (r) => result = r);
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(result, expected, reason: '按钮「$label」');
    }
  });

  testWidgets('无更新说明时展示占位文案', (tester) async {
    await pumpDialog(
      tester,
      release: const ReleaseInfo(
        tag: '1.0.5',
        name: 'n',
        body: '  ',
        pageUrl: 'https://example.test',
        assets: [],
      ),
      onResult: (_) {},
    );
    expect(find.text('该版本未提供更新说明。'), findsOneWidget);
  });

  group('提醒判定', () {
    final now = DateTime(2026, 11, 24);

    bool allowed({
      String tag = '1.0.5',
      String current = '1.0.4',
      DateTime? snoozeUntil,
      String snoozeVersion = '',
      String skipVersion = '',
      bool manual = false,
    }) =>
        shouldPromptForUpdate(
          releaseTag: tag,
          currentVersion: current,
          now: now,
          snoozeUntil: snoozeUntil,
          snoozeVersion: snoozeVersion,
          skipVersion: skipVersion,
          manual: manual,
        );

    test('版本不新 → 不提醒', () {
      expect(allowed(tag: '1.0.4'), isFalse);
      expect(allowed(tag: '1.0.3'), isFalse);
      expect(allowed(tag: '1.0.5'), isTrue);
    });

    test('延后未到期静默，到期后提醒', () {
      expect(allowed(snoozeUntil: DateTime(2026, 12, 1)), isFalse);
      expect(allowed(snoozeUntil: DateTime(2026, 11, 1)), isTrue);
    });

    test('延后只压住当时的版本，更高版本照常提醒', () {
      expect(
        allowed(snoozeUntil: DateTime(2026, 12, 1), snoozeVersion: '1.0.5'),
        isFalse,
      );
      expect(
        allowed(
          tag: '1.0.6',
          snoozeUntil: DateTime(2026, 12, 1),
          snoozeVersion: '1.0.5',
        ),
        isTrue,
      );
    });

    test('忽略当前版本静默，更高版本仍提醒', () {
      expect(allowed(skipVersion: '1.0.5'), isFalse);
      expect(allowed(skipVersion: '1.0.4'), isTrue, reason: '忽略的是旧版本号');
    });

    test('手动检查无视延后与忽略', () {
      expect(
        allowed(
          manual: true,
          snoozeUntil: DateTime(2099, 1, 1),
          skipVersion: '1.0.5',
        ),
        isTrue,
      );
    });

    test('手动检查也不提醒「没有更新」', () {
      expect(allowed(manual: true, tag: '1.0.4'), isFalse);
    });
  });
}
