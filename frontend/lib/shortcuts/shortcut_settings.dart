import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/local/app_settings.dart';
import 'shortcut_models.dart';

/// 一个可被新快捷键覆盖的旧绑定。
///
/// 快捷键设置不再因为组合已被占用而直接失败：录制时把冲突展示给用户，
/// 确认保存后清掉旧绑定，避免「先清空旧键才能设置新键」的来回操作。
@immutable
class ShortcutConflict {
  const ShortcutConflict({
    required this.action,
    required this.scope,
    required this.sameScope,
  });

  final ShortcutAction action;

  /// 冲突绑定所在的 scope（同 scope 冲突时就是目标 scope）。
  final ShortcutScope scope;

  /// true 表示同 scope 冲突；false 表示窗口内与全局互相冲突。
  final bool sameScope;

  String get message => sameScope
      ? '与「${action.label}」冲突'
      : '与${scope == ShortcutScope.window ? '窗口' : '全局'}快捷键'
          '「${action.label}」冲突';
}

class ShortcutSettings extends ChangeNotifier {
  ShortcutSettings(
    this._settings, {
    bool? primaryIsMeta,
    bool? metaSupported,
    bool? standaloneGlobalKeys,
  })  : primaryIsMeta = primaryIsMeta ?? (!kIsWeb && Platform.isMacOS),
        metaSupported =
            metaSupported ?? (kIsWeb || Platform.operatingSystem != 'ohos'),
        standaloneGlobalKeys = standaloneGlobalKeys ??
            (kIsWeb || Platform.operatingSystem != 'ohos') {
    _load();
  }

  final AppSettings _settings;
  final bool primaryIsMeta;

  /// 鸿蒙 inputConsumer 不支持 Meta。
  final bool metaSupported;

  /// 是否允许 F1~F24 / 媒体键不带修饰键作为全局快捷键。
  final bool standaloneGlobalKeys;

  late Map<ShortcutAction, ShortcutBinding?> _window;
  late Map<ShortcutAction, ShortcutBinding?> _global;

  int _recordingDepth = 0;

  /// 快捷键录制期间为 true：调用方应暂停系统全局热键注册，
  /// 否则按到已注册的组合时旧动作会先触发，甚至吞掉录制事件。
  bool get isRecording => _recordingDepth > 0;

  Map<ShortcutAction, ShortcutBinding?> get windowBindings =>
      Map.unmodifiable(_window);

  Map<ShortcutAction, ShortcutBinding?> get globalBindings =>
      Map.unmodifiable(_global);

  Map<ShortcutAction, ShortcutBinding?> defaultsForScope(ShortcutScope scope) =>
      scope == ShortcutScope.window
          ? defaultWindowBindings(primaryIsMeta: primaryIsMeta)
          : defaultGlobalBindings(primaryIsMeta: primaryIsMeta);

  ShortcutBinding? bindingFor(ShortcutAction action, ShortcutScope scope) =>
      (scope == ShortcutScope.window ? _window : _global)[action];

  /// 录制对话框打开/关闭时成对调用。使用计数以兼容重复进入。
  void beginRecording() {
    _recordingDepth++;
    notifyListeners();
  }

  void endRecording() {
    if (_recordingDepth == 0) return;
    _recordingDepth--;
    notifyListeners();
  }

  String? validateBinding(ShortcutScope scope, ShortcutBinding? binding) =>
      _validateBinding(
        scope: scope,
        binding: binding,
        metaSupported: metaSupported,
        standaloneGlobalKeys: standaloneGlobalKeys,
      );

  List<ShortcutConflict> conflictsFor(
    ShortcutAction action,
    ShortcutScope scope,
    ShortcutBinding? binding,
  ) =>
      findConflicts(
        action: action,
        scope: scope,
        binding: binding,
        window: _window,
        global: _global,
      );

  /// 保存绑定。
  ///
  /// [replaceConflicts] 为 true 时会清除占用同一组合的旧绑定（可能在另一个
  /// scope），用于录制对话框确认「覆盖保存」的场景。
  String? setBinding(
    ShortcutAction action,
    ShortcutScope scope,
    ShortcutBinding? binding, {
    bool replaceConflicts = false,
  }) {
    final validation = validateBinding(scope, binding);
    if (validation != null) return validation;
    final conflicts = conflictsFor(action, scope, binding);
    if (conflicts.isNotEmpty && !replaceConflicts) {
      return conflicts.first.message;
    }

    final target = scope == ShortcutScope.window ? _window : _global;
    final persistScopes = <ShortcutScope>{scope};
    if (replaceConflicts) {
      for (final conflict in conflicts) {
        final map = conflict.scope == ShortcutScope.window ? _window : _global;
        if (map[conflict.action] == binding) {
          map[conflict.action] = null;
          persistScopes.add(conflict.scope);
        }
      }
    }

    final unchanged = target[action] == binding;
    target[action] = binding;
    for (final changed in persistScopes) {
      _persist(changed);
    }
    if (!unchanged || conflicts.isNotEmpty) notifyListeners();
    return null;
  }

  String? resetAction(ShortcutAction action, ShortcutScope scope) {
    final defaults = defaultsForScope(scope);
    if (!defaults.containsKey(action)) return null;
    final target = scope == ShortcutScope.window ? _window : _global;
    if (target[action] == defaults[action]) return null;
    final candidate = Map.of(target)..[action] = defaults[action];
    final error = _conflictInScope(scope, candidate);
    if (error != null) return '无法恢复默认：$error';
    target[action] = defaults[action];
    _persist(scope);
    notifyListeners();
    return null;
  }

