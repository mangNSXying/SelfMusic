import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../data/sources/music_source.dart';
import '../../../data/sources/sftp_common.dart';
import '../../../utils/format_bytes.dart';
import '../../../widgets/single_choice_group.dart';

import 'source_form_fields.dart';
import 'source_form_model.dart';
import 'source_form_widgets.dart';

const sftpAuthOptions = <SingleChoiceOption<SftpAuthMethod>>[
  SingleChoiceOption(value: SftpAuthMethod.password, label: '密码'),
  SingleChoiceOption(value: SftpAuthMethod.key, label: '密钥'),
];

const sourceRouteOptions = <SingleChoiceOption<SourceRoute>>[
  SingleChoiceOption(
    value: SourceRoute.direct,
    label: '直连',
    icon: Icons.bolt_outlined,
  ),
  SingleChoiceOption(
    value: SourceRoute.proxy,
    label: '代理',
    icon: Icons.cloud_outlined,
  ),
];

const sourceKindOptions = <SingleChoiceOption<SourceKind>>[
  SingleChoiceOption(
    value: SourceKind.local,
    label: '本地',
    icon: Icons.folder_outlined,
  ),
  SingleChoiceOption(
    value: SourceKind.smb,
    label: 'SMB',
    icon: Icons.dns_outlined,
  ),
  SingleChoiceOption(
    value: SourceKind.webdav,
    label: 'WebDAV',
    icon: Icons.cloud_outlined,
  ),
  SingleChoiceOption(
    value: SourceKind.sftp,
    label: 'SFTP',
    icon: Icons.storage_outlined,
  ),
];

const remoteKindOptions = <SingleChoiceOption<SourceKind>>[
  SingleChoiceOption(
    value: SourceKind.smb,
    label: 'SMB',
    icon: Icons.dns_outlined,
  ),
  SingleChoiceOption(
    value: SourceKind.webdav,
    label: 'WebDAV',
    icon: Icons.cloud_outlined,
  ),
  SingleChoiceOption(
    value: SourceKind.sftp,
    label: 'SFTP',
    icon: Icons.storage_outlined,
  ),
];

/// 主源与备用源共用的表单渲染器。
///
/// 按 [sourceSectionsOf] 的声明逐行渲染；本组件不持有业务状态，值全在
/// [model]，错误按字段 id 查 [errors]，交互回调由外层提供。
class SourceFormBuilder extends StatelessWidget {
  const SourceFormBuilder({
    super.key,
    required this.model,
    required this.isFallback,
    required this.onChanged,
    this.errors = const {},
    this.enabled = true,
    this.onPickDirectory,
    this.onPickLocalFiles,
    this.onRemoveLocalFile,
    this.onExpandLocalFiles,
    this.onImportKeyFile,
    this.onClearKey,
    this.localFilesExpanded = false,
    this.showLocalFilesToggle = true,
    this.sectionTrailing,
  });

  final SourceFormModel model;

  /// 备用源：无名称字段，且类型由外层卡头控制。
  final bool isFallback;

  /// 任意字段变化（用于清空旧的测试结果）。
  final VoidCallback onChanged;

  /// 字段级错误：由 `SourceInvalid.field` 落位。
  final Map<SourceFieldId, String> errors;

  final bool enabled;

  final VoidCallback? onPickDirectory;
  final VoidCallback? onPickLocalFiles;
  final void Function(String ref)? onRemoveLocalFile;
  final VoidCallback? onExpandLocalFiles;
  final VoidCallback? onImportKeyFile;
  final VoidCallback? onClearKey;
  final bool localFilesExpanded;
  final bool showLocalFilesToggle;

  /// 分组组头右侧的控件：按分组标题取。
  ///
  /// 「连接」组用它放测试按钮 + 连接状态，从而省掉底部那一整行。
  final Widget? Function(String sectionTitle)? sectionTrailing;

  void _changed() => onChanged();

  /// 窄容器阈值：低于此宽度时并排字段改成上下排列。
  ///
  /// 用 `MediaQuery` 而不是 `LayoutBuilder`：`AlertDialog` 的内容被包在
  /// `IntrinsicWidth` 里，`LayoutBuilder` 会在 intrinsic 计算时抛异常。
  static bool _isCompact(BuildContext context) =>
      MediaQuery.sizeOf(context).width < 520;

