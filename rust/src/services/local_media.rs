//! 桌面端本地音乐扫描（Windows / Linux）。
//!
//! Android 侧本地音乐走 MediaStore（MainActivity.kt 的 getLocalSongs），
//! 桌面没有统一媒体库，改为：用户显式添加扫描根目录 → 递归列出音频
//! 扩展名文件 → symphonia probe 读标题/艺术家/专辑/时长标签。
//!
//! probe 只读容器头与元数据（不解码音频主体），单文件毫秒级；
//! 大库扫描用 rayon 并行 probe，进度经回调推送（Dart 侧 Stream）。

use std::fs::File;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

use rayon::prelude::*;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::StandardTagKey;
use symphonia::core::probe::Hint;

/// 扫描结果条目（Dart 侧转 Song 模型）。
pub struct LocalSongEntry {
    pub path: String,
    /// 标签缺失时为空串，由 Dart 侧回退"文件名猜标题"。
    pub title: String,
    pub artist: String,
    pub album: String,
    /// 时长（毫秒）；probe 拿不到时为 0。
    pub duration_ms: i64,
}

/// 支持的音频扩展名。
///
/// 白名单按**播放内核的能力**（桌面 = media_kit/libmpv + ffmpeg）而不是
/// symphonia 的解析能力来定：probe 不了的文件（ape/wma/dsf 等）只是拿不到
/// 标签，回退成"仅文件名"条目，仍能正常播放——旧实现把它们排除在扫描之外，
/// 用户库里这些格式会整片消失（issue #32 的「本地音频无法播放」在桌面端的
/// 典型成因之一）。
///
/// `mp4` 仍然不收：视频文件会混进来，音频 mp4 用 `m4a`/`m4b` 扩展名。
const AUDIO_EXTENSIONS: &[&str] = &[
    "mp3", "flac", "wav", "ogg", "oga", "opus", "m4a", "m4b", "caf", "aac", "aiff", "aif", "aifc",
    "ape", "wma", "wv", "tta", "mka", "dsf", "dff",
];

static SCAN_CANCELLED: AtomicBool = AtomicBool::new(false);

/// 取消在途扫描。
pub fn cancel_scan() {
    SCAN_CANCELLED.store(true, Ordering::SeqCst);
}

/// 递归扫描多个根目录下的音频文件。
///
/// - 符号链接不跟随（防环 + 避免扫到系统目录）；
/// - 单目录读取失败（权限等）跳过；
/// - probe 失败的文件回退"仅路径"条目（见 [AUDIO_EXTENSIONS] 注释）；
/// - 结果按路径排序（同次扫描顺序稳定，UI 不跳动）。
///
/// `progress` 回调 `(已处理文件数, 总文件数)`，每 20 个推一次。
pub fn scan(
    roots: &[String],
    progress: &mut (dyn FnMut(usize, usize) + Send + Sync),
) -> anyhow::Result<Vec<LocalSongEntry>> {
    SCAN_CANCELLED.store(false, Ordering::SeqCst);

    let mut files = Vec::new();
    for root in roots {
        if SCAN_CANCELLED.load(Ordering::SeqCst) {
            return Ok(Vec::new());
        }
        let root_path = PathBuf::from(root);
        if !root_path.is_dir() {
            continue;
        }
        collect_audio_files(&root_path, &mut files, 0);
    }
    files.sort();
    files.dedup();

    let total = files.len();
    let processed = std::sync::atomic::AtomicUsize::new(0);
    // 并行闭包需 Fn，进度回调是 FnMut，用 Mutex 包一层。
    let progress = std::sync::Mutex::new(progress);
    let entries: Vec<LocalSongEntry> = files
        .into_par_iter()
        .filter_map(|path| {
            if SCAN_CANCELLED.load(Ordering::SeqCst) {
                return None;
            }
            let done = processed.fetch_add(1, Ordering::Relaxed) + 1;
            if done.is_multiple_of(20) || done == total {
                if let Ok(mut cb) = progress.lock() {
                    cb(done, total);
                }
            }
            Some(probe_entry(&path).unwrap_or_else(|| LocalSongEntry {
                path: path.to_string_lossy().into_owned(),
                title: String::new(),
                artist: String::new(),
                album: String::new(),
                duration_ms: 0,
            }))
        })
        .collect();

    Ok(entries)
}

/// 递归收集音频文件（深度上限防御异常深的树）。
fn collect_audio_files(dir: &Path, out: &mut Vec<PathBuf>, depth: usize) {
    if depth > 16 {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        // file_type() 对符号链接返回链接自身，is_symlink 跳过（防环）。
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if file_type.is_symlink() {
            continue;
        }
        let path = entry.path();
        if file_type.is_dir() {
            collect_audio_files(&path, out, depth + 1);
        } else if is_audio_file(&path) {
            out.push(path);
        }
    }
}

