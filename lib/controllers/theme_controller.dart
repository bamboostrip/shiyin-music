import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/device_info_service.dart';
import '../ui/adaptive_layout.dart';
import '../ui/form_factor.dart';

/// 背景图解码上限（最长边，像素），桌面形态。
///
/// 桌面窗口常见 2K/4K，取 1920 尽量清晰；再往上基本都是白占内存（4K 原图
/// 解码后单张可到 30MB+）。缩放走解码阶段（见 [buildBackgroundImageProvider]），
/// 省的是真实位图内存。
const int backgroundImageDecodeCapDesktop = 1920;

/// 背景图解码上限（最长边，像素），移动/车机形态。
///
/// 手机与车机屏幕物理宽度多在 1080~1440，按 1440 解码已够铺满且省内存
/// （单张约 3.7~4.7MB）；竖屏被 cover 放大后略软，但背景上叠着遮罩，
/// 实际观感不受影响。
const int backgroundImageDecodeCapMobile = 1440;

/// 预览缩略图解码上限：设置页卡片只有 160 逻辑像素高，
/// 没必要按整屏尺寸解码（背景开关关闭时全局层不渲染，这张就是唯一解码）。
const int backgroundPreviewDecodeCap = 800;

/// 当前设备形态下的背景图解码上限。
int get backgroundImageDecodeCap => isDesktopFormFactor
    ? backgroundImageDecodeCapDesktop
    : backgroundImageDecodeCapMobile;

/// 背景图统一使用的 [ImageProvider]（全局背景层、设置页预览、启动预缓存共用）。
///
/// 必须显式用 [ResizeImagePolicy.fit]：默认的 `exact` 会把图片硬拉到
/// width×height（等价 `BoxFit.fill`），横图被压成正方形——这正是全局背景层
/// 与两个预览「一换图就变形」的根因（issue #13 第 1 点）。等比例降采样后再
/// 交给 `BoxFit.cover` 裁剪铺满，才是「铺满整屏 + 不拉伸」的正确组合。
///
/// 三处共用本函数、各自通过 [cap] 选解码档位：主背景层与全屏预览用默认档
/// （provider 相同 → 缓存键相同 → 只解一份），设置页缩略图用小档，避免为一个
/// 160 逻辑像素高的卡片解整屏大图。[cap] 为空时按设备形态取
/// [backgroundImageDecodeCap]。
ImageProvider buildBackgroundImageProvider(String path, {int? cap}) {
  final size = cap ?? backgroundImageDecodeCap;
  return ResizeImage(
    FileImage(File(path)),
    width: size,
    height: size,
    policy: ResizeImagePolicy.fit,
  );
}

/// 背景图选择/安装失败（[message] 可直接展示给用户）。
class BackgroundImageException implements Exception {
  BackgroundImageException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 全局个性化设置控制器。
///
/// 管理：
/// - 全局种子色（影响配色方案）
/// - 外观模式（跟随系统/浅色/深色）
/// - 自定义全局背景图（开关 + 图片路径 + 透明度）
///
/// 通过 SharedPreferences 持久化，通过 ChangeNotifier 驱动 UI 重建。
class ThemeController extends ChangeNotifier {
  ThemeController() {
    _instance = this;
  }

  static ThemeController? _instance;
  static ThemeController get instance => _instance ??= ThemeController();

  // ===== SharedPreferences keys =====
  static const _seedColorKey = 'theme.seed_color';
  static const _bgEnabledKey = 'theme.bg_enabled';
  static const _bgImagePathKey = 'theme.bg_image_path';
  static const _bgOpacityKey = 'theme.bg_opacity';
  static const _landscapeEnabledKey = 'theme.landscape_enabled';
  static const _carModeEnabledKey = 'theme.car_mode_enabled';
  static const _fontScaleKey = 'theme.font_scale';
  static const _themeModeKey = 'theme.mode';
  static const _carDisplayScaleKey = 'theme.car_display_scale';
  static const _carMarginTopKey = 'theme.car_margin_top';
  static const _carMarginBottomKey = 'theme.car_margin_bottom';

  /// 全局字体大小档位（1.0 = 标准，1.1 = 大，1.2 = 特大）。
  static const fontScaleOptions = [1.0, 1.1, 1.2];

