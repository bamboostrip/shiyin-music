use crate::engine::KugouEngine;
use crate::frb_generated::StreamSink;
use flutter_rust_bridge::frb;

use crate::services::local_media::{self, LocalSongEntry};
use crate::services::loudness;

#[frb(opaque)]
pub struct Engine(KugouEngine);

pub async fn create_engine(data_dir: String) -> Engine {
    Engine(KugouEngine::new(data_dir).await)
}

pub async fn engine_request(
    engine: &mut Engine,
    method: String,
    path: String,
    query: String,
    body: Option<String>,
) -> Result<String, String> {
    engine
        .0
        .request(&method, &path, &query, body.as_deref())
        .await
        .map_err(|e| e.to_string())
}

pub fn engine_set_session(engine: &mut Engine, userid: String, token: String, t1: String) {
    engine.0.set_session_fields(&userid, &token, &t1);
}

// ---- 桌面响度均衡 / 本地音乐（Windows/Linux，见 services/loudness.rs、
// services/local_media.rs 的模块文档） ----
//
// frb 的 StreamSink 模式会丢弃 Rust 函数返回值（Dart 侧只拿到 Stream），
// 因此结果/失败一律作为流事件下发，函数本身恒返回 Ok。
// 事件用"带可空字段的结构体"而非带数据的 enum：后者要求 Dart 侧
// freezed + build_runner 工具链，不值得为此引入。

/// 响度分析流事件。
pub struct LoudnessEvent {
    /// 截至当前/最终的 integrated LUFS。
    pub lufs: f64,
    /// 已解码音频时长（毫秒）。
    pub analyzed_ms: i64,
    /// true = 全曲分析完成（Dart 侧据此写缓存 + 最后微调）。
    pub is_final: bool,
    /// Some(reason) = 分析失败（解码/网络等），此时 lufs 无效。
    pub failure: Option<String>,
}

/// 渐进式分析一首歌的响度（LUFS）。取消（cancel_loudness_analysis 或
/// Dart 侧取消订阅）时流直接关闭且没有 is_final 事件，对齐 Android
/// 通道"取消返回 null"的语义。
pub fn analyze_loudness(url: String, events: StreamSink<LoudnessEvent>) -> Result<(), String> {
    let mut send_progress = |p: loudness::LoudnessProgress| {
        let event = LoudnessEvent {
            lufs: p.lufs,
            analyzed_ms: p.analyzed_ms,
            is_final: p.is_final,
            failure: None,
        };
        // Dart 侧取消订阅后 add 报错，置取消标志让解码循环退出。
        if events.add(event).is_err() {
            loudness::cancel_loudness_analysis();
        }
    };
    match loudness::analyze(&url, &mut send_progress) {
        Ok(_) => Ok(()), // 取消（None）时不发事件，直接关流
        Err(e) => {
            let _ = events.add(LoudnessEvent {
                lufs: f64::NAN,
                analyzed_ms: 0,
                is_final: true,
                failure: Some(e.to_string()),
            });
            Ok(())
        }
    }
}

/// 取消在途的响度分析（切歌时 Dart 侧调用）。
pub fn cancel_loudness_analysis() {
    loudness::cancel_loudness_analysis();
}

/// 读取本地音频的内嵌歌词标签（桌面端对应 Android 的 getEmbeddedLyrics）。
pub fn read_local_lyrics(path: String) -> Result<Option<String>, String> {
    loudness::read_embedded_lyrics(&path).map_err(|e| e.to_string())
}

/// 本地音乐扫描流事件。
pub struct ScanEvent {
    pub done: u32,
    pub total: u32,
    /// Some = 扫描完成（含结果）。取消时流关闭且本字段恒为 None。
    pub entries: Option<Vec<LocalSongEntry>>,
    /// Some(reason) = 扫描失败。
    pub failure: Option<String>,
}

/// 扫描用户添加的本地音乐根目录，结果经流事件下发；
/// cancel_local_scan 或取消订阅可中止。
pub fn scan_local_media(roots: Vec<String>, events: StreamSink<ScanEvent>) -> Result<(), String> {
    let mut send_progress = |done: usize, total: usize| {
        let event = ScanEvent {
            done: u32::try_from(done).unwrap_or(u32::MAX),
            total: u32::try_from(total).unwrap_or(u32::MAX),
            entries: None,
            failure: None,
        };
        if events.add(event).is_err() {
            local_media::cancel_scan();
        }
    };
    match local_media::scan(&roots, &mut send_progress) {
        Ok(entries) => {
            let _ = events.add(ScanEvent {
                done: u32::MAX,
                total: u32::MAX,
                entries: Some(entries),
                failure: None,
            });
            Ok(())
        }
        Err(e) => {
            let _ = events.add(ScanEvent {
                done: 0,
                total: 0,
                entries: None,
                failure: Some(e.to_string()),
            });
            Ok(())
        }
    }
}

/// 取消在途的本地音乐扫描。
pub fn cancel_local_scan() {
    local_media::cancel_scan();
}
