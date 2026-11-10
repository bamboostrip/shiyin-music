// prefs「值没变就不写」扩展：Windows 上每次 setX 都会整文件 JSON 编解码，
// 启动流程里大量重复写（未变化的 token/收藏/歌单缓存）必须能整次跳过。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/services/prefs_write.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('setStringIfChanged：相同值跳过，不同值写入', () async {
    final prefs = await SharedPreferences.getInstance();

    expect(await prefs.setStringIfChanged('k', 'v'), isTrue);
    expect(await prefs.setStringIfChanged('k', 'v'), isFalse);
    expect(await prefs.setStringIfChanged('k', 'v2'), isTrue);
    expect(prefs.getString('k'), 'v2');
  });

  test('setBoolIfChanged / setIntIfChanged / setDoubleIfChanged', () async {
    final prefs = await SharedPreferences.getInstance();

    expect(await prefs.setBoolIfChanged('b', true), isTrue);
    expect(await prefs.setBoolIfChanged('b', true), isFalse);
    expect(await prefs.setIntIfChanged('i', 1), isTrue);
    expect(await prefs.setIntIfChanged('i', 1), isFalse);
    expect(await prefs.setDoubleIfChanged('d', 1.5), isTrue);
    expect(await prefs.setDoubleIfChanged('d', 1.5), isFalse);
    expect(await prefs.setDoubleIfChanged('d', 2.5), isTrue);
  });

  test('setStringListIfChanged：内容相同跳过', () async {
    final prefs = await SharedPreferences.getInstance();

    expect(await prefs.setStringListIfChanged('l', ['a', 'b']), isTrue);
    expect(await prefs.setStringListIfChanged('l', ['a', 'b']), isFalse);
    expect(await prefs.setStringListIfChanged('l', ['a']), isTrue);
  });

  test('removeIfExists：键不存在返回 false', () async {
    final prefs = await SharedPreferences.getInstance();

    expect(await prefs.removeIfExists('missing'), isFalse);
    await prefs.setString('k', 'v');
    expect(await prefs.removeIfExists('k'), isTrue);
    expect(prefs.containsKey('k'), isFalse);
  });
}