  /// 车机模式下文字放大倍数（远距离观看更清晰）。
  static const double carModeFontScaleFactor = 1.12;

  /// 车机显示缩放档位（仅车机模式生效，1.0 = 标准）。
  ///
  /// 车机屏幕分辨率与 DPI 差异极大：低分屏 100% 观感偏大、高分屏偏小。
  /// 用档位而非连续滑杆，保证每一档都能做布局回归（缩放过度会让触控
  /// 目标过小或撞上网格/侧栏断点）。
  static const carDisplayScaleOptions = [0.8, 0.9, 1.0, 1.15, 1.3];

  /// 车机安全留白上限（逻辑像素）。
  ///
  /// 车机 dpr 常见 1~2，100 逻辑像素足以让出悬浮状态栏/底部悬浮条。
  static const double carMarginMax = 100;

  /// 预设种子色列表（首位即默认配色）。
  static const presetColors = <_PresetColor>[
    _PresetColor(name: '拾音金', color: Color(0xFFF6A200)),
    _PresetColor(name: '经典蓝', color: Color(0xFF1478FF)),
    _PresetColor(name: '酷狗红', color: Color(0xFFFF2D55)),
    _PresetColor(name: '清新绿', color: Color(0xFF24C768)),
    _PresetColor(name: '优雅紫', color: Color(0xFF8B5CF6)),
    _PresetColor(name: '暖阳橙', color: Color(0xFFF59E0B)),
    _PresetColor(name: '樱花粉', color: Color(0xFFEC4899)),
    _PresetColor(name: '天际青', color: Color(0xFF06B6D4)),
    _PresetColor(name: '石墨灰', color: Color(0xFF64748B)),
  ];

  /// 项目默认种子色（新 Logo 金）。
  static const defaultSeedColor = Color(0xFFF6A200);

  Color _seedColor = defaultSeedColor;
  ThemeMode _themeMode = ThemeMode.system;
  bool _backgroundEnabled = false;
  String? _backgroundImagePath;
  double _backgroundOpacity = 0.15;
  bool _landscapeEnabled = false;
  bool _carModeEnabled = false;
  double _fontScale = 1.0;
  double _carDisplayScale = 1.0;
  double _carMarginTop = 0;
  double _carMarginBottom = 0;
  // 车机检测结果缓存（设备不变，启动时检测一次）。
  bool _isAutomotiveDevice = false;

  bool? _lastAppliedIsTablet;
  bool? _lastAppliedLandscapeEnabled;
  bool? _lastAppliedCarModeEnabled;

  Color get seedColor => _seedColor;

  /// 当前外观模式（跟随系统/浅色/深色）。
  ThemeMode get themeMode => _themeMode;

  /// 外观模式的中文标签（设置页选项文案）。
  String get themeModeLabel => switch (_themeMode) {
    ThemeMode.system => '跟随系统',
    ThemeMode.light => '浅色模式',
    ThemeMode.dark => '深色模式',
  };

  bool get backgroundEnabled => _backgroundEnabled;
  String? get backgroundImagePath => _backgroundImagePath;
  double get backgroundOpacity => _backgroundOpacity;
  bool get landscapeEnabled => _landscapeEnabled;

  /// 车机模式开关（仅移动形态生效：桌面恒 false）。
  ///
  /// PC 窗口恒横屏，若把移动端残留的开关值当真，全项目约 18 处
  /// `横屏 && carModeEnabled` 的车机分支会把车机/移动布局整套套到桌面
  /// （AppShell 早已桌面先行返回，页面层缺同款护栏）；与该契约收敛到
  /// 本唯一判定入口。开关 UI 本就只在移动端展示，桌面读到的必为残留值。
  bool get carModeEnabled => _carModeEnabled && !isDesktopFormFactor;
  double get fontScale => _fontScale;
  bool get isAutomotiveDevice => _isAutomotiveDevice;

  /// 车机显示缩放（仅移动形态；桌面恒 1.0，避免移动端残留值劫持 PC 布局）。
  double get carDisplayScale => isDesktopFormFactor ? 1.0 : _carDisplayScale;