fn is_audio_file(path: &Path) -> bool {
    let Some(ext) = path.extension().and_then(|e| e.to_str()) else {
        return false;
    };
    let ext = ext.to_ascii_lowercase();
    AUDIO_EXTENSIONS.contains(&ext.as_str())
}

/// 一首本地文件里读到的标签（只取本 fork 用得到的字段）。
///
/// 标签来源分两层：容器元数据（FLAC VorbisComment、MP4 ilst、OGG、WAV INFO、
/// AIFF ID3 chunk）与 **ID3v2**。后者必须单独读——symphonia 的 mp3 解复用器
/// （`symphonia-bundle-mp3`）里没有任何 ID3 解析代码，`format.metadata()`
/// 对 mp3 恒为空，所以 mp3（本地音乐里最普遍的格式）的标题/内嵌歌词/内嵌
/// 封面全靠这一层。
///
/// issue #32「无法直接加载本地文件的封面还有歌词」在桌面端的根因就在这里：
/// 旧实现只读容器元数据，mp3 一律拿不到图，标题也只能退化成文件名。
#[derive(Default)]
pub struct LocalTags {
    pub title: String,
    pub artist: String,
    pub album: String,
    pub lyrics: Option<String>,
    pub cover: Option<Vec<u8>>,
}

impl LocalTags {
    /// 用 [other] 补齐本结构里仍为空的字段（容器层优先，ID3v2 兜底）。
    fn fill_from(&mut self, other: LocalTags) {
        if self.title.is_empty() {
            self.title = other.title;
        }
        if self.artist.is_empty() {
            self.artist = other.artist;
        }
        if self.album.is_empty() {
            self.album = other.album;
        }
        if self.lyrics.is_none() {
            self.lyrics = other.lyrics;
        }
        if self.cover.is_none() {
            self.cover = other.cover;
        }
    }

    fn is_empty(&self) -> bool {
        self.title.is_empty()
            && self.artist.is_empty()
            && self.album.is_empty()
            && self.lyrics.is_none()
            && self.cover.is_none()
    }
}

/// 标签 key 是否表示「歌词」。
///
/// 覆盖三种实际写法：
/// - 标准的 `LYRICS` / `UNSYNCED LYRICS`（VorbisComment、部分 ID3 写入器）；
/// - ID3v2 的 `USLT` 帧（symphonia 已映射成 `StandardTagKey::Lyrics`，
///   这里只是兜底）；
/// - **`TXXX:<desc>`**：ffmpeg 等写入 `-metadata lyrics=...` 时用的就是
///   `TXXX:lyrics`，symphonia 会把 key 拼成 `TXXX:lyrics` 且不映射 std_key。
///   不剥前缀会漏掉这类文件（local_media 的封面/歌词读取因此都要用它）。
pub(crate) fn is_lyrics_key(key: &str) -> bool {
    let lower = key.to_ascii_lowercase();
    let bare = lower.strip_prefix("txxx:").unwrap_or(&lower);
    matches!(
        bare,
        "lyrics" | "lyric" | "unsynced lyrics" | "unsyncedlyrics" | "uslt"
    )
}

/// 容器元数据修订 → [LocalTags]。
///
/// [include_visuals]=false 时跳过封面字节拷贝：symphonia 解析时无论如何
/// 都会把图数据读进 revision（不可省的读盘），但扫描/歌词只要文本标签，
/// 调用方至少可以免掉每文件一次 MB 级的 `to_vec()` 拷贝。
fn tags_from_revision(
    revision: &symphonia::core::meta::MetadataRevision,
    include_visuals: bool,
) -> LocalTags {
    let mut tags = LocalTags::default();
    for tag in revision.tags() {
        let symphonia::core::meta::Value::String(value) = &tag.value else {
            continue;
        };
        if value.trim().is_empty() {
            continue;
        }
        match tag.std_key {
            Some(StandardTagKey::TrackTitle) if tags.title.is_empty() => {
                tags.title = value.clone();
            }
            Some(StandardTagKey::Artist) | Some(StandardTagKey::Performer)
                if tags.artist.is_empty() =>
            {
                tags.artist = value.clone();
            }
            Some(StandardTagKey::Album) if tags.album.is_empty() => tags.album = value.clone(),
            Some(StandardTagKey::Lyrics) if tags.lyrics.is_none() => {
                tags.lyrics = Some(value.clone());
            }
            _ => {
                // 部分写入器不映射 std_key，按原始 key 名兜底。
                if tags.lyrics.is_none() && is_lyrics_key(&tag.key) {
                    tags.lyrics = Some(value.clone());
                }
            }
        }
    }
    if include_visuals {
        // 一张图就够了：优先 FrontCover（ID3v2 APIC 的照片类型 3）。
        let front = revision.visuals().iter().find(|visual| {
            !visual.data.is_empty()
                && visual.usage == Some(symphonia::core::meta::StandardVisualKey::FrontCover)
        });
        let any = revision
            .visuals()
            .iter()
            .find(|visual| !visual.data.is_empty());
        if let Some(visual) = front.or(any) {
            tags.cover = Some(visual.data.to_vec());
        }
    }
    tags
}

