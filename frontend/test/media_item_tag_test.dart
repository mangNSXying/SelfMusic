import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:selfmusic/services/selfmusic_audio_handler.dart';

/// Android 通知栏元数据（settings.md §3.6）。
///
/// 迁移到 just_audio_background 后，通知栏不再由自研 handler 主动回推，而是由它在
/// `setAudioSource` 时从**每个播放源的 tag** 里读。因此 tag 的 `id` 唯一、非空，
/// 字段与自研 handler 一致，是两条通知栏路径不漂移的唯一保证。

Song _song({
  String title = '夜曲',
  String? album = '十一月的萧邦',
  String? artist = '周杰伦',
  String? coverPath = '/data/cover/1.jpg',
}) =>
    Song(
      id: 0,
      sourceKey: 'webdav:nas',
      title: title,
      albumName: album,
      artist: artist,
      coverPath: coverPath,
      source: 'webdav',
      sourceRef: 'music/01.mp3',
      fileSize: 4096,
    );

void main() {
  test('mediaItemOf：字段齐备且 id 唯一', () {
    final a = PlayerProvider.mediaItemOf(_song());
    final b = PlayerProvider.mediaItemOf(_song(title: '退后'));

    expect(a.id, 'webdav:nas:music/01.mp3');
    expect(a.title, '夜曲');
    expect(a.album, '十一月的萧邦');
    expect(a.artist, '周杰伦');
    expect(a.artUri, Uri.file('/data/cover/1.jpg'));

    // 同一首歌不同标题：id 必须一致（通知栏按 id 认同一首歌，不能换歌就变 id）。
    expect(b.id, a.id);
    expect(b.title, '退后');
  });

  test('mediaItemOf：缺元数据时不至于空标题（通知栏空行）', () {
    final item = PlayerProvider.mediaItemOf(
        _song(title: '', album: null, artist: null, coverPath: null));
    expect(item.title, '未知曲目');
    expect(item.album, isNull);
    expect(item.artUri, isNull);
  });

  test('mediaItemOf：不同歌曲的 id 不相同', () {
    final one = PlayerProvider.mediaItemOf(_song());
    final two = PlayerProvider.mediaItemOf(Song(
      id: 0,
      sourceKey: 'webdav:nas',
      title: '夜曲',
      source: 'webdav',
      sourceRef: 'music/02.mp3',
      fileSize: 4096,
    ));
    expect(one.id, isNot(two.id));
  });

  test('自研 handler 回推的 MediaItem 与 tag 构造同源', () {
    // 两条通知栏路径（Android 包 / 桌面自研 handler）必须给同一条歌同一个 id，
    // 否则切换路径时媒体会话会认成另一首歌。
    final s = _song();
    expect(PlayerProvider.mediaItemOf(s).id, '${s.sourceKey}:${s.sourceRef}');
  });

  test('MediaItem 可作为 tag 传给播放源（just_audio_background 的读取入口）', () {
    // 形状校验：tag 类型必须是 MediaItem，包内部会强转（否则运行期崩）。
    final MediaItem tag = PlayerProvider.mediaItemOf(_song());
    expect(tag, isA<MediaItem>());
    expect(tag.id, isNotEmpty);
    expect(SelfMusicAudioHandler, isNotNull);
  });
}
