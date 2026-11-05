import 'package:flutter/material.dart';
import '../../providers/navigation_provider.dart';
import '../library/album_detail.dart';
import '../library/artist_detail.dart';

Widget detailPageOf(BuildContext context, ContentRoute route) {
  return switch (route) {
    AlbumDetailRoute(:final album, :final songs) =>
      AlbumDetailPage(album: album, songs: songs),
    ArtistDetailRoute(:final artist, :final songs) =>
      ArtistDetailPage(artist: artist, songs: songs),
    _ => const SizedBox.shrink(),
  };
}
