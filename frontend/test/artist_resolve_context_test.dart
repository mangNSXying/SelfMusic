import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/services/artist_resolver.dart';
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

Future<(LocalIndex, Directory)> _openIndex() async {
  open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
  final dir = await Directory.systemTemp.createTemp('selfmusic_artist_ctx_');
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final index = LocalIndex();
  await index.open();
  return (index, dir);
}

Future<void> _dispose(LocalIndex index, Directory dir) async {
  index.close();
  for (var i = 0; i < 20; i++) {
    try {
      if (!dir.existsSync()) return;
      dir.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      await Future<void>.delayed(Duration(milliseconds: 50 * (i + 1)));
    }
  }
}

DirectSongRow _song(String ref, String artist, {required String album}) =>
    DirectSongRow(
      sourceKey: 'local:test',
      ref: ref,
      title: '标题 $ref',
      artist: artist,
      album: album,
      duration: 100,
      format: 'mp3',
      size: 1024,
      mtime: 1,
    );

const _megPerson = '2b024651-7d45-48a8-b0db-4bfa2f0e435c';
const _megCharacter = '913a2bce-4db3-49d0-b296-a7c5f9648923';
const _murakawa = 'c1970887-9e13-4f24-aa87-d8cacc3b0690';

/// 2026-11-04 实测 musicbrainz.org 的搜索顺序与实体关系：
/// 同名 Person（さよならポニーテール）100 分排在角色（ご注文はうさぎですか?）98 分前面。
final Map<String, Map<String, dynamic>> _searchBodies = {
  'メグ': {
    'artists': [
      {
        'id': _megPerson,
        'type': 'Person',
        'score': 100,
        'name': 'メグ',
        'sort-name': 'メグ',
        'country': 'JP',
        'disambiguation': 'さよならポニーテール',
        'life-span': {'ended': null},
      },
      {
        'id': _megCharacter,
        'type': 'Character',
        'score': 98,
        'name': 'メグ',
        'sort-name': 'Megu',
        'country': 'JP',
        'disambiguation': 'ご注文はうさぎですか?',
        'life-span': {'ended': null},
      },
    ],
  },
  '村川梨衣': {
    'artists': [
      {
        'id': _murakawa,
        'type': 'Person',
        'score': 100,
        'name': '村川梨衣',
        'sort-name': 'むらかわ りえ',
        'country': 'JP',
        'life-span': {'ended': null},
      },
    ],
  },
};

final Map<String, Map<String, dynamic>> _entities = {
  _megPerson: {
    'id': _megPerson,
    'name': 'メグ',
    'type': 'Person',
    'sort-name': 'メグ',
    'disambiguation': 'さよならポニーテール',
    'aliases': <Object>[],
    'relations': [
      {
        'type': 'member of band',
        'direction': 'forward',
        'artist': {
          'name': 'メグとパトロン',
          'type': 'Group',
          'id': 'cb37b6b6-4b0d-48dd-8b39-a3651708b086',
        },
      },
    ],
  },
  _megCharacter: {
    'id': _megCharacter,
    'name': 'メグ',
    'type': 'Character',
    'sort-name': 'Megu',
    'disambiguation': 'ご注文はうさぎですか?',
    'aliases': <Object>[],
    'relations': [
      {
        'type': 'member of band',
        'direction': 'forward',
        'artist': {
          'name': 'チマメ隊',
          'type': 'Group',
          'id': '4e718f9e-1439-4268-8234-9456a214209a',
        },
      },
      {
        'type': 'voice actor',
        'direction': 'backward',
        'artist': {
          'name': '村川梨衣',
          'type': 'Person',
          'id': _murakawa,
        },
      },
    ],
  },
  _murakawa: {
    'id': _murakawa,
    'name': '村川梨衣',
    'type': 'Person',
    'sort-name': 'むらかわ りえ',
    'aliases': <Object>[],
    'relations': <Object>[],
  },
};

