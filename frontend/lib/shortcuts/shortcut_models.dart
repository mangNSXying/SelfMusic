import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

enum ShortcutScope {
  window('窗口内'),
  global('全局');

  const ShortcutScope(this.label);
  final String label;
}

enum ShortcutAction {
  playPause('播放/暂停'),
  previous('上一首'),
  next('下一首'),
  seekBackward5('快退 5 秒'),
  seekForward5('快进 5 秒'),
  seekBackward30('快退 30 秒'),
  seekForward30('快进 30 秒'),
  volumeUp('音量 +'),
  volumeDown('音量 -'),
  back('返回/关闭'),
  search('聚焦搜索'),
  sectionPlaylists('歌单'),
  sectionLiked('喜欢'),
  sectionSources('播放源'),
  sectionSongs('歌曲'),
  sectionAlbums('专辑'),
  sectionArtists('歌手'),
  queue('播放队列'),
  player('播放页'),
  cyclePlayMode('切换播放模式'),
  toggleFavorite('喜欢/取消喜欢'),
  toggleSidebar('伸缩侧栏'),
  openSettings('打开设置'),
  sleepTimer('睡眠定时'),
  cycleTheme('切换主题'),
  quit('退出应用'),
  help('快捷键帮助'),
  removeFromQueue('从队列移除当前曲');

  const ShortcutAction(this.label);
  final String label;

  ShortcutGroup get group => switch (this) {
        playPause ||
        previous ||
        next ||
        seekBackward5 ||
        seekForward5 ||
        seekBackward30 ||
        seekForward30 ||
        volumeUp ||
        volumeDown ||
        cyclePlayMode ||
        toggleFavorite ||
        sleepTimer =>
          ShortcutGroup.playback,
        back ||
        search ||
        sectionPlaylists ||
        sectionLiked ||
        sectionSources ||
        sectionSongs ||
        sectionAlbums ||
        sectionArtists ||
        queue ||
        player ||
        toggleSidebar ||
        openSettings =>
          ShortcutGroup.navigation,
        cycleTheme || quit || help || removeFromQueue => ShortcutGroup.system,
      };
}

enum ShortcutGroup {
  playback('播放控制'),
  navigation('导航'),
  system('系统');

  const ShortcutGroup(this.label);
  final String label;
}

@immutable
class ShortcutBinding {
  const ShortcutBinding({
    required this.keyId,
    this.control = false,
    this.shift = false,
    this.alt = false,
    this.meta = false,
  });

  final int keyId;
  final bool control;
  final bool shift;
  final bool alt;
  final bool meta;

  bool get hasAnyModifier => control || alt || meta;

  /// F1~F24：不产生文本，可安全地单独注册为系统全局快捷键。
  bool get isFunctionKey =>
      keyId >= LogicalKeyboardKey.f1.keyId &&
      keyId <= LogicalKeyboardKey.f24.keyId;

  /// 媒体/音量键：同样不产生文本，允许不带修饰键直接触发。
  bool get isMediaKey =>
      keyId == LogicalKeyboardKey.mediaPlayPause.keyId ||
      keyId == LogicalKeyboardKey.mediaStop.keyId ||
      keyId == LogicalKeyboardKey.mediaPlay.keyId ||
      keyId == LogicalKeyboardKey.mediaPause.keyId ||
      keyId == LogicalKeyboardKey.mediaTrackNext.keyId ||
      keyId == LogicalKeyboardKey.mediaTrackPrevious.keyId ||
      keyId == LogicalKeyboardKey.mediaRewind.keyId ||
      keyId == LogicalKeyboardKey.mediaFastForward.keyId ||
      keyId == LogicalKeyboardKey.audioVolumeUp.keyId ||
      keyId == LogicalKeyboardKey.audioVolumeDown.keyId ||
      keyId == LogicalKeyboardKey.audioVolumeMute.keyId;

  /// 全局快捷键允许不按 Ctrl/Alt/Meta 的键：字母、数字、空格等会抢占
  /// 系统输入，不能单独注册；F 键与媒体键没有这个问题。
  bool get isStandaloneGlobalKey => isFunctionKey || isMediaKey;

