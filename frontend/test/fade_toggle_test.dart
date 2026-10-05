import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:sqlite3/open.dart';

/// 播放/暂停按钮即时响应（US1）：
/// - 点击后 `provider.playing`（目标态）立即翻转，实际态（`provider.player.playing`）
///   延迟到淡出完成后才翻转；
/// - 淡入淡出关闭时点击立即直切（目标态与实际态同步翻转，同现状）。
///
/// 沿用仓库「真实实例」模式（见 player_audio_config_test.dart）：真实 LocalIndex
/// （sqlite3 open.overrideFor）+ 真实 AudioPlayer（play/pause/setVolume 的平台调用
/// 异常由 provider 侧静默守卫兜住）+ testWidgets FakeAsync（tester.pump 推进
/// 16ms tick 与渐变时长）。

DynamicLibrary _openOnLinux() {
  try {
    return DynamicLibrary.open('libsqlite3.so');
  } on ArgumentError {
    return DynamicLibrary.open('libsqlite3.so.0');
  }
}

class _FakePathProvider extends PathProviderPlatform {
  final String dir;
  _FakePathProvider(this.dir);
  @override
  Future<String> getApplicationSupportPath() async => dir;
  @override
  Future<String> getApplicationCachePath() async => dir;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late LocalIndex index;

  setUp(() async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    dir = await Directory.systemTemp.createTemp('selfmusic_fadetgl_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    index = LocalIndex();
    await index.open();
  });

