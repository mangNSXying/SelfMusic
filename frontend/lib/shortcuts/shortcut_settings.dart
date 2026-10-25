import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/local/app_settings.dart';
import 'shortcut_models.dart';

class ShortcutSettings extends ChangeNotifier {
  ShortcutSettings(
    this._settings, {
    bool? primaryIsMeta,
  }) : primaryIsMeta = primaryIsMeta ?? (!kIsWeb && Platform.isMacOS) {
    _load();
  }

  final AppSettings _settings;
  final bool primaryIsMeta;

  late Map<ShortcutAction, ShortcutBinding?> _window;
  late Map<ShortcutAction, ShortcutBinding?> _global;

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

  String? setBinding(
    ShortcutAction action,
    ShortcutScope scope,
    ShortcutBinding? binding,
  ) {
    final error = findConflict(
      action: action,
      scope: scope,
      binding: binding,
      window: _window,
      global: _global,
    );
    if (error != null) return error;
    final target = scope == ShortcutScope.window ? _window : _global;
    if (target[action] == binding) return null;
    target[action] = binding;
    _persist(scope);
    notifyListeners();
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
  }) {
    if (binding == null) return null;
    if (scope == ShortcutScope.global && !binding.hasAnyModifier) {
      return '全局快捷键至少需要 Ctrl、Alt 或 Meta 修饰键';
    }
    final sameScope = scope == ShortcutScope.window ? window : global;
    for (final entry in sameScope.entries) {
      if (entry.key == action || entry.value != binding) continue;
      return '与「${entry.key.label}」冲突';
    }
    final otherScope = scope == ShortcutScope.window ? global : window;
    for (final entry in otherScope.entries) {
      if (entry.value != binding) continue;
      final label = scope == ShortcutScope.window ? '全局' : '窗口';
      return '与$label快捷键「${entry.key.label}」冲突';
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
      requireModifier: true,
    );
  }

  Map<ShortcutAction, ShortcutBinding?> _decode(
    String raw,
    Map<ShortcutAction, ShortcutBinding?> defaults, {
    bool requireModifier = false,
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
          result[action] = requireModifier && !binding.hasAnyModifier
              ? defaults[action]
              : binding;
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
