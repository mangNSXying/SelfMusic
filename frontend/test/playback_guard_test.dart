import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/services/playback_guard.dart';

/// 静音暂停 / 断连暂停的守卫逻辑（settings.md §3.2，仅 Android）。
/// 平台信号以假 [AudioGuardPlatform] 注入，验证开关/播放态门控与订阅起停。

class _FakePlatform implements AudioGuardPlatform {
  final _controller = StreamController<AudioGuardEvent>.broadcast();
  int? volume = 5;

  @override
  Stream<AudioGuardEvent> get events => _controller.stream;

  @override
  Future<int?> get mediaVolume async => volume;

  void emit(AudioGuardEvent e) => _controller.add(e);

  Future<void> close() => _controller.close();
}

void main() {
  late _FakePlatform platform;
  var volumeOn = false;
  var disconnectOn = false;
  var playing = false;
  var pauses = 0;

  setUp(() {
    platform = _FakePlatform();
    volumeOn = false;
    disconnectOn = false;
    playing = false;
    pauses = 0;
  });

  tearDown(() => platform.close());

  PlaybackGuard make() => PlaybackGuard(
        platform: platform,
        volumePauseEnabled: () => volumeOn,
        disconnectPauseEnabled: () => disconnectOn,
        isPlaying: () => playing,
        onPause: () async {
          pauses++;
        },
      );

  test('音量归零 + 开关开 + 播放中 → 暂停一次', () async {
    volumeOn = true;
    playing = true;
    final g = make()..refresh();
    platform.emit(const AudioGuardEvent.volume(0));
    await pumpEventQueue();
    expect(pauses, 1);
    g.dispose();
  });

  test('音量非零不暂停', () async {
    volumeOn = true;
    playing = true;
    final g = make()..refresh();
    platform.emit(const AudioGuardEvent.volume(3));
    await pumpEventQueue();
    expect(pauses, 0);
    g.dispose();
  });

  test('开关关闭时音量归零不暂停', () async {
    volumeOn = false;
    playing = true;
    final g = make()..refresh();
    platform.emit(const AudioGuardEvent.volume(0));
    await pumpEventQueue();
    expect(pauses, 0);
    g.dispose();
  });

  test('未播放时音量归零不暂停', () async {
    volumeOn = true;
    playing = false;
    final g = make()..refresh();
    platform.emit(const AudioGuardEvent.volume(0));
    await pumpEventQueue();
    expect(pauses, 0);
    g.dispose();
  });

  test('断连 + 开关开 + 播放中 → 暂停一次', () async {
    disconnectOn = true;
    playing = true;
    final g = make()..refresh();
    platform.emit(const AudioGuardEvent.outputLost());
    await pumpEventQueue();
    expect(pauses, 1);
    g.dispose();
  });

  test('断连开关关闭时不暂停（即便静音开关开着）', () async {
    volumeOn = true;
    disconnectOn = false;
    playing = true;
    final g = make()..refresh();
    platform.emit(const AudioGuardEvent.outputLost());
    await pumpEventQueue();
    expect(pauses, 0);
    g.dispose();
  });

  test('订阅时音量已为 0 → 立即暂停', () async {
    volumeOn = true;
    playing = true;
    platform.volume = 0;
    final g = make()..refresh();
    await pumpEventQueue();
    expect(pauses, 1);
    g.dispose();
  });

  test('订阅时音量已为 0 但未播放 → 不暂停', () async {
    volumeOn = true;
    playing = false;
    platform.volume = 0;
    final g = make()..refresh();
    await pumpEventQueue();
    expect(pauses, 0);
    g.dispose();
  });

  test('两个开关全关后取消订阅，后续事件不再触发', () async {
    volumeOn = true;
    playing = true;
    final g = make()..refresh();
    platform.emit(const AudioGuardEvent.volume(0));
    await pumpEventQueue();
    expect(pauses, 1);

    volumeOn = false;
    g.refresh();
    platform.emit(const AudioGuardEvent.volume(0));
    await pumpEventQueue();
    expect(pauses, 1, reason: '已取消订阅，事件不应再触发暂停');
    g.dispose();
  });

  test('dispose 后事件不再触发', () async {
    volumeOn = true;
    playing = true;
    final g = make()..refresh();
    g.dispose();
    platform.emit(const AudioGuardEvent.volume(0));
    await pumpEventQueue();
    expect(pauses, 0);
  });
}
