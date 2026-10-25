import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:provider/provider.dart';

import '../layout/queue_panel.dart';
import '../providers/direct_source_manager.dart';
import '../providers/navigation_provider.dart';
import '../providers/player_provider.dart';
import '../shortcuts/shortcut_models.dart';
import '../shortcuts/shortcut_settings.dart';
import '../theme/app_theme.dart';
import '../theme/theme_provider.dart';
import '../utils/app_exit.dart';
import '../utils/focus_utils.dart';
import 'app_dialog_actions.dart';
import 'app_toast.dart';
import 'draggable_sheet.dart';
import 'root_focus_keeper.dart';
import 'shortcut_help_dialog.dart';
import 'sleep_timer_dialog.dart';

class AppShortcuts extends StatefulWidget {
  const AppShortcuts({
    super.key,
    required this.child,
    this.enableGlobalHotkeys = true,
  });

  final Widget child;
  final bool enableGlobalHotkeys;

  @override
  State<AppShortcuts> createState() => _AppShortcutsState();
}

class _AppShortcutsState extends State<AppShortcuts> {
  final FocusNode _rootFocus = FocusNode(debugLabel: 'appShortcuts');
  ShortcutSettings? _settings;
  Future<void> _registrationQueue = Future<void>.value();
  int _registrationGeneration = 0;
  bool _disposed = false;

  bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final settings = context.read<ShortcutSettings>();
    if (identical(_settings, settings)) return;
    _settings?.removeListener(_onSettingsChanged);
    _settings = settings;
    settings.addListener(_onSettingsChanged);
    _scheduleGlobalRegistration();
  }

  @override
  void dispose() {
    _disposed = true;
    _rootFocus.dispose();
    _settings?.removeListener(_onSettingsChanged);
    if (widget.enableGlobalHotkeys && _isDesktop) {
      unawaited(
        _registrationQueue.catchError((Object e) {
          debugPrint('global hotkeys queue failed: $e');
        }).then((_) async {
          try {
            await hotKeyManager.unregisterAll();
          } catch (e) {
            debugPrint('global hotkeys unregister failed: $e');
          }
        }),
      );
    }
    super.dispose();
  }

  void _onSettingsChanged() {
    _scheduleGlobalRegistration();
  }

  void _scheduleGlobalRegistration() {
    if (_disposed || !widget.enableGlobalHotkeys || !_isDesktop) return;
    _registrationQueue = _registrationQueue.catchError((Object e) {
      debugPrint('global hotkeys queue failed: $e');
    }).then((_) => _applyGlobalHotkeys());
  }

  Future<void> _applyGlobalHotkeys() async {
    if (_disposed || !_isDesktop) return;
    final generation = ++_registrationGeneration;
    try {
      await hotKeyManager.unregisterAll();
    } catch (e) {
      debugPrint('global hotkeys unregister failed: $e');
    }
    if (_disposed || generation != _registrationGeneration) return;
    final settings = _settings;
    if (settings == null) return;
    for (final entry in settings.globalBindings.entries) {
      final binding = entry.value;
      if (binding == null) continue;
      if (_disposed || generation != _registrationGeneration) return;
      final hotKey = HotKey(
        identifier: 'selfmusic.global.${entry.key.name}',
        key: LogicalKeyboardKey(binding.keyId),
        modifiers: _modifiersOf(binding),
        scope: HotKeyScope.system,
      );
      try {
        await hotKeyManager.register(
          hotKey,
          keyDownHandler: (_) => _runGlobal(entry.key),
        );
      } catch (e) {
        debugPrint('global hotkey register failed ${entry.key.name}: $e');
      }
    }
  }

  List<HotKeyModifier> _modifiersOf(ShortcutBinding binding) => [
        if (binding.control) HotKeyModifier.control,
        if (binding.alt) HotKeyModifier.alt,
        if (binding.shift) HotKeyModifier.shift,
        if (binding.meta) HotKeyModifier.meta,
      ];

  void _runGlobal(ShortcutAction action) {
    if (!mounted) return;
    _runSafely(action);
  }

  void _runSafely(ShortcutAction action) {
    unawaited(
      _runAction(action).catchError((Object e, StackTrace stack) {
        debugPrint('shortcut ${action.name} failed: $e\n$stack');
      }),
    );
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final settings = _settings;
    if (settings == null) return KeyEventResult.ignored;
    for (final entry in settings.windowBindings.entries) {
      final binding = entry.value;
      if (binding == null) continue;
      if (!binding.activator.accepts(event, HardwareKeyboard.instance)) {
        continue;
      }
      if (!_shouldHandle(entry.key)) return KeyEventResult.ignored;
      if (event is KeyRepeatEvent && !_allowsRepeat(entry.key)) {
        return KeyEventResult.handled;
      }
      _runSafely(entry.key);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  bool _allowsRepeat(ShortcutAction action) => switch (action) {
        ShortcutAction.seekBackward5 ||
        ShortcutAction.seekForward5 ||
        ShortcutAction.seekBackward30 ||
        ShortcutAction.seekForward30 =>
          true,
        _ => false,
      };

  bool _shouldHandle(ShortcutAction action) {
    final nav = context.read<NavigationProvider>();
    if (primaryFocusIsTextInput()) {
      return action == ShortcutAction.back;
    }
    if (Navigator.of(context).canPop()) return false;
    final launcher = context.read<AppSheetLauncher?>();
    if (launcher?.isShowing ?? false) {
      return action == ShortcutAction.back ||
          (action == ShortcutAction.removeFromQueue && nav.queueOpen);
    }
    return switch (action) {
      ShortcutAction.back => !nav.playerView,
      ShortcutAction.seekBackward5 ||
      ShortcutAction.seekForward5 ||
      ShortcutAction.seekBackward30 ||
      ShortcutAction.seekForward30 =>
        nav.playerView,
      ShortcutAction.removeFromQueue => nav.queueOpen,
      _ => true,
    };
  }

  Future<void> _runAction(ShortcutAction action) async {
    if (!mounted) return;
    final nav = context.read<NavigationProvider>();
    final player = context.read<PlayerProvider>();
    switch (action) {
      case ShortcutAction.playPause:
        unawaited(player.toggle());
      case ShortcutAction.previous:
        unawaited(player.prev());
      case ShortcutAction.next:
        unawaited(player.next());
      case ShortcutAction.seekBackward5:
        unawaited(_seekBy(player, const Duration(seconds: -5)));
      case ShortcutAction.seekForward5:
        unawaited(_seekBy(player, const Duration(seconds: 5)));
      case ShortcutAction.seekBackward30:
        unawaited(_seekBy(player, const Duration(seconds: -30)));
      case ShortcutAction.seekForward30:
        unawaited(_seekBy(player, const Duration(seconds: 30)));
      case ShortcutAction.back:
        _handleBack(nav);
      case ShortcutAction.search:
        if (nav.inSettings) nav.closeSettings();
        if (nav.playerView) nav.closePlayer();
        nav.requestSearchFocus();
      case ShortcutAction.sectionPlaylists:
        nav.select(NavSection.playlists);
      case ShortcutAction.sectionLiked:
        nav.select(NavSection.liked);
      case ShortcutAction.sectionSources:
        nav.select(NavSection.sources);
      case ShortcutAction.sectionSongs:
        nav.select(NavSection.songs);
      case ShortcutAction.sectionAlbums:
        nav.select(NavSection.albums);
      case ShortcutAction.sectionArtists:
        nav.select(NavSection.artists);
      case ShortcutAction.queue:
        if (nav.playerView) nav.closePlayer();
        toggleQueuePanel(context);
      case ShortcutAction.player:
        if (nav.playerView) {
          nav.closePlayer();
        } else {
          nav.openPlayer();
        }
      case ShortcutAction.cyclePlayMode:
        player.cycleMode();
        AppToast.show('播放模式：${_playModeLabel(player.mode)}', isError: false);
      case ShortcutAction.toggleFavorite:
        _toggleFavorite(player);
      case ShortcutAction.toggleSidebar:
        nav.requestSidebarToggle();
      case ShortcutAction.openSettings:
        nav.openSettings(SettingsItem.general);
      case ShortcutAction.sleepTimer:
        await showSleepTimerDialog(context);
      case ShortcutAction.cycleTheme:
        final theme = context.read<ThemeProvider>();
        await theme.cycleMode();
        if (mounted) {
          AppToast.show('主题：${_themeModeLabel(theme.themeMode)}',
              isError: false);
        }
      case ShortcutAction.quit:
        await confirmExitApp(context);
      case ShortcutAction.help:
        await showShortcutHelpDialog(context);
      case ShortcutAction.removeFromQueue:
        await _removeFromQueue(player);
    }
  }

  void _handleBack(NavigationProvider nav) {
    if (primaryFocusIsTextInput()) {
      FocusManager.instance.primaryFocus?.unfocus();
      _rootFocus.requestFocus();
      return;
    }
    final launcher = context.read<AppSheetLauncher?>();
    if (launcher?.isShowing ?? false) {
      launcher!.close();
      return;
    }
    if (nav.playerView) return;
    nav.backToPrevious();
  }

  Future<void> _seekBy(PlayerProvider player, Duration delta) async {
    var target = player.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    final duration = player.duration;
    if (duration != null && target > duration) target = duration;
    await player.seek(target);
  }

  void _toggleFavorite(PlayerProvider player) {
    final song = player.current;
    if (song == null) {
      AppToast.show('没有正在播放的歌曲', isError: false);
      return;
    }
    final direct = context.read<DirectSourceManager>();
    final favorite = direct.weight.isFavorite(song);
    unawaited(direct.setFavorite(song, !favorite));
    if (favorite) {
      unawaited(
          player.onAnchorSongRemoved(PlayerProvider.anchorForLiked(), song));
    }
    AppToast.show(!favorite ? '已加入喜欢' : '已取消喜欢', isError: false);
  }

  Future<void> _removeFromQueue(PlayerProvider player) async {
    final queue = player.queue;
    final index = player.currentIndex;
    if (queue.isEmpty || index < 0 || index >= queue.length) return;
    final target = queue[index];
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('移除歌曲'),
        content: const Text('确定从队列中移除当前歌曲？'),
        actions: appDialogActions(
          c,
          confirmLabel: '移除',
          destructive: true,
          onCancel: () => Navigator.of(c).pop(false),
          onConfirm: () => Navigator.of(c).pop(true),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    var current = -1;
    for (var i = 0; i < player.queue.length; i++) {
      if (identical(player.queue[i], target)) {
        current = i;
        break;
      }
    }
    if (current >= 0) player.removeAt(current);
  }

  static String _playModeLabel(PlayMode mode) => switch (mode) {
        PlayMode.sequence => '顺序播放',
        PlayMode.loopList => '列表循环',
        PlayMode.loopOne => '单曲循环',
        PlayMode.weighted => '随机播放',
      };

  static String _themeModeLabel(ThemeMode mode) => switch (mode) {
        ThemeMode.system => '跟随系统',
        ThemeMode.light => '浅色',
        ThemeMode.dark => '深色',
      };

  @override
  Widget build(BuildContext context) {
    return RootFocusKeeper(
      focusNode: _rootFocus,
      child: Focus(
        focusNode: _rootFocus,
        autofocus: true,
        canRequestFocus: true,
        skipTraversal: true,
        onKeyEvent: _handleKeyEvent,
        child: widget.child,
      ),
    );
  }
}
