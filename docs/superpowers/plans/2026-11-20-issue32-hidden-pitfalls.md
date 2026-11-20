# issue #32 分支隐藏问题修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复 `fix/local-audio-playback-diagnostics` 分支 review 发现的 1 个 P2（Android 10 内嵌歌词读不到）与全部可低成本修复的 P3（切音质路径缺预检、existsSync 阻塞主 isolate、封面负缓存误吞瞬时失败、陈旧队列条目无 contentUri、Kotlin 裸线程、扫描重入、扫描期封面字节拷贝、注释与行为不符）。

**Architecture:** 四个独立任务按序执行：① 歌词读取加 content:// 字节兜底（Rust 字节解析 API + Kotlin 头部截取通道 + Dart 注入式回退）；② 播放预检统一（`_resolveLocalSourceUrl` 移入基类并异步化，切音质路径接入，本地库 contentUri 兜底查找）；③ 封面负缓存三分支（确定无图才缓存）；④ 杂项加固（线程池、重入保护、扫描跳过封面拷贝、注释修正）。

**Tech Stack:** Flutter/Dart、Rust (flutter_rust_bridge 2.12.0 + symphonia 0.5)、Kotlin (Android MainActivity)。

## Global Constraints

- 分支：直接在 `fix/local-audio-playback-diagnostics` 上提交，不新建分支，不 push。
- 提交信息中文，格式沿用现状：`fix(local): …` / `refactor(local): …`（见 `git log --oneline -5`）。
- 不新增任何第三方依赖（Dart pubspec / Rust Cargo / Android gradle 均不动）。
- 全量基线：`flutter analyze` 0 issue、`flutter test` 2133 全过（本计划新增用例后按新数递增）；任何任务不得使其回退。
- Rust 侧改动后必须跑 `cd rust && cargo check && cargo test`；FRB 重新生成用仓库根目录已有的 `flutter_rust_bridge.yaml` 配置，命令 `flutter_rust_bridge_codegen generate`（版本 pin 2.12.0，已在 PATH）。
- Kotlin 侧改动后必须跑 `cd android && ./gradlew :app:compileImpellerDebugKotlin`（Windows 下为 `gradlew.bat`）。
- 测试里 `debugDefaultTargetPlatformOverride` 必须在 `finally` 中还原为 null（现有用例同款纪律）。
- issue #32 三个症状的既有修复行为不得回退：`test/controllers/player_local_source_failure_test.dart` 现有 4 用例必须保持绿。

---

### Task 1: Android 10 内嵌歌词 content:// 兜底

**背景（写给零上下文的实现者）**：issue #32 修复后，本地歌的播放与封面在 Android 10（分区存储、裸路径不可读）上都有 `content://` 媒体库地址兜底，唯独歌词没有：`LocalLyricsService._load` 全程用 `song.id` 裸路径调 `LocalMusicController.getEmbeddedLyrics(path)` → Rust `readLocalLyrics(path)`（`std::fs` 打不开 content://，Err 被吞成 null）→ 静默退回在线匹配。本任务加一条兜底：路径读不了时，经 MethodChannel 把文件**头部字节**取回来（ID3v2 标签驻留在文件开头），交给新的 Rust 字节解析 API。同名 `.lrc` sidecar 在 Android 10 上无法访问（非媒体文件、不在 MediaStore），维持现状不动。

**Files:**
- Modify: `rust/src/services/local_media.rs`（`read_id3v2_tags` 重构出「从任意流读」的内核心，新增 `read_lyrics_from_bytes`）
- Modify: `rust/src/api.rs`（新增 `read_local_lyrics_from_bytes` FRB 入口）
- Regenerate: `lib/src/rust/*`（FRB codegen 产物，勿手改）
- Modify: `android/app/src/main/kotlin/shiyin/famlife/top/MainActivity.kt`（新增 `readMediaHead` 通道方法）
- Modify: `lib/controllers/local_music_controller.dart`（`getEmbeddedLyrics` 加 `contentUri` 参数与三级回退；构造函数加三个可注入读取器）
- Modify: `lib/services/local_lyrics_service.dart`（`embeddedLyricsReader` 签名从 `(String path)` 改为 `(Song song)`）
- Modify: `lib/controllers/player_controller.lyrics.dart`（注入闭包改传 `song`，透传 `song.localContentUri`）
- Test: `rust/src/services/local_media.rs` 内 `#[cfg(test)]`；新建 `test/services/local_music_controller_lyrics_test.dart`

**Interfaces:**
- Consumes: 现有 `rust.readLocalLyrics(path)`（Dart 签名 `Future<String?> Function(String)`，Err 时 throw）；`Song.localContentUri`（`String?`）；`LocalLyricsService` 构造参数 `embeddedLyricsReader`。
- Produces（后续任务/外部依赖的签名，必须逐字一致）:
  - Rust: `pub fn read_local_lyrics_from_bytes(data: Vec<u8>) -> Result<Option<String>, String>`
  - Dart (FRB 生成): `Future<String?> readLocalLyricsFromBytes({required Uint8List data})`
  - Kotlin 通道: method `readMediaHead`，args `{source: String}`，成功回 `ByteArray?`（null=空文件），失败回 error code `read_failed`
  - Dart: `LocalMusicController.getEmbeddedLyrics(String filePath, {String? contentUri})`
  - Dart: `LocalLyricsService` 参数 `embeddedLyricsReader: Future<String?> Function(Song song)?`

- [ ] **Step 1: Rust 字节解析的失败测试**

在 `rust/src/services/local_media.rs` 文件末尾追加测试模块（若已有 `#[cfg(test)]` 则并入）：