  SingleActivator get activator => SingleActivator(
        LogicalKeyboardKey(keyId),
        control: control,
        shift: shift,
        alt: alt,
        meta: meta,
      );

  String describe({bool isMac = false}) {
    final parts = <String>[];
    if (isMac) {
      if (control) parts.add('⌃');
      if (alt) parts.add('⌥');
      if (shift) parts.add('⇧');
      if (meta) parts.add('⌘');
    } else {
      if (control) parts.add('Ctrl');
      if (alt) parts.add('Alt');
      if (shift) parts.add('Shift');
      if (meta) parts.add('Meta');
    }
    parts.add(_keyLabel(keyId));
    return parts.join(' + ');
  }

  Map<String, dynamic> toJson() => {
        'keyId': keyId,
        'control': control,
        'shift': shift,
        'alt': alt,
        'meta': meta,
      };

  static ShortcutBinding? tryParse(Object? value) {
    if (value is! Map) return null;
    final keyId = value['keyId'];
    if (keyId is! int || keyId <= 0) return null;
    bool flag(String name) => value[name] == true;
    return ShortcutBinding(
      keyId: keyId,
      control: flag('control'),
      shift: flag('shift'),
      alt: flag('alt'),
      meta: flag('meta'),
    );
  }

  static String _keyLabel(int keyId) {
    final key = LogicalKeyboardKey.findKeyByKeyId(keyId);
    if (key == null) return 'Key $keyId';
    if (key == LogicalKeyboardKey.space) return 'Space';
    if (key == LogicalKeyboardKey.escape) return 'Esc';
    if (key == LogicalKeyboardKey.delete) return 'Delete';
    if (key == LogicalKeyboardKey.arrowLeft) return '←';
    if (key == LogicalKeyboardKey.arrowRight) return '→';
    if (key == LogicalKeyboardKey.arrowUp) return '↑';
    if (key == LogicalKeyboardKey.arrowDown) return '↓';
    if (key == LogicalKeyboardKey.comma) return ',';
    if (key == LogicalKeyboardKey.mediaPlayPause) return 'Media Play/Pause';
    if (key == LogicalKeyboardKey.mediaStop) return 'Media Stop';
    if (key == LogicalKeyboardKey.mediaPlay) return 'Media Play';
    if (key == LogicalKeyboardKey.mediaPause) return 'Media Pause';
    if (key == LogicalKeyboardKey.mediaTrackNext) return 'Media Next';
    if (key == LogicalKeyboardKey.mediaTrackPrevious) return 'Media Prev';
    if (key == LogicalKeyboardKey.mediaRewind) return 'Media Rewind';
    if (key == LogicalKeyboardKey.mediaFastForward) return 'Media Forward';
    if (key == LogicalKeyboardKey.audioVolumeUp) return 'Volume Up';
    if (key == LogicalKeyboardKey.audioVolumeDown) return 'Volume Down';
    if (key == LogicalKeyboardKey.audioVolumeMute) return 'Volume Mute';
    final label = key.keyLabel;
    if (label.trim().isNotEmpty) return label;
    return 'Key $keyId';
  }

  @override
  bool operator ==(Object other) =>
      other is ShortcutBinding &&
      other.keyId == keyId &&
      other.control == control &&
      other.shift == shift &&
      other.alt == alt &&
      other.meta == meta;

  @override
  int get hashCode => Object.hash(keyId, control, shift, alt, meta);
}

ShortcutBinding _binding(
  LogicalKeyboardKey key, {
  bool primary = false,
  bool primaryIsMeta = false,
  bool shift = false,
  bool alt = false,
}) =>
    ShortcutBinding(
      keyId: key.keyId,
      control: primary && !primaryIsMeta,
      meta: primary && primaryIsMeta,
      shift: shift,
      alt: alt,
    );

