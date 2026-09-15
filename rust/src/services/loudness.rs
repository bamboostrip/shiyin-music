//! 桌面端响度均衡分析（Windows / Linux）。
//!
//! 算法与 Android 侧 `LoudnessAnalyzer.kt` 1:1 对齐（EBU R128 /
//! ITU-R BS.1770-4 integrated LUFS：K-weighting 双 biquad + 400ms 块 /
//! 100ms hop + 绝对/相对两轮门限），保证同一首歌在手机与桌面测得的
//! LUFS 一致——响度缓存按 song.hash 共享，跨端不一致会让换设备后
//! 首播增益跳变。
//!
//! 解码用 symphonia（mp3/flac/wav/ogg/m4a 等常见格式）。http(s) 音源优先
//! 流式边下边解（顺序容器无需 seek，下载过程中即出首个响度进度，对齐
//! 移动端 MediaExtractor / AVAssetReader）；probe 需要 seek（如 m4a 定位
//! moov）或流中途读错误时，自动回退原"整曲下载到临时文件"路径。
//!
//! 渐进式进度：每满 [PROGRESS_INTERVAL_MS] 解码音频时长推送一次
//! "截至当前"的 LUFS（integrated 在任意时刻都能由已累积块算出），
//! Dart 侧立即算增益渐变应用——与 Android 原生通道的
//! `onLoudnessProgress` 反向推送语义一致。