```rust
#[cfg(test)]
mod lyrics_bytes_tests {
    use super::*;

    /// 手工拼一个最小合法 ID3v2.3 头 + 一个 USLT 帧（英语、无描述、歌词文本）。
    /// USLT 帧体: encoding(1) + lang(3) + desc(0x00 结尾) + text。
    fn id3v2_with_uslt(text: &str) -> Vec<u8> {
        let text_bytes = text.as_bytes();
        // 帧体 = 1(编码=ISO-8859-1) + 3(eng) + 1(空 desc) + 文本
        let frame_body_len = 1 + 3 + 1 + text_bytes.len();
        let mut frame = Vec::new();
        frame.extend_from_slice(b"USLT");
        frame.extend_from_slice(&frame_body_len.to_be_bytes()[..]); // v2.3 是 4 字节普通整数
        frame.extend_from_slice(&[0, 0]); // flags
        frame.push(0);
        frame.extend_from_slice(b"eng");
        frame.push(0);
        frame.extend_from_slice(text_bytes);

        let mut out = Vec::new();
        out.extend_from_slice(b"ID3");
        out.extend_from_slice(&[3, 0, 0, 0]); // v2.3, flags=0
        // syncsafe 长度（4×7bit）
        let len = frame.len();
        out.push(((len >> 21) & 0x7f) as u8);
        out.push(((len >> 14) & 0x7f) as u8);
        out.push(((len >> 7) & 0x7f) as u8);
        out.push((len & 0x7f) as u8);
        out.extend_from_slice(&frame);
        out
    }

    #[test]
    fn lyrics_from_bytes_reads_uslt() {
        let bytes = id3v2_with_uslt("[00:01.00]line");
        assert_eq!(
            read_lyrics_from_bytes(&bytes).unwrap().as_deref(),
            Some("[00:01.00]line")
        );
    }

    #[test]
    fn lyrics_from_bytes_no_tag_is_none_not_err() {
        assert!(read_lyrics_from_bytes(&[0x00; 4]).unwrap().is_none());
        assert!(read_lyrics_from_bytes(&[]).unwrap().is_none());
    }

    #[test]
    fn lyrics_from_bytes_truncated_container_falls_back_to_id3v2() {
        // 非 "ID3" 开头且容器探测必然失败的截断流：不能 Err，走 ID3v2 层后按无标签处理。
        let mut bytes = vec![0xff; 64];
        bytes[0] = b'x';
        assert!(read_lyrics_from_bytes(&bytes).unwrap().is_none());
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd rust && cargo test lyrics_bytes`
Expected: 编译失败，`read_lyrics_from_bytes` 未定义。

- [ ] **Step 3: 实现 Rust 字节解析**

`rust/src/services/local_media.rs` 三处改动：

1. 把 `read_id3v2_tags` 的解析核心抽成「从 MediaSourceStream 读」：

```rust
/// 从流的当前位置读 ID3v2。调用方负责先行长度上限校验。
fn read_id3v2_from_stream(
    mss: &mut MediaSourceStream,
) -> Option<LocalTags> {
    let mut builder = symphonia::core::meta::MetadataBuilder::new();
    symphonia_metadata::id3v2::read_id3v2(mss, &mut builder).ok()?;
    let tags = tags_from_revision(&builder.metadata());
    if tags.is_empty() {
        None
    } else {
        Some(tags)
    }
}
```

`read_id3v2_tags(path)` 保留原签名与「头 10 字节校验 + 16MB 上限」逻辑，第二段打开文件后改为调 `read_id3v2_from_stream(&mut mss)`（删掉原内联的 builder 代码）。

2. 新增公开函数（供 api.rs 调用）：

```rust
/// 从文件头部字节里读内嵌歌词（Android 10 分区存储的 content:// 兜底）。
///
/// 数据是截断的头部（调用方截取），容器探测是尽力而为：FLAC/OGG 的标签
/// 在文件头，通常完整；MP4 的 moov 在尾部，截断后探测失败属预期——
/// 一律降级为 Ok(None)，绝不能把「读不了」当 Err 上抛（Err 在 Dart 侧
/// 语义是「文件打不开」，会触发不必要的重试路径）。
pub fn read_lyrics_from_bytes(data: &[u8]) -> anyhow::Result<Option<String>> {
    if data.len() < 10 {
        return Ok(None);
    }
    // 1. 容器层（截断流探测失败按没有处理，不冒错）。
    //    无扩展名可用，让 probe 按魔数嗅探。
    let cursor = std::io::Cursor::new(data.to_vec());
    let mss = MediaSourceStream::new(Box::new(cursor), Default::default());
    let mut hint = Hint::new();
    if let Ok(probed) = symphonia::default::get_probe().format(
        &hint,
        mss,
        &FormatOptions::default(),
        &Default::default(),
    ) {
        let mut format = probed.format;
        if let Some(revision) = format.metadata().current() {
            for tag in revision.tags() {
                if is_lyrics_key(&tag.key)
                    || matches!(tag.std_key, Some(StandardTagKey::Lyrics))
                {
                    if let symphonia::core::meta::Value::String(s) = &tag.value {
                        if !s.trim().is_empty() {
                            return Ok(Some(s.clone()));
                        }
                    }
                }
            }
        }
    }
    // 2. ID3v2 层（mp3 的唯一来源；ID3 在文件头，截断数据里完整可用）。
    //    16MB 上限由调用方（Kotlin 头部截取）保证，这里不再重复校验。
    let cursor = std::io::Cursor::new(data.to_vec());
    let mut mss = MediaSourceStream::new(Box::new(cursor), Default::default());
    Ok(read_id3v2_from_stream(&mut mss).and_then(|tags| tags.lyrics))
}
```

注意 `MediaSourceStream::new(Box::new(cursor), ...)` 要求 `Read + Seek`，`Cursor<Vec<u8>>` 满足。

3. `rust/src/api.rs` 在 `read_local_cover` 之后新增：

```rust
/// 从文件头部字节读内嵌歌词（Android 10 分区存储下裸路径不可读，
/// 由 Kotlin 侧截取头部后走这里；见 issue #32）。
///
/// 与 [read_local_lyrics] 的差别：入参是已截断的头部字节，容器探测
/// 尽力而为，任何「读不了」都返回 `Ok(None)` 而非 Err。
pub fn read_local_lyrics_from_bytes(data: Vec<u8>) -> Result<Option<String>, String> {
    local_media::read_lyrics_from_bytes(&data).map_err(|e| e.to_string())
}
```

