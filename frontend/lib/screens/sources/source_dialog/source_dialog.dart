import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/sources/local_file_direct_source.dart';
import '../../../data/sources/music_source.dart';
import '../../../providers/direct_source_manager.dart';
import '../../../providers/player_provider.dart';
import '../../../utils/url_input.dart';
import '../../../widgets/app_dialog_actions.dart';
import '../../../widgets/app_toast.dart';
import '../../../widgets/single_choice_group.dart';

import 'source_fallback_panel.dart';
import 'source_file_pickers.dart';
import 'source_form_fields.dart';
import 'source_form_model.dart';
import 'source_form_ops.dart';
import 'source_form_renderer.dart';
import 'source_form_widgets.dart';

/// 新增/编辑播放源弹窗：按源类型切换字段（本地 / SMB / WebDAV / SFTP）。
///
/// 结构：类型选择 → 分组表单（主源）→ 测试连接 → 备用源（折叠）。
/// 主源与备用源共用 [SourceFormBuilder] 与 [SourceFormModel]；校验与测试
/// 连接统一走 `source_form_ops.dart`；平台选择器在 `source_file_pickers.dart`。
/// 本文件只做编排。
class SourceDialog extends StatefulWidget {
  final String? editKey;
  const SourceDialog({super.key, this.editKey});

  @override
  State<SourceDialog> createState() => _SourceDialogState();
}

class _SourceDialogState extends State<SourceDialog> {
  late final SourceFormModel _form;
  late final FocusNode _baseUrlFocus;

  /// 字段级错误（由校验结果的 `field` 落位到对应输入框）。
  Map<SourceFieldId, String> _errors = const {};

  /// 跨字段 / 落库错误（显示在弹窗底部）。
  String? _error;

  ConnectionStatus _testStatus = ConnectionStatus.idle;
  SourceTestResult? _testResult;

  bool _saving = false;
  bool _pickingFiles = false;

  /// 本地文件清单是否展开。编辑已有文件源时默认展开（用户多半来增删文件）。
  late bool _filesExpanded;

  final List<SourceFallbackSlot> _fallbacks = [];

  bool get _isEdit => widget.editKey != null;

  @override
  void initState() {
    super.initState();
    Map<String, dynamic> cfg = const {};
    if (widget.editKey != null) {
      cfg = context.read<DirectSourceManager>().editableConfig(widget.editKey!);
    }
    final kind = switch (cfg['kind'] as String?) {
      'local' => SourceKind.local,
      'sftp' => SourceKind.sftp,
      'smb' => SourceKind.smb,
      'webdav' => SourceKind.webdav,
      _ => SourceKind.local,
    };
    _form = SourceFormModel.fromConfig(cfg, kind: kind);
    _filesExpanded = _form.localFiles.isNotEmpty;
    // 仅走 HTTP 的 WebDAV 地址失焦时可视化补 `https://`；
    // SFTP/SMB/本地路径不走 HTTP，禁止挂此逻辑。
    _baseUrlFocus = FocusNode();
    _baseUrlFocus.addListener(() {
      if (!_baseUrlFocus.hasFocus && mounted && _form.kind == SourceKind.webdav) {
        if (autoCompleteUrlController(_form[SourceFieldId.baseUrl])) {
          setState(() {});
        }
      }
    });
    // 备用回填（editableConfig 已回填各槽位敏感字段）。
    for (final raw in parseFallbackConfigs(cfg['fallbacks'])) {
      _fallbacks.add(SourceFallbackSlot.fromRaw(raw));
    }
  }

  @override
  void dispose() {
    _baseUrlFocus.dispose();
    _form.dispose();
    for (final fb in _fallbacks) {
      fb.dispose();
    }
    super.dispose();
  }

  /// 任意字段变化：清掉字段错误与上一次测试结果（回到「待测」）。
  void _onFormChanged() {
    setState(() {
      _errors = const {};
      _error = null;
      _testStatus = ConnectionStatus.idle;
      _testResult = null;
    });
  }

  void _onKindChanged(SourceKind kind) {
    setState(() {
      _form.changeKind(kind);
      _errors = const {};
      _error = null;
      _testStatus = ConnectionStatus.idle;
      _testResult = null;
    });
  }

  // ---------- 校验 ----------

