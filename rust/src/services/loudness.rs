//! 桌面端响度均衡分析（Windows / Linux）。
//!
//! 算法与 Android 侧 `LoudnessAnalyzer.kt` 1:1 对齐（EBU R128 /
//! ITU-R BS.1770-4 integrated LUFS：K-weighting 双 biquad + 400ms 块 /
//! 100ms hop + 绝对/相对两轮门限），保证同一首歌在手机与桌面测得的
//! LUFS 一致——响度缓存按 song.hash 共享，跨端不一致会让换设备后
//! 首播增益跳变。
//!
//! 解码用 symphonia（mp3/flac/wav/ogg/m4a 等常见格式），http(s) 音源
//! 先全量下载到临时文件再分析（K-weighting 需要顺序读，流式 seek 麻烦；
//! 单曲 3-10MB，桌面场景可接受）。
//!
//! 渐进式进度：每满 [PROGRESS_INTERVAL_MS] 解码音频时长推送一次
//! "截至当前"的 LUFS（integrated 在任意时刻都能由已累积块算出），
//! Dart 侧立即算增益渐变应用——与 Android 原生通道的
//! `onLoudnessProgress` 反向推送语义一致。

use std::fs::File;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};

use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::{DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::StandardTagKey;
use symphonia::core::probe::Hint;

use crate::kugou::config::USER_AGENT;

/// 中途进度推送间隔（解码音频时长，毫秒），对齐 Dart 侧 _progressIntervalMs。
const PROGRESS_INTERVAL_MS: i64 = 500;

/// 分析时长上限（毫秒）：足够覆盖绝大多数歌曲，防御超长文件/损坏流。
const MAX_ANALYSIS_MS: i64 = 30 * 60 * 1000;

/// 全局取消标志。同一时刻只允许一个分析在途（controller 切歌时先取消
/// 旧的再起新的），全局 AtomicBool 与 Android 侧 `loudnessAnalysisCancelled`
/// 语义一致。
static CANCELLED: AtomicBool = AtomicBool::new(false);

/// 取消当前在途的响度分析（对应 Android 通道的 cancelLoudnessAnalysis）。
pub fn cancel_loudness_analysis() {
    CANCELLED.store(true, Ordering::SeqCst);
}

/// 分析进度/结果事件（Dart 侧 Stream 元素）。
pub struct LoudnessProgress {
    /// 截至当前的 integrated LUFS。
    pub lufs: f64,
    /// 已解码音频时长（毫秒）。
    pub analyzed_ms: i64,
    /// true = 全曲分析完成的最终值（Dart 侧据此写缓存）。
    pub is_final: bool,
}

/// 分析结果。注意：frb 的 StreamSink 模式会丢弃函数返回值，最终数据
/// 经 `Done` 事件下发（api.rs），此结构体的字段仅作内部完成标记使用。
#[allow(dead_code)]
pub struct LoudnessResult {
    pub lufs: f64,
    pub sample_rate: u32,
    pub analyzed_ms: i64,
}

/// 分析一首歌的响度。`source` 为 http(s) URL 或本地文件路径。
///
/// 进度经 `progress` 回调推送（含最终值一次）；取消（全局标志）时返回
/// `None`，与 Android 通道"取消返回 null"对齐。
pub fn analyze(
    source: &str,
    progress: &mut dyn FnMut(LoudnessProgress),
) -> anyhow::Result<Option<LoudnessResult>> {
    CANCELLED.store(false, Ordering::SeqCst);

    let local_path = match resolve_local(source)? {
        Some(path) => path,
        None => return Ok(None), // 已取消
    };

    let file = File::open(&local_path)?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = local_path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }

    let probed = symphonia::default::get_probe().format(
        &hint,
        mss,
        &FormatOptions::default(),
        &Default::default(),
    )?;
    let mut format = probed.format;

    let track = format
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
        .ok_or_else(|| anyhow::anyhow!("no audio track"))?;
    let track_id = track.id;

    let mut decoder =
        symphonia::default::get_codecs().make(&track.codec_params, &DecoderOptions::default())?;
    let sample_rate = track
        .codec_params
        .sample_rate
        .ok_or_else(|| anyhow::anyhow!("no sample rate"))?;
    let channels = track
        .codec_params
        .channels
        .map(|c| c.count())
        .unwrap_or(2)
        .clamp(1, 2);

    let mut meter = GatedLoudnessMeter::new(sample_rate, channels, MAX_ANALYSIS_MS);
    let mut sample_buf: Option<(SampleBuffer<f32>, symphonia::core::audio::SignalSpec)> = None;
    let mut last_progress_ms: i64 = 0;

    loop {
        if CANCELLED.load(Ordering::SeqCst) {
            return Ok(None);
        }
        let packet = match format.next_packet() {
            Ok(p) => p,
            Err(symphonia::core::errors::Error::IoError(ref e))
                if e.kind() == std::io::ErrorKind::UnexpectedEof =>
            {
                break; // 正常结束
            }
            Err(_) => break, // 截断/异常流：按已解码部分出结果（容错）
        };
        if packet.track_id() != track_id {
            continue;
        }
        match decoder.decode(&packet) {
            Ok(decoded) => {
                let spec = *decoded.spec();
                // 声道数/采样率变化（罕见）时重建缓冲。
                let need_rebuild = match &sample_buf {
                    Some((_, prev)) => prev.channels != spec.channels || prev.rate != spec.rate,
                    None => true,
                };
                if need_rebuild {
                    sample_buf = Some((
                        SampleBuffer::<f32>::new(decoded.capacity() as u64, spec),
                        spec,
                    ));
                }
                let (buf, _) = sample_buf.as_mut().unwrap();
                buf.copy_interleaved_ref(decoded);
                let samples = buf.samples();
                if !meter.feed(samples) {
                    break; // 达分析上限
                }
                let analyzed_ms = meter.analyzed_ms();
                if analyzed_ms - last_progress_ms >= PROGRESS_INTERVAL_MS {
                    last_progress_ms = analyzed_ms;
                    let lufs = meter.integrated_lufs();
                    if lufs.is_finite() {
                        progress(LoudnessProgress { lufs, analyzed_ms, is_final: false });
                    }
                }
            }
            Err(symphonia::core::errors::Error::DecodeError(_)) => continue, // 跳过坏包
            Err(_) => break,
        }
    }

    if CANCELLED.load(Ordering::SeqCst) {
        return Ok(None);
    }
    let lufs = meter.integrated_lufs();
    if !lufs.is_finite() {
        anyhow::bail!("no valid loudness blocks");
    }
    let analyzed_ms = meter.analyzed_ms();
    progress(LoudnessProgress { lufs, analyzed_ms, is_final: true });
    Ok(Some(LoudnessResult { lufs, sample_rate, analyzed_ms }))
}