（api.rs 顶部已有的 `use` 若不含 `local_media`，按文件现状补。）

- [ ] **Step 4: 跑 Rust 测试**

Run: `cd rust && cargo test && cargo check`
Expected: 新增 3 用例全过，存量全过，0 warning。

- [ ] **Step 5: 重新生成 FRB 绑定**

Run（仓库根目录）: `flutter_rust_bridge_codegen generate`
Expected: `lib/src/rust/api.dart` 出现 `readLocalLyricsFromBytes`，`frb_generated*.dart`/`frb_generated.rs` 更新。生成后 `flutter analyze` 仍 0 issue。
Commit 这一步与 Step 3-4 合并。

- [ ] **Step 6: Kotlin `readMediaHead` 通道方法（失败测试先行）**

Dart 侧注入点测试（Step 8）会覆盖通道逻辑，Kotlin 无法单测，编译验证为准。直接实现：

`MainActivity.kt` 的 `setMethodCallHandler` 里，紧跟 `"getEmbeddedCover"` 分支之后新增：

```kotlin
"readMediaHead" -> {
    val source = call.argument<String>("source")
    if (source.isNullOrEmpty()) {
        result.success(null)
        return@setMethodCallHandler
    }
    // 头部截取也压后台：contentResolver 打开可能涉网络盘（云媒体）。
    Thread {
        val outcome = runCatching { readMediaHead(source) }
        runOnUiThread {
            outcome
                .onSuccess { result.success(it) }
                .onFailure { error -> result.error("read_failed", error.message, null) }
        }
    }.start()
}
```

并新增私有函数（放在 `getEmbeddedCover` 之后）：

```kotlin
/**
 * 截取音频文件头部字节，供 Dart 侧交给 Rust 解析 ID3v2/容器标签
 * （Android 10 分区存储下裸路径不可读、content:// 只有 ContentResolver
 * 认识，Rust 打不开；issue #32 歌词兜底）。
 *
 * 截取量：开头 10 字节若是 ID3v2 头，按其声明长度精确截取（上限 16MB，
 * 与 Rust 侧上限一致）；否则截 1MB（FLAC/OGG 标签驻留头部，通常远小于此）。
 * 文件比请求量短则全量返回；空文件返回 null。
 */
private fun readMediaHead(source: String): ByteArray? {
    val input = if (source.startsWith("content://")) {
        contentResolver.openInputStream(Uri.parse(source))
    } else {
        java.io.FileInputStream(source)
    } ?: return null

    input.use { stream ->
        val header = ByteArray(10)
        var headerLen = 0
        while (headerLen < header.size) {
            val n = stream.read(header, headerLen, header.size - headerLen)
            if (n < 0) break
            headerLen += n
        }
        if (headerLen == 0) return null
        val want = if (headerLen == 10 && header[0] == 'I'.code.toByte() &&
            header[1] == 'D'.code.toByte() && header[2] == '3'.code.toByte()
        ) {
            // syncsafe 4×7bit，与 Rust 侧同一上限。
            val declared = ((header[6].toInt() and 0x7f) shl 21) or
                ((header[7].toInt() and 0x7f) shl 14) or
                ((header[8].toInt() and 0x7f) shl 7) or
                (header[9].toInt() and 0x7f)
            (10L + declared).coerceAtMost(16L * 1024 * 1024)
        } else {
            1L * 1024 * 1024
        }
        val out = java.io.ByteArrayOutputStream()
        out.write(header, 0, headerLen)
        val buf = ByteArray(64 * 1024)
        var copied = headerLen.toLong()
        while (copied < want) {
            val n = stream.read(buf, 0, minOf(buf.size.toLong(), want - copied).toInt())
            if (n < 0) break
            out.write(buf, 0, n)
            copied += n
        }
        return out.toByteArray()
    }
}
```

注意：`header[6].toInt() and 0x7f` —— Kotlin 的 Byte.toInt() 带符号扩展，`and 0x7f` 后取值域 0..127，正确。

- [ ] **Step 7: Dart 三级回退（失败测试先行）**

新建 `test/services/local_music_controller_lyrics_test.dart`：

```dart
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/local_music_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  LocalMusicController build({
    Future<String?> Function(String path)? pathReader,
    Future<String?> Function(Uint8List bytes)? bytesReader,
    Future<Uint8List?> Function(String source)? headReader,
  }) {
    return LocalMusicController(
      rustLyricsReader: pathReader,
      rustLyricsBytesReader: bytesReader,
      mediaHeadReader: headReader,
    );
  }

  test('路径读到歌词：直接返回，不走字节兜底', () async {
    var headCalls = 0;
    final c = build(
      pathReader: (_) async => '[00:01.00]你好',
      headReader: (_) async {
        headCalls++;
        return Uint8List.fromList(const [1]);
      },
    );
    expect(await c.getEmbeddedLyrics('/a.mp3'), '[00:01.00]你好');
    expect(headCalls, 0);
  });

  test('路径解析成功但无歌词（返回 null）：这是确定性结论，不走兜底', () async {
    var headCalls = 0;
    final c = build(
      pathReader: (_) async => null,
      headReader: (_) async {
        headCalls++;
        return Uint8List.fromList(const [1]);
      },
    );
    expect(await c.getEmbeddedLyrics('/a.mp3'), isNull);
    expect(headCalls, 0);
  });

  test('路径读不了（抛错）且有 contentUri：截头→字节解析拿到歌词', () async {
    final bytes = Uint8List.fromList(const [1, 2, 3]);
    var headSource = '';
    final c = build(
      pathReader: (_) async => throw Exception('open failed'),
      bytesReader: (b) async {
        expect(b, same(bytes)); // 字节原样透传
        return '[00:02.00]兜底';
      },
      headReader: (s) async {
        headSource = s;
        return bytes;
      },
    );
    final r = await c.getEmbeddedLyrics(
      '/storage/0/a.mp3',
      contentUri: 'content://media/external/audio/media/9',
    );
    expect(r, '[00:02.00]兜底');
    expect(headSource, 'content://media/external/audio/media/9');
  });

  test('路径读不了但没有 contentUri：返回 null', () async {
    final c = build(pathReader: (_) async => throw Exception('open failed'));
    expect(await c.getEmbeddedLyrics('/a.mp3'), isNull);
  });

  test('截头失败：返回 null 且不把异常抛给调用方', () async {
    final c = build(
      pathReader: (_) async => throw Exception('open failed'),
      headReader: (_) async => throw Exception('content gone'),
    );
    expect(
      await c.getEmbeddedLyrics('/a.mp3', contentUri: 'content://x/y'),
      isNull,
    );
  });
}
```