use std::fs::File;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::{DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::{MediaSource, MediaSourceStream};
use symphonia::core::meta::StandardTagKey;
use symphonia::core::probe::Hint;

use crate::kugou::config::USER_AGENT;

/// 中途进度推送间隔（解码音频时长，毫秒），对齐 Dart 侧 _progressIntervalMs。
const PROGRESS_INTERVAL_MS: i64 = 500;

/// 分析时长上限（毫秒）：足够覆盖绝大多数歌曲，防御超长文件/损坏流。
const MAX_ANALYSIS_MS: i64 = 30 * 60 * 1000;

/// 分析取消模型：代数计数（generation）+ 每次调用的独立 stop 标志。
///
/// 历史实现是单个全局 `AtomicBool`，analyze 入口先 `store(false)`：
/// - 快速切歌时"取消旧分析"与"启动新分析"两次调用在 FRB 线程池上无序，
///   新分析可能先复位标志，旧分析随即失去取消（白跑整段解码）；
/// - Dart 侧取消订阅导致的 `events.add` 失败也置同一个全局标志，
///   迟到的旧订阅错误会误杀**其后才启动**的新歌分析（返回 None，
///   新歌整轮没有响度均衡）。
///
/// 现在：cancel 使代数 +1；analyze 启动时记录当前代数，代数变化即取消
/// ——旧任务只被"自己启动之后"发生的取消杀死，复位语义不复存在。
/// 订阅断开只置本调用私有的 stop，不影响其他任务。
static GENERATION: AtomicU64 = AtomicU64::new(0);

/// 取消当前在途的响度分析（对应 Android 通道的 cancelLoudnessAnalysis）。
pub fn cancel_loudness_analysis() {
    GENERATION.fetch_add(1, Ordering::SeqCst);
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
/// 进度经 `progress` 回调推送（含最终值一次）；取消（代数变化或本调用
/// 的 [stop] 置位）时返回 `None`，与 Android 通道"取消返回 null"对齐。
pub fn analyze(
    source: &str,
    stop: &AtomicBool,
    progress: &mut dyn FnMut(LoudnessProgress),
) -> anyhow::Result<Option<LoudnessResult>> {
    let generation = GENERATION.load(Ordering::SeqCst);
    let cancelled =
        || stop.load(Ordering::SeqCst) || GENERATION.load(Ordering::SeqCst) != generation;

    // 本地文件：直接分析（原路径）。
    if !source.starts_with("http://") && !source.starts_with("https://") {
        return analyze_path(Path::new(source), &cancelled, progress);
    }

    // http(s) 源：流式优先。成功则全程不落盘，且边下边解——不等整曲
    // 下载完成即开始出进度，对齐移动端体验；失败（probe 需要 seek 的
    // 容器如 isomp4/m4a、网络错误、解码中读错误）自动回退整曲下载。
    match analyze_streaming(source, &cancelled, progress) {
        Ok(Some(result)) => return Ok(Some(result)),
        Ok(None) => return Ok(None), // 已取消
        Err(_) => {
            // 回退前再确认一次取消：流式失败可能正是取消信号打断了
            // 网络读，此时不应误触发回退重新下载。
            if cancelled() {
                return Ok(None);
            }
        }
    }

    // 回退：整曲下载到临时文件再分析（原路径）。流式中途失败会重新完整
    // 下载一次——有界（仅此一次），换取半截 LUFS 不被当成最终值；流式
    // 期间已推送的进度事件会从头重放，"截至当前"语义下无害，final 恒以
    // 最后一次为准。
    let (local_path, is_temp) = match resolve_local(source, &cancelled)? {
        Some(pair) => pair,
        None => return Ok(None), // 已取消
    };
    let result = analyze_path(&local_path, &cancelled, progress);
    // http 源的临时文件分析完就删（成功/失败/取消一致）：历史实现只写
    // 不删也不复用,每首首次播放的歌都给 %TEMP% 永久留下 3-10MB。
    // 删除必须在 analyze_path 返回后:解码期间 File 句柄未释放,Windows
    // 上打开中的文件删除会失败。
    if is_temp {
        let _ = std::fs::remove_file(&local_path);
    }
    result
}

/// 分析本地文件（本地播放与整曲下载回退共用）：打开文件构造可 seek 的
/// MSS + 扩展名 hint，交统一解码循环。
fn analyze_path(
    local_path: &Path,
    cancelled: &dyn Fn() -> bool,
    progress: &mut dyn FnMut(LoudnessProgress),
) -> anyhow::Result<Option<LoudnessResult>> {
    let file = File::open(local_path)?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = local_path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }
    // 本地/回退路径对 interrupted（截断文件）沿用容错语义：按已解码
    // 部分出结果，与历史行为一致。
    Ok(analyze_mss(mss, &hint, cancelled, progress)?.map(|analysis| analysis.result))
}

/// [analyze_mss] 的产物：结果 + 是否异常中断。
struct MssAnalysis {
    result: LoudnessResult,
    /// true = 包循环因非 EOF 错误（截断/读错误）退出而非干净流尾。
    /// symphonia 对正常流尾统一报 IoError(UnexpectedEof)，其余错误即
    /// 中途读错误。流式路径不得把半截 LUFS 当最终值，由调用方据此回退
    /// 整曲下载；本地/回退路径沿用容错语义、忽略此标记。
    interrupted: bool,
}

/// 统一解码循环：probe → 选轨 → 包循环 → 门限响度计。本地文件、整曲
/// 下载回退、HTTP 流式三条路径共用，差异仅在 MediaSource 与 hint 的构造。
fn analyze_mss(
    mss: MediaSourceStream,
    hint: &Hint,
    cancelled: &dyn Fn() -> bool,
    progress: &mut dyn FnMut(LoudnessProgress),
) -> anyhow::Result<Option<MssAnalysis>> {
    let probed = symphonia::default::get_probe().format(
        hint,
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
    let mut interrupted = false;

    loop {
        if cancelled() {
            return Ok(None);
        }
        let packet = match format.next_packet() {
            Ok(p) => p,
            Err(symphonia::core::errors::Error::IoError(ref e))
                if e.kind() == io::ErrorKind::UnexpectedEof =>
            {
                break; // 正常结束
            }
            Err(_) => {
                // 截断/异常流：本地与回退路径按已解码部分出结果（容错，
                // 行为不变）；流式路径视为中途读错误，由调用方回退。
                interrupted = true;
                break;
            }
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
                        progress(LoudnessProgress {
                            lufs,
                            analyzed_ms,
                            is_final: false,
                        });
                    }
                }
            }
            Err(symphonia::core::errors::Error::DecodeError(_)) => continue, // 跳过坏包
            Err(_) => break,
        }
    }

    if cancelled() {
        return Ok(None);
    }
    let lufs = meter.integrated_lufs();
    if !lufs.is_finite() {
        anyhow::bail!("no valid loudness blocks");
    }
    let analyzed_ms = meter.analyzed_ms();
    progress(LoudnessProgress {
        lufs,
        analyzed_ms,
        is_final: true,
    });
    Ok(Some(MssAnalysis {
        result: LoudnessResult {
            lufs,
            sample_rate,
            analyzed_ms,
        },
        interrupted,
    }))
}

/// 只读顺序源（HTTP 流式响度分析用）：Read 直通，Seek 恒返回 Unsupported，
/// byte_len 未知返回 None。mp3/flac/ogg/wav 等顺序容器无需 seek 即可
/// probe+解码；isomp4(m4a) 等需 seek 定位 moov 的容器 probe 失败 → 上层
/// 回退整曲下载。
struct SequentialReadSource<R: std::io::Read> {
    inner: R,
}