class _MegAdapter implements HttpClientAdapter {
  final List<Uri> calls = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    calls.add(options.uri);
    final path = options.uri.path;
    Map<String, dynamic> data;
    if (path.endsWith('/artist/')) {
      final q = options.uri.queryParameters['query'] ?? '';
      data = _searchBodies.entries
              .firstWhere((e) => q.contains(e.key),
                  orElse: () => const MapEntry('', {'artists': []}))
              .value;
    } else {
      final id = path.split('/').last;
      data = _entities[id] ?? {'artists': <Object>[]};
    }
    return ResponseBody.fromString(jsonEncode(data), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioOf(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://mb.test/ws/2'));
  dio.httpClientAdapter = adapter;
  return dio;
}

Future<void> _resolve(
    LocalIndex index, List<DirectSongRow> songs) async {
  await index.upsertSongs(songs);
  await index.reconcileArtists();
  final resolver = ArtistResolver(index, dio: _dioOf(_MegAdapter()));
  try {
    await resolver.runOnceNow();
  } finally {
    resolver.dispose();
  }
}

void main() {
  test('メグ：专辑名命中角色作品 → 解析为角色，歌手页只留声优', () async {
    final (index, dir) = await _openIndex();
    try {
      await _resolve(index, [
        _song('a', 'メグ',
            album: 'TVアニメ「ご注文はうさぎですか？」キャラクターソングアルバム'),
        _song('b', '村川梨衣', album: 'Rie Murakawa Best'),
      ]);

      final meg = index.artistRowByCanonical('メグ')!;
      expect(meg.mbid, _megCharacter);
      expect(meg.type, 'character');

      final names = index.identityArtistGroups().map((a) => a.name).toList();
      expect(names, isNot(contains('メグ')));
      expect(names, contains('村川梨衣'));
      // 角色名下的歌经 voice actor 边继承给声优（自己 1 首 + メグ 1 首）。
      final va = index.identityArtistGroups().firstWhere((a) => a.name == '村川梨衣');
      expect(va.songCount, 2);
    } finally {
      await _dispose(index, dir);
    }
  });

  test('メグ：专辑名命中真人消歧义串 → 仍选同名真人', () async {
    final (index, dir) = await _openIndex();
    try {
      await _resolve(index, [
        _song('a', 'メグ', album: 'さよならポニーテール 1stアルバム'),
        _song('b', '村川梨衣', album: 'Rie Murakawa Best'),
      ]);

      final meg = index.artistRowByCanonical('メグ')!;
      expect(meg.mbid, _megPerson);
      expect(meg.type, 'person');

      final names = index.identityArtistGroups().map((a) => a.name).toList();
      expect(names, containsAll(['メグ', '村川梨衣']));
    } finally {
      await _dispose(index, dir);
    }
  });

  test('メグ：专辑名对不上任何候选 → 回落首个可用候选', () async {
    final (index, dir) = await _openIndex();
    try {
      await _resolve(index, [
        _song('a', 'メグ', album: '某专辑'),
        _song('b', '村川梨衣', album: 'Rie Murakawa Best'),
      ]);

      final meg = index.artistRowByCanonical('メグ')!;
      expect(meg.mbid, _megPerson);
      final names = index.identityArtistGroups().map((a) => a.name).toList();
      expect(names, containsAll(['メグ', '村川梨衣']));
    } finally {
      await _dispose(index, dir);
    }
  });

  group('同名候选的专辑上下文匹配', () {
    const person = MbArtistHit(
        mbid: 'p',
        name: 'メグ',
        type: 'Person',
        disambiguation: 'さよならポニーテール');
    const character = MbArtistHit(
        mbid: 'c',
        name: 'メグ',
        type: 'Character',
        disambiguation: 'ご注文はうさぎですか?');

    test('全角 ？ / 空白 / 大小写不影响匹配', () {
      final pick = ArtistResolver.pickByAlbumContext(
          [person, character], ['TVアニメ「ご注文はうさぎですか？」 キャラクターソング']);
      expect(pick, character);
    });

    test('候选顺序不做优先：命中的那个胜出', () {
      expect(
          ArtistResolver.pickByAlbumContext(
              [person, character], ['さよならポニーテール']),
          person);
      expect(
          ArtistResolver.pickByAlbumContext(
              [character, person], ['さよならポニーテール']),
          person);
    });

    test('无 disambiguation / 无专辑 / 短串包含都不误命中', () {
      expect(ArtistResolver.pickByAlbumContext([person, character], const []),
          isNull);
      expect(
          ArtistResolver.pickByAlbumContext([
            const MbArtistHit(mbid: 'x', name: 'メグ', type: 'Person'),
          ], [
            '某专辑'
          ]),
          isNull);
      // `TV` 这种短串即使出现在专辑里也不能定向。
      expect(
          ArtistResolver.pickByAlbumContext([
            const MbArtistHit(
                mbid: 't', name: 'メグ', type: 'Person', disambiguation: 'TV'),
          ], [
            'TVアニメ サントラ'
          ]),
          isNull);
    });
  });
}
