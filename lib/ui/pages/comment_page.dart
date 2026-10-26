import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/music_api.dart';
import 'comment_list_view.dart';

class CommentPage extends StatelessWidget {
  const CommentPage({super.key, required this.api, required this.mixsongid});

  final MusicApi api;
  final String mixsongid;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        // iOS 语义是「背景明暗」，与 Android 前景图标亮度取镜像值，
        // 否则浅色页面会出现白字白底不可见。
        statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
      ),
      child: Scaffold(
        appBar: AppBar(title: const Text('评论'), centerTitle: false),
        body: CommentListView(api: api, mixsongid: mixsongid),
      ),
    );
  }
}