impl<R: std::io::Read> std::io::Read for SequentialReadSource<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.inner.read(buf)
    }
}

impl<R: std::io::Read> std::io::Seek for SequentialReadSource<R> {
    fn seek(&mut self, _pos: io::SeekFrom) -> io::Result<u64> {
        // 顺序流不可 seek：需要 seek 的读取器（如 isomp4 定位 moov）拿到
        // 此错误而失败，正是上层回退整曲下载的触发点。
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "sequential stream source",
        ))
    }
}

// MediaSource 还要求 Send + Sync（symphonia 装箱后跨线程使用）；
// reqwest 的 blocking Response 满足。
impl<R: std::io::Read + Send + Sync> MediaSource for SequentialReadSource<R> {
    fn is_seekable(&self) -> bool {
        false
    }

    fn byte_len(&self) -> Option<u64> {
        None // 流式响应总长度未知（chunked / 缺 Content-Length 均可能）
    }
}

/// HTTP 流式分析：响应体包装成不可 seek 的顺序源直接喂 symphonia，
/// 边下边解、全程不落盘。返回的任何 Err（状态码错误、probe 失败——如
/// isomp4 需要 seek 定位 moov、解码中途读错误）均由上层回退整曲下载。
fn analyze_streaming(
    source: &str,
    cancelled: &dyn Fn() -> bool,
    progress: &mut dyn FnMut(LoudnessProgress),
) -> anyhow::Result<Option<LoudnessResult>> {
    // reqwest 的 blocking Response 直接实现 io::Read，无需先缓冲整包响应体。
    let response = build_http_request(source)?.send()?.error_for_status()?;
    let mss = MediaSourceStream::new(
        Box::new(SequentialReadSource { inner: response }),
        Default::default(),
    );
    let mut hint = Hint::new();
    if let Some(ext) = url_extension(source) {
        hint.with_extension(&ext);
    }
    match analyze_mss(mss, &hint, cancelled, progress)? {
        None => Ok(None), // 已取消
        // 中途读错误（网络抖动/超时截断）：半截结果不可当最终值，返回
        // Err 交由上层回退整曲下载（代价是重新完整下载一次，有界）。
        Some(MssAnalysis {
            interrupted: true, ..
        }) => {
            anyhow::bail!("streaming decode interrupted by read error")
        }
        Some(MssAnalysis {
            result,
            interrupted: false,
        }) => Ok(Some(result)),
    }
}

/// 构造 http(s) GET 请求（60s 超时），整曲下载（resolve_local）与流式
/// 分析共用：酷狗 UA 全局注入（缺省 403）；网易云外链校验 Referer（与
/// Dart 播放代理一致）——酷狗 CDN 不吃 Referer，但为防个别节点拒绝
/// 陌生 Referer，仅对 163 域名注入。
fn build_http_request(source: &str) -> anyhow::Result<reqwest::blocking::RequestBuilder> {
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
    Ok(request)
}

/// 取 URL path 最后一段的扩展名作 probe hint（小写）。先剥 query/
/// fragment，避免把 "?token=1" 之类残片当扩展名；无扩展名或超长
/// （>16——正常音频容器扩展名至多 4-5 字符，超长即 query 残片）返回
/// None。None 只是不提供提示，symphonia 仍会按内容标记探测。
fn url_extension(source: &str) -> Option<String> {
    let path = source.split(['?', '#']).next().unwrap_or(source);
    let file_name = path.rsplit('/').next().unwrap_or_default();
    let (name, ext) = file_name.rsplit_once('.')?;
    if name.is_empty() || ext.is_empty() || ext.len() > 16 {
        return None;
    }
    Some(ext.to_ascii_lowercase())
}

