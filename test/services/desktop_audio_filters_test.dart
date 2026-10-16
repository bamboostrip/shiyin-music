import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/services/desktop_audio_filters.dart';

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

  test('EQ 开启产出 firequalizer，毫贝尔转 dB 保留一位小数', () {
    final filters = DesktopAudioFilters.build(
      equalizerEnabled: true,
      centerHz: centers,
      levelsMillibels: [500, 0, 0, 0, 0, 0, 0, 0, 0, 250],
    );
    expect(filters, hasLength(1));
    expect(
      filters.single,
      "lavfi=[firequalizer=gain_entry='entry(31,5.0);entry(62,0.0);"
      "entry(125,0.0);entry(250,0.0);entry(500,0.0);entry(1000,0.0);"
      "entry(2000,0.0);entry(4000,0.0);entry(8000,0.0);entry(16000,2.5)']",
    );
  });

  test('低音增强在 EQ 关闭时仍产出搁架抬升曲线', () {
    final filters = DesktopAudioFilters.build(
      equalizerEnabled: false,
      centerHz: centers,
      levelsMillibels: List.filled(10, 0),
      bassEnabled: true,
      bassStrength: 0.5,
    );
    expect(filters, hasLength(1));
    // 满强度 +12dB：0.5 → 31Hz +6.0 / 62Hz +4.2 / 125Hz +2.1，其余 0.0。
    expect(filters.single, contains('entry(31,6.0)'));
    expect(filters.single, contains('entry(62,4.2)'));
    expect(filters.single, contains('entry(125,2.1)'));
    expect(filters.single, contains('entry(250,0.0)'));
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
    expect(filters.single, contains('entry(31,15.0)'));
  });

  test('环绕映射 extrastereo 系数并带削波保护', () {
    final filters = DesktopAudioFilters.build(
      equalizerEnabled: false,
      centerHz: centers,
      levelsMillibels: List.filled(10, 0),
      surroundEnabled: true,
      surroundStrength: 0.8,
    );
    // m = 1 + 0.55×0.8 = 1.440。
    expect(filters.single, 'extrastereo=m=1.440:c=1');
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
    expect(filters.first, startsWith('lavfi=[firequalizer'));
    expect(filters.last, 'extrastereo=m=1.275:c=1');
  });

  test('频点与电平数不一致时按短侧截断不抛', () {
    final filters = DesktopAudioFilters.build(
      equalizerEnabled: true,
      centerHz: centers,
      levelsMillibels: [100, 200],
    );
    expect(filters.single, contains('entry(62,2.0)'));
    expect(filters.single, isNot(contains('entry(125,')));
  });
}