  @override
  Widget build(BuildContext context) {
    final sections = sourceSectionsOf(
      model.kind,
      isFallback: isFallback,
      authMethod: model.authMethod,
      filesMode: model.filesMode,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final section in sections)
          SourceFormSection(
            title: section.title,
            trailing: section.trailing
                ? sectionTrailing?.call(section.title)
                : null,
            children: _buildRows(context, section.rows),
          ),
      ],
    );
  }

  List<Widget> _buildRows(BuildContext context, List<SourceRowSpec> rows) {
    final out = <Widget>[];
    final compact = _isCompact(context);
    // 收集相邻的 half 字段，两两并排。
    final pair = <Widget>[];
    void flushPair() {
      while (pair.isNotEmpty) {
        if (pair.length >= 2) {
          out.add(SourceFieldRow(
            left: pair.removeAt(0),
            right: pair.removeAt(0),
            compact: compact,
          ));
        } else {
          out.add(pair.removeAt(0));
        }
        out.add(const SizedBox(height: 12));
      }
    }

    for (final row in rows) {
      switch (row) {
        case SourceTextFieldRow(:final spec):
          final w = _textField(spec);
          if (spec.span == SourceFieldSpan.half) {
            pair.add(w);
            if (pair.length == 2) flushPair();
          } else {
            flushPair();
            out.add(w);
            out.add(const SizedBox(height: 12));
          }
        case SourceKeyImportRow():
          flushPair();
          out.add(_keyImport(context));
          out.add(const SizedBox(height: 12));
        case SourceLocalFilesRow():
          flushPair();
          out.add(_localFiles(context));
          out.add(const SizedBox(height: 12));
        case SourceRouteRow():
          flushPair();
          // 行化：左「标题 + 说明」/ 右「当前值按钮组」，省掉独占一行的小节标题。
          out.add(SourceSettingRow(
            title: '播放链路',
            description: playbackRouteNote(model.route),
            trailing: SingleChoiceGroup<SourceRoute>(
              options: sourceRouteOptions,
              value: model.route,
              onChanged: enabled
                  ? (v) {
                      model.route = v;
                      _changed();
                    }
                  : null,
            ),
          ));
          out.add(const SizedBox(height: 12));
      }
    }
    flushPair();
    return out;
  }

  Widget _textField(SourceFieldSpec spec) {
    final error = errors[spec.id];
    final inline = spec.inline == null ? null : _inlineControl(spec.inline!);
    if (spec.secret) {
      return SourceSecretField(
        controller: model[spec.id],
        label: spec.label,
        note: spec.note,
        hint: spec.hint,
        helper: spec.helper,
        error: error,
        enabled: enabled,
        trailing: inline,
        onChanged: (_) => _changed(),
      );
    }
    // 本地目录字段带「选择文件夹」按钮。
    final isDirPicker =
        spec.id == SourceFieldId.path && model.kind == SourceKind.local;
    return SourceTextField(
      controller: model[spec.id],
      label: spec.label,
      note: spec.note,
      hint: spec.hint,
      helper: spec.helper,
      error: error,
      digitsOnly: spec.digitsOnly,
      keyboardType: spec.keyboardType,
      enabled: enabled,
      onChanged: (_) => _changed(),
      suffix: isDirPicker
          ? IconButton(
              icon: const Icon(Icons.folder_open),
              tooltip: '选择文件夹',
              onPressed: enabled ? onPickDirectory : null,
            )
          : inline,
    );
  }

  /// 字段旁的内联控件。目前只有 SFTP 认证方式一个。
  Widget? _inlineControl(SourceInlineControl control) {
    switch (control) {
      case SourceInlineControl.sftpAuthMethod:
        return _InlineSftpAuth(
          value: model.authMethod,
          enabled: enabled,
          onChanged: (v) {
            model.authMethod = v;
            _changed();
          },
        );
    }
  }

  /// 私钥导入：单行文件条。
  ///
  /// 未导入时整行是一个虚线边框的「导入密钥文件」入口；已导入时显示
  /// 「文件名 · 大小」+ 更换 / 清除，不再另起一行写状态文字。
  Widget _keyImport(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pem = model.raw(SourceFieldId.keyPem);
    final hasKey = pem.isNotEmpty;
    final fileName = model.keyFileName;
    final summary = !hasKey
        ? '未导入（支持 OpenSSH / PKCS8）'
        : fileName != null
            ? '$fileName · ${pem.length} 字符'
            : '已保存密钥 · ${pem.length} 字符';

    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(
        color: hasKey ? cs.outlineVariant : cs.outlineVariant.withValues(alpha: 0.7),
      ),
    );
    return Material(
      color: hasKey ? cs.surface : cs.surfaceContainerHighest.withValues(alpha: 0.35),
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        customBorder: shape,
        onTap: enabled ? onImportKeyFile : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
          child: Row(
            children: [
              Icon(Icons.key_outlined,
                  size: 16,
                  color: hasKey ? cs.primary : cs.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  summary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: hasKey ? cs.onSurface : cs.onSurfaceVariant,
                      ),
                ),
              ),
              if (hasKey)
                TextButton(
                  onPressed: enabled ? onImportKeyFile : null,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('更换'),
                )
              else
                TextButton(
                  onPressed: enabled ? onImportKeyFile : null,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('导入'),
                ),
              if (hasKey)
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: '清除已导入密钥',
                  visualDensity: VisualDensity.compact,
                  onPressed: enabled
                      ? () {
                          model[SourceFieldId.keyPem].clear();
                          model.keyFileName = null;
                          _changed();
                        }
                      : null,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _localFiles(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final files = model.localFiles;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '已选择 ${files.length} 个音频文件',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            TextButton.icon(
              onPressed: enabled ? onPickLocalFiles : null,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('选择音频文件'),
            ),
          ],
        ),
        if (files.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '还没有选择文件。支持 mp3 / flac / m4a / aac / ogg / wav / aiff，单次最多 500 个。',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
          )
        else ...[
          if (localFilesExpanded)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: files.length,
                itemBuilder: (context, index) {
                  final f = files[index];
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.audio_file_outlined, size: 20),
                    title: Text(f.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      f.size > 0 ? formatSourceBytes(f.size) : '大小未知',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      tooltip: '移除',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed:
                          enabled ? () => onRemoveLocalFile?.call(f.ref) : null,
                    ),
                  );
                },
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                '文件清单已收起',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
          if (showLocalFilesToggle)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onExpandLocalFiles,
                icon: Icon(
                  localFilesExpanded
                      ? Icons.expand_less
                      : Icons.expand_more,
                  size: 18,
                ),
                label: Text(localFilesExpanded ? '收起文件清单' : '展开文件清单'),
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: enabled && files.isNotEmpty
                  ? () {
                      model.localFiles = const [];
                      _changed();
                    }
                  : null,
              icon: const Icon(Icons.clear_all, size: 18),
              label: const Text('清空'),
            ),
          ),
        ],
        Text(
          '提示：保存后请点该源「扫描」建立索引；同目录歌词/封面不在授权范围，不会自动关联。',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: cs.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// SFTP 认证方式的内联切换：密码 / 密钥。
///
/// 认证方式描述的是「这个密码框里填的是什么」，所以贴在密码/密钥字段的
/// 输入框右侧，而不是自己单开一行。
class _InlineSftpAuth extends StatelessWidget {
  const _InlineSftpAuth({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final SftpAuthMethod value;
  final bool enabled;
  final ValueChanged<SftpAuthMethod> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 紧凑版：与输入框同高（44 → 34），放在 suffixIcon 位置不撑高文本框。
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final option in sftpAuthOptions) ...[
            if (option.value != sftpAuthOptions.first.value)
              const SizedBox(width: 4),
            _InlineChoiceButton(
              label: option.label,
              selected: option.value == value,
              enabled: enabled,
              onTap: () => onChanged(option.value),
              accent: cs.primary,
              onAccent: cs.onPrimaryContainer,
              idleBg: cs.surfaceContainerHighest,
              idleFg: cs.onSurfaceVariant,
              idleBorder: cs.outlineVariant,
            ),
          ],
        ],
      ),
    );
  }
}