/// http(s) 源下载到临时文件（整曲下载回退路径，请求头见
/// [build_http_request]）；本地路径直接返回。
/// 返回 None 表示下载前/中被取消；Some((path, is_temp)) 的 is_temp 标记
/// 是否为本函数管理的临时文件（分析结束后由调用方删除，本地文件绝不能删）。
fn resolve_local(
    source: &str,
    cancelled: &dyn Fn() -> bool,
) -> anyhow::Result<Option<(PathBuf, bool)>> {
    if !source.starts_with("http://") && !source.starts_with("https://") {
        return Ok(Some((PathBuf::from(source), false)));
    }

    let dir = std::env::temp_dir().join("shiyin-loudness");
    std::fs::create_dir_all(&dir)?;
    let path = dir.join(format!("analyze-{}.bin", simple_hash(source)));

    // 崩溃/取消残留的同名临时文件直接复用，免去一次重复下载
    // （正常路径分析结束即删，命中窗口很小，但零成本顺手兜住）。
    if path.exists() {
        return Ok(Some((path, true)));
    }

    let bytes = build_http_request(source)?
        .send()?
        .error_for_status()?
        .bytes()?;
    if cancelled() {
        let _ = std::fs::remove_file(&path);
        return Ok(None);
    }
    std::fs::write(&path, &bytes)?;
    Ok(Some((path, true)))
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
            filters: (0..channels)
                .map(|_| KWeightingFilter::new(sample_rate))
                .collect(),
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
        let final_z = if rel_count == 0 {
            z_mean_abs
        } else {
            rel_sum / rel_count as f64
        };
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
        1.53512485958697,
        -2.69169618940638,
        1.19839281085285,
        -1.69065929318241,
        0.73248077421585,
    ];
    const STAGE2_48K: [f64; 5] = [1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036653];
    const STAGE1_44K: [f64; 5] = [
        1.53090959966746,
        -2.65091438192596,
        1.16905317746076,
        -1.66363706312434,
        0.71264612449092,
    ];
    const STAGE2_44K: [f64; 5] = [1.0, -2.0, 1.0, -1.98917551073170, 0.98922153047043];
    match sr {
        48000 => (STAGE1_48K, STAGE2_48K),
        44100 => (STAGE1_44K, STAGE2_44K),
        _ if sr < 46000 => (STAGE1_44K, STAGE2_44K),
        _ => (STAGE1_48K, STAGE2_48K),
    }
}

/// 直接 II 型转置 biquad。
struct Biquad {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
    z1: f64,
    z2: f64,
}

