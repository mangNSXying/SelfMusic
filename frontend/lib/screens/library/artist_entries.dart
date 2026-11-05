import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import '../../providers/library_provider.dart';
import '../../layout/app_shell.dart';
import '../../navigation/detail_target.dart';
import '../../models/artist.dart';
import '../../services/artist_resolver.dart';
import '../../utils/zh_variant.dart';
import '../../widgets/app_dialog_actions.dart';
import '../../widgets/draggable_sheet.dart';
import '../../widgets/row_list.dart';
import '../../widgets/row_action_button.dart';
import '../../widgets/song_tile.dart';
import '../../widgets/square_card.dart';
import 'artist_detail.dart';

/// 打开歌手（卡片/列表两种形态共用，唯一分流入口）。
///
/// 按 [Artist.resolveState] 分流，未解析成功的歌手一律不进歌曲列表：
/// - confirm（同名多真人需人工确认）→ 弹候选选择页；
/// - retry（待解析/未命中）→ 弹「重试解析」确认窗；
/// - normal（已解析/非 identity 模式）→ 打开歌曲弹层。
///
/// [fromDetail] = true 表示从详情内部（成员/组合身份行）进入：分栏时压在
/// 上一层之上（可逐级返回），而不是当作左栏换选中项。
void openArtist(BuildContext context, Artist artist, ArtistResolver resolver,
    {bool fromDetail = false}) {
  switch (artist.resolveState) {
    case ArtistResolveState.confirm:
      _showAmbiguousPicker(context, artist, resolver);
      return;
    case ArtistResolveState.retry:
      _showRetryConfirm(context, artist, resolver);
      return;
    case ArtistResolveState.normal:
      break;
  }
  final lib = context.read<LibraryProvider>();
  final songs = lib.artistSongs(artist);
  if (!context.mounted) return;
  if (AppShell.isWide(context)) {
    openDetail(context, ArtistTarget(artist, songs, fromDetail: fromDetail));
    return;
  }
  showAppDraggableSheet<void>(
    context,
    // 弹层可上拉到全高：顶部安全区由统一窗口的路由外层 SafeArea 消费
    // （否则盖住时间/电量，见 artist_sheet_gesture_test 回归）。
    builder: (c, scrollCtrl) =>
        ArtistSongsSheet(artist: artist, songs: songs, scrollCtrl: scrollCtrl),
  );
}

