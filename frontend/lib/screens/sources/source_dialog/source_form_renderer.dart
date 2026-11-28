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
        case SourceAuthMethodRow():
          flushPair();
          out.add(SingleChoiceGroup<SftpAuthMethod>(
            options: sftpAuthOptions,
            value: model.authMethod,
            onChanged: enabled
                ? (v) {
                    model.authMethod = v;
                    _changed();
                  }
                : null,
          ));
          out.add(const SizedBox(height: 12));
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
          out.add(SingleChoiceGroup<SourceRoute>(
            options: sourceRouteOptions,
            value: model.route,
            onChanged: enabled
                ? (v) {
                    model.route = v;
                    _changed();
                  }
                : null,
          ));
          out.add(const SizedBox(height: 6));
          out.add(Text(
            playbackRouteNote(model.route),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.6),
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
    if (spec.secret) {
      return SourceSecretField(
        controller: model[spec.id],
        label: spec.label,
        note: spec.note,
        hint: spec.hint,
        helper: spec.helper,
        error: error,
        enabled: enabled,
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
          : null,
    );
  }

  Widget _keyImport(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasKey = model.raw(SourceFieldId.keyPem).isNotEmpty;
    final status = !hasKey
        ? '未导入（支持 OpenSSH / PKCS8 私钥）'
        : model.keyFileName != null
            ? '已导入 ${model.keyFileName}（${model.raw(SourceFieldId.keyPem).length} 字符）'
            : '已保存密钥（${model.raw(SourceFieldId.keyPem).length} 字符）';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: enabled ? onImportKeyFile : null,
                icon: const Icon(Icons.key_outlined, size: 18),
                label: const Text('导入密钥文件'),
              ),
            ),
            if (hasKey) ...[
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.clear, size: 18),
                tooltip: '清除已导入密钥',
                onPressed: enabled
                    ? () {
                        model[SourceFieldId.keyPem].clear();
                        model.keyFileName = null;
                        _changed();
                      }
                    : null,
              ),
            ],
          ],
        ),
        const SizedBox(height: 4),
        Text(
          status,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: cs.onSurfaceVariant),
        ),
      ],
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

/// 文件大小展示（沿用弹窗原有口径）。
String formatSourceBytes(int bytes) => formatBytes(
      bytes,
      zero: '大小未知',
      minUnit: ByteUnit.b,
      kbDecimals: 1,
      mbDecimals: 1,
      gbDecimals: 2,
    );