  /// 车机顶部安全留白（逻辑像素，0 = 仅依赖系统 inset）。
  double get carMarginTop => isDesktopFormFactor ? 0 : _carMarginTop;

  /// 车机底部安全留白（逻辑像素，0 = 仅依赖系统 inset）。
  double get carMarginBottom => isDesktopFormFactor ? 0 : _carMarginBottom;

  /// 车机显示是否偏离默认值（用于设置页「恢复默认」置灰与副标题）。
  bool get hasCustomCarDisplay =>
      carDisplayScale != 1.0 || carMarginTop != 0 || carMarginBottom != 0;

  /// 是否使用了非默认种子色。
  bool get hasCustomSeedColor => _seedColor != defaultSeedColor;

  /// 检测是否为 Android Automotive 车机并缓存结果。
  /// 设备类型不变，启动时调用一次即可。须在 [load] 之前调用，
  /// 以便首次安装时据检测结果决定车机模式默认值。
  Future<void> detectAutomotive(DeviceInfoService deviceInfo) async {
    _isAutomotiveDevice = await deviceInfo.isAutomotive();
  }

  /// 加载持久化设置。
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final colorValue = prefs.getInt(_seedColorKey);
    if (colorValue != null) {
      _seedColor = Color(colorValue);
    }
    _backgroundEnabled = prefs.getBool(_bgEnabledKey) ?? false;
    final storedBgPath = prefs.getString(_bgImagePathKey);
    if (storedBgPath == null) {
      _backgroundImagePath = null;
    } else if (await File(storedBgPath).exists()) {
      _backgroundImagePath = storedBgPath;
    } else {
      // 文件已不在（被用户/系统清理、换图被中断、prefs 被并发写回旧值）：
      // 清掉脏设置，避免设置页显示「已选择背景图」却一直是破图，也避免每次
      // 启动都去解析一个不存在的文件。
      _backgroundImagePath = null;
      _backgroundEnabled = false;
      try {
        await prefs.remove(_bgImagePathKey);
        await prefs.setBool(_bgEnabledKey, false);
      } catch (_) {}
    }
    _landscapeEnabled = prefs.getBool(_landscapeEnabledKey) ?? false;
    // 首次安装（键不存在）：检测到车机则默认开启车机模式；
    // 否则默认关闭。用户手动开关过后键一定存在，永不覆盖用户选择。
    if (prefs.containsKey(_carModeEnabledKey)) {
      _carModeEnabled = prefs.getBool(_carModeEnabledKey) ?? false;
    } else {
      _carModeEnabled = _isAutomotiveDevice;
    }
    final storedFontScale = prefs.getDouble(_fontScaleKey) ?? 1.0;
    _fontScale =
        fontScaleOptions.contains(storedFontScale) ? storedFontScale : 1.0;
    // 车机显示微调：默认中性值（缩放 1.0 / 留白 0），老用户升级无感；
    // 手改 prefs 或旧版本残留的非法值一律回落。
    final storedCarScale = prefs.getDouble(_carDisplayScaleKey) ?? 1.0;
    _carDisplayScale = carDisplayScaleOptions.contains(storedCarScale)
        ? storedCarScale
        : 1.0;
    _carMarginTop = (prefs.getDouble(_carMarginTopKey) ?? 0.0)
        .clamp(0.0, carMarginMax)
        .toDouble();
    _carMarginBottom = (prefs.getDouble(_carMarginBottomKey) ?? 0.0)
        .clamp(0.0, carMarginMax)
        .toDouble();
    final opacity = prefs.getDouble(_bgOpacityKey);
    if (opacity != null) {
      _backgroundOpacity = opacity.clamp(0.0, 0.8);
    }
    // 外观模式：键不存在（老用户）或存了非法值时回落跟随系统。
    final themeModeValue = prefs.getString(_themeModeKey);
    _themeMode = switch (themeModeValue) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    applyOrientations(AdaptiveLayout.isTabletByPlatform());
    notifyListeners();

    // 预缓存自定义背景图，避免页面切换时出现纯色闪烁。
    // 必须与全局背景层用同一个 provider：缓存键 = provider + 解码尺寸，
    // 这里若用裸 FileImage，预缓存的就是另一份全尺寸解码（既不命中、
    // 又多占一份内存）。
    if (_backgroundEnabled && _backgroundImagePath != null) {
      buildBackgroundImageProvider(
        _backgroundImagePath!,
      ).resolve(ImageConfiguration.empty);
    }
  }