Map<ShortcutAction, ShortcutBinding?> defaultWindowBindings({
  required bool primaryIsMeta,
}) {
  ShortcutBinding p(
    LogicalKeyboardKey key, {
    bool shift = false,
    bool alt = false,
  }) =>
      _binding(
        key,
        primary: true,
        primaryIsMeta: primaryIsMeta,
        shift: shift,
        alt: alt,
      );

  return {
    ShortcutAction.playPause: _binding(LogicalKeyboardKey.space),
    ShortcutAction.previous: p(LogicalKeyboardKey.arrowLeft),
    ShortcutAction.next: p(LogicalKeyboardKey.arrowRight),
    ShortcutAction.seekBackward5: _binding(LogicalKeyboardKey.arrowLeft),
    ShortcutAction.seekForward5: _binding(LogicalKeyboardKey.arrowRight),
    ShortcutAction.seekBackward30:
        _binding(LogicalKeyboardKey.arrowLeft, shift: true),
    ShortcutAction.seekForward30:
        _binding(LogicalKeyboardKey.arrowRight, shift: true),
    ShortcutAction.volumeUp: p(LogicalKeyboardKey.arrowUp),
    ShortcutAction.volumeDown: p(LogicalKeyboardKey.arrowDown),
    ShortcutAction.back: _binding(LogicalKeyboardKey.escape),
    ShortcutAction.search: p(LogicalKeyboardKey.keyF),
    ShortcutAction.sectionPlaylists: p(LogicalKeyboardKey.digit1),
    ShortcutAction.sectionLiked: p(LogicalKeyboardKey.digit2),
    ShortcutAction.sectionSources: p(LogicalKeyboardKey.digit3),
    ShortcutAction.sectionSongs: p(LogicalKeyboardKey.digit4),
    ShortcutAction.sectionAlbums: p(LogicalKeyboardKey.digit5),
    ShortcutAction.sectionArtists: p(LogicalKeyboardKey.digit6),
    ShortcutAction.queue: _binding(LogicalKeyboardKey.keyQ),
    ShortcutAction.player: _binding(LogicalKeyboardKey.keyP),
    ShortcutAction.cyclePlayMode: _binding(LogicalKeyboardKey.keyR),
    ShortcutAction.toggleFavorite: _binding(LogicalKeyboardKey.keyL),
    ShortcutAction.toggleSidebar: p(LogicalKeyboardKey.keyB),
    ShortcutAction.openSettings: p(LogicalKeyboardKey.comma),
    ShortcutAction.sleepTimer: _binding(LogicalKeyboardKey.keyT),
    ShortcutAction.cycleTheme: p(LogicalKeyboardKey.keyT, shift: true),
    ShortcutAction.quit: p(LogicalKeyboardKey.keyQ),
    ShortcutAction.help: _binding(LogicalKeyboardKey.f1),
    ShortcutAction.removeFromQueue: _binding(LogicalKeyboardKey.delete),
  };
}

Map<ShortcutAction, ShortcutBinding?> defaultGlobalBindings({
  required bool primaryIsMeta,
}) {
  ShortcutBinding p(
    LogicalKeyboardKey key, {
    bool shift = false,
  }) =>
      _binding(
        key,
        primary: true,
        primaryIsMeta: primaryIsMeta,
        shift: shift,
        alt: true,
      );

  // 其余动作默认未设置，但允许用户在「全局快捷键」里自行添加。
  final result = <ShortcutAction, ShortcutBinding?>{
    for (final action in ShortcutAction.values) action: null,
  };
  result[ShortcutAction.playPause] = p(LogicalKeyboardKey.space);
  result[ShortcutAction.previous] = p(LogicalKeyboardKey.arrowLeft);
  result[ShortcutAction.next] = p(LogicalKeyboardKey.arrowRight);
  result[ShortcutAction.volumeUp] = p(LogicalKeyboardKey.arrowUp);
  result[ShortcutAction.volumeDown] = p(LogicalKeyboardKey.arrowDown);
  result[ShortcutAction.toggleFavorite] = p(LogicalKeyboardKey.keyL);
  return result;
}
