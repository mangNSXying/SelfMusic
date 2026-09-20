import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:sqlite3/open.dart';

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
  test('集合页展示形式与标题格式：默认值、持久化、备份白名单', () async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_settings_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();

    final s = AppSettings(index);
    expect(s.viewModePlaylists, CollectionViewMode.list);
    expect(s.viewModeSources, CollectionViewMode.card);
    expect(s.viewModeAlbums, CollectionViewMode.card);
    expect(s.viewModeArtists, CollectionViewMode.card);
    expect(s.songTitleFormat, SongTitleFormat.artistTitle);

    s.viewModePlaylists = CollectionViewMode.card;
    s.viewModeAlbums = CollectionViewMode.list;
    s.songTitleFormat = SongTitleFormat.titleArtist;

    // 重新读取（模拟重启）保持。
    final s2 = AppSettings(index);
    expect(s2.viewModePlaylists, CollectionViewMode.card);
    expect(s2.viewModeAlbums, CollectionViewMode.list);
    expect(s2.viewModeArtists, CollectionViewMode.card);
    expect(s2.songTitleFormat, SongTitleFormat.titleArtist);

    for (final k in [
      AppSettings.kSongTitleFormat,
      AppSettings.kViewModePlaylists,
      AppSettings.kViewModeSources,
      AppSettings.kViewModeAlbums,
      AppSettings.kViewModeArtists,
    ]) {
      expect(AppSettings.knownKeys, contains(k));
    }

    index.close();
    dir.deleteSync(recursive: true);
  });
}