  /// 设置全局种子色。
  Future<void> setSeedColor(Color color) async {
    if (_seedColor == color) return;
    _seedColor = color;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_seedColorKey, color.toARGB32());
    notifyListeners();
  }

  /// 设置外观模式（跟随系统/浅色/深色），持久化并通知 UI 重建。
  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeModeKey, mode.name);
    notifyListeners();
  }

  /// 开启/关闭自定义背景图。
  Future<void> setBackgroundEnabled(bool enabled) async {
    if (_backgroundEnabled == enabled) return;
    _backgroundEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_bgEnabledKey, enabled);
    notifyListeners();
  }

  /// 开启/关闭横屏模式。
  Future<void> setLandscapeEnabled(bool enabled, bool isTablet) async {
    if (_landscapeEnabled == enabled) return;
    _landscapeEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_landscapeEnabledKey, enabled);
    applyOrientations(isTablet);
    notifyListeners();
  }

  /// 设置全局字体大小档位（仅接受 [fontScaleOptions] 中的值）。
  Future<void> setFontScale(double scale) async {
    final clamped = fontScaleOptions.contains(scale) ? scale : 1.0;
    if (_fontScale == clamped) return;
    _fontScale = clamped;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_fontScaleKey, clamped);
    notifyListeners();
  }

  /// 设置车机显示缩放档位（仅接受 [carDisplayScaleOptions] 中的值）。
  ///
  /// 档位由 [CarDisplayViewport] 消费：缩小布局视口 + 变换放大还原，
  /// 因此改变的不仅是文字，网格列数、按钮物理尺寸同步变化。
  Future<void> setCarDisplayScale(double scale) async {
    final clamped = carDisplayScaleOptions.contains(scale) ? scale : 1.0;
    if (_carDisplayScale == clamped) return;
    _carDisplayScale = clamped;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_carDisplayScaleKey, clamped);
    notifyListeners();
  }

  /// 设置车机顶部安全留白（逻辑像素，0~[carMarginMax]）。
  Future<void> setCarMarginTop(double margin) async {
    final clamped = margin.clamp(0.0, carMarginMax).toDouble();
    if (_carMarginTop == clamped) return;
    _carMarginTop = clamped;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_carMarginTopKey, clamped);
    notifyListeners();
  }

  /// 设置车机底部安全留白（逻辑像素，0~[carMarginMax]）。
  Future<void> setCarMarginBottom(double margin) async {
    final clamped = margin.clamp(0.0, carMarginMax).toDouble();
    if (_carMarginBottom == clamped) return;
    _carMarginBottom = clamped;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_carMarginBottomKey, clamped);
    notifyListeners();
  }

  /// 恢复车机显示默认值（缩放 1.0、上下留白 0）。
  Future<void> resetCarDisplay() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_carDisplayScaleKey);
    await prefs.remove(_carMarginTopKey);
    await prefs.remove(_carMarginBottomKey);
    if (_carDisplayScale == 1.0 &&
        _carMarginTop == 0.0 &&
        _carMarginBottom == 0.0) {
      return;
    }
    _carDisplayScale = 1.0;
    _carMarginTop = 0;
    _carMarginBottom = 0;
    notifyListeners();
  }

  /// 开启/关闭车机模式：横屏时启用左侧播放面板 + 顶栏布局，并放大文字。
  /// 关闭时回到普通横屏（NavigationRail），竖屏始终不受影响。
  Future<void> setCarModeEnabled(bool enabled) async {
    if (_carModeEnabled == enabled) return;
    _carModeEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_carModeEnabledKey, enabled);
    applyOrientations(AdaptiveLayout.isTabletByPlatform());
    notifyListeners();
  }

  /// 动态应用屏幕方向锁定/解锁。
  void applyOrientations(bool isTablet) {
    if (_lastAppliedIsTablet == isTablet &&
        _lastAppliedLandscapeEnabled == _landscapeEnabled &&
        _lastAppliedCarModeEnabled == _carModeEnabled) {
      return;
    }
    _lastAppliedIsTablet = isTablet;
    _lastAppliedLandscapeEnabled = _landscapeEnabled;
    _lastAppliedCarModeEnabled = _carModeEnabled;

    if (isTablet || _landscapeEnabled || _carModeEnabled) {
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]);
    }
  }

  /// 设置背景图路径（null 表示清除）。
  ///
  /// 返回是否已持久化成功。平台层写失败时 [SharedPreferences] 可能只返回
  /// false 而不抛异常（同 `CacheService.write` 的处理），调用方必须据此决定
  /// 能否删除旧图：写失败还删旧文件，重启后 prefs 会回退到旧路径、文件却已
  /// 不在，背景就永久丢了。
  Future<bool> setBackgroundImagePath(String? path) async {
    final previous = _backgroundImagePath;
    _backgroundImagePath = path;
    final prefs = await SharedPreferences.getInstance();
    var persisted = false;
    try {
      persisted = path != null
          ? await prefs.setString(_bgImagePathKey, path)
          : await prefs.remove(_bgImagePathKey);
    } catch (_) {
      persisted = false;
    }
    if (!persisted) {
      // 回滚内存态：不要让界面显示一个重启后会消失的状态。
      _backgroundImagePath = previous;
      notifyListeners();
      return false;
    }
    notifyListeners();
    return true;
  }

  /// 设置背景透明度（0.0 ~ 0.8，值越大背景越明显）。
  Future<void> setBackgroundOpacity(double opacity) async {
    _backgroundOpacity = opacity.clamp(0.0, 0.8);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_bgOpacityKey, _backgroundOpacity);
    notifyListeners();
  }

  /// 从相册选择图片并复制到应用永久目录。
  ///
  /// 返回是否成功设置。
  Future<bool> pickAndSetBackgroundImage() async {
    // 延迟导入避免非必要平台初始化
    final ImagePicker picker = ImagePicker();
    final xFile = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 90,
    );
    if (xFile == null) return false;

    final sourceFile = File(xFile.path);
    if (!await sourceFile.exists()) return false;

    return installBackgroundImage(sourceFile);
  }

  /// 把 [source] 安装为当前背景图：复制进应用文档目录、验证可解码、写入设置。
  ///
  /// [targetDir] 仅测试用（传临时目录可绕开 path_provider 平台通道）。
  /// 返回是否成功设置；失败时抛 [BackgroundImageException] 且旧背景原样保留。
  @visibleForTesting
  Future<bool> installBackgroundImage(
    File source, {
    Directory? targetDir,
  }) async {
    // 复制到应用文档目录，避免临时文件被系统清理
    final docsDir = targetDir ?? await getApplicationDocumentsDirectory();
    final permanentPath = await saveBackgroundImageCopy(source, docsDir);
    final previousPath = _backgroundImagePath;

    // 先确认能解码再上位：Windows 选择器允许 tif/tiff 等 Flutter 解不了的
    // 格式，损坏文件也会走到这里；直接提交会「提示设置成功但界面一片空白」，
    // 而旧图此时已经被删。探测用的就是背景层同一个 provider，解码结果进
    // 缓存，真正显示时不再重复解码。
    try {
      await _probeDecodable(permanentPath);
    } catch (_) {
      await deleteBackgroundImageFile(permanentPath);
      throw BackgroundImageException('这张图片无法解码，请换一张');
    }

    if (!await setBackgroundImagePath(permanentPath)) {
      // 新路径没进 prefs：删掉刚复制的新文件（此刻无人引用），旧图与旧设置
      // 原样保留。否则重启后 prefs 指向旧路径而旧文件已删除，背景永久丢失。
      await deleteBackgroundImageFile(permanentPath);
      throw BackgroundImageException('背景图保存失败，请重试');
    }

    if (!_backgroundEnabled) {
      await setBackgroundEnabled(true);
    }

    // 新图已经上位后再清旧文件：顺序反过来，切换瞬间背景层会读到已被删除
    // 的文件，界面先闪一下空白再出新图。
    if (previousPath != null && previousPath != permanentPath) {
      await deleteBackgroundImageFile(previousPath);
    }
    return true;
  }

  /// 试解码一次，确认图片格式与内容可用（TIFF 等不支持格式、损坏文件会被拦下）。
  ///
  /// 解码与背景层共用同一 provider，因此这次解码结果会被图像缓存复用。
  static Future<void> _probeDecodable(String path) async {
    final stream = buildBackgroundImageProvider(
      path,
    ).resolve(ImageConfiguration.empty);
    final completer = Completer<void>();
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (_, _) {
        if (!completer.isCompleted) completer.complete();
      },
      onError: (Object error, StackTrace? stackTrace) {
        if (!completer.isCompleted) completer.completeError(error, stackTrace);
      },
    );
    stream.addListener(listener);
    try {
      // 超大图在低端设备上解码也要几百毫秒，给足余量；超时按失败处理。
      await completer.future.timeout(const Duration(seconds: 8));
    } finally {
      stream.removeListener(listener);
    }
  }

  /// 把背景图复制到 [dir]，返回一个**每次都不相同**的新路径。
  ///
  /// 文件名必须带唯一后缀：Flutter 的 ImageCache 以「provider（文件路径）
  /// + 解码尺寸」为键。此前固定写 `bg_custom.jpg`，换图（甚至清除后重新
  /// 选择）路径没变，缓存直接命中上一张的解码结果，界面继续显示旧背景
  /// （issue #13 第 2 点）。时间戳 + 进程内自增序号保证连续选择也不撞名。
  @visibleForTesting
  static Future<String> saveBackgroundImageCopy(
    File source,
    Directory dir,
  ) async {
    final ext = _backgroundImageExtension(source.path);
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final target = File(
      '${dir.path}/bg_custom_${stamp}_${_bgImageNameSeq++}$ext',
    );
    await source.copy(target.path);
    return target.path;
  }

  /// 删除背景图文件，并清掉它留在 [ImageCache] 里的解码结果。
  ///
  /// 文件可能已被系统/用户删掉，删除失败一律静默；缓存也要清，否则换图后
  /// 旧位图会继续占内存直到被容量策略淘汰。同一张图可能按三种上限各存过一
  /// 份：主背景（桌面/移动两档，取当前形态）与设置页缩略图，逐个键逐出；
  /// 没出现过的键是幂等空操作。裸 [FileImage] 那层当前渲染已不再使用，
  /// 一并逐出作为历史键兜底。
  @visibleForTesting
  static Future<void> deleteBackgroundImageFile(String? path) async {
    if (path == null) return;
    final file = File(path);
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
    for (final cap in <int>{
      backgroundImageDecodeCapDesktop,
      backgroundImageDecodeCapMobile,
      backgroundPreviewDecodeCap,
    }) {
      await buildBackgroundImageProvider(path, cap: cap).evict();
    }
    await FileImage(file).evict();
  }

  /// 进程内自增序号，配合时间戳保证背景图文件名唯一。
  static int _bgImageNameSeq = 0;

  /// 安全扩展名：只接受 `.jpg` 这类形态，其余回落 `.jpg`。
  static final RegExp _safeImageExtPattern = RegExp(r'^\.[A-Za-z0-9]{1,5}$');

  /// 从源路径取扩展名（小写）；路径里没有或形态异常时回落 `.jpg`。
  static String _backgroundImageExtension(String sourcePath) {
    final dot = sourcePath.lastIndexOf('.');
    if (dot <= 0 || dot == sourcePath.length - 1) return '.jpg';
    final ext = sourcePath.substring(dot);
    return _safeImageExtPattern.hasMatch(ext) ? ext.toLowerCase() : '.jpg';
  }

  /// 清除自定义背景图。
  Future<void> clearBackgroundImage() async {
    final path = _backgroundImagePath;
    // 先关掉背景层再删文件：反过来背景层会短暂读到不存在的文件。
    final cleared = await setBackgroundImagePath(null);
    await setBackgroundEnabled(false);
    // 持久化失败时保留文件：宁可下次启动「背景又回来了」，也不能留下一个
    // 指向已删除文件的设置（设置页会变成破图）。
    if (cleared) {
      await deleteBackgroundImageFile(path);
    }
  }
}

/// 预设颜色项。
class _PresetColor {
  const _PresetColor({required this.name, required this.color});

  final String name;
  final Color color;
}
