// 音效预设与音效档案的数据层（issue #2 扩容与曲线调优）。
//
// 原先内联在 PlayerController 里的两张静态 const 表拆到本文件集中维护，
// 控制器侧 `import` 供自身与 part 分片使用，并以 `export` 透出
// AudioEffectPreset/AudioEffectProfile，既有消费方（均衡器页、预设
// 弹层、测试）的引用路径与写法零改动。
//
// 曲线为本仓库按公开的曲风调音指引自写，禁止从酷狗/ViPER 等 GPL 或
// 闭源仓库拷贝参数文件或逐字参数。
//
// 单位毫贝尔（millibel，1/100 dB），10 段标准倍频程中心：
// 31 / 62 / 125 / 250 / 500 / 1k / 2k / 4k / 8k / 16kHz，
// 应用时经 PlayerEqualizerLogic 重采样到设备实际段数。

/// 均衡器预设：一条命名 EQ 曲线。
class AudioEffectPreset {
  const AudioEffectPreset({required this.name, required this.levels});

  final String name;
  final List<int> levels;
}

/// 命名音效档案：EQ 曲线 + 低音增强 + 环绕的组合预设（issue #1，酷狗式
/// 「全景环绕/超重低音」同类效果的开源复刻）。EQ 仍按 10 段标准倍频程
/// 中心（31Hz..16kHz）定义，经 PlayerEqualizerLogic 重采样到设备段数。
class AudioEffectProfile {
  const AudioEffectProfile({
    required this.name,
    required this.description,
    required this.eqLevels,
    this.bassBoost = false,
    this.bassStrength = 0,
    this.surround = false,
    this.surroundStrength = 0,
  });

  final String name;
  final String description;
  final List<int> eqLevels;
  final bool bassBoost;

  /// 低音增强强度（0..1，映射到 Android BassBoost strength 0..1000）。
  final double bassStrength;
  final bool surround;

  /// 环绕强度（0..1，映射到 Android Virtualizer strength / 桌面 stereotools）。
  final double surroundStrength;
}

