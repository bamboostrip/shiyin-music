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
        statusBarBrightness: isDark ? Brightness.light : Brightness.dark,
      ),
      child: Scaffold(
        appBar: AppBar(title: const Text('评论'), centerTitle: false),
        body: CommentListView(api: api, mixsongid: mixsongid),
      ),
    );
  }
}