- [ ] **Step 8: 跑测试确认失败**

Run: `flutter test test/services/local_music_controller_lyrics_test.dart`
Expected: 编译失败——`LocalMusicController` 没有这些构造参数 / `getEmbeddedLyrics` 没有 `contentUri`。

- [ ] **Step 9: 实现 Dart 回退**

`lib/controllers/local_music_controller.dart`：

1. 顶部补 `import 'dart:typed_data';`（若未有）与 `import '../src/rust/api.dart' as rust;`（已有则不动）。
2. 构造函数与字段（保持现有构造体内的初始化逻辑不动，只是包一层可选参数）：

```dart
class LocalMusicController extends ChangeNotifier {
  LocalMusicController({
    Future<String?> Function(String path)? rustLyricsReader,
    Future<String?> Function(Uint8List bytes)? rustLyricsBytesReader,
    Future<Uint8List?> Function(String source)? mediaHeadReader,
  })  : _rustLyricsReader = rustLyricsReader ?? _defaultRustLyricsReader,
        _rustLyricsBytesReader =
            rustLyricsBytesReader ?? _defaultRustLyricsBytesReader,
        _mediaHeadReader = mediaHeadReader ?? _defaultMediaHeadReader {
    // ……原构造体逐行保留……
  }

  /// 三个读取器抽成可注入字段：单测里 Rust 引擎与平台通道都跑不起来，
  /// 注入假实现才能钉住回退顺序（默认实现见文件底部静态函数）。
  final Future<String?> Function(String path) _rustLyricsReader;
  final Future<String?> Function(Uint8List bytes) _rustLyricsBytesReader;
  final Future<Uint8List?> Function(String source) _mediaHeadReader;
```

文件底部（类外或类内 static 皆可，与文件风格一致）：

```dart
Future<String?> _defaultRustLyricsReader(String path) =>
    rust.readLocalLyrics(path: path);

Future<String?> _defaultRustLyricsBytesReader(Uint8List bytes) =>
    rust.readLocalLyricsFromBytes(data: bytes);

Future<Uint8List?> _defaultMediaHeadReader(String source) =>
    const MethodChannel('shiyin_music/local_music')
        .invokeMethod<Uint8List>('readMediaHead', {'source': source});
```

（`MethodChannel` 若类内已有 `_channel` 常量则复用之，别新建第二份。）

3. `getEmbeddedLyrics` 替换为：

```dart
/// 获取本地歌曲的内嵌歌词。
///
/// 读取顺序（issue #32 的 Android 10 兜底）：
/// 1. Rust 按裸路径读（Android 11+ / 桌面正常路径）；
/// 2. 路径打不开（Err）且带 [contentUri] 时（Android 10 分区存储）：
///    经通道截取文件头部字节 → Rust 字节解析（ID3v2 驻留文件头，截断数据
///    里完整可用；容器层尽力而为）。
/// 「路径解析成功但没有歌词」（Ok(None)）是确定性结论，不再兜底。
///
/// 注：`MediaMetadataRetriever` 没有歌词 metadata key（历史上的
/// extractMetadata(26) 实为 METADATA_KEY_HAS_IMAGE），移动端内嵌歌词
/// 从未生效过——这是统一走 Rust 的原因。
Future<String?> getEmbeddedLyrics(String filePath, {String? contentUri}) async {
  try {
    return await _rustLyricsReader(filePath);
  } catch (e) {
    debugPrint('按路径读内嵌歌词失败，准备走头部字节兜底: $filePath ($e)');
  }
  if (contentUri == null || contentUri.isEmpty) return null;
  try {
    final head = await _mediaHeadReader(contentUri);
    if (head == null || head.isEmpty) return null;
    return await _rustLyricsBytesReader(head);
  } catch (e) {
    debugPrint('头部字节兜底读内嵌歌词失败: $contentUri ($e)');
    return null;
  }
}
```

4. `LocalLyricsService`（`lib/services/local_lyrics_service.dart`）：构造参数类型 `Future<String?> Function(String path)? embeddedLyricsReader` 改为 `Future<String?> Function(Song song)? embeddedLyricsReader`，字段同改；`_load` 里 `await _embeddedLyricsReader(song.id)` 改为 `await _embeddedLyricsReader(song)`；类顶 doc 注释里「`embeddedLyricsReader` 注入」段落补一句「入参是 Song：读取器可拿到 `localContentUri` 做 Android 10 兜底」。
5. `player_controller.lyrics.dart` 的注入闭包改为：

```dart
        embeddedLyricsReader: (song) async {
          final reader = localMusic;
          if (reader == null) return null;
          return reader.getEmbeddedLyrics(
            song.id,
            contentUri: song.localContentUri,
          );
        },
```

- [ ] **Step 10: 全量验证**

Run: `flutter test test/services/local_music_controller_lyrics_test.dart && flutter analyze && flutter test`
Expected: 新 5 用例过、analyze 0 issue、全量绿（基线 2133 + 新 5）。

- [ ] **Step 11: Commit**

```bash
git add rust/ lib/src/rust/ lib/ android/ test/
git commit -m "fix(local): 内嵌歌词 Android 10 兜底——裸路径读不了时截文件头部字节走 Rust 解析（issue #32 遗留）"
```

---

### Task 2: 播放预检统一——切音质路径接入 + 异步化 + 本地库 contentUri 兜底

