import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/local/play_meta_sql.dart';
import 'package:selfmusic/data/local/schema.dart';
import 'package:selfmusic/data/local/sql_columns.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

DynamicLibrary _openOnLinux() {
  try {
    return DynamicLibrary.open('libsqlite3.so');
  } on ArgumentError {
    return DynamicLibrary.open('libsqlite3.so.0');
  }
}

Set<String> _columns(Database db, String table) {
  final rs = db.select('PRAGMA table_info($table)');
  return {for (final r in rs) r['name'] as String};
}

List<String> _splitColumns(String value) => value
    .split(',')
    .map((e) => e.trim())
    .where((e) => e.isNotEmpty)
    .toList(growable: false);

void main() {
  late Database db;

  setUp(() {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    db = sqlite3.openInMemory();
    applySchema(db);
  });
  tearDown(() => db.dispose());

  test('歌曲 SELECT 引用的列都存在于 idx_songs', () {
    final columns = _columns(db, 'idx_songs');
    final referenced = RegExp(r'\bi\.([a-z_]+)')
        .allMatches(kSongSelectColumns)
        .map((m) => m.group(1)!);
    expect(referenced, isNotEmpty);
    for (final c in referenced) {
      expect(columns, contains(c), reason: 'idx_songs.$c');
    }
  });

  test('固定列清单都能在 schema 中找到', () {
    final playMeta = _columns(db, 'play_meta');
    for (final c in _splitColumns(kPlayMetaColumns)) {
      expect(playMeta, contains(c), reason: 'play_meta.$c');
    }
    final items = _columns(db, 'playlist_items');
    for (final c in _splitColumns(kPlaylistItemColumns)) {
      expect(items, contains(c), reason: 'playlist_items.$c');
    }
    for (final c in _splitColumns(kPlaylistItemInsertColumns)) {
      expect(items, contains(c), reason: 'playlist_items.$c');
    }
    final mirror = _columns(db, 'breakpoint_mirror');
    for (final c in _splitColumns(kBreakpointMirrorColumns)) {
      expect(mirror, contains(c), reason: 'breakpoint_mirror.$c');
    }
  });

  test('INSERT 占位符数量与列数一致', () {
    expect(_splitColumns(kPlayMetaColumns).length, 10);
    expect(kPlaylistItemInsertColumns.split(',').length, 10);
    expect('?'.allMatches(kPlaylistItemInsertSql).length, 10);
    expect('?'.allMatches(kPlaylistItemInsertIgnoreSql).length, 10);

    final mirrorCols = _splitColumns(kBreakpointMirrorColumns);
    expect(mirrorCols.length, 17);
    expect('?'.allMatches(kBreakpointMirrorV2UpsertSql).length, 17);
    expect('?'.allMatches(kBreakpointMirrorV1UpsertSql).length, 10);
  });

  test('play_meta 增量/掩码 upsert 只改指定列', () {
    upsertPlayMetaRow(db, PlayMetaRow.empty('webdav:test', 'a.mp3'),
        update: PlayMetaField.values.toSet());
    var row = readPlayMetaOrDefault(db, 'webdav:test', 'a.mp3');
    expect(row.factor, 1.0);
    expect(row.playSec, 0);

    upsertPlayMetaRow(db, row, update: {PlayMetaField.playSec}, addPlaySec: 5);
    expect(readPlayMetaOrDefault(db, 'webdav:test', 'a.mp3').playSec, 5);
    upsertPlayMetaRow(db, readPlayMetaOrDefault(db, 'webdav:test', 'a.mp3'),
        update: {PlayMetaField.playSec}, addPlaySec: 7);
    expect(readPlayMetaOrDefault(db, 'webdav:test', 'a.mp3').playSec, 12);

    row = readPlayMetaOrDefault(db, 'webdav:test', 'a.mp3')
        .copyWith(favorite: true, songJson: '{}');
    upsertPlayMetaRow(db, row,
        update: {PlayMetaField.favorite, PlayMetaField.songJson});
    row = readPlayMetaOrDefault(db, 'webdav:test', 'a.mp3');
    expect(row.favorite, isTrue);
    expect(row.playSec, 12);
    expect(row.songJson, '{}');

    upsertPlayMetaRow(db, row.copyWith(songJson: null),
        update: {PlayMetaField.songJson});
    expect(readPlayMetaOrDefault(db, 'webdav:test', 'a.mp3').songJson, '{}');
  });
}
