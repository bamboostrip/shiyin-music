/// 评论列表（CommentPage 与歌曲详情页「评论」tab 共用）。
///
/// 自带分页加载/重试/空态；首屏成功后经 [onCountChanged] 回报总数，
/// 调用方可据此刷新 tab 标题（如 `评论655`）。
library;

import 'package:flutter/material.dart';

import '../../models/music_models.dart';
import '../../services/music_api.dart';

class CommentListView extends StatefulWidget {
  const CommentListView({
    super.key,
    required this.api,
    required this.mixsongid,
    this.onCountChanged,
  });

  final MusicApi api;
  final String mixsongid;

  /// 评论总数变化回调（首屏/翻页成功且上游带 count 时触发）。
  final ValueChanged<int?>? onCountChanged;

  @override
  State<CommentListView> createState() => _CommentListViewState();
}

class _CommentListViewState extends State<CommentListView> {
  static const _pageSize = 30;

  final _scrollController = ScrollController();
  final _comments = <MusicCommentItem>[];

  var _isLoading = true;
  var _isLoadingMore = false;
  var _hasMore = true;
  var _nextPage = 1;
  var _loadMoreError = false;
  String? _errorMessage;
  // 加载代际：初始加载（重试）会清空列表并复位 _nextPage，此时若有
  // 在途 loadMore，其旧页响应落地会造成重复/乱序，必须按代际丢弃。
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_maybeLoadMore);
    _loadInitial();
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_maybeLoadMore)
      ..dispose();
    _comments.clear();
    super.dispose();
  }

  Future<void> _loadInitial() async {
    final generation = ++_loadGeneration;
    setState(() {
      _isLoading = true;
      // 复位在途 loadMore 标记：其响应将被代际守卫丢弃，不复位会卡住后续翻页。
      _isLoadingMore = false;
      _errorMessage = null;
      _nextPage = 1;
      _hasMore = true;
      _comments.clear();
    });

    try {
      final data = await widget.api.musicComments(
        widget.mixsongid,
        page: 1,
        pageSize: _pageSize,
      );
      if (!mounted || generation != _loadGeneration) return;
      final list = data.list ?? const [];
      widget.onCountChanged?.call(data.count);
      setState(() {
        _comments.addAll(list);
        _nextPage = 2;
        _hasMore = list.length == _pageSize;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _errorMessage = error.toString();
        _isLoading = false;
      });
    }
  }

  void _maybeLoadMore() {
    if (!_scrollController.hasClients || !_hasMore || _isLoadingMore) return;
    if (_scrollController.position.extentAfter < 320) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMore) return;
    final generation = _loadGeneration;
    setState(() {
      _isLoadingMore = true;
      _loadMoreError = false;
    });

    try {
      final data = await widget.api.musicComments(
        widget.mixsongid,
        page: _nextPage,
        pageSize: _pageSize,
      );
      // 初始加载/重试已重建列表：旧页响应作废（_isLoadingMore 已被复位）。
      if (!mounted || generation != _loadGeneration) return;
      final list = data.list ?? const [];
      widget.onCountChanged?.call(data.count);
      setState(() {
        _comments.addAll(list);
        _nextPage++;
        _hasMore = list.length == _pageSize;
        _isLoadingMore = false;
      });
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _isLoadingMore = false;
        _loadMoreError = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('评论加载失败', style: Theme.of(context).textTheme.bodyLarge),
              const SizedBox(height: 8),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _loadInitial,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    if (_comments.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.comment_outlined,
              size: 56,
              color: Theme.of(
                context,
              ).colorScheme.onSurfaceVariant.withValues(alpha: .42),
            ),
            const SizedBox(height: 16),
            Text(
              '还没有人评论，快来抢沙发吧！',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      itemCount: _comments.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _comments.length) {
          // 加载更多失败时展示点击重试，避免页脚永远转圈（样式对齐云盘页 _LoadMoreFooter）
          if (_loadMoreError) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: TextButton.icon(
                  onPressed: _loadMore,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('加载失败，点击重试'),
                ),
              ),
            );
          }
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return _CommentRow(comment: _comments[index]);
      },
    );
  }
}

class _CommentRow extends StatelessWidget {
  const _CommentRow({required this.comment});

  final MusicCommentItem comment;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 18,
            backgroundImage: comment.userPic != null
                ? ResizeImage(
                    NetworkImage(comment.userPic!),
                    width: 72,
                    height: 72,
                  )
                : null,
            child: comment.userPic == null
                ? Icon(
                    Icons.person_rounded,
                    size: 18,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  )
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  comment.userName ?? '匿名用户',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  comment.content ?? '',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(
                      Icons.thumb_up_outlined,
                      size: 14,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${comment.like?.count ?? 0}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Text(
                      comment.addtime ?? '',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
