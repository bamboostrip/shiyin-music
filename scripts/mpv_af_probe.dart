// 一次性探针：用仓库内的真实 libmpv-2.dll 验证 af 属性接受哪种字符串
// 转义格式（诊断 "unsupported format for accessing property _setProperty(af, 1)"）。
// 运行：dart run scripts/mpv_af_probe.dart
// ignore_for_file: avoid_print, depend_on_referenced_packages
import 'dart:ffi';

import 'package:ffi/ffi.dart';

typedef MpvCreateC = Pointer<Void> Function();
typedef MpvCreateDart = Pointer<Void> Function();
typedef MpvInitializeC = Int32 Function(Pointer<Void>);
typedef MpvInitializeDart = int Function(Pointer<Void>);
typedef MpvDestroyC = Void Function(Pointer<Void>);
typedef MpvDestroyDart = void Function(Pointer<Void>);
typedef MpvErrorStringC = Pointer<Utf8> Function(Int32);
typedef MpvErrorStringDart = Pointer<Utf8> Function(int);
typedef MpvSetPropertyC = Int32 Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Int32,
  Pointer<Void>,
);
typedef MpvSetPropertyDart = int Function(
  Pointer<Void>,
  Pointer<Utf8>,
  int,
  Pointer<Void>,
);
typedef MpvGetPropertyC = Int32 Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Int32,
  Pointer<Pointer<Utf8>>,
);
typedef MpvGetPropertyDart = int Function(
  Pointer<Void>,
  Pointer<Utf8>,
  int,
  Pointer<Pointer<Utf8>>,
);
typedef MpvFreeC = Void Function(Pointer<Void>);
typedef MpvFreeDart = void Function(Pointer<Void>);

const mpvFormatString = 1;

void main() {
  final lib = DynamicLibrary.open(
    'build/windows/x64/runner/Debug/libmpv-2.dll',
  );
  final mpvCreate =
      lib.lookupFunction<MpvCreateC, MpvCreateDart>('mpv_create');
  final mpvInitialize =
      lib.lookupFunction<MpvInitializeC, MpvInitializeDart>('mpv_initialize');
  final mpvDestroy =
      lib.lookupFunction<MpvDestroyC, MpvDestroyDart>('mpv_destroy');
  final mpvErrorString =
      lib.lookupFunction<MpvErrorStringC, MpvErrorStringDart>('mpv_error_string');
  final mpvSetProperty =
      lib.lookupFunction<MpvSetPropertyC, MpvSetPropertyDart>('mpv_set_property');
  final mpvGetProperty =
      lib.lookupFunction<MpvGetPropertyC, MpvGetPropertyDart>('mpv_get_property');
  final mpvFree = lib.lookupFunction<MpvFreeC, MpvFreeDart>('mpv_free');

  final ctx = mpvCreate();
  if (ctx == nullptr) {
    print('mpv_create 失败');
    return;
  }
  final initCode = mpvInitialize(ctx);
  print('mpv_initialize => $initCode');

  String readAf() {
    final name = 'af'.toNativeUtf8();
    final out = calloc<Pointer<Utf8>>();
    final code = mpvGetProperty(ctx, name, mpvFormatString, out);
    final result = code == 0 ? out.value.toDartString() : '<$code>';
    if (code == 0) mpvFree(out.value.cast());
    calloc.free(out);
    calloc.free(name);
    return result;
  }

  void trySet(String label, String value) {
    final name = 'af'.toNativeUtf8();
    final val = value.toNativeUtf8();
    final pp = calloc<Pointer<Utf8>>()..value = val;
    final code = mpvSetProperty(ctx, name, mpvFormatString, pp.cast());
    final err = code < 0
        ? mpvErrorString(code).toDartString()
        : 'OK';
    print('[$label] code=$code $err  af=${code == 0 ? readAf() : "-"}');
    // 无论成败都清回空链，避免上一条的残留影响下一条的判定。
    final empty = ''.toNativeUtf8();
    final ppEmpty = calloc<Pointer<Utf8>>()..value = empty;
    mpvSetProperty(ctx, name, mpvFormatString, ppEmpty.cast());
    calloc.free(ppEmpty);
    calloc.free(empty);
    calloc.free(pp);
    calloc.free(val);
    calloc.free(name);
  }

  trySet('A 变速基线', 'scaletempo:scale=1.00000000');
  trySet(
    'B 括号+单段',
    'lavfi=[equalizer=f=31:t=q:w=1.2:g=5.0]',
  );
  trySet(
    'C 引号+单段',
    "lavfi='equalizer=f=31:t=q:w=1.2:g=5.0'",
  );
  trySet(
    'D 括号+两段逗号',
    'lavfi=[equalizer=f=31:t=q:w=1.2:g=5.0,equalizer=f=62:t=q:w=1.2:g=2.0]',
  );
  trySet(
    'E 引号+两段逗号',
    "lavfi='equalizer=f=31:t=q:w=1.2:g=5.0,equalizer=f=62:t=q:w=1.2:g=2.0'",
  );
  trySet(
    'F 旧firequalizer格式',
    "lavfi=[firequalizer=gain_entry='entry(31,5.0)']",
  );
  trySet('G stereotools括号', 'lavfi=[stereotools=slev=1.440]');
  trySet('H stereotools引号', "lavfi='stereotools=slev=1.440'");
  trySet(
    'I 变速+EQ整链',
    'scaletempo:scale=1.00000000,lavfi=[equalizer=f=31:t=q:w=1.2:g=5.0]',
  );

  mpvDestroy(ctx);
}