/// 均衡器预设表（16 条）。各曲线调法依据公开曲风调音指引的通行要点，
/// 逐条注在曲线上；±1200 毫贝尔（±12dB）为设备侧钳制上限。
const kEqualizerPresets = [
  // 平直：全 0 基准线，重置与「关 EQ」语义同源。
  AudioEffectPreset(name: '平直', levels: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
  // 流行：中频温和 + 轻微两端 V。指引要点：流行以人声为中心，深 V 会让
  // 伴奏喧宾夺主，中频轻拱即「人声不糊、伴奏不闷」。
  AudioEffectPreset(
    name: '流行',
    levels: [0, 100, 250, 350, 300, 150, 100, 150, 250, 250],
  ),
  // 摇滚：两端抬、中段让位的经典 V。指引要点：吉他/鼓的能量在两端，
  // 中段（500-2k）略收避免失真墙糊成一团，保住冲击力。
  AudioEffectPreset(
    name: '摇滚',
    levels: [400, 300, 100, -150, -200, -100, 200, 400, 450, 450],
  ),
  // 人声：500-4k 主导、低频压掉。指引要点：人声基频与唇齿音都在中频，
  // 低频收可避免底鼓/贝斯轰头盖过唱词。
  AudioEffectPreset(
    name: '人声',
    levels: [-250, -150, 0, 250, 450, 500, 350, 150, 0, -150],
  ),
  // 低音：低频主导、高频逐段收。指引要点：大幅抬低频必须同步收高频，
  // 否则残余高频让整体浑浊刺耳。
  AudioEffectPreset(
    name: '低音',
    levels: [800, 700, 500, 250, 0, -100, -150, -200, -250, -300],
  ),
  // 古典：近平直 + 两端空气感。指引要点：古典录音动态与频响本身完整，
  // 只在极低频撑舞台、极高频加空气，中段不干预。
  AudioEffectPreset(
    name: '古典',
    levels: [300, 250, 150, 0, 0, 0, 100, 200, 250, 300],
  ),
  // 电子：深低音 + 亮高频。指引要点：电子乐的 kick/synth 低频与镲片
  // 高频是主体，中频略收让位，形成干净的两端能量。
  AudioEffectPreset(
    name: '电子',
    levels: [650, 500, 150, -100, -150, 0, 300, 500, 600, 700],
  ),
  // 舞曲：低频推、中频挖。指引要点：舞曲重律动，250-1k 下挖让 kick
  // 与人声钩子各自清晰，高频适度补亮。
  AudioEffectPreset(
    name: '舞曲',
    levels: [500, 400, 150, 0, -150, -300, -150, 150, 350, 450],
  ),
  // 爵士：整体轻抬，中频乐器细节。指引要点：爵士小编制动态细腻，
  // 近乎「响度微增」的轻抬即可突出钢琴/萨克斯的中频质感，忌深 V。
  AudioEffectPreset(
    name: '爵士',
    levels: [250, 200, 100, 0, 100, 150, 100, 150, 250, 250],
  ),
  // 金属：激进 V。指引要点：失真吉他的轮廓在 2k 以上，双踩在低频，
  // 中段下挖防止高增益失真泥泞，保住吉他线条。
  AudioEffectPreset(
    name: '金属',
    levels: [450, 300, 50, -200, -250, -150, 150, 350, 450, 500],
  ),
  // 民谣：中频拱形。指引要点：木吉他箱体共鸣与叙事人声集中在 250-2k，
  // 温润拱起即可，两端不动保持原声底色。
  AudioEffectPreset(
    name: '民谣',
    levels: [100, 150, 250, 300, 250, 150, 100, 100, 150, 200],
  ),
  // 嘻哈：808 低频 + 高频咬字。指引要点：808/sub 是骨架，2k 以上补
  // 唇齿音让 flow 咬字清楚，中低频衔接段轻收防糊。
  AudioEffectPreset(
    name: '嘻哈',
    levels: [650, 550, 300, 50, -100, -100, 100, 250, 400, 450],
  ),
  // 乡村：中高频亮。指引要点：班卓/小提琴的泛音与叙事人声在 2k-8k，
  // 中高频抬起足够，低频基本不动保清爽。
  AudioEffectPreset(
    name: '乡村',
    levels: [200, 250, 200, 50, -50, 0, 150, 250, 300, 250],
  ),
  // 蓝调：中频厚。指引要点：吉他滑音与嗓音的「沙」都在中频，整体
  // 厚铺而非 V 形，保住蓝调的暖与糙。
  AudioEffectPreset(
    name: '蓝调',
    levels: [200, 250, 150, 50, 100, 200, 250, 250, 200, 150],
  ),
  // R&B：低频氛围 + 人声区轻抬。指引要点：sub 托氛围、500-1k 轻抬
  // 甜嗓，幅度都比嘻哈克制，整体圆滑不冲。
  AudioEffectPreset(
    name: 'R&B',
    levels: [550, 450, 200, 0, -100, -50, 150, 300, 350, 300],
  ),
  // 柔和：轻中频、压高频。指引要点：长时间聆听的疲劳主要来自 2k 以上，
  // 中频轻抬保清晰度、高频下压即「久听不累」。
  AudioEffectPreset(
    name: '柔和',
    levels: [0, 0, 50, 100, 200, 250, 200, 100, -50, -150],
  ),
];

/// 音效档案表（6 条，酷狗习惯命名）。EQ 曲线 + 低音/环绕强度组合，
/// 强度均为 0..1。档案名持久化按名字串匹配，改名后旧存量名自然落到
/// 非选中态（历史遗留「清澈人声/现场氛围」无迁移必要）。
const kAudioEffectProfiles = [
  // 全景环绕：高频两端展宽营造声场 + 轻低音托底。环绕 0.85 接近满档：
  // 展宽类效果低强度感知弱，但留 0.15 余量防极端相感。
  AudioEffectProfile(
    name: '全景环绕',
    description: '声场展宽 + 轻低音，空间感拉满',
    eqLevels: [200, 150, 50, 0, -50, 0, 100, 200, 250, 200],
    bassBoost: true,
    bassStrength: 0.3,
    surround: true,
    surroundStrength: 0.85,
  ),
  // 3D丽音：近平直的均衡轻抬 + 中低频细节，中等环绕。
  // 不走深 V：通透感来自「不动大结构 + 轻展宽」。
  AudioEffectProfile(
    name: '3D丽音',
    description: '均衡声场，细节通透氛围感',
    eqLevels: [150, 100, 50, 0, 100, 100, 50, 100, 150, 150],
    bassBoost: true,
    bassStrength: 0.2,
    surround: true,
    surroundStrength: 0.6,
  ),
  // 超重低音：低频大幅增强 + 高频同步收。指引要点：抬低频必收高频
  // 防浑浊；bass 0.95 逼近上限留少量余量防限幅爆音。
  AudioEffectProfile(
    name: '超重低音',
    description: '低频大幅增强，节奏冲击力',
    eqLevels: [900, 800, 600, 250, 0, -100, -150, -200, -150, -100],
    bassBoost: true,
    bassStrength: 0.95,
  ),
  // 纯净人声：500-4k 主导、压低频避轰头（同「人声」预设要点）。
  // 不挂低音/环绕：任何染色都会抢人声的「干净靠前」。
  AudioEffectProfile(
    name: '纯净人声',
    description: '中频突出，人声干净靠前',
    eqLevels: [-200, -100, 50, 250, 450, 550, 400, 150, 0, -100],
  ),
  // 现场演唱会：低频撑舞台、中频轻收让欢呼层、高频补空气。
  // 环绕 0.6 中等：还原「厅堂感」而非耳机头中展宽。
  AudioEffectProfile(
    name: '现场演唱会',
    description: '环绕声场还原现场氛围',
    eqLevels: [300, 200, 80, -80, -150, 0, 200, 300, 350, 300],
    bassBoost: true,
    bassStrength: 0.35,
    surround: true,
    surroundStrength: 0.6,
  ),
  // 深夜舒缓：压高频 + 轻低频。指引要点：夜听疲劳源在 2k 以上，
  // 高频大幅下压、低频轻托防声音发「瘦」，bass 仅 0.15。
  AudioEffectProfile(
    name: '深夜舒缓',
    description: '压低高频，夜间久听不累',
    eqLevels: [-100, 0, 100, 200, 250, 150, 50, -50, -150, -300],
    bassBoost: true,
    bassStrength: 0.15,
  ),
];