/// http(s) 源下载到临时文件（带酷狗 UA，缺省 403）；本地路径直接返回。
/// 返回 None 表示下载前/中被取消。
fn resolve_local(source: &str) -> anyhow::Result<Option<PathBuf>> {
    if !source.starts_with("http://") && !source.starts_with("https://") {
        return Ok(Some(PathBuf::from(source)));
    }

    let dir = std::env::temp_dir().join("shiyin-loudness");
    std::fs::create_dir_all(&dir)?;
    let path = dir.join(format!("analyze-{}.bin", simple_hash(source)));

    // 网易云外链校验 Referer（与 Dart 播放代理一致）；酷狗 CDN 不吃
    // Referer，但为防个别节点拒绝陌生 Referer，仅对 163 域名注入。
    let is_netease = source
        .split("://")
        .nth(1)
        .and_then(|rest| rest.split(['/', '?', '#']).next())
        .map(|host| {
            let host = host.to_ascii_lowercase();
            host.ends_with(".163.com") || host.ends_with(".126.net")
        })
        .unwrap_or(false);

    let mut request = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(60))
        .build()?
        .get(source)
        .header("User-Agent", USER_AGENT);
    if is_netease {
        request = request.header("Referer", "https://music.163.com/");
    }
    let bytes = request.send()?.error_for_status()?.bytes()?;
    if CANCELLED.load(Ordering::SeqCst) {
        let _ = std::fs::remove_file(&path);
        return Ok(None);
    }
    std::fs::write(&path, &bytes)?;
    // 同 hash 复用临时文件（命中即免重复下载），目录交给系统清理。
    Ok(Some(path))
}

