import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/player_provider.dart';

/// 下一首预热（改进.txt：切后台后还能播一两首，播完静默停住）。
///
/// ee15375 让装载失败不再静默（退避重试 / 跳下一首 / 收尾），但切歌那一刻仍要
/// 等一次冷启动请求：DNS + TCP + TLS + 鉴权全在关键路径上，后台又容易被 Doze /
/// 应用待机限流拖到超时。预热把这次请求提前到本曲播放期间，失败还有时间重试。

Song _song(String ref) => Song(
      id: 0,
      sourceKey: 'webdav:d',
      title: '歌$ref',
      source: 'webdav',
      sourceRef: ref,
      fileSize: 1024,
    );

class _FakeSource extends MusicSource {
  _FakeSource({this.cached = false});

  /// 假装已离线缓存（走本地文件，无需预热）。
  final bool cached;

  @override
  String get key => 'webdav:d';
  @override
  String get name => 'd';
  @override
  SourceKind get kind => SourceKind.webdav;

  @override
  Future<String?> cachedFilePath(Song song) async =>
      cached ? '/tmp/a.mp3' : null;
}

void main() {
  // AudioPlayer 构造时会碰 audio_session 的 MethodChannel，需要 binding。
  TestWidgetsFlutterBinding.ensureInitialized();

  final savedDelay = PlayerProvider.warmRetryDelay;
  setUp(() => PlayerProvider.warmRetryDelay = Duration.zero);
  tearDown(() => PlayerProvider.warmRetryDelay = savedDelay);

  test('预热成功：走 probe 一次，重复调用被 TTL 挡下', () async {
    final p = PlayerProvider();
    var probes = 0;
    p.probeOverride = (s, src) async => probes++;

    await p.debugWarmNext(_song('a'), _FakeSource());
    expect(probes, 1);

    // TTL 内同一首不再重复握手。
    await p.debugWarmNext(_song('a'), _FakeSource());
    expect(probes, 1);

    p.dispose();
  });

  test('预热失败：按 warmRetryDelay 退避重试，达上限后放弃', () {
    fakeAsync((async) {
      final p = PlayerProvider();
      var probes = 0;
      p.probeOverride = (s, src) async {
        probes++;
        throw PlayerException(1003, 'Source error', {'code': 'timeout'});
      };

      p.debugWarmNext(_song('b'), _FakeSource());
      async.flushMicrotasks();
      expect(probes, 1);

      // 退避定时器到点后重试：首次 + 上限内的重试 = 3 次，之后放弃
      //（间隔置零，一次 elapse 足以排空整条重试链）。
      async.elapse(PlayerProvider.warmRetryDelay);
      async.flushMicrotasks();
      expect(probes, 3);

      // 用尽上限后不再排新的重试（否则会无限重试打源）。
      async.elapse(const Duration(seconds: 300));
      async.flushMicrotasks();
      expect(probes, 3);

      p.dispose();
    });
  });

  test('预热不阻塞：预热失败不影响任何返回值（void）', () async {
    final p = PlayerProvider();
    p.probeOverride = (s, src) async => throw StateError('源不可达');
    // 不抛：预热失败只是「没预热成」，装载重试才是真正的兜底。
    await expectLater(p.debugWarmNext(_song('c'), _FakeSource()), completes);
    p.dispose();
  });

  test('已缓存的曲目不预热（走本地文件，没有连接可打通）', () async {
    final p = PlayerProvider();
    var probes = 0;
    p.probeOverride = (s, src) async => probes++;

    await p.debugWarmNext(_song('d'), _FakeSource(cached: true));
    expect(probes, 0);

    p.dispose();
  });
}
