/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:ffi';

import 'package:media_kit/generated/libmpv/bindings.dart' as generated;
import 'package:media_kit/src/player/native/core/execmem_restriction.dart';
import 'package:media_kit/src/player/native/core/initializer_isolate.dart';
import 'package:media_kit/src/player/native/core/initializer_native_callable.dart';
import 'package:media_kit/src/values.dart';

/// {@template initializer}
///
/// Initializer
/// -----------
/// Initializes [Pointer<mpv_handle>] & notifies about events through the supplied callback.
///
/// {@endtemplate}
class Initializer {
  /// Singleton instance.
  static Initializer? _instance;

  /// {@macro initializer}
  Initializer._(this.mpv);

  /// {@macro initializer}
  factory Initializer(generated.MPV mpv) {
    _instance ??= Initializer._(mpv);
    return _instance!;
  }

  /// Generated libmpv C API bindings.
  final generated.MPV mpv;

  /// Creates [Pointer<mpv_handle>].
  Future<Pointer<generated.mpv_handle>> create(
    Future<void> Function(Pointer<generated.mpv_event>) callback, {
    Map<String, String> options = const {},
  }) async {
    // LOCAL PATCH (hot restart crash fix, shiyin-music):
    // In debug/profile mode (or on execmem-restricted platforms), use InitializerIsolate
    // instead of InitializerNativeCallable.
    //
    // Root Cause: During Flutter Hot Restart ('R'), the root Dart isolate is abruptly
    // killed, and the Dart VM marks all NativeCallable callbacks belonging to it as deleted.
    // However, libmpv's background OS thread continues running in the Windows process.
    // Any wakeup callback triggered by libmpv will invoke the deleted callback pointer,
    // crashing the Dart VM fatally with:
    //   "Callback invoked after it has been deleted" (runtime_entry.cc:5143).
    // InitializerIsolate uses Isolate.spawn and an internal mpv_wait_event loop without
    // registering any native callback with libmpv, completely eliminating the crash.
    if (!kReleaseMode || isExecmemRestricted) {
      return InitializerIsolate().create(callback, options: options);
    } else {
      return InitializerNativeCallable(mpv).create(callback, options: options);
    }
  }

  /// Disposes [Pointer<mpv_handle>].
  void dispose(Pointer<generated.mpv_handle> ctx) {
    if (!kReleaseMode || isExecmemRestricted) {
      InitializerIsolate().dispose(mpv, ctx);
    } else {
      InitializerNativeCallable(mpv).dispose(ctx);
    }
  }
}