/// URL → 稳定短哈希文件名（FNV-1a，仅用于临时文件命名）。
fn simple_hash(s: &str) -> String {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in s.bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    format!("{h:016x}")
}

// ===== EBU R128 门限响度计（与 LoudnessAnalyzer.kt 1:1 对齐） =====

struct GatedLoudnessMeter {
    channels: usize,
    filters: Vec<KWeightingFilter>,
    block_len: usize,
    hop_len: usize,
    ring_sq: Vec<Vec<f64>>,
    running_sum: Vec<f64>,
    write_pos: usize,
    sample_count: i64,
    block_zs: Vec<f64>,
    max_samples_per_channel: i64,
    total_sq: f64,
    total_samples: i64,
    sample_rate: u32,
}

impl GatedLoudnessMeter {
    fn new(sample_rate: u32, channels: usize, max_duration_ms: i64) -> Self {
        let block_len = ((sample_rate as i64 * 400 / 1000).max(1)) as usize;
        Self {
            channels,
            filters: (0..channels).map(|_| KWeightingFilter::new(sample_rate)).collect(),
            block_len,
            hop_len: ((sample_rate as i64 * 100 / 1000).max(1)) as usize,
            ring_sq: vec![vec![0.0; block_len]; channels],
            running_sum: vec![0.0; channels],
            write_pos: 0,
            sample_count: 0,
            block_zs: Vec::new(),
            max_samples_per_channel: sample_rate as i64 * (max_duration_ms / 1000),
            total_sq: 0.0,
            total_samples: 0,
            sample_rate,
        }
    }

    /// 喂入交错 f32 样本。返回 false 表示已达分析时长上限。
    fn feed(&mut self, samples: &[f32]) -> bool {
        let ch = self.channels;
        let frame_count = samples.len() / ch;
        for frame in 0..frame_count {
            if self.sample_count >= self.max_samples_per_channel {
                return false;
            }
            let mut combined_sq = 0.0;
            for c in 0..ch {
                let x = samples[frame * ch + c] as f64;
                let y = self.filters[c].process(x);
                let sq = y * y;
                let old = self.ring_sq[c][self.write_pos];
                self.running_sum[c] += sq - old;
                self.ring_sq[c][self.write_pos] = sq;
                combined_sq += sq;
            }
            self.total_sq += combined_sq;
            self.total_samples += 1;
            self.write_pos = (self.write_pos + 1) % self.block_len;
            self.sample_count += 1;
            if self.sample_count >= self.block_len as i64
                && (self.sample_count - self.block_len as i64) % self.hop_len as i64 == 0
            {
                let mut z = 0.0;
                for c in 0..ch {
                    z += self.running_sum[c];
                }
                z /= self.block_len as f64;
                self.block_zs.push(z);
            }
        }
        true
    }

    fn analyzed_ms(&self) -> i64 {
        self.sample_count * 1000 / self.sample_rate as i64
    }

    /// Gated integrated loudness（LUFS）。无有效数据返回 NaN。
    fn integrated_lufs(&self) -> f64 {
        if self.block_zs.is_empty() || self.total_samples == 0 {
            return f64::NAN;
        }
        let abs_gate = 10f64.powf((-70.0 + 0.691) / 10.0);
        let mut abs_sum = 0.0;
        let mut abs_count = 0;
        for &z in &self.block_zs {
            if z > abs_gate {
                abs_sum += z;
                abs_count += 1;
            }
        }
        if abs_count == 0 {
            let z = self.total_sq / self.total_samples as f64;
            return -0.691 + 10.0 * z.max(1e-12).log10();
        }
        let z_mean_abs = abs_sum / abs_count as f64;
        let rel_gate = z_mean_abs * 0.1;
        let mut rel_sum = 0.0;
        let mut rel_count = 0;
        for &z in &self.block_zs {
            if z > abs_gate && z > rel_gate {
                rel_sum += z;
                rel_count += 1;
            }
        }
        let final_z = if rel_count == 0 { z_mean_abs } else { rel_sum / rel_count as f64 };
        -0.691 + 10.0 * final_z.max(1e-12).log10()
    }
}