/// 歧义身份候选选择（候选来自 MB 搜索 hit，零额外请求）。
Future<void> _showAmbiguousPicker(
    BuildContext context, Artist artist, ArtistResolver resolver) async {
  final canonicalKey = artist.canonicalKey;
  if (canonicalKey == null) return;
  final candidates = await resolver.candidatesFor(canonicalKey);
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (c) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      builder: (c2, scrollCtrl) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('选择「${zhDisplay(artist.name)}」对应的真人',
                style: Theme.of(c)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('本地多个不同写法的歌手指向同名的可能身份，请选择其一；'
                '未列出的可稍后重试。'),
          ),
          const Divider(height: 1),
          Expanded(
            child: candidates.isEmpty
                ? _AmbiguousEmptyState(
                    resolver: resolver,
                    canonicalKey: canonicalKey,
                  )
                : RowList(
                    controller: scrollCtrl,
                    count: candidates.length,
                    itemBuilder: (c3, i) {
                      final h = candidates[i];
                      return ListTile(
                        leading: const CircleAvatar(child: Icon(Icons.person)),
                        title: Text(zhDisplay(h.name),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          [
                            if (h.sortName != null && h.sortName != h.name)
                              zhDisplay(h.sortName!),
                            if (h.type != null) h.type,
                            if (h.disambiguation != null)
                              zhDisplay(h.disambiguation!),
                            if (h.beginYear != null)
                              '${h.beginYear}—${h.endYear ?? '…'}',
                          ].join(' · '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () async {
                          await resolver.bindManual(canonicalKey, h);
                          if (c3.mounted) Navigator.of(c3).pop();
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
  );
}

/// 候选为空（重试后仍无可选）时的空态：
/// 网络不可用与“确实无候选”分开提示，并给出「重试解析」立即再试。
class _AmbiguousEmptyState extends StatelessWidget {
  final ArtistResolver resolver;
  final String canonicalKey;
  const _AmbiguousEmptyState({
    required this.resolver,
    required this.canonicalKey,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final offline = resolver.networkDown;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(offline ? Icons.wifi_off : Icons.search_off,
              size: 40, color: cs.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(offline ? '网络不可用，可稍后再试' : '暂无可选候选，稍后自动重试',
              style: TextStyle(color: cs.onSurfaceVariant)),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重试解析'),
            onPressed: () async {
              await resolver.retryOne(canonicalKey);
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
        ],
      ),
    );
  }
}

/// 未命中/待解析歌手：手动立即重试确认。
Future<void> _showRetryConfirm(
    BuildContext context, Artist artist, ArtistResolver resolver) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text('重试解析「${zhDisplay(artist.name)}」？'),
      content: Text(artist.status == 'local'
          ? '上次解析未找到可靠身份（MusicBrainz 可能未收录），确认后立即重试。'
          : '该歌手尚未解析，确认后立即尝试。'),
      actions: appDialogActions(
        c,
        confirmLabel: '重试',
        onCancel: () => Navigator.of(c).pop(false),
        onConfirm: () => Navigator.of(c).pop(true),
      ),
    ),
  );
  if (ok == true) {
    final canonicalKey = artist.canonicalKey;
    if (canonicalKey != null) await resolver.retryOne(canonicalKey);
  }
}

class ArtistListTile extends StatelessWidget {
  final Artist artist;

  /// 分栏时是否为「当前详情」对应的左栏行（只做底色提示，不改文字色）。
  final bool active;
  const ArtistListTile({required this.artist, this.active = false});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      tileColor: active
          ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.10)
          : null,
      // 歌手用圆形头像（其余集合行统一圆角方形）。
      leading: CoverThumb(
        coverPath: artist.coverPath,
        fallbackIcon: Icons.person,
        shape: CoverShape.circle,
      ),
      title: Text(zhDisplay(artist.name),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context)
              .textTheme
              .bodyLarge
              ?.copyWith(fontWeight: FontWeight.w600)),
      subtitle: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${artist.songCount}首 · ${artist.albumCount}张专辑',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          if (artist.resolveState == ArtistResolveState.confirm)
            ..._statusChip(context),
        ],
      ),
      trailing: switch (artist.resolveState) {
        ArtistResolveState.retry => RowActionIconButton(
            icon: Icons.refresh,
            tooltip: '重试解析',
            onPressed: () =>
                openArtist(context, artist, context.read<ArtistResolver>()),
          ),
        ArtistResolveState.confirm =>
          const Icon(Icons.help_outline, size: 20, color: Colors.orange),
        ArtistResolveState.normal => null,
      },
      onTap: () => openArtist(context, artist, context.read<ArtistResolver>()),
    );
  }
}

/// 身份状态小徽标（歧义/未匹配在地图右侧展示）。
List<Widget> _statusChip(BuildContext context) => [
      const SizedBox(width: 8),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Text('需确认',
            style: TextStyle(fontSize: 11, color: Colors.orange)),
      ),
    ];

class ArtistCard extends StatelessWidget {
  final Artist artist;
  const ArtistCard({required this.artist});

  @override
  Widget build(BuildContext context) => SquareCard(
        title: zhDisplay(artist.name),
        subtitle: artist.resolveState == ArtistResolveState.confirm
            ? '${artist.songCount}首 · ${artist.albumCount}张专辑 · 需确认'
            : '${artist.songCount}首 · ${artist.albumCount}张专辑',
        coverPath: artist.coverPath,
        fallbackIcon: Icons.person,
        // 未解析成功的歌手：封面右上角叠状态角标（重试/需确认），
        // 点击角标与整卡一致走 openArtist（只弹解析交互，不进歌曲）。
        cornerAction: switch (artist.resolveState) {
          ArtistResolveState.normal => null,
          ArtistResolveState.confirm =>
            const _StatusBadge(icon: Icons.help_outline, color: Colors.orange),
          ArtistResolveState.retry =>
            const _StatusBadge(icon: Icons.refresh, color: Colors.white),
        },
        onTap: () =>
            openArtist(context, artist, context.read<ArtistResolver>()),
      );
}

class _StatusBadge extends StatelessWidget {
  final IconData icon;
  final Color color;
  const _StatusBadge({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(4),
        child: DecoratedBox(
          decoration: const BoxDecoration(
            color: Colors.black45,
            shape: BoxShape.circle,
          ),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(icon, size: 16, color: color),
          ),
        ),
      );
}