**背景：** 三个独立小坑：① `_reloadCurrentSongForQuality`（`setAudioQuality(quality, reloadCurrent: true)` 触发）里 `SongSource.local` 的 `url = song.id` 直交引擎，没有 `_resolveLocalSourceUrl` 的格式/存在性预检，Android 10 上以引擎错误收场；② `_resolveLocalSourceUrl` 用 `File(path).existsSync()` 同步 IO，桌面 NAS/UNC 失联路径会卡主 isolate 秒级；③ 升级路径：旧序列化的队列/历史 Song 没有 `localContentUri`，Android 10 上明明库里重扫出了地址、当前条目却仍判「文件已不存在」。

**Files:**
- Modify: `lib/controllers/player_controller.dart`（`_resolveLocalSourceUrl`/`_isRemoteAudioUrl` 从 `_PlayerPlayback` mixin 移入 `_PlayerControllerBase`，签名改 `Future<String>`）
- Modify: `lib/controllers/player_controller.playback.dart`（删原实现；`playSong` 调用点加 `await`）
- Modify: `lib/controllers/player_controller.settings.dart`（`_reloadCurrentSongForQuality` 接入预检 + catch 里本地异常的友好文案）
- Modify: `lib/controllers/local_music_controller.dart`（新增 `contentUriForPath`）
- Test: `test/controllers/player_local_source_failure_test.dart`（扩展）

**Interfaces:**
- Consumes: Task 1 无依赖；现有 `LocalAudioMissingException`/`LocalAudioFormatException`（`lib/models/song.dart`）、`unsupportedLocalAudioReason`（`lib/services/local_audio_formats.dart`）、`localMusic`（`_PlayerControllerBase` 上已注入的 `LocalMusicController?`）。
- Produces:
  - `Future<String> _resolveLocalSourceUrl(Song song, String path)`（`_PlayerControllerBase` 成员）
  - `static bool _isRemoteAudioUrl(String url)`（`_PlayerControllerBase` 静态成员）
  - `String? contentUriForPath(String path)`（`LocalMusicController` 公开方法）

- [ ] **Step 1: 失败测试（3 个新用例）**

`test/controllers/player_local_source_failure_test.dart`：

1. `_SpyLocalMusicController` 扩展：

```dart
class _SpyLocalMusicController extends LocalMusicController {
  int scanCalls = 0;
  String? contentUriForPathOverride;

  @override
  Future<void> scanLocalMusic() async {
    scanCalls++;
  }

  @override
  String? contentUriForPath(String path) => contentUriForPathOverride;
}
```

2. 新用例（追加到 main() 的既有用例之后）：

```dart
  testWidgets('陈旧队列条目：localContentUri 为空但本地库里有地址 → 兜底直读', (tester) async {
    await pumpToastHost(tester);
    final missing =
        '${Directory.systemTemp.path}/shiyin_stale_${DateTime.now().microsecondsSinceEpoch}.mp3';
    final song = _localSong(missing); // 无 localContentUri（升级前的旧记录）
    controller.queue = [song];
    localMusic.contentUriForPathOverride = 'content://media/external/audio/media/7';

    await controller.playSong(song);
    await tester.pump();

    expect(handler.loadedUrls, ['content://media/external/audio/media/7']);
    expect(controller.errorMessage, isNull);
    expect(localMusic.scanCalls, 1); // 仍触发一次重扫收敛库
    await tearDownController(tester);
  });

  testWidgets('本地库也没有地址：维持「文件已不存在」', (tester) async {
    await pumpToastHost(tester);
    final missing =
        '${Directory.systemTemp.path}/shiyin_none_${DateTime.now().microsecondsSinceEpoch}.mp3';
    final song = _localSong(missing);
    controller.queue = [song];
    localMusic.contentUriForPathOverride = null;

    await controller.playSong(song);
    await tester.pump();

    expect(handler.loadedUrls, isEmpty);
    expect(controller.errorMessage, contains('本地文件已不存在'));
    await tearDownController(tester);
  });

  testWidgets('切音质重载本地歌：缺文件时不交给引擎，落可读错误', (tester) async {
    await pumpToastHost(tester);
    final missing =
        '${Directory.systemTemp.path}/shiyin_q_${DateTime.now().microsecondsSinceEpoch}.mp3';
    controller.queue = [_localSong(missing)];
    controller.currentSong = _localSong(missing);

    await controller.setAudioQuality(
      AudioQuality.lossless,
      reloadCurrent: true,
    );
    await tester.pump();

    expect(handler.loadedUrls, isEmpty);
    expect(controller.errorMessage, contains('本地文件已不存在'));
    await tearDownController(tester);
  });
```