  /// 跑一次校验；`SourceNeedsHttpConsent` 时弹「去开启」确认并重试。
  ///
  /// 返回 null 表示校验失败（错误已落位到 `_errors` / `_error`）。
  Future<SourceValid?> _validate() async {
    final direct = context.read<DirectSourceManager>();
    var result = validateSource(_form,
        allowInsecureHttp: direct.settings.allowInsecureHttp);
    if (result is SourceNeedsHttpConsent) {
      final ok = await ensureHttpAllowed(context, result.url);
      if (!mounted) return null;
      if (ok) {
        result = validateSource(_form,
            allowInsecureHttp: direct.settings.allowInsecureHttp);
      }
    }
    switch (result) {
      case SourceValid():
        return result;
      case SourceInvalid(:final field, :final message):
        setState(() {
          if (field == null) {
            _errors = const {};
            _error = message;
          } else {
            _errors = {field: message};
            _error = null;
          }
        });
        return null;
      case SourceNeedsHttpConsent():
        setState(() => _error = '检测到明文 HTTP，已取消');
        return null;
    }
  }

  // ---------- 测试连接 ----------

  Future<void> _test() async {
    final direct = context.read<DirectSourceManager>();
    final valid = await _validate();
    if (valid == null || !mounted) return;
    setState(() {
      _testStatus = ConnectionStatus.testing;
      _testResult = null;
    });
    final result = await testSource(_form,
        allowSelfSigned: direct.settings.allowSelfSigned);
    if (!mounted) return;
    // SFTP：拿到指纹后走 TOFU 确认（成功与否由确认结果决定）。
    if (result.ok && result.fingerprint != null) {
      final trusted = await confirmSshFingerprint(
        context,
        direct: direct,
        host: _form.text(SourceFieldId.host),
        port: int.tryParse(_form.text(SourceFieldId.port)) ?? 22,
        fingerprint: result.fingerprint!,
      );
      if (!mounted) return;
      setState(() {
        _testStatus = trusted ? ConnectionStatus.ok : ConnectionStatus.failed;
        _testResult = trusted
            ? result
            : SourceTestResult(
                ok: false,
                elapsed: result.elapsed,
                message: '未确认主机指纹',
              );
      });
      return;
    }
    setState(() {
      _testStatus = result.ok ? ConnectionStatus.ok : ConnectionStatus.failed;
      _testResult = result;
    });
  }

  // ---------- 本地目录 / 文件选择 ----------

  Future<void> _pickDirectory() async {
    final picked = await pickSourceDirectory(onUnsupported: _pickAudioFiles);
    if (picked == null || !mounted) return;
    setState(() {
      _form[SourceFieldId.path].text = picked.path;
      _form.localFiles = const [];
      _onFormChanged();
    });
    if (!picked.persisted) {
      // 不阻断本次使用（会话内临时授权仍可用），但必须当场告知：
      // 否则重启后用户只会看到「目录授权已失效」，无从得知原因
      // （2026-10-06 bug 修复，此前 persisted=false 被静默忽略）。
      AppToast.show('目录持久化授权失败：应用重启后需重新选择目录');
    }
  }

  Future<void> _pickAudioFiles() async {
    if (_pickingFiles) return;
    setState(() => _pickingFiles = true);
    try {
      final picked = await pickSourceAudioFiles();
      if (!mounted || picked == null) return;
      if (picked.isEmpty) {
        AppToast.show('未选择可读取的音频文件');
        return;
      }
      final merged = mergePickedLocalFiles(
        existing: _form.localFiles,
        picked: picked,
      );
      setState(() {
        _form.localFiles = merged;
        _filesExpanded = true;
        _form[SourceFieldId.path].clear();
        _onFormChanged();
      });
      final unreadable = picked.where((f) => !f.readable).length;
      final unpersisted = picked.where((f) => !f.persisted).length;
      if (unpersisted > 0) {
        AppToast.show('部分文件持久化授权失败：应用重启后需重新选择文件', ms: 4000);
      } else if (unreadable > 0) {
        AppToast.show('部分文件当前不可读取，请确认文件仍存在且未移动');
      } else {
        AppToast.show('已导入 ${picked.length} 个音频文件', isError: false);
      }
    } finally {
      if (mounted) setState(() => _pickingFiles = false);
    }
  }

