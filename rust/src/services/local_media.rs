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

/// 支持的音频扩展名。probe 识别不了的（如 opus：mpv 能放、symphonia
/// 不识别）会回退成"仅文件名"条目，不丢出曲库；mp4 不收（视频文件
/// 会混进来，音频 mp4 用 m4a 扩展名）。
const AUDIO_EXTENSIONS: &[&str] = &[
    "mp3", "flac", "wav", "ogg", "oga", "opus", "m4a", "aac", "aiff", "aif", "aifc",
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
        let Ok(file_type) = entry.file_type() else { continue };
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

/// probe 单个文件读取标签与时长，失败返回 None。
fn probe_entry(path: &Path) -> Option<LocalSongEntry> {
    let file = File::open(path).ok()?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }

    let probed = symphonia::default::get_probe().format(
        &hint,
        mss,
        &FormatOptions::default(),
        &Default::default(),
    )
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
        .map(|(tb, frames)| {
            ((frames as u128 * tb.numer as u128 * 1000) / tb.denom as u128) as i64
        })
        .filter(|&ms| ms > 0)
        .unwrap_or(0);

    // 标签：容器元数据（mp3 的 ID3 在容器层；metadata() 需 &mut）。
    let mut title = String::new();
    let mut artist = String::new();
    let mut album = String::new();
    if let Some(revision) = format.metadata().current() {
        for tag in revision.tags() {
            let symphonia::core::meta::Value::String(value) = &tag.value else {
                continue;
            };
            if value.trim().is_empty() {
                continue;
            }
            match tag.std_key {
                Some(StandardTagKey::TrackTitle) if title.is_empty() => {
                    title = value.clone();
                }
                Some(StandardTagKey::Artist) | Some(StandardTagKey::Performer)
                    if artist.is_empty() =>
                {
                    artist = value.clone();
                }
                Some(StandardTagKey::Album) if album.is_empty() => album = value.clone(),
                _ => {}
            }
        }
    }

    Some(LocalSongEntry {
        path: path.to_string_lossy().into_owned(),
        title,
        artist,
        album,
        duration_ms,
    })
}