`AudioQuality` 的 import 若缺则按文件现状补（`package:shiyin_music/…`，先 grep 枚举所在文件）。`controller.currentSong` 是公开可写字段（playSong 内直接赋值，测试同款用法）。

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/controllers/player_local_source_failure_test.dart`
Expected: 新 3 用例失败（前两个 loadedUrls 不符——contentUriForPath 不存在；第三个 errorMessage 为引擎异常原文/或 loadedUrls 非空），存量 4 用例仍绿。

- [ ] **Step 3: 实现**

1. `local_music_controller.dart` 新增公开方法（放 `songs` getter 附近）：

```dart
/// 按裸路径查这首歌在媒体库里的 `content://` 地址。
///
/// 用途：升级前落盘的队列/历史条目没有 [Song.localContentUri]（老版本
/// 不序列化该字段），Android 10 上裸路径不可读时靠这里从当前库状态兜底
/// （issue #32：自动重扫完成后，第二次尝试即可命中）。
String? contentUriForPath(String path) {
  for (final song in _songs) {
    if (song.id == path) return song.localContentUri;
  }
  return null;
}
```

2. `player_controller.playback.dart`：剪切 `_isRemoteAudioUrl` 与 `_resolveLocalSourceUrl`（连带 doc 注释），粘到 `player_controller.dart` 的 `_PlayerControllerBase`（放 `_localRescanRequested` 字段之后），并改造：

```dart
  /// 是否远端音源（http/https）。本地文件虽然也经本机代理加载，但语义上
  /// 仍是「本地」，两条路径的失败判定完全不同。
  static bool _isRemoteAudioUrl(String url) =>
      url.startsWith('http://') || url.startsWith('https://');

  /// 本地音源起播前的确定性检查，返回真正交给引擎的地址。
  ///
  /// 抛出的两类异常都由调用方（playSong / _reloadCurrentSongForQuality）
  /// 的 catch 收口，走「一次即判跳过」：
  /// - [LocalAudioFormatException]：当前内核没有该后缀的解析器（Android 上的
  ///   APE/WMA/AIFF 等），交给引擎只会换来一句 `Failed to open`；
  /// - [LocalAudioMissingException]：裸路径读不到、也没有可回退的媒体库地址。
  ///
  /// 注意三点：
  /// 1. **格式检查排在可读性之前**——格式不支持时文件通常是在的；
  /// 2. 存在性检查用异步 [File.exists]：桌面 NAS/UNC 失联路径的一次探测
  ///    可能秒级阻塞，不能压主 isolate（旧实现是 existsSync）；
  /// 3. 裸路径读不到时的回退顺序：`song.localContentUri` →
  ///    [LocalMusicController.contentUriForPath]（升级前的陈旧条目）。
  ///    分区存储下 Android 10 只有 content URI 能读，交给引擎时由
  ///    `MusicAudioHandler` 直接透传（不进本地文件代理）。
  Future<String> _resolveLocalSourceUrl(Song song, String path) async {
    final reason = unsupportedLocalAudioReason(path);
    if (reason != null) {
      _nextLog('本地音源格式不支持: ${song.title} → $reason');
      throw LocalAudioFormatException('《${song.title}》$reason');
    }
    if (await File(path).exists()) return path;
    final fromEntry = song.localContentUri;
    if (fromEntry != null && fromEntry.isNotEmpty) {
      _nextLog('本地路径不可读，回退条目媒体库地址: ${song.title} → $fromEntry');
      return fromEntry;
    }
    final fromLibrary = localMusic?.contentUriForPath(path);
    if (fromLibrary != null && fromLibrary.isNotEmpty) {
      _nextLog('本地路径不可读，回退媒体库地址(库内查找): ${song.title} → $fromLibrary');
      return fromLibrary;
    }
    _nextLog('本地音源文件缺失: ${song.title} → $path');
    throw LocalAudioMissingException(path);
  }
```

`_nextLog` 若此前只在 playback mixin 可见——它是基类方法则无事；若定义在 mixin 里，把它一并留在基类可访问处（先 grep `_nextLog` 定义位置，按现状处理，不改语义）。
`playSong` 调用点改为 `url = await _resolveLocalSourceUrl(song, url);`。

3. `player_controller.settings.dart` 的 `_reloadCurrentSongForQuality`：在 `url`/`networkUrl` 赋值块之后、`_currentLoudnessUrl = url;` 之前插入：

```dart
      // 与 playSong 同一条确定性预检：本地音源缺文件/格式不支持时不交给
      // 引擎白等超时（Android 10 的 content:// 兜底同样适用）。
      if (!_isRemoteAudioUrl(url)) {
        url = await _resolveLocalSourceUrl(song, url);
      }
```

catch 块里 `errorMessage = error.toString();` 替换为与 playSong 同款：

```dart
      errorMessage = switch (error) {
        LocalAudioMissingException() => '本地文件已不存在，可能已被移动或删除',
        final LocalAudioFormatException e => e.message,
        _ => error.toString(),
      };
```

- [ ] **Step 4: 定向 + 全量验证**

Run: `flutter test test/controllers/player_local_source_failure_test.dart && flutter analyze && flutter test`
Expected: 7 用例全绿、analyze 0、全量绿。

- [ ] **Step 5: Commit**

```bash
git add lib/ test/
git commit -m "fix(local): 播放预检三处收口——切音质同走确定性检查、exists 异步化、陈旧条目从本地库兜底 contentUri"
```

---

### Task 3: 封面负缓存区分「确定无图」与「读取失败」

**背景：** `LocalArtworkService` 的负缓存把两类结果混在一起：`_readPlatform` 读不到字节（无论是「解析成功、确实没有内嵌图」还是「IO 失败/权限拒绝/外接盘未挂载」）一律返回 null 并进 `_noArtwork` 负缓存——外接盘慢挂载期间探过的封面，挂载完成后到重启前都不会再试。Kotlin 侧 `getEmbeddedCover` 的 `runCatching{…}.getOrNull()` 是混淆源头：把异常吞成了 null。

**Files:**
- Modify: `android/app/src/main/kotlin/shiyin/famlife/top/MainActivity.kt`（`getEmbeddedCover` 分支错误上抛）
- Modify: `lib/services/local_artwork_service.dart`（读取结果三分支；负缓存只记「确定无图」）
- Test: `test/services/local_artwork_service_test.dart`（扩展 2 用例）

**Interfaces:**
- Consumes: 现有 channel method `getEmbeddedCover`（args `{source}`；本任务后 null=确定无图、error(`cover_failed`)=读取失败）。
- Produces: 无外部接口变化；`LocalArtworkService.load` 行为变更（读取失败不进负缓存）。

- [ ] **Step 1: 失败测试**

`test/services/local_artwork_service_test.dart` 追加（沿用文件顶部既有的 `channel`/`calls`/`reply`/`lastSource` 桩；`debugDefaultTargetPlatformOverride` 设 android 使 `_readPlatform` 走通道分支，`finally` 还原——文件里若已有同款 group 结构则并入）：

```dart
    test('通道报错=瞬时失败：不进负缓存，下次重试能拿到图', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        LocalArtworkService.debugReset();
        var fail = true;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'getEmbeddedCover') return null;
          calls++;
          if (fail) {
            throw PlatformException(code: 'cover_failed', message: 'io');
          }
          return Uint8List.fromList(const [9, 9]);
        });

        expect(await LocalArtworkService.load('/x/a.mp3'), isNull);
        expect(await LocalArtworkService.load('/x/a.mp3'), isNull);
        expect(calls, 2); // 失败不缓存 → 重进视口重试

        fail = false;
        expect(await LocalArtworkService.load('/x/a.mp3'), const [9, 9]);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('通道返回 null=确定无图：照旧进负缓存', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        LocalArtworkService.debugReset();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'getEmbeddedCover') return null;
          calls++;
          return null;
        });

        expect(await LocalArtworkService.load('/y/b.flac'), isNull);
        expect(await LocalArtworkService.load('/y/b.flac'), isNull);
        expect(calls, 1); // 确定无图 → 负缓存
        expect(LocalArtworkService.debugMissingEntries, 1);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