/// 单独读 ID3v2（v2.2 / v2.3 / v2.4）：mp3 的标签、内嵌歌词、内嵌封面都在这。
///
/// 无 ID3v2 标签、文件打不开、标签损坏都返回 None（标签缺失是常态，
/// 调用方按"没有"处理即可）。
pub fn read_id3v2_tags(path: &str) -> Option<LocalTags> {
    read_id3v2_path(path, true)
}

/// 同 [read_id3v2_tags]，但只取文本标签（扫描 probe / loudness 歌词用）：
/// 跳过封面字节的 `to_vec()` 拷贝。
pub(crate) fn read_id3v2_text_tags(path: &str) -> Option<LocalTags> {
    read_id3v2_path(path, false)
}

/// 路径版外壳：头 10 字节校验（"ID3" 魔数 + syncsafe 声明长度 ≤16MB）
/// + 二次打开后走 [read_id3v2_impl]。两个薄包装只差 [include_visuals]。
fn read_id3v2_path(path: &str, include_visuals: bool) -> Option<LocalTags> {
    let mut file = File::open(path).ok()?;
    // 先看标签头声明的长度再决定要不要解析：ID3v2 允许整块标签驻留内存，
    // 一个损坏/恶意的头就能让解析器按几 GB 去分配。正常歌曲的标签（含
    // 4000×4000 封面）也远小于 16MB。
    let mut header = [0u8; 10];
    std::io::Read::read_exact(&mut file, &mut header).ok()?;
    if &header[0..3] != b"ID3" {
        return None;
    }
    // 长度是 4 个 7-bit 同步安全字节（最高位恒 0）。
    let declared = header[6..10]
        .iter()
        .fold(0usize, |acc, byte| (acc << 7) | usize::from(byte & 0x7f));
    if declared > _MAX_ID3V2_TAG_BYTES {
        return None;
    }

    // read_id3v2 从流的当前位置开始读，这里重新打开从 0 开始。
    let file = File::open(path).ok()?;
    let mut mss = MediaSourceStream::new(Box::new(file), Default::default());
    read_id3v2_impl(&mut mss, include_visuals)
}

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
    if tags.is_empty() {
        None
    } else {
        Some(tags)
    }
}

/// 只取文本标签（扫描 probe / 字节歌词的 ID3v2 层用）。同样从流的
/// 当前位置读，调用方负责先行长度上限校验。
fn read_id3v2_text_from_stream(mss: &mut MediaSourceStream) -> Option<LocalTags> {
    read_id3v2_impl(mss, false)
}

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
    // 按魔数分流，两条路径各自只做一次 to_vec()：单拷贝已是 'static 约束
    // 下的最优（MediaSourceStream 内部是 Box<dyn MediaSource>，零拷贝需
    // 上游支持借用源），不再像旧实现那样两层各拷一份。
    if data.starts_with(b"ID3") {
        // 只走 ID3v2 层（mp3 的唯一来源；ID3 在文件头，截断数据里完整可用）。
        // 容器层对 ID3 开头的文件恒拿不到歌词——symphonia 的 mp3 解复用器
        // 没有 ID3 解析代码；FLAC/WAV/AIFF 的头 3 字节固定为 fLaC/RIFF/FORM，
        // MP4 即便头 4 字节 size 巧合 "ID3"，后续 ftyp 也在截断流上必然探测
        // 失败、moov/ilst 不可达，歌词同样拿不到。跳过容器探测还省掉对截断
        // mp3 找 frame sync 的 MB 级扫描。
        // 16MB 上限由调用方（Kotlin 头部截取）保证，这里不再重复校验。
        let cursor = std::io::Cursor::new(data.to_vec());
        let mut mss = MediaSourceStream::new(Box::new(cursor), Default::default());
        return Ok(read_id3v2_text_from_stream(&mut mss).and_then(|tags| tags.lyrics));
    }
    // 只走容器层（截断流探测失败按没有处理，不冒错）。
    // 无扩展名可用，让 probe 按魔数嗅探；ID3v2 层可整体跳过——
    // read_id3v2 内部首先校验 "ID3" 魔数，非 ID3 开头必然 Err→None。
    let cursor = std::io::Cursor::new(data.to_vec());
    let mss = MediaSourceStream::new(Box::new(cursor), Default::default());
    let hint = Hint::new();
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
    Ok(None)
}

