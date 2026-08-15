import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../../models/music_models.dart';
import '../../services/music_api.dart';
import '../widgets/artwork.dart';
import '../widgets/mini_player.dart';
import 'playlist_detail_page.dart';

class AlbumShopPage extends StatefulWidget {
  const AlbumShopPage({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
    required this.initialAlbums,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final List<AlbumShopItem> initialAlbums;

  @override
  State<AlbumShopPage> createState() => _AlbumShopPageState();
}

class _AlbumShopPageState extends State<AlbumShopPage> {
  final _scrollController = ScrollController();
  final _albums = <AlbumShopItem>[];
  var _nextPage = 1;
  var _hasMore = true;
  var _isLoadingMore = false;

  @override
  void initState() {
    super.initState();
    _albums.addAll(widget.initialAlbums);
    _nextPage = 2;
    _scrollController.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_maybeLoadMore)
      ..dispose();
    _albums.clear();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (!_scrollController.hasClients || !_hasMore || _isLoadingMore) return;
    if (_scrollController.position.extentAfter < 500) _loadMore();
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMore) return;
    setState(() => _isLoadingMore = true);
    try {
      final newAlbums = await widget.api.albumShop(page: _nextPage);
      if (!mounted) return;
      setState(() {
        _albums.addAll(newAlbums);
        _nextPage++;
        _hasMore = newAlbums.length >= 30;
        _isLoadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  void _openAlbum(AlbumShopItem album) {
    final playlist = PlaylistSummary(
      id: album.mediaId.toString(),
      title: album.albumName,
      subtitle: album.singerName,
      coverUrl: album.coverUrl,
      // 标记专辑侧 ID，使 isCollectedAlbum/albumId 走专辑分支（/album/songs）。
      sourceListId: album.mediaId.toString(),
    );
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlaylistDetailPage(
          api: widget.api,
          auth: widget.auth,
          player: widget.player,
          playlist: playlist,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final size = MediaQuery.sizeOf(context);
    // 多列自适应是车机横屏专属；普通横屏/竖屏保持原项目固定 2 列。
    final isCarLandscape =
        size.width > size.height && ThemeController.instance.carModeEnabled;
    final crossAxisCount = isCarLandscape
        ? (size.width / 180).floor().clamp(2, 5)
        : 2;

    return Scaffold(
      extendBody: true,
      body: Stack(
        children: [
          CustomScrollView(
            controller: _scrollController,
            slivers: [
              SliverAppBar(
                pinned: true,
                title: const Text(
                  '新碟上架',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: crossAxisCount,
                    mainAxisSpacing: 14,
                    crossAxisSpacing: 14,
                    childAspectRatio: 0.72,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final album = _albums[index];
                      return _AlbumCard(
                        album: album,
                        onTap: () => _openAlbum(album),
                      );
                    },
                    childCount: _albums.length,
                  ),
                ),
              ),
              if (_isLoadingMore)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(18, 8, 18, 118),
                    child: Center(
                      child: SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      ),
                    ),
                  ),
                )
              else if (!_hasMore)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(18, 8, 18, 118),
                    child: Center(
                      child: Text(
                        '已加载全部',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Colors.grey,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: bottomInset + 10,
            child: MiniPlayer(player: widget.player, auth: widget.auth),
          ),
        ],
      ),
    );
  }
}

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({required this.album, required this.onTap});

  final AlbumShopItem album;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Artwork(
              url: album.coverUrl,
              size: double.infinity,
              borderRadius: 12,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            album.albumName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            album.singerName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          if (album.priceText.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              album.priceText,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
