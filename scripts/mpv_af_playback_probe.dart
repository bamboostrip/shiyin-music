// 播放级探针：让真实 libmpv-2.dll 实际播放生成的正弦波 WAV，验证 lavfi
// 音效图能否在起播时真正配置成功（属性层 set 成功≠图配置成功，真机上
// 'aresample' filter not present 就是图配置阶段才暴露的）。
// 运行：dart run scripts/mpv_af_playback_probe.dart
// ignore_for_file: avoid_print, depend_on_referenced_packages
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final class MpvEvent extends Struct {
  @Int32()
  external int eventId;
  @Int32()
  external int error;
  @Uint64()
  external int replyUserdata;
  external Pointer<Void> data;
}

final class MpvEventLogMessage extends Struct {
  @Int32()
  external int level;
  @Int32()
  external int padding;
  external Pointer<Utf8> prefix;
  external Pointer<Utf8> text;
  external Pointer<Utf8> logLevel;
}

final class MpvEventEndFile extends Struct {
  @Int32()
  external int reason;
  @Int32()
  external int error;
}

const _eventShutdown = 1;
const _eventLogMessage = 2;
const _eventEndFile = 7;

String _wavPath({bool float32 = false}) {
  // 1 秒 44.1kHz 立体声正弦（1kHz，幅值 0.25）。float32=false 生成 s16 PCM
  // （最常见解码输出，触发 equalizer 的格式转换需求）；true 生成 IEEE
  // float32 WAV（解码原生输出 float，验证"源格式匹配即可免 aresample"）。
  const sampleRate = 44100;
  const seconds = 1;
  const frames = sampleRate * seconds;
  final bytes = BytesBuilder();
  void le16(int v) {
    bytes.addByte(v & 0xff);
    bytes.addByte((v >> 8) & 0xff);
  }

  void le32(int v) {
    bytes.addByte(v & 0xff);
    bytes.addByte((v >> 8) & 0xff);
    bytes.addByte((v >> 16) & 0xff);
    bytes.addByte((v >> 24) & 0xff);
  }

  final bytesPerSample = float32 ? 4 : 2;
  final dataBytes = frames * 2 /*ch*/ * bytesPerSample;
  bytes.add('RIFF'.codeUnits);
  le32(36 + dataBytes);
  bytes.add('WAVE'.codeUnits);
  bytes.add('fmt '.codeUnits);
  le32(16);
  le16(float32 ? 3 : 1); // 3=IEEE float, 1=PCM
  le16(2); // stereo
  le32(sampleRate);
  le32(sampleRate * 2 * bytesPerSample);
  le16(2 * bytesPerSample);
  le16(bytesPerSample * 8);
  bytes.add('data'.codeUnits);
  le32(dataBytes);
  for (var i = 0; i < frames; i++) {
    final v = math.sin(2 * math.pi * 1000 * i / sampleRate) * 0.25;
    if (float32) {
      final b = ByteData(4)..setFloat32(0, v, Endian.little);
      // 左右声道各写一次同样的样本。
      bytes.add(b.buffer.asUint8List());
      bytes.add((ByteData(4)..setFloat32(0, v, Endian.little))
          .buffer
          .asUint8List());
    } else {
      final s = (v * 32767).round();
      le16(s);
      le16(s);
    }
  }
  final file = File(float32
      ? 'build/mpv_probe_input_f32.wav'
      : 'build/mpv_probe_input.wav');
  file.createSync(recursive: true);
  file.writeAsBytesSync(bytes.takeBytes());
  return file.absolute.path.replaceAll('\\', '/');
}