/// EBU R128 K-weighting：两级 biquad 串联。系数用 EBU TECH 3321 固定
/// 系数表（48k/44.1k 精确，其它采样率取最接近者）——与 Android 端
/// 完全一致，见 LoudnessAnalyzer.kt 的 STAGE1/STAGE2 表。
struct KWeightingFilter {
    stage1: Biquad,
    stage2: Biquad,
}

impl KWeightingFilter {
    fn new(sample_rate: u32) -> Self {
        let (s1, s2) = coefficients_for(sample_rate);
        Self {
            stage1: Biquad::new(&s1),
            stage2: Biquad::new(&s2),
        }
    }

    fn process(&mut self, x: f64) -> f64 {
        self.stage2.process(self.stage1.process(x))
    }
}

fn coefficients_for(sr: u32) -> ([f64; 5], [f64; 5]) {
    // [b0, b1, b2, a1, a2]
    const STAGE1_48K: [f64; 5] = [
        1.53512485958697, -2.69169618940638, 1.19839281085285,
        -1.69065929318241, 0.73248077421585,
    ];
    const STAGE2_48K: [f64; 5] = [
        1.0, -2.0, 1.0,
        -1.99004745483398, 0.99007225036653,
    ];
    const STAGE1_44K: [f64; 5] = [
        1.53090959966746, -2.65091438192596, 1.16905317746076,
        -1.66363706312434, 0.71264612449092,
    ];
    const STAGE2_44K: [f64; 5] = [
        1.0, -2.0, 1.0,
        -1.98917551073170, 0.98922153047043,
    ];
    match sr {
        48000 => (STAGE1_48K, STAGE2_48K),
        44100 => (STAGE1_44K, STAGE2_44K),
        _ if sr < 46000 => (STAGE1_44K, STAGE2_44K),
        _ => (STAGE1_48K, STAGE2_48K),
    }
}

/// 直接 II 型转置 biquad。
struct Biquad {
    b0: f64, b1: f64, b2: f64, a1: f64, a2: f64,
    z1: f64, z2: f64,
}

impl Biquad {
    fn new(c: &[f64; 5]) -> Self {
        Self { b0: c[0], b1: c[1], b2: c[2], a1: c[3], a2: c[4], z1: 0.0, z2: 0.0 }
    }

    fn process(&mut self, x: f64) -> f64 {
        let y = self.b0 * x + self.z1;
        self.z1 = self.b1 * x - self.a1 * y + self.z2;
        self.z2 = self.b2 * x - self.a2 * y;
        y
    }
}

/// 读取本地音频的内嵌歌词标签（USLT/LYRICS），供桌面端"本地歌曲歌词"
/// 使用（Android 走 MediaMetadataRetriever 通道）。
pub fn read_embedded_lyrics(path: &str) -> anyhow::Result<Option<String>> {
    let file = File::open(path)?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = PathBuf::from(path).extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }
    let probed = symphonia::default::get_probe().format(
        &hint,
        mss,
        &FormatOptions::default(),
        &Default::default(),
    )?;
    let mut format = probed.format;

    // 容器元数据（mp3 的 ID3 在容器层；metadata() 需 &mut）。
    let mut found: Option<String> = None;
    if let Some(revision) = format.metadata().current() {
        found = find_lyrics_tag(revision.tags());
    }
    Ok(found.filter(|s| !s.trim().is_empty()))
}

fn find_lyrics_tag(tags: &[symphonia::core::meta::Tag]) -> Option<String> {
    for tag in tags {
        let is_lyrics = matches!(tag.std_key, Some(StandardTagKey::Lyrics))
            || tag.key.eq_ignore_ascii_case("lyrics")
            || tag.key.eq_ignore_ascii_case("unsynced lyrics")
            || tag.key.eq_ignore_ascii_case("uslt");
        if is_lyrics {
            if let symphonia::core::meta::Value::String(s) = &tag.value {
                if !s.trim().is_empty() {
                    return Some(s.clone());
                }
            }
        }
    }
    None
}