/// ID3v2 标签块的内存上限（16MB）。
const _MAX_ID3V2_TAG_BYTES: usize = 16 * 1024 * 1024;

/// probe 单个文件读取标签与时长，失败返回 None。
fn probe_entry(path: &Path) -> Option<LocalSongEntry> {
    let file = File::open(path).ok()?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }

    let probed = symphonia::default::get_probe()
        .format(&hint, mss, &FormatOptions::default(), &Default::default())
        .ok()?;
    let mut format = probed.format;

    // 必须有音轨（纯视频/损坏文件排除）。
    let track = format
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec != symphonia::core::codecs::CODEC_TYPE_NULL)?;

    // 时长：n_frames × time_base（time_base.num/den 秒/帧）。
    let duration_ms = track
        .codec_params
        .time_base
        .zip(track.codec_params.n_frames)
        .map(|(tb, frames)| ((frames as u128 * tb.numer as u128 * 1000) / tb.denom as u128) as i64)
        .filter(|&ms| ms > 0)
        .unwrap_or(0);

    // 标签：容器元数据（FLAC/MP4/OGG 等）+ ID3v2 兜底（mp3 唯一来源）。
    // 扫描只要文本标签，两层都传 false 免掉封面字节的 `to_vec()` 拷贝
    // （封面由 UI 按需经 [read_cover] 另取）。
    let mut tags = match format.metadata().current() {
        Some(revision) => tags_from_revision(revision, false),
        None => LocalTags::default(),
    };
    if tags.title.is_empty() || tags.artist.is_empty() || tags.album.is_empty() {
        if let Some(id3v2) = read_id3v2_text_tags(&path.to_string_lossy()) {
            tags.fill_from(id3v2);
        }
    }

    Some(LocalSongEntry {
        path: path.to_string_lossy().into_owned(),
        title: tags.title,
        artist: tags.artist,
        album: tags.album,
        duration_ms,
    })
}

/// 读取音频文件的自带封面（ID3v2 APIC / FLAC PICTURE / MP4 `covr`）。
///
/// 返回**原始**图片字节（不转码、不缩放），由 Flutter 侧按展示尺寸解码，
/// 避免在 Rust 里重复实现一套图片缩放。
///
/// 无图返回 `None`：封面缺失是常态（大量本地文件本来就没有内嵌图），
/// 不该让调用方按错误处理。
pub fn read_cover(path: &str) -> Option<Vec<u8>> {
    // 1. 容器层：FLAC PICTURE、MP4 ilst/covr、AIFF 的 ID3 chunk。
    if let Some(bytes) = container_cover(path) {
        return Some(bytes);
    }
    // 2. ID3v2：mp3 的唯一来源（见 [LocalTags] 的说明）。
    read_id3v2_tags(path).and_then(|tags| tags.cover)
}

/// 容器元数据里的封面（不含 ID3v2）。
fn container_cover(path: &str) -> Option<Vec<u8>> {
    let file = File::open(path).ok()?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = Path::new(path).extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }
    let probed = symphonia::default::get_probe()
        .format(&hint, mss, &FormatOptions::default(), &Default::default())
        .ok()?;
    let mut format = probed.format;
    let metadata = format.metadata();
    let revision = metadata.current()?;
    revision
        .visuals()
        .iter()
        .find(|visual| !visual.data.is_empty())
        .map(|visual| visual.data.to_vec())
}

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
        frame.extend_from_slice(&(frame_body_len as u32).to_be_bytes()); // v2.3 是 4 字节普通整数
        frame.extend_from_slice(&[0, 0]); // flags
        frame.push(0);
        frame.extend_from_slice(b"eng");
        frame.push(0);
        frame.extend_from_slice(text_bytes);

        let mut out = Vec::new();
        out.extend_from_slice(b"ID3");
        out.extend_from_slice(&[3, 0, 0]); // v2.3, flags=0
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
    fn lyrics_from_bytes_truncated_container_is_none() {
        // 非 "ID3" 开头且容器探测必然失败的截断流：不能 Err，按无标签处理。
        let mut bytes = vec![0xff; 64];
        bytes[0] = b'x';
        assert!(read_lyrics_from_bytes(&bytes).unwrap().is_none());
    }

    #[test]
    fn lyrics_from_bytes_id3_without_uslt_is_none() {
        // ID3 开头但去掉 USLT 帧（tag size=0 的空标签）：只走 ID3v2 分支，
        // 解析无歌词 → None 而非 Err。
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"ID3");
        bytes.extend_from_slice(&[3, 0, 0]); // v2.3, flags=0
        bytes.extend_from_slice(&[0, 0, 0, 0]); // tag size = 0（无帧）
        assert!(read_lyrics_from_bytes(&bytes).unwrap().is_none());
    }
}