  /// SFTP 导入密钥文件（失败落到密钥字段的错误位）。
  Future<void> _importKeyFile() async {
    try {
      final picked = await pickPrivateKeyFile();
      if (picked == null || !mounted) return;
      setState(() {
        _form[SourceFieldId.keyPem].text = picked.pem;
        _form.keyFileName = picked.fileName;
        _errors = const {};
        _error = null;
      });
    } on InvalidPrivateKeyException catch (e) {
      if (!mounted) return;
      setState(() => _errors = {SourceFieldId.keyPem: e.message});
    } catch (e) {
      if (!mounted) return;
      setState(() => _errors = {
            SourceFieldId.keyPem: '读取密钥文件失败：${normalizeSourceError(e)}',
          });
    }
  }

  Future<void> _importFallbackKey(int slot) async {
    try {
      final picked = await pickPrivateKeyFile();
      if (picked == null || !mounted) return;
      setState(() {
        _fallbacks[slot].form[SourceFieldId.keyPem].text = picked.pem;
        _fallbacks[slot].form.keyFileName = picked.fileName;
        _error = null;
      });
    } on InvalidPrivateKeyException catch (e) {
      if (!mounted) return;
      setState(() => _error = '${fallbackLabel(slot)}：${e.message}');
    } catch (e) {
      if (!mounted) return;
      setState(() =>
          _error = '${fallbackLabel(slot)}：读取密钥文件失败：${normalizeSourceError(e)}');
    }
  }

  // ---------- 保存 ----------