```

import 缺 `TargetPlatform`/`PlatformException` 则补（`package:flutter/foundation.dart` / `package:flutter/services.dart`；文件已 import services）。

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/services/local_artwork_service_test.dart`
Expected: 新 2 用例失败——现有实现把 PlatformException 也吞进负缓存（第一个用例 calls 断言 2 实得 1）。

- [ ] **Step 3: 实现**

1. Kotlin `getEmbeddedCover` 分支改为（错误不再吞）：

```kotlin
"getEmbeddedCover" -> {
    val source = call.argument<String>("source")
    if (source.isNullOrEmpty()) {
        result.success(null)
        return@setMethodCallHandler
    }
    // MediaMetadataRetriever 要读文件并解析整张图，压主线程会在列表滚动时
    // 逐行掉帧；后台线程解析、主线程回包。
    // null = 解析成功但确实没有内嵌图（Dart 侧据此进负缓存）；
    // 异常 = 读取失败（IO/权限），上抛让 Dart 侧按瞬时失败重试。
    Thread {
        val outcome = runCatching { getEmbeddedCover(source) }
        runOnUiThread {
            outcome
                .onSuccess { bytes -> result.success(bytes) }
                .onFailure { error ->
                    result.error("cover_failed", error.message, null)
                }
        }
    }.start()
}
```

（`getEmbeddedCover` 私有函数本身 catch(Exception)→null 保持不变——它区分不了「打不开」与「没图」，让外层 runCatching 只接住未预期错误即可？**不行**——这样 IO 失败仍被吞。把私有函数的 `catch (e: Exception) { null }` 删掉，让异常直穿到 runCatching 上抛；`finally` 里的 release 保留。doc 注释同步：补「读取失败抛出，由通道层转 error」。）

2. Dart `local_artwork_service.dart`：

```dart
/// 一次读取的三种结果：拿到字节 / 确定没有图（进负缓存）/ 读取失败
/// （瞬时态，不缓存——外接盘未挂载、通道异常都属此类）。
enum _ArtworkRead { bytes, none, failed }
```

`_readPlatform` 改造（返回 `_ArtworkReadResult`；简单起见用一个小类或 record）：

```dart
/// 读取结果载体：[_ArtworkRead.bytes] 时 [bytes] 非空。
typedef _ArtworkOutcome = ({_ArtworkRead kind, Uint8List? bytes});
```

```dart
  static Future<_ArtworkOutcome> _readPlatform(String source) async {
    final engine = currentLocalAudioEngine;
    // content:// 只有 Android 侧认得（Rust 只能开真实路径）。
    final isContentUri = source.startsWith('content://');
    try {
      if (engine == LocalAudioEngine.mpv && !isContentUri) {
        // Windows / Linux：Rust symphonia 读容器内嵌图。
        // Err(打不开) → failed（不缓存）；Ok(None) → none（确定无图）。
        final bytes = await rust.readLocalCover(path: source);
        return bytes == null || bytes.isEmpty
            ? (kind: _ArtworkRead.none, bytes: null)
            : (kind: _ArtworkRead.bytes, bytes: bytes);
      }
      if (engine == LocalAudioEngine.exoPlayer) {
        // Android：MMR.embeddedPicture；null=确定无图，异常=读取失败。
        final bytes = await _channel.invokeMethod<Uint8List>(
          'getEmbeddedCover',
          {'source': source},
        );
        return bytes == null || bytes.isEmpty
            ? (kind: _ArtworkRead.none, bytes: null)
            : (kind: _ArtworkRead.bytes, bytes: bytes);
      }
    } catch (error) {
      // 读取失败不进负缓存：外接盘慢挂载/瞬时 IO 错误后，挂载完成即可恢复。
      debugPrint('[时音][artwork] 读取本地封面失败(不缓存): $source ($error)');
      return (kind: _ArtworkRead.failed, bytes: null);
    }
    // 未知引擎（iOS 等）：按无图处理（无本地音乐能力，进负缓存无害）。
    return (kind: _ArtworkRead.none, bytes: null);
  }
```

`_read` 改为：

```dart
  static Future<Uint8List?> _read(String source) async {
    final outcome = await _readPlatform(source);
    switch (outcome.kind) {
      case _ArtworkRead.bytes:
        _remember(source, outcome.bytes!);
        return outcome.bytes;
      case _ArtworkRead.none:
        _rememberMissing(source);
        return null;
      case _ArtworkRead.failed:
        return null; // 瞬时失败：不写任何缓存
    }
  }
```

类顶 doc 注释里「负缓存」一句补：「只记『确定无图』（解析成功无图）；读取失败（IO/权限/外接盘未挂载）是瞬时态，不进负缓存」。

- [ ] **Step 4: 定向 + 全量验证**

Run: `flutter test test/services/local_artwork_service_test.dart && flutter analyze && flutter test && cd android && gradlew.bat :app:compileImpellerDebugKotlin`
Expected: 该文件全绿（存量用例中「无封面时记负缓存」走 reply=null 路径不受影响）、analyze 0、Dart 全量绿、Kotlin 编译过。

- [ ] **Step 5: Commit**

```bash
git add lib/ android/ test/
git commit -m "fix(local): 封面负缓存只记「确定无图」——读取失败改瞬时态，外接盘挂载后可自愈"
```

