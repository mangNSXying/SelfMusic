import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/services/online_meta/online_meta_models.dart';
import 'package:selfmusic/widgets/online_meta_detail_dialog.dart';

/// 1×1 透明 PNG（字节是否可解码不影响断言，Image widget 仍会挂载）。
const List<int> _k1x1Png = [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, //
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, //
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, //
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, //
  0x42, 0x60, 0x82,
];

OnlineLyricCandidate _cand({String? synced, String? plain}) =>
    OnlineLyricCandidate(
      onlineId: '1',
      source: OnlineMetaSource.qq,
      trackName: '发如雪',
      artistName: '周杰伦',
      albumName: '十一月的萧邦',
      durationSec: 302,
      syncedLyrics: synced,
      plainLyrics: plain,
      matchWeight: 0.9,
    );

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  testWidgets('歌词详情：懒取正文、逐行展示、回填回调', (tester) async {
    OnlineLyricCandidate? backfilled;
    var calls = 0;
    await tester.pumpWidget(_host(LyricDetailDialog(
      candidate: _cand(),
      isBest: true,
      ensure: (c) async {
        calls++;
        return c.withLyrics(syncedLyrics: '[00:01.00]第一行\n[00:02.00]第二行\n');
      },
      onLoaded: (full) => backfilled = full,
    )));
    await tester.pumpAndSettle();

    expect(calls, 1);
    final body = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(body.data, contains('第一行'));
    expect(body.data, contains('第二行'));
    expect(body.data, isNot(contains('[00:01.00]'))); // 已解析去时间轴
    expect(backfilled, isNotNull);
    expect(backfilled!.hasContent, isTrue);
  });

  testWidgets('歌词详情：已有正文不再取词', (tester) async {
    var calls = 0;
    await tester.pumpWidget(_host(LyricDetailDialog(
      candidate: _cand(synced: '[00:01.00]现成的词\n'),
      ensure: (c) async {
        calls++;
        return c;
      },
    )));
    await tester.pumpAndSettle();

    expect(calls, 0);
    final body = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(body.data, contains('现成的词'));
  });

  testWidgets('歌词详情：取词失败显示错误，重试成功', (tester) async {
    var fail = true;
    await tester.pumpWidget(_host(LyricDetailDialog(
      candidate: _cand(),
      ensure: (c) async {
        if (fail) throw StateError('boom');
        return c.withLyrics(plainLyrics: '恢复的正文');
      },
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining('取词失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    final body = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(body.data, contains('恢复的正文'));
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('封面详情：已缓存直接展示，不再取图', (tester) async {
    var loads = 0;
    await tester.pumpWidget(_host(CoverDetailDialog(
      header: '发如雪 — 周杰伦',
      metaLines: const ['来源 MB→CAA'],
      initialBytes: Uint8List.fromList(_k1x1Png),
      initialLabel: 'Front 1200px',
      load: () async {
        loads++;
        return null;
      },
    )));
    await tester.pumpAndSettle();

    expect(loads, 0);
    expect(find.byType(Image), findsOneWidget);
    expect(find.textContaining('Front 1200px'), findsOneWidget);
  });

  testWidgets('封面详情：懒取成功回调缓存', (tester) async {
    Uint8List? got;
    String? gotLabel;
    final bytes = Uint8List.fromList(_k1x1Png);
    await tester.pumpWidget(_host(CoverDetailDialog(
      header: 'h',
      metaLines: const [],
      load: () async => (bytes: bytes, label: 'Front 1200px'),
      onLoaded: (b, l) {
        got = b;
        gotLabel = l;
      },
    )));
    await tester.pumpAndSettle();

    expect(got, isNotNull);
    expect(gotLabel, 'Front 1200px');
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('封面详情：无图提示', (tester) async {
    await tester.pumpWidget(_host(CoverDetailDialog(
      header: 'h',
      metaLines: const [],
      load: () async => null,
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining('无封面'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('标签详情：展示来源与标题/歌手/专辑', (tester) async {
    await tester.pumpWidget(_host(const TagDetailDialog(
      source: OnlineMetaSource.qq,
      title: '发如雪',
      artist: '周杰伦',
      album: '十一月的萧邦',
      metaLines: ['匹配 0.93 · 最佳匹配'],
    )));
    await tester.pumpAndSettle();

    expect(find.text('标签详情'), findsOneWidget);
    expect(find.textContaining('来源 QQ音乐'), findsOneWidget);
    expect(find.text('发如雪'), findsOneWidget);
    expect(find.text('周杰伦'), findsOneWidget);
    expect(find.text('十一月的萧邦'), findsOneWidget);
    expect(find.text('匹配 0.93 · 最佳匹配'), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
  });

  testWidgets('标签详情：在线空值提示不覆盖本地', (tester) async {
    await tester.pumpWidget(_host(const TagDetailDialog(
      source: OnlineMetaSource.mbCaa,
      title: '只有标题',
      artist: '',
      album: '',
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining('（在线为空，不覆盖本地）'), findsNWidgets(2));
  });
}