  String? resetScope(ShortcutScope scope) {
    final defaults = defaultsForScope(scope);
    final candidate = Map.of(defaults);
    final error = _conflictInScope(scope, candidate);
    if (error != null) return '无法恢复默认：$error';
    if (scope == ShortcutScope.window) {
      _window = candidate;
    } else {
      _global = candidate;
    }
    _persist(scope);
    notifyListeners();
    return null;
  }

  String? _conflictInScope(
    ShortcutScope scope,
    Map<ShortcutAction, ShortcutBinding?> candidate,
  ) {
    for (final entry in candidate.entries) {
      final error = findConflict(
        action: entry.key,
        scope: scope,
        binding: entry.value,
        window: scope == ShortcutScope.window ? candidate : _window,
        global: scope == ShortcutScope.global ? candidate : _global,
        metaSupported: metaSupported,
        standaloneGlobalKeys: standaloneGlobalKeys,
      );
      if (error != null) return error;
    }
    return null;
  }

  void resetAll() {
    _window = defaultWindowBindings(primaryIsMeta: primaryIsMeta);
    _global = defaultGlobalBindings(primaryIsMeta: primaryIsMeta);
    _persist(ShortcutScope.window);
    _persist(ShortcutScope.global);
    notifyListeners();
  }

  void reload() {
    _load();
    notifyListeners();
  }

  static String? findConflict({
    required ShortcutAction action,
    required ShortcutScope scope,
    required ShortcutBinding? binding,
    required Map<ShortcutAction, ShortcutBinding?> window,
    required Map<ShortcutAction, ShortcutBinding?> global,
    bool metaSupported = true,
    bool standaloneGlobalKeys = true,
  }) {
    final validation = _validateBinding(
      scope: scope,
      binding: binding,
      metaSupported: metaSupported,
      standaloneGlobalKeys: standaloneGlobalKeys,
    );
    if (validation != null) return validation;
    final conflicts = findConflicts(
      action: action,
      scope: scope,
      binding: binding,
      window: window,
      global: global,
    );
    return conflicts.isEmpty ? null : conflicts.first.message;
  }

  static List<ShortcutConflict> findConflicts({
    required ShortcutAction action,
    required ShortcutScope scope,
    required ShortcutBinding? binding,
    required Map<ShortcutAction, ShortcutBinding?> window,
    required Map<ShortcutAction, ShortcutBinding?> global,
  }) {
    if (binding == null) return const <ShortcutConflict>[];
    final conflicts = <ShortcutConflict>[];

    final sameScope = scope == ShortcutScope.window ? window : global;
    for (final entry in sameScope.entries) {
      if (entry.key == action || entry.value != binding) continue;
      conflicts.add(ShortcutConflict(
        action: entry.key,
        scope: scope,
        sameScope: true,
      ));
    }

    final otherScope = scope == ShortcutScope.window
        ? ShortcutScope.global
        : ShortcutScope.window;
    final other = otherScope == ShortcutScope.window ? window : global;
    for (final entry in other.entries) {
      if (entry.value != binding) continue;
      conflicts.add(ShortcutConflict(
        action: entry.key,
        scope: otherScope,
        sameScope: false,
      ));
    }
    return conflicts;
  }

  static String? _validateBinding({
    required ShortcutScope scope,
    required ShortcutBinding? binding,
    bool metaSupported = true,
    bool standaloneGlobalKeys = true,
  }) {
    if (binding == null || scope != ShortcutScope.global) return null;
    if (!metaSupported && binding.meta) {
      return '鸿蒙全局快捷键不支持 Meta/Command 修饰键';
    }
    if (!binding.hasAnyModifier &&
        !(standaloneGlobalKeys && binding.isStandaloneGlobalKey)) {
      return metaSupported
          ? '全局快捷键至少需要 Ctrl、Alt 或 Meta 修饰键'
              '（F1-F24 / 媒体键可单独使用）'
          : '鸿蒙全局快捷键至少需要 Ctrl 或 Alt 修饰键';
    }
    return null;
  }

  void _load() {
    _window = _decode(
      _settings.shortcutWindowBindings,
      defaultWindowBindings(primaryIsMeta: primaryIsMeta),
    );
    _global = _decode(
      _settings.shortcutGlobalBindings,
      defaultGlobalBindings(primaryIsMeta: primaryIsMeta),
      validateGlobal: true,
    );
  }

  Map<ShortcutAction, ShortcutBinding?> _decode(
    String raw,
    Map<ShortcutAction, ShortcutBinding?> defaults, {
    bool validateGlobal = false,
  }) {
    final result = Map<ShortcutAction, ShortcutBinding?>.of(defaults);
    if (raw.trim().isEmpty) return result;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return result;
      for (final action in result.keys.toList()) {
        if (!decoded.containsKey(action.name)) continue;
        final value = decoded[action.name];
        if (value == null) {
          result[action] = null;
          continue;
        }
        final binding = ShortcutBinding.tryParse(value);
        if (binding != null) {
          final invalid = validateGlobal &&
              _validateBinding(
                    scope: ShortcutScope.global,
                    binding: binding,
                    metaSupported: metaSupported,
                    standaloneGlobalKeys: standaloneGlobalKeys,
                  ) !=
                  null;
          result[action] = invalid ? defaults[action] : binding;
        }
      }
    } catch (e) {
      debugPrint('shortcut settings parse failed: $e');
    }
    return result;
  }

  void _persist(ShortcutScope scope) {
    final map = scope == ShortcutScope.window ? _window : _global;
    final raw = jsonEncode({
      for (final entry in map.entries) entry.key.name: entry.value?.toJson(),
    });
    if (scope == ShortcutScope.window) {
      _settings.shortcutWindowBindings = raw;
    } else {
      _settings.shortcutGlobalBindings = raw;
    }
  }
}