---

### Task 4: 杂项加固

**背景：** 四个低危但便宜的问题：① Kotlin 侧每个封面解析裸 `new Thread`，快滚大库时瞬时线程数=未缓存封面数；② Android `scanLocalMusic` 无重入保护（桌面路径有 `if (_isScanning) return`），自动重扫与手动扫描可并发；③ 桌面扫描 `probe_entry` 对每个 mp3 完整解析 ID3v2 后把封面字节 `to_vec()` 拷进 `LocalTags.cover` 又立刻丢弃（解析读盘不可避免，这份多余拷贝可免）；④ `_LocalArtworkImage` doc 说「无图不显示 shimmer」与实现不符（首载仍闪 shimmer）。

**Files:**
- Modify: `android/app/src/main/kotlin/shiyin/famlife/top/MainActivity.kt`
- Modify: `rust/src/services/local_media.rs`
- Modify: `lib/ui/widgets/artwork.dart`（仅注释）

**Interfaces:** 无接口变化，纯内部加固。

- [ ] **Step 1: Kotlin 单线程执行器 + 扫描重入保护**

1. `MainActivity` 类内新增字段（`getEmbeddedCover` 附近）：

```kotlin
    /** 媒体元数据 IO 专用单线程执行器：封面/头部截取都是短任务，
     *  单线程串行既避免快滚大库时的线程风暴，也不会让长查询插队饿死。 */
    private val mediaIoExecutor = java.util.concurrent.Executors.newSingleThreadExecutor()
```

2. `getEmbeddedCover` 分支与 Task 1 新增的 `readMediaHead` 分支里的 `Thread { … }.start()` 全部替换为 `mediaIoExecutor.execute { … }`（lambda 体不变）。
3. `scanLocalMusic` 对应的 Dart 侧函数 `LocalMusicController.scanLocalMusic()`（`lib/controllers/local_music_controller.dart`）Android 分支开头、`_isScanning = true;` 之前加：

```dart
    // 重入保护：手动扫描进行中时，自动重扫（文件缺失触发）直接跳过——
    // 并发扫只是重复查询、last-wins，桌面路径同款守卫。
    if (_isScanning) return;
```

- [ ] **Step 2: Rust 扫描跳过封面拷贝**

`rust/src/services/local_media.rs`：

1. `tags_from_revision` 加参：

```rust
fn tags_from_revision(
    revision: &symphonia::core::meta::MetadataRevision,
    include_visuals: bool,
) -> LocalTags {
```

函数末尾的 visuals 收集段包进 `if include_visuals { … }`（原代码不动，只加守卫）。
2. 调用点区分——`read_id3v2_from_stream`（Task 1 产物）重构为带开关的私有核心 + 三个薄包装：

```rust
/// ID3v2 解析核心。[include_visuals]=false 时跳过封面字节拷贝：
/// symphonia 的 id3v2 reader 解析时无论如何都会把 APIC 数据读进 builder
/// （不可省的读盘），但扫描/歌词只要文本标签，这里至少免掉每文件一次
/// MB 级的 `to_vec()` 拷贝。
fn read_id3v2_impl(
    mss: &mut MediaSourceStream,
    include_visuals: bool,
) -> Option<LocalTags> {
    let mut builder = symphonia::core::meta::MetadataBuilder::new();
    symphonia_metadata::id3v2::read_id3v2(mss, &mut builder).ok()?;
    let tags = tags_from_revision(&builder.metadata(), include_visuals);
    if tags.is_empty() { None } else { Some(tags) }
}

/// 含封面的完整读取（read_cover 用）。
fn read_id3v2_from_stream(mss: &mut MediaSourceStream) -> Option<LocalTags> {
    read_id3v2_impl(mss, true)
}

/// 只取文本标签（扫描 probe / 字节歌词的 ID3v2 层用）。
fn read_id3v2_text_from_stream(mss: &mut MediaSourceStream) -> Option<LocalTags> {
    read_id3v2_impl(mss, false)
}
```

`read_id3v2_tags(path)`（含封面，`read_cover` 用）内部改调 `read_id3v2_impl(&mut mss, true)`；`probe_entry` 里的 `read_id3v2_tags(&path.to_string_lossy())` 改为一个新的**路径版文本包装** `read_id3v2_text_tags(path)`（同 `read_id3v2_tags` 的头 10 字节校验 + 16MB 上限 + 二次打开，只是内部调 `read_id3v2_impl(mss, false)`）；`read_lyrics_from_bytes` 的 ID3v2 层改调 `read_id3v2_text_from_stream`。`probe_entry` 容器层的 `tags_from_revision(revision)` 调用改传 `false`。

- [ ] **Step 3: 注释修正**

`lib/ui/widgets/artwork.dart` `_LocalArtworkImage` 的 doc 注释「无图时直接落到占位图，不显示 shimmer：本地歌没有内嵌图是常态，每行都闪一下反而更吵。」改为：

```dart
/// 首次取字节期间显示 shimmer（进程内 LRU 命中时毫秒级即消失），
/// 确认无图后落到占位图；本地歌没有内嵌图是常态，shimmer 只闪一次
/// （负缓存后重进视口直接占位）。
```

- [ ] **Step 4: 全量验证**

Run: `cd rust && cargo check && cargo test`，然后仓库根 `flutter analyze && flutter test`，再 `cd android && gradlew.bat :app:compileImpellerDebugKotlin`
Expected: Rust 编译过+存量测试绿、analyze 0、Dart 全量绿、Kotlin 编译过。

- [ ] **Step 5: Commit**

```bash
git add lib/ android/ rust/
git commit -m "refactor(local): 杂项加固——媒体IO线程池化/扫描重入保护/扫描免封面拷贝/注释对齐实现"
```

---

## 收尾（controller 做，不派发）

- 全分支终审：`git diff main...HEAD` 整体复核 + dispatch 最终 reviewer（用最强模型）。
- 更新 `.superpowers/sdd/progress.md` 台账。