/// 内联小号单选按钮：视觉与 [SingleChoiceGroup] 同族（填充选中 + 主色描边），
/// 只是更紧凑，用于贴合输入框的高度。
class _InlineChoiceButton extends StatelessWidget {
  const _InlineChoiceButton({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
    required this.accent,
    required this.onAccent,
    required this.idleBg,
    required this.idleFg,
    required this.idleBorder,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;
  final Color accent;
  final Color onAccent;
  final Color idleBg;
  final Color idleFg;
  final Color idleBorder;

  @override
  Widget build(BuildContext context) {
    final fg = !enabled
        ? idleFg.withValues(alpha: 0.38)
        : selected
            ? onAccent
            : idleFg;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(9),
      side: BorderSide(
        color: selected
            ? accent.withValues(alpha: enabled ? 1 : 0.4)
            : idleBorder,
      ),
    );
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: Material(
        color: selected
            ? accent.withValues(alpha: 0.14)
            : enabled
                ? idleBg
                : idleBg.withValues(alpha: 0.5),
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: shape,
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
            child: Text(
              label,
              style: TextStyle(
                color: fg,
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 文件大小展示（沿用弹窗原有口径）。
String formatSourceBytes(int bytes) => formatBytes(
      bytes,
      zero: '大小未知',
      minUnit: ByteUnit.b,
      kbDecimals: 1,
      mbDecimals: 1,
      gbDecimals: 2,
    );
