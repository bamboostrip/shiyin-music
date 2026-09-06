import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/services/search_history_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SearchHistoryService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    service = SearchHistoryService();
  });

  group('SearchHistoryService 搜索历史限制与管理', () {
    test('初始状态下历史记录为空', () async {
      final history = await service.getHistory();
      expect(history, isEmpty);
    });

    test('添加搜索词后最新一条排在最前', () async {
      await service.add('林俊杰');
      await service.add('周杰伦');

      final history = await service.getHistory();
      expect(history, ['周杰伦', '林俊杰']);
    });

    test('同一搜索词再次添加时去重并置顶', () async {
      await service.add('林俊杰');
      await service.add('周杰伦');
      await service.add('林俊杰');

      final history = await service.getHistory();
      expect(history, ['林俊杰', '周杰伦']);
    });

    test('空字符串或全空格不加入历史', () async {
      await service.add('   ');
      await service.add('');

      final history = await service.getHistory();
      expect(history, isEmpty);
    });

    test('搜索历史严格限制在最多 10 条，超出自动截断最旧记录', () async {
      for (var i = 1; i <= 15; i++) {
        await service.add('搜索词$i');
      }

      final history = await service.getHistory();
      expect(history.length, 10);
      expect(history.first, '搜索词15');
      expect(history.last, '搜索词6');
      expect(history.contains('搜索词1'), isFalse);
      expect(history.contains('搜索词5'), isFalse);
    });

    test('已存在的超长历史在读取时也会自动截断至上限 10 条', () async {
      final prefs = await SharedPreferences.getInstance();
      final old20 = List.generate(20, (i) => '旧历史$i');
      // 直接写入 20 条模拟旧版本数据
      await prefs.setString('search_history', '["${old20.join('","')}"]');

      final history = await service.getHistory();
      expect(history.length, 10);
      expect(history.first, '旧历史0');
      expect(history.last, '旧历史9');
    });

    test('删除单条搜索词', () async {
      await service.add('词A');
      await service.add('词B');
      await service.remove('词A');

      final history = await service.getHistory();
      expect(history, ['词B']);
    });

    test('清空全部历史记录', () async {
      await service.add('词A');
      await service.add('词B');
      await service.clear();

      final history = await service.getHistory();
      expect(history, isEmpty);
    });
  });
}
