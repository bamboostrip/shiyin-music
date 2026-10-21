import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/services/desktop_audio_filters.dart';

/// 滤镜链字符串钉死测试：mpv af 值逐字符断言，防转义/分隔符回归
/// （真机教训：写入运行时不支持的滤镜会打断播放，见实现注释）。
void main() {
  const centers = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];

  test('全部关闭时产出空链', () {
    expect(
      DesktopAudioFilters.build(
        equalizerEnabled: false,
        centerHz: centers,
        levelsMillibels: List.filled(10, 0),
      ),
      isEmpty,
    );
  });

  test('EQ 开启产出 biquad 链，毫贝尔转 dB 且跳过零增益段', () {
    final filters = DesktopAudioFilters.build(
      equalizerEnabled: true,
      centerHz: centers,
      levelsMillibels: [500, 0, 0, 0, 0, 0, 0, 0, 0, 250],
    );
    expect(filters, hasLength(1));
    expect(
      filters.single,
      "lavfi=[equalizer=f=31:t=q:w=1.2:g=5.0,"
      "equalizer=f=16000:t=q:w=1.2:g=2.5]",
    );
  });

  test('低音增强在 EQ 关闭时仍产出低频抬升链', () {
    final filters = DesktopAudioFilters.build(
      equalizerEnabled: false,
      centerHz: centers,
      levelsMillibels: List.filled(10, 0),
      bassEnabled: true,
      bassStrength: 0.5,
    );
    // 满强度 +12dB：0.5 → 31Hz +6.0 / 62Hz +4.2 / 125Hz +2.1，其余跳过。
    expect(
      filters.single,
      "lavfi=[equalizer=f=31:t=q:w=1.2:g=6.0,"
      "equalizer=f=62:t=q:w=1.2:g=4.2,"
      "equalizer=f=125:t=q:w=1.2:g=2.1]",
    );
  });

  test('EQ 与低音叠加时低频点为两者之和', () {
    final filters = DesktopAudioFilters.build(
      equalizerEnabled: true,
      centerHz: centers,
      levelsMillibels: [300, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      bassEnabled: true,
      bassStrength: 1.0,
    );
    // 31Hz = 3.0(EQ) + 12.0(bass 满强度) = 15.0。
    expect(filters.single, contains('equalizer=f=31:t=q:w=1.2:g=15.0'));
  });

  test('环绕映射 stereotools 边声道增益', () {
    final filters = DesktopAudioFilters.build(
      equalizerEnabled: false,
      centerHz: centers,
      levelsMillibels: List.filled(10, 0),
      surroundEnabled: true,
      surroundStrength: 0.8,
    );
    // slev = 1 + 0.55×0.8 = 1.440。
    expect(filters.single, "lavfi=[stereotools=slev=1.440]");
  });

  test('surroundAvailable=false 时不产环绕段（Windows 滤镜白名单）', () {
    final filters = DesktopAudioFilters.build(
      equalizerEnabled: false,
      centerHz: centers,
      levelsMillibels: List.filled(10, 0),
      surroundEnabled: true,
      surroundStrength: 0.8,
      surroundAvailable: false,
    );
    expect(filters, isEmpty);
  });

  test('EQ 与环绕同开时链序为先 EQ 后环绕', () {
    final filters = DesktopAudioFilters.build(
      equalizerEnabled: true,
      centerHz: centers,
      levelsMillibels: List.filled(10, 100),
      surroundEnabled: true,
      surroundStrength: 0.5,
    );
    expect(filters, hasLength(2));
    expect(filters.first, startsWith("lavfi=[equalizer=f=31"));
    expect(filters.last, "lavfi=[stereotools=slev=1.275]");
  });

  test('频点与电平数不一致时按短侧截断不抛', () {
    final filters = DesktopAudioFilters.build(
      equalizerEnabled: true,
      centerHz: centers,
      levelsMillibels: [100, 200],
    );
    expect(
      filters.single,
      "lavfi=[equalizer=f=31:t=q:w=1.2:g=1.0,"
      "equalizer=f=62:t=q:w=1.2:g=2.0]",
    );
  });
}