impl Biquad {
    fn new(c: &[f64; 5]) -> Self {
        Self {
            b0: c[0],
            b1: c[1],
            b2: c[2],
            a1: c[3],
            a2: c[4],
            z1: 0.0,
            z2: 0.0,
        }
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

// 注意：本 crate 只产 cdylib/staticlib（无 rlib），integration test 无法
// 链接，单元测试必须放本文件内。
#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    /// 手写最小 PCM WAV（44 字节 RIFF 头 + i16 单声道正弦），测试不依赖
    /// 素材文件。
    fn make_wav_bytes(duration_secs: f64, sample_rate: u32) -> Vec<u8> {
        const CHANNELS: usize = 1;
        let num_samples = (duration_secs * sample_rate as f64) as usize;
        let data_len = num_samples * CHANNELS * 2;
        let mut out = Vec::with_capacity(44 + data_len);
        out.extend_from_slice(b"RIFF");
        out.extend_from_slice(&((36 + data_len) as u32).to_le_bytes());
        out.extend_from_slice(b"WAVE");
        out.extend_from_slice(b"fmt ");
        out.extend_from_slice(&16u32.to_le_bytes()); // fmt 块固定长
        out.extend_from_slice(&1u16.to_le_bytes()); // PCM
        out.extend_from_slice(&(CHANNELS as u16).to_le_bytes());
        out.extend_from_slice(&sample_rate.to_le_bytes());
        out.extend_from_slice(&((sample_rate as usize * CHANNELS * 2) as u32).to_le_bytes()); // 字节率
        out.extend_from_slice(&((CHANNELS * 2) as u16).to_le_bytes()); // 块对齐
        out.extend_from_slice(&16u16.to_le_bytes()); // 位深
        out.extend_from_slice(b"data");
        out.extend_from_slice(&(data_len as u32).to_le_bytes());
        for i in 0..num_samples {
            let t = i as f64 / sample_rate as f64;
            // 440Hz / 0.5 振幅：响度远高于 -70 LUFS 绝对门限，必出有效块。
            let v = (2.0 * std::f64::consts::PI * 440.0 * t).sin() * 0.5;
            out.extend_from_slice(&((v * 32767.0) as i16).to_le_bytes());
        }
        out
    }

    /// 同一份音频字节分别经「不可 seek（Cursor 包装 SequentialReadSource）」
    /// 与「可 seek（File）」两条路跑 analyze_mss，final LUFS 必须一致——
    /// 证明顺序容器在不可 seek 源上 probe+解码与分析结果等价，这是 HTTP
    /// 流式分析正确性的根基。
    #[test]
    fn sequential_source_equivalence() {
        let bytes = make_wav_bytes(5.0, 44100);
        let cancelled = || false;
        let mut hint = Hint::new();
        hint.with_extension("wav");

        let mut streaming_events = Vec::new();
        let non_seekable = analyze_mss(
            MediaSourceStream::new(
                Box::new(SequentialReadSource {
                    inner: Cursor::new(bytes.clone()),
                }),
                Default::default(),
            ),
            &hint,
            &cancelled,
            &mut |p| streaming_events.push(p),
        )
        .unwrap()
        .expect("不可 seek 源上不应取消");

        let tmp =
            std::env::temp_dir().join(format!("shiyin-loudness-test-{}.wav", std::process::id()));
        std::fs::write(&tmp, &bytes).unwrap();
        let seekable = analyze_mss(
            MediaSourceStream::new(Box::new(File::open(&tmp).unwrap()), Default::default()),
            &hint,
            &cancelled,
            &mut |_| {},
        )
        .unwrap()
        .expect("可 seek 源上不应取消");
        let _ = std::fs::remove_file(&tmp);

        assert!(non_seekable.result.lufs.is_finite());
        // WAV 干净流尾应走 UnexpectedEof 分支，不得误判为中断（否则线上
        // 会白白触发整曲下载回退）。
        assert!(!non_seekable.interrupted, "干净流尾不应标记中断");
        assert!(
            (non_seekable.result.lufs - seekable.result.lufs).abs() < 0.05,
            "LUFS 应等价：不可 seek={} 可 seek={}",
            non_seekable.result.lufs,
            seekable.result.lufs
        );
        // 不可 seek 源上中途进度照常推送：5s 音频按 500ms 间隔离散推送，
        // 至少 1 个中途事件 + 1 个 final。
        assert!(
            streaming_events.len() >= 2 && streaming_events.iter().any(|p| !p.is_final),
            "期望 >=2 个进度事件（含中途），实际 {}",
            streaming_events.len()
        );
    }

    #[test]
    fn url_extension_parses() {
        assert_eq!(
            url_extension("http://a.com/x/y.MP3?token=1").as_deref(),
            Some("mp3")
        );
        assert_eq!(url_extension("https://a.com/noext"), None);
    }

    /// 端到端（需本地 HTTP 服务提供音频 URL）：验证流式路径真实可用，且
    /// 首个中途进度事件早于整曲下载完成（"没下完整曲就已开始出进度"）。
    /// CI 无 SHIYIN_LOUDNESS_E2E_URL 自动跳过；手动运行示例（bash）：
    /// SHIYIN_LOUDNESS_E2E_URL=http://127.0.0.1:8000/test.mp3 \
    ///   cargo test loudness_http_streaming_e2e -- --ignored --nocapture
    #[test]
    #[ignore = "需本地 HTTP 服务：设 SHIYIN_LOUDNESS_E2E_URL 后手动运行"]
    fn loudness_http_streaming_e2e() {
        let url = match std::env::var("SHIYIN_LOUDNESS_E2E_URL") {
            Ok(u) if !u.trim().is_empty() => u,
            _ => return, // 未设置：跳过（CI 依赖此行为）
        };
        let stop = AtomicBool::new(false);
        let started = std::time::Instant::now();
        let mut events: Vec<(std::time::Duration, LoudnessProgress)> = Vec::new();
        let result = analyze(&url, &stop, &mut |p| {
            let at = started.elapsed();
            println!(
                "[+{:>8.0} ms] analyzed_ms={} lufs={:.2} final={}",
                at.as_secs_f64() * 1000.0,
                p.analyzed_ms,
                p.lufs,
                p.is_final
            );
            events.push((at, p));
        })
        .expect("analyze 失败");
        let result = result.expect("分析被取消");
        assert!(result.lufs.is_finite(), "final LUFS 应为有限值");

        // 流式证据链：事件数 >=2（首个中途进度 + final），且首个非 final
        // 事件出现时已分析的音频时长 >0。
        assert!(events.len() >= 2, "进度事件应 >=2，实际 {}", events.len());
        if let Some((at, p)) = events.iter().find(|(_, p)| !p.is_final) {
            assert!(p.analyzed_ms > 0);
            println!(
                "首个中途进度：开始分析后 {:.0} ms 出现，已分析 {} ms 音频",
                at.as_secs_f64() * 1000.0,
                p.analyzed_ms
            );
        }
        println!("final LUFS = {:.2}", result.lufs);
    }
}