  Future<void> _submit() async {
    if (_saving) return;
    final direct = context.read<DirectSourceManager>();
    final valid = await _validate();
    if (valid == null || !mounted) return;

    // 备用先校验（格式），再与主源统一去重——与原先同样的顺序，避免半落库。
    final fallbackMaps = <Map<String, dynamic>>[];
    for (var i = 0; i < _fallbacks.length; i++) {
      final fb = _fallbacks[i];
      final fbResult = validateSource(fb.form, allowInsecureHttp: true);
      if (fbResult is SourceInvalid) {
        setState(() {
          _error = '${fallbackLabel(i)}：${fbResult.message}';
          _errors = const {};
        });
        fb.focusError(fbResult.field);
        return;
      }
      fallbackMaps.add(fb.form.toRawMap());
    }
    String? fbErr;
    try {
      fbErr = direct.validateFallbacks(_form.kind.name, valid.raw, fallbackMaps);
    } catch (_) {}
    if (fbErr != null) {
      setState(() => _error = fbErr);
      return;
    }

    // 编辑前记下旧链路：仅 route 真变化时才重载当前曲，避免改密码/改名等
    // 无关编辑打断正在播放。
    final oldRoute =
        _isEdit ? direct.sourceByKey(widget.editKey!)?.route : null;

    setState(() => _saving = true);
    try {
      await direct.saveSource(
        editKey: widget.editKey,
        kind: _form.kind,
        raw: valid.raw,
        fallbacks: fallbackMaps,
      );
      if (!mounted) return;

      // SFTP 未钉指纹仍允许保存（离线等场景），首次扫描/播放会明确引导先确认。
      if (_form.kind == SourceKind.sftp &&
          !isSshPinned(
            direct,
            _form.text(SourceFieldId.host),
            int.tryParse(_form.text(SourceFieldId.port)) ?? 22,
          )) {
        AppToast.show('已保存；首次使用前请点「测试连接」确认主机指纹', isError: false);
      }

      // 播放链路（直连↔代理）即时生效：若编辑的是正在播放的源且 route 变了，
      // 重载当前曲（保位置/保播放态），无需重启；已缓存歌曲内部自动跳过。
      if (_isEdit && oldRoute != null && oldRoute != _form.route) {
        final player = context.read<PlayerProvider>();
        final curKey = player.current?.sourceKey;
        // 同名编辑 key 不变；改名时新 key 为 kind:name，两种都判。
        final newKey = '${_form.kind.name}:${_form.text(SourceFieldId.name)}';
        if (curKey == widget.editKey || curKey == newKey) {
          // 先关弹窗再重载，避免 context 释放竞态。
          Navigator.of(context).pop();
          unawaited(player.reloadCurrentForPlaybackRoute().then((ok) {
            if (ok) {
              AppToast.show(
                  '已切换到${_form.route == SourceRoute.proxy ? '代理' : '直连'}链路',
                  isError: false);
            }
          }));
          return;
        }
      }
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = normalizeSourceError(e);
      });
    }
  }

  // ---------- 备用源 ----------

  void _addFallback() {
    if (_fallbacks.length >= kMaxFallbacks) return;
    setState(() => _fallbacks.add(SourceFallbackSlot.empty()));
  }

  void _removeFallback(int i) {
    setState(() {
      _fallbacks[i].dispose();
      _fallbacks.removeAt(i);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isLocal = _form.kind == SourceKind.local;
    return PopScope(
      // 保存中不允许关窗，避免写了一半的源状态不明。
      canPop: !_saving,
      child: AlertDialog(
        // 固定宽 512：`AlertDialog` 的内容会被包进 `IntrinsicWidth`，因此
        // content 里不能放 `LayoutBuilder` 或 shrink-wrap 不了的 viewport；
        // 用定宽而不是外层 `constraints` 撑开，窄屏由系统钳制。
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        // 编辑态的类型是既定事实（updateSource 无类型迁移），放在标题右侧
        // 做注解，不再单占一段「类型」分组。
        title: Row(
          children: [
            Flexible(
              child: Text(
                _isEdit ? '编辑播放源' : '添加播放源',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (_isEdit) ...[
              const SizedBox(width: 10),
              _KindChip(kind: _form.kind),
            ],
          ],
        ),
        content: SizedBox(
          width: 512,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 类型：仅新增态可选（编辑态已在标题里）。
                if (!_isEdit)
                  SourceFormSection(
                    title: '类型',
                    children: [
                      SingleChoiceGroup<SourceKind>(
                        options: sourceKindOptions,
                        value: _form.kind,
                        onChanged: _saving ? null : _onKindChanged,
                      ),
                    ],
                  ),
                SourceFormBuilder(
                  model: _form,
                  isFallback: false,
                  onChanged: _onFormChanged,
                  errors: _errors,
                  enabled: !_saving,
                  onPickDirectory: _pickDirectory,
                  onPickLocalFiles: _pickAudioFiles,
                  onRemoveLocalFile: (ref) => setState(() {
                    _form.localFiles = _form.localFiles
                        .where((e) => e.ref != ref)
                        .toList(growable: false);
                    _onFormChanged();
                  }),
                  onExpandLocalFiles: () =>
                      setState(() => _filesExpanded = !_filesExpanded),
                  localFilesExpanded: _filesExpanded,
                  onImportKeyFile: _importKeyFile,
                  onClearKey: () => setState(() {
                    _form[SourceFieldId.keyPem].clear();
                    _form.keyFileName = null;
                    _onFormChanged();
                  }),
                  // 测试连接进「连接」组头：本地源没有远端可测。
                  sectionTrailing: (title) {
                    if (title != '连接' || isLocal) return null;
                    return ConnectionTestRow(
                      status: _testStatus,
                      onTest: _test,
                      testLabel: '测试',
                      result: _testResult,
                      enabled: !_saving,
                    );
                  },
                ),
                SourceFallbackPanel(
                  slots: _fallbacks,
                  enabled: !_saving,
                  onAdd: _addFallback,
                  onRemove: _removeFallback,
                  onChanged: _onFormChanged,
                  onPickKeyFile: _importFallbackKey,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: cs.error)),
                ],
              ],
            ),
          ),
        ),
        actions: appDialogActions(
          context,
          confirmLabel: _isEdit ? '保存' : '添加',
          cancelEnabled: !_saving,
          confirmEnabled: !_saving,
          onCancel: () => Navigator.of(context).pop(),
          onConfirm: _submit,
        ),
      ),
    );
  }
}

/// 编辑态的类型徽标：放在标题右侧做注解。
///
/// 排版上比标题小一号、主色描边 + 主色浅底，与全站「选中态」同一套视觉语言，
/// 但不带交互（类型在编辑态不可改）。
class _KindChip extends StatelessWidget {
  const _KindChip({required this.kind});

  final SourceKind kind;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (IconData icon, String label) = switch (kind) {
      SourceKind.local => (Icons.folder_outlined, '本地'),
      SourceKind.smb => (Icons.dns_outlined, 'SMB'),
      SourceKind.webdav => (Icons.cloud_outlined, 'WebDAV'),
      SourceKind.sftp => (Icons.storage_outlined, 'SFTP'),
    };
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: BorderSide(color: cs.primary.withValues(alpha: 0.35)),
    );
    return Material(
      color: cs.primaryContainer.withValues(alpha: 0.55),
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: cs.onPrimaryContainer),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: cs.onPrimaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