  tearDown(() {
    // 必须保持同步：tearDown 运行在 FakeAsync zone 里，任何真实 await
    // （如 Future.delayed）都不会被推进，测试会挂死。Windows 上写隔离
    // isolate 的 kill 异步生效、句柄释放略滞后于 close()：删除失败
    // （errno=32）时静默留给系统临时目录清理，不让清理噪音污染测试结果。
    index.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  PlayerProvider makeProvider({required bool fade, int durationMs = 500}) {
    final settings = AppSettings(index)
      ..fadeEnabled = fade
      ..fadeDurationMs = durationMs;
    final p = PlayerProvider();
    p.attachAppSettings(settings);
    addTearDown(p.dispose);
    return p;
  }

  /// 把真实 AudioPlayer 置为「播放中」。不 await play()：其平台往返在
  /// FakeAsync 下可能挂住，而 just_audio 的本地 playing 标志在 play() 的
  /// 同步段已置位——发起后由随后的 pump 冲刷平台异常（实现侧静默兜住）。
  void startPlaying(PlayerProvider p) {
    try {
      unawaited(p.player.play());
    } catch (_) {}
  }

  testWidgets('淡入淡出开（500ms）点击暂停：目标态立即翻转，实际态延迟到淡出完成',
      (tester) async {
    final p = makeProvider(fade: true, durationMs: 500);
    startPlaying(p);
    expect(p.player.playing, isTrue, reason: '前置：底层处于实际播放态');
    expect(p.playing, isTrue, reason: '前置：目标态为播放中');

    unawaited(p.toggle());
    await tester.pump();
    expect(p.playing, isFalse, reason: 'US1：目标态一帧内翻转为「已暂停」');
    expect(p.player.playing, isTrue, reason: '实际态在淡出完成前仍播放');

    // 推进淡出全程（500ms ≈ 32 个 16ms tick）+ 完成回调余量。
    await tester.pump(const Duration(milliseconds: 600));
    expect(p.player.playing, isFalse, reason: '淡出完成后实际暂停');
    expect(p.playing, isFalse, reason: '目标态保持「已暂停」');
    // 淡出完成：音量已复位，供下次归零淡入。
    expect(p.player.volume, 1.0);
  });

  testWidgets('淡入淡出关：点击立即直切，目标态与实际态同步翻转', (tester) async {
    final p = makeProvider(fade: false);
    startPlaying(p);
    expect(p.player.playing, isTrue, reason: '前置：底层处于实际播放态');
    expect(p.playing, isTrue);

    unawaited(p.toggle());
    await tester.pump();
    expect(p.playing, isFalse, reason: '目标态立即翻转');
    expect(p.player.playing, isFalse, reason: '无渐变：实际态同步暂停');
    expect(p.player.volume, 1.0, reason: '无渐变：不产生音量残留');
  });

  testWidgets('淡出中再点播放：反向打断——目标态立即回 true，引擎从未暂停，音量从当前值回升',
      (tester) async {
    final p = makeProvider(fade: true, durationMs: 500);
    startPlaying(p);
    expect(p.player.playing, isTrue, reason: '前置：底层处于实际播放态');

    // 第一次点击：暂停，进入淡出。
    unawaited(p.toggle());
    await tester.pump();
    expect(p.playing, isFalse, reason: '前置：目标态已翻转为暂停');

    // 推进到淡出中段（250ms / 500ms），音量约 0.5。
    await tester.pump(const Duration(milliseconds: 250));
    final midVolume = p.player.volume;
    expect(midVolume, lessThan(1.0), reason: '前置：淡出进行中，音量已下降');
    expect(midVolume, greaterThan(0.0));

    // 反向打断：再点一次（播放）。
    unawaited(p.toggle());
    await tester.pump();
    expect(p.playing, isTrue, reason: 'US2：目标态立即回「播放中」');
    expect(p.player.playing, isTrue, reason: '引擎从未实际暂停');
    // 打断瞬间无音量跳变：从当前值回升，而非归零重启/预设复位。
    expect(p.player.volume, midVolume, reason: '打断瞬间音量无跳变');

    // 推进回升全程：音量平滑回到 1.0，播放持续。
    await tester.pump(const Duration(milliseconds: 700));
    expect(p.player.volume, 1.0, reason: '音量从当前值平滑回升至正常');
    expect(p.player.playing, isTrue);
    expect(p.playing, isTrue);
  });

  testWidgets('淡入中再点暂停：从当前音量淡出后实际暂停', (tester) async {
    final p = makeProvider(fade: true, durationMs: 500);
    expect(p.player.playing, isFalse, reason: '前置：初始为实际暂停态');

    // 第一次点击：播放（归零后淡入）。
    unawaited(p.toggle());
    await tester.pump();
    expect(p.playing, isTrue, reason: '前置：目标态立即为播放中');
    expect(p.player.playing, isTrue, reason: '前置：底层 play 已发起');

    // 推进到淡入中段（250ms / 500ms），音量约 0.5。
    await tester.pump(const Duration(milliseconds: 250));
    final midVolume = p.player.volume;
    expect(midVolume, greaterThan(0.0), reason: '前置：淡入进行中，音量已上升');
    expect(midVolume, lessThan(1.0));

    // 淡入中再点暂停：目标态立即翻转，音量从当前值淡出。
    unawaited(p.toggle());
    await tester.pump();
    expect(p.playing, isFalse, reason: 'US2：目标态立即翻转为「已暂停」');
    expect(p.player.playing, isTrue, reason: '淡出完成前实际仍播放');
    expect(p.player.volume, midVolume, reason: '打断瞬间从当前音量淡出，无跳变');

    // 推进淡出全程：实际暂停 + 音量复位。
    await tester.pump(const Duration(milliseconds: 700));
    expect(p.player.playing, isFalse, reason: '从当前音量淡出后实际暂停');
    expect(p.player.volume, 1.0, reason: '淡出完成后音量复位');
    expect(p.playing, isFalse);
  });

  testWidgets('快速交替点击：每次点击都响应，最终状态与点击次数奇偶一致', (tester) async {
    final p = makeProvider(fade: true, durationMs: 2000);
    startPlaying(p);
    expect(p.player.playing, isTrue, reason: '前置：底层处于实际播放态');
    expect(p.playing, isTrue);

    // 4 次交替点击，间隔 200ms（全部落在 2s 渐变窗口内）。
    // 点 1：暂停。
    unawaited(p.toggle());
    await tester.pump();
    expect(p.playing, isFalse, reason: '第 1 次点击：目标态翻转为暂停');

    // 点 2（淡出 200ms 处）：恢复。
    await tester.pump(const Duration(milliseconds: 200));
    unawaited(p.toggle());
    await tester.pump();
    expect(p.playing, isTrue, reason: '第 2 次点击：目标态回播放中');

    // 点 3（淡入 200ms 处）：暂停。
    await tester.pump(const Duration(milliseconds: 200));
    unawaited(p.toggle());
    await tester.pump();
    expect(p.playing, isFalse, reason: '第 3 次点击：目标态翻转为暂停');

    // 点 4（淡出 200ms 处）：恢复。
    await tester.pump(const Duration(milliseconds: 200));
    unawaited(p.toggle());
    await tester.pump();
    expect(p.playing, isTrue, reason: '第 4 次点击：目标态回播放中');

    // 全程 4 次点击均在渐变窗口内反向打断：底层引擎从未实际暂停。
    expect(p.player.playing, isTrue, reason: '引擎从未暂停（连续播放）');

    // 让最后的淡入走完：音量回到 1.0，状态稳定。
    await tester.pump(const Duration(seconds: 3));
    expect(p.playing, isTrue, reason: '偶数次点击：最终为播放中');
    expect(p.player.playing, isTrue);
    expect(p.player.volume, 1.0);
  });
}