void main() {
  final lib = DynamicLibrary.open(
    'build/windows/x64/runner/Debug/libmpv-2.dll',
  );
  final mpvCreate =
      lib.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
    'mpv_create',
  );
  final mpvInitialize = lib.lookupFunction<
      Int32 Function(Pointer<Void>),
      int Function(Pointer<Void>)>('mpv_initialize');
  final mpvDestroy = lib.lookupFunction<
      Void Function(Pointer<Void>),
      void Function(Pointer<Void>)>('mpv_destroy');
  final mpvWaitEvent = lib.lookupFunction<
      Pointer<MpvEvent> Function(Pointer<Void>, Double),
      Pointer<MpvEvent> Function(Pointer<Void>, double)>('mpv_wait_event');
  final mpvRequestLog = lib.lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Utf8>),
      int Function(Pointer<Void>, Pointer<Utf8>)>(
    'mpv_request_log_messages',
  );
  final mpvSetProperty = lib.lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Utf8>, Int32, Pointer<Void>),
      int Function(Pointer<Void>, Pointer<Utf8>, int, Pointer<Void>)>(
    'mpv_set_property',
  );
  final mpvCommand = lib.lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Pointer<Utf8>>),
      int Function(Pointer<Void>, Pointer<Pointer<Utf8>>)>('mpv_command');

  int setString(Pointer<Void> ctx, String name, String value) {
    final n = name.toNativeUtf8();
    final v = value.toNativeUtf8();
    final pp = calloc<Pointer<Utf8>>()..value = v;
    final code = mpvSetProperty(ctx, n, 1, pp.cast());
    calloc
      ..free(pp)
      ..free(v)
      ..free(n);
    return code;
  }

  void probe(
    String label,
    String? afValue,
    String? audioFormat, {
    String? file,
  }) {
    final wav = file ?? _wavPath();
    final ctx = mpvCreate();
    mpvInitialize(ctx);
    setString(ctx, 'ao', 'null');
    if (audioFormat != null) {
      final code = setString(ctx, 'audio-format', audioFormat);
      print('  (audio-format=$audioFormat 设置返回 $code)');
    }
    if (afValue != null) {
      final code = setString(ctx, 'af', afValue);
      if (code < 0) {
        print('[$label] af 属性写入即失败 code=$code');
        mpvDestroy(ctx);
        return;
      }
    }
    final level = 'v'.toNativeUtf8();
    mpvRequestLog(ctx, level);
    calloc.free(level);

    final args = [
      'loadfile',
      wav,
    ].map((e) => e.toNativeUtf8()).toList();
    final argv = calloc<Pointer<Utf8>>(args.length + 1);
    for (var i = 0; i < args.length; i++) {
      argv[i] = args[i];
    }
    argv[args.length] = nullptr.cast();
    mpvCommand(ctx, argv.cast());
    for (final p in args) {
      calloc.free(p);
    }
    calloc.free(argv);

    var aresampleMissing = false;
    var filterDisabled = false;
    var endReason = -99;
    for (var i = 0; i < 200; i++) {
      final event = mpvWaitEvent(ctx, 0.2);
      final id = event.ref.eventId;
      if (id == _eventLogMessage) {
        final msg = event.ref.data.cast<MpvEventLogMessage>().ref;
        final text = msg.text == nullptr ? '' : msg.text.toDartString();
        if (text.contains("'aresample' filter not present")) {
          aresampleMissing = true;
        }
        if (text.contains('Disabling filter')) {
          filterDisabled = true;
        }
      } else if (id == _eventEndFile) {
        endReason = event.ref.data.cast<MpvEventEndFile>().ref.reason;
      } else if (id == _eventShutdown) {
        break;
      }
      if (endReason != -99) {
        // END_FILE 后再抽两轮事件收尾日志。
        if (i > 0 && event.ref.eventId == 0) break;
      }
    }
    print(
      '[$label] endReason=$endReason '
      'aresample缺失=$aresampleMissing 滤镜被禁用=$filterDisabled',
    );
    mpvDestroy(ctx);
  }

  const eq = 'lavfi=[equalizer=f=1000:t=q:w=1.2:g=10.0]';
  const fullChain =
      'scaletempo:scale=1.00000000,'
      'lavfi=[equalizer=f=31:t=q:w=1.2:g=5.0,equalizer=f=1000:t=q:w=1.2:g=10.0]';

  probe('A 复现：EQ链·默认格式', eq, null);
  probe('B EQ链·audio-format=float', eq, 'float');
  probe('C 整链(变速+EQ)·float', fullChain, 'float');
  probe('D 控制组：无af·float', null, 'float');
  probe('E 原生float32源·EQ链', eq, null, file: _wavPath(float32: true));
  probe('F audio-format=floatp尝试', eq, 'floatp');
  probe('G 原生float32源·整链', fullChain, null, file: _wavPath(float32: true));
}
