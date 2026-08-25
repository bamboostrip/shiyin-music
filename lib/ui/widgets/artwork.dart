import 'dart:async';
import 'dart:math' show cos, pi;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/network_monitor.dart';

/// 网络图片，断网恢复后自动重试。
///
/// Flutter 的 [Image] 在 provider 不变时 rebuild 不会重新发起请求，
/// 断网期间失败的图片会一直停留在 errorBuilder 上，直到该 widget
/// 被销毁重建。这里监听 [NetworkMonitor] 的网络恢复事件，通过更换
/// key 强制重建内部 [Image] 重新加载；已成功的图片命中内存
/// ImageCache，重建无闪烁。
class RetryableNetworkImage extends StatefulWidget {
  const RetryableNetworkImage({
    super.key,
    required this.url,
    this.fit,
    this.cacheWidth,
    this.cacheHeight,
    this.loadingBuilder,
    this.errorBuilder,
  });

  final String url;
  final BoxFit? fit;
  final int? cacheWidth;
  final int? cacheHeight;
  final ImageLoadingBuilder? loadingBuilder;
  final ImageErrorWidgetBuilder? errorBuilder;

  @override
  State<RetryableNetworkImage> createState() => _RetryableNetworkImageState();
}

class _RetryableNetworkImageState extends State<RetryableNetworkImage> {
  int _generation = 0;
  StreamSubscription<void>? _networkRestoredSub;

  @override
  void initState() {
    super.initState();
    _networkRestoredSub = NetworkMonitor.instance.onConnectivityRestored.listen(
      (_) {
        if (mounted) setState(() => _generation++);
      },
    );
  }

  @override
  void dispose() {
    _networkRestoredSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Image.network(
      widget.url,
      // key 变化会让 Element 整体重建（而非复用 _ImageState），
      // 从而重新 resolve 图片、重新发起网络请求。
      key: ValueKey('retry-$_generation'),
      fit: widget.fit,
      cacheWidth: widget.cacheWidth,
      cacheHeight: widget.cacheHeight,
      errorBuilder: widget.errorBuilder,
      loadingBuilder: widget.loadingBuilder,
    );
  }
}

class Artwork extends StatefulWidget {
  const Artwork({
    super.key,
    this.url,
    required this.size,
    this.borderRadius = 8,
    this.icon = Icons.music_note_rounded,
  });

  final String? url;
  final double size;
  final double borderRadius;
  final IconData icon;

  @override
  State<Artwork> createState() => _ArtworkState();
}

class _ArtworkState extends State<Artwork> {
  @override
  Widget build(BuildContext context) {
    final imageUrl = widget.url;
    final child = imageUrl == null
        ? _Fallback(icon: widget.icon)
        : imageUrl.startsWith('content://')
            ? _ContentUriImage(
                uri: imageUrl,
                size: widget.size,
                borderRadius: widget.borderRadius,
                icon: widget.icon,
              )
            : RetryableNetworkImage(
                url: imageUrl,
                cacheWidth:
                    widget.size.isFinite
                        ? (widget.size * 2.0).ceil().clamp(1, 600)
                        : 600,
                cacheHeight:
                    widget.size.isFinite
                        ? (widget.size * 2.0).ceil().clamp(1, 600)
                        : 600,
                fit: BoxFit.cover,
                errorBuilder:
                    (context, error, stackTrace) => _Fallback(icon: widget.icon),
                loadingBuilder: (context, child, progress) {
                  if (progress == null) {
                    return child;
                  }
                  return _ShimmerBox(
                    size: widget.size,
                    borderRadius: widget.borderRadius,
                  );
                },
              );

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: widget.size.isFinite
          ? SizedBox.square(dimension: widget.size, child: child)
          : SizedBox.expand(child: child),
    );
  }
}

/// 加载 content:// URI 的图片（用于本地音乐专辑封面）。
class _ContentUriImage extends StatefulWidget {
  const _ContentUriImage({
    required this.uri,
    required this.size,
    required this.borderRadius,
    required this.icon,
  });

  final String uri;
  final double size;
  final double borderRadius;
  final IconData icon;

  @override
  State<_ContentUriImage> createState() => _ContentUriImageState();
}

class _ContentUriImageState extends State<_ContentUriImage> {
  static const _channel = MethodChannel('kgka_music_hl/local_music');
  Uint8List? _bytes;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    try {
      // 从 content URI 中提取 albumId
      final uri = widget.uri;
      final albumId = int.tryParse(uri.split('/').last);
      if (albumId == null || albumId <= 0) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final bytes = await _channel.invokeMethod<Uint8List>(
        'getAlbumArt',
        {'albumId': albumId},
      );
      if (mounted) {
        setState(() {
          _bytes = bytes;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return _ShimmerBox(size: widget.size, borderRadius: widget.borderRadius);
    }
    if (_bytes == null) {
      return _Fallback(icon: widget.icon);
    }
    return Image.memory(
      _bytes!,
      fit: BoxFit.cover,
      cacheWidth: widget.size.isFinite ? (widget.size * 2.0).ceil().clamp(1, 600) : 600,
      cacheHeight: widget.size.isFinite ? (widget.size * 2.0).ceil().clamp(1, 600) : 600,
    );
  }
}

class _Fallback extends StatelessWidget {
  const _Fallback({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.primary.withValues(alpha: .88),
            const Color(0xFF70D6FF),
            colorScheme.secondary.withValues(alpha: .72),
          ],
        ),
      ),
      child: Icon(icon, color: Colors.white, size: 28),
    );
  }
}

/// 图片加载时的 Shimmer 占位效果。
class _ShimmerBox extends StatefulWidget {
  const _ShimmerBox({required this.size, required this.borderRadius});

  final double size;
  final double borderRadius;

  @override
  State<_ShimmerBox> createState() => _ShimmerBoxState();
}

class _ShimmerBoxState extends State<_ShimmerBox> {
  static final _shared = _ShimmerNotifier();

  @override
  void initState() {
    super.initState();
    _shared.attach();
  }

  @override
  void dispose() {
    _shared.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseColor = isDark
        ? colorScheme.surfaceContainerHighest
        : colorScheme.surfaceContainer;
    final highlightColor = isDark
        ? colorScheme.surfaceContainerHighest.withValues(alpha: .4)
        : Colors.white.withValues(alpha: .6);

    return AnimatedBuilder(
      animation: _shared,
      builder: (context, child) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment(_shared.value - 0.5, 0),
                end: Alignment(_shared.value + 0.5, 0),
                colors: [baseColor, highlightColor, baseColor],
                stops: const [0, 0.5, 1],
              ),
            ),
            child: child,
          ),
        );
      },
      child: SizedBox(
        width: widget.size.isFinite ? widget.size : null,
        height: widget.size.isFinite ? widget.size : null,
      ),
    );
  }
}

class _ShimmerNotifier extends ChangeNotifier {
  Timer? _timer;
  int _refCount = 0;

  void attach() {
    _refCount++;
    _timer ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
      _elapsed = (_elapsed + 16) % 1200;
      _value = -cos(_elapsed / 1200.0 * pi);
      notifyListeners();
    });
  }

  void detach() {
    _refCount--;
    if (_refCount <= 0) {
      _refCount = 0;
      _timer?.cancel();
      _timer = null;
    }
  }

  double _elapsed = 0;
  double _value = -1.0;
  double get value => _value;
}
