# 听歌识曲(移动端 + PC)实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 shiyin-music 的 Windows/Linux 桌面端与 Android 端实现"听歌识曲":采集音频 → 上传酷狗指纹服务 → 候选歌曲列表 → 点击播放。

**Architecture:** 协议层全部在 Rust(`services/identify.rs`):上传裸 PCM(8000Hz/16bit/单声道)到 `gateway.kugou.com/fingerprint.service/v1/music_trackid_mulit`,签名用现有 `calc_post_signature_binary`(Lite 身份),指纹匹配在服务端完成,客户端不需要 FFT。PCM 来源按平台分流:桌面端 Rust 内 `cpal` 采集(麦克风 + WASAPI loopback 系统内录)+ `rubato` 重采样;Android 端原生 `AudioRecord` MethodChannel(8000Hz 原生采集,无需重采样)。Dart 侧 `IdentifyService` 做平台分流与候选→`Song` 映射,UI 为独立 `IdentifyPage`(监听动画→结果列表→点击播放),入口在移动端搜索页 AppBar 与桌面搜索浮层。

**Tech Stack:** Rust: flutter_rust_bridge 2.12(已有)、reqwest(已有)、新增 cpal 0.18 + rubato 0.16(仅桌面 target)。Android: AudioRecord + MethodChannel(模式对齐现有 `shiyin_music/audio_effects`)。Dart: 现有 Song/PlayerController/Material 3 主题。

## Global Constraints

- 所有构建/测试命令通过 **pwsh7** 执行:`pwsh -NoProfile -Command "<命令>"`(子代理的 Bash 工具里包一层即可)。
- 每个任务结束跑完该任务验证命令后 **commit 一次**,提交信息用仓库现有 conventional-commit 中文风格,scope 用 `identify`,如 `feat(identify): ...`。
- 协议常量(端点、参数名、UA)**必须逐字**使用本计划中的值;`useid` 是官方拼写(不是 userid),不得"修正"。
- 不新增 Dart 依赖(pub.dev 包一律不加);Rust 仅新增 `cpal`、`rubato`,且只放在 `[target.'cfg(any(target_os = "windows", target_os = "linux", target_os = "macos"))'.dependencies]` 表下。
- 不修改 `windows/CMakeLists.txt`、`android/app/build.gradle.kts`(构建链自动编译新增 Rust 依赖)。
- `lib/src/rust/` 下全部文件是 frb 生成物,**只准**用 `flutter_rust_bridge_codegen generate` 重新生成,禁止手改。
- Dart 文案硬编码中文(项目无 l10n);UI 图标用 `Icons.*_rounded` 系列;主题取 `Theme.of(context).colorScheme`。
- Rust 注释风格对齐仓库:解释"为什么"与协议来源,密度与 `services/loudness.rs` 相当。
- 测试不得依赖 Rust DLL(`RustLib.init`),纯函数/映射/通道 mock 均可测;现有测试约定:`SharedPreferences.setMockInitialValues({})`、`TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler`、Fake 控制器 `noSuchMethod` 兜底。
- 工作分支:`feature/music-identify`(从当前 `feature/pc-desktop-adaptation` 切出,任务 1 第一步创建)。

---

### Task 1: Rust 识曲协议服务(全平台通用)

**Files:**
- Create: `rust/src/services/identify.rs`
- Modify: `rust/src/services/mod.rs`(加 `pub mod identify;`)
- Modify: `rust/src/engine.rs`(`KugouEngine` 加 `identify` 方法)
- Modify: `rust/src/api.rs`(暴露 `IdentifyCandidate` + `identify_music`)
- Generate: `lib/src/rust/*`(codegen)

**Interfaces:**
- Consumes: `crate::kugou::transport::send(client, session, &req)`(现有)、`KgRequest` 链式构造(现有)、`KugouEngine { client, session }` 字段(现有,私有,方法加在 engine.rs 内所以可用)。
- Produces(后续任务依赖的精确签名):
  - Rust: `pub struct IdentifyCandidate { name, singer, hash, album_audio_id, album_id, album_name, cover, hash_320, hash_flac: String, duration_ms: i64, dist: f64 }`(字段顺序即此)
  - Rust: `pub async fn identify_music(engine: &mut Engine, pcm: Vec<u8>) -> Result<Vec<IdentifyCandidate>, String>`
  - Dart(frb 生成): `Future<List<IdentifyCandidate>> identifyMusic({required Engine engine, required Uint8List pcm})`,类 `IdentifyCandidate{String name; String singer; String hash; String albumAudioId; String albumId; String albumName; String cover; String hash320; String hashFlac; int durationMs; double dist;}`

- [ ] **Step 1: 创建工作分支**

```bash
git checkout -b feature/music-identify
```

- [ ] **Step 2: 写失败的单测(请求构造 + 候选解析)**

创建 `rust/src/services/identify.rs`,先只写模块文档 + 测试模块(实现函数留到 Step 4;测试引用的函数 Step 3 声明):

```rust
//! 听歌识曲 —— 上传 8000Hz/16bit/单声道 PCM 到酷狗指纹服务,返回候选歌曲。
//!
//! 协议对照 MakcRe/KuGouMusicApi `module/audio_match.js`(经 EchoMusic
//! 桌面端生产验证),签名/参数注入与本项目 kugou 传输层 1:1 同源:
//! - `POST /fingerprint.service/v1/music_trackid_mulit`(默认网关)
//! - body 为**裸 PCM**(`application/octet-stream`),指纹匹配在服务端做,
//!   客户端无需 FFT;
//! - 签名走 Lite 身份的 md5(salt + 排序k=v + 二进制body + salt),即
//!   `signer::calc_post_signature_binary`(transport 对 binary_body 自动选择);
//! - 候选 `data[]` 含 hash/songname/singername/album/dist 等,dist 越小越匹配,
//!   置信度 = 1 - dist。
//!
//! 若上游升级导致签名被拒(实测特征:HTTP 200 但 status=0 且 errcode 提示
//! 验证失败),备选方案是把 [`build_identify_request`] 的签名策略改为
//! `SignatureType::OfficialAndroid`(appid=1005,见 request.rs 注释)。

use std::time::{SystemTime, UNIX_EPOCH};

use reqwest::Method;
use serde_json::Value;

use crate::error::AppResult;
use crate::kugou::request::KgRequest;
use crate::kugou::session::KgSession;
use crate::kugou::transport;

/// 识曲接口专用 UA(audio_match 模块显式覆盖默认 UA,照抄不得改动)。
const IDENTIFY_UA: &str = "KuGou/11490 (Android)";

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const PCM: &[u8] = b"\x01\x02\x03\x04";

    #[test]
    fn request_carries_identify_params_and_binary_body() {
        let req = build_identify_request(PCM.to_vec(), "12345");
        assert_eq!(req.path, "/fingerprint.service/v1/music_trackid_mulit");
        assert_eq!(req.method, Method::POST);
        // 官方拼写就是 useid(非 userid),照抄
        assert_eq!(req.params.get("useid").map(String::as_str), Some("12345"));
        assert_eq!(req.params.get("area_code").map(String::as_str), Some("1"));
        assert_eq!(
            req.params.get("include_unpublish").map(String::as_str),
            Some("1")
        );
        assert_eq!(
            req.params.get("multi_result").map(String::as_str),
            Some("1")
        );
        assert!(req.params.contains_key("fpid"));
        // 裸 PCM body + octet-stream
        assert_eq!(req.binary_body.as_deref(), Some(PCM));
        assert_eq!(req.content_type, "application/octet-stream");
        let ua = req
            .custom_headers
            .as_ref()
            .and_then(|h| h.get("User-Agent"))
            .cloned()
            .unwrap_or_default();
        assert_eq!(ua, "KuGou/11490 (Android)");
    }

    #[test]
    fn empty_userid_becomes_zero() {
        let req = build_identify_request(PCM.to_vec(), "");
        assert_eq!(req.params.get("useid").map(String::as_str), Some("0"));
    }

    #[test]
    fn parse_candidates_maps_fields_and_sorts_by_dist() {
        let resp = json!({
            "status": 1,
            "data": [
                {"hash": "aaa", "songname": "歌B", "singername": "歌手B",
                 "album_audio_id": 222, "album_id": "alb2", "albumname": "专辑B",
                 "sizable_cover": "http://c/b.jpg", "timelength": 210000,
                 "dist": "0.20", "hash_320": "aaa320", "hash_flac": "aaaf"},
                {"hash": "bbb", "songname": "歌A", "singername": "歌手A",
                 "mixsongid": 111, "dist": 0.1, "timelength": 180000},
                // 无 hash 的条目丢弃
                {"songname": "坏数据"},
            ]
        });
        let got = parse_candidates(&resp);
        assert_eq!(got.len(), 2);
        // dist 小的排前
        assert_eq!(got[0].hash, "bbb");
        assert_eq!(got[0].name, "歌A");
        assert_eq!(got[0].album_audio_id, "111");
        assert!((got[0].dist - 0.1).abs() < 1e-9);
        assert_eq!(got[1].hash, "aaa");
        assert_eq!(got[1].hash_flac, "aaaf");
        assert_eq!(got[1].duration_ms, 210000);
        // dist 是字符串也能解析
        assert!((got[1].dist - 0.2).abs() < 1e-9);
        assert_eq!(got[1].cover, "http://c/b.jpg");
    }

    #[test]
    fn parse_candidates_empty_or_missing_data() {
        assert!(parse_candidates(&json!({"status": 0})).is_empty());
        assert!(parse_candidates(&json!({"status": 1, "data": []})).is_empty());
    }
}
```

- [ ] **Step 3: 跑测试确认编译失败**

```bash
pwsh -NoProfile -Command "cargo test --manifest-path rust/Cargo.toml --lib identify"
```

预期:编译错误 `build_identify_request` / `parse_candidates` 未定义。

- [ ] **Step 4: 最小实现(请求构造 + 解析)**

在 `rust/src/services/identify.rs` 测试模块之前补上:

```rust
/// 单条识曲候选(字段名与酷狗指纹接口对齐,经别名兜底后为非空缺省)。
pub struct IdentifyCandidate {
    pub name: String,
    pub singer: String,
    /// 可播放主 hash(128k)
    pub hash: String,
    pub album_audio_id: String,
    pub album_id: String,
    pub album_name: String,
    pub cover: String,
    pub duration_ms: i64,
    /// 匹配距离(0~1,越小越准)
    pub dist: f64,
    pub hash_320: String,
    pub hash_flac: String,
}

/// 构造识曲请求(纯函数便于单测)。签名与默认参数注入由 transport 层完成,
/// 此处只带业务参数与专用 UA。
pub fn build_identify_request(pcm: Vec<u8>, userid: &str) -> KgRequest {
    let fpid = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    let mut req = KgRequest::get("/fingerprint.service/v1/music_trackid_mulit")
        .method(Method::POST)
        .param("fpid", fpid.to_string())
        .param("area_code", "1")
        .param("include_unpublish", "1")
        // 官方客户端即此拼写(非 userid);未登录传 0
        .param("useid", if userid.is_empty() { "0" } else { userid })
        .param("multi_result", "1")
        .custom_header("User-Agent", IDENTIFY_UA);
    req.binary_body = Some(pcm);
    req.content_type = "application/octet-stream".into();
    req
}

/// 上传 PCM 并透传上游响应(status!=1 时 transport 已原样返回根 JSON,
/// 由 [`parse_candidates`] 兜底为空列表)。
pub async fn identify_music(
    client: &reqwest::Client,
    session: &KgSession,
    pcm: Vec<u8>,
) -> AppResult<Value> {
    let req = build_identify_request(pcm, &session.userid);
    transport::send(client, session, &req).await
}

/// 从上游响应提取候选列表并按 dist 升序(dist 小 = 匹配好)。
pub fn parse_candidates(v: &Value) -> Vec<IdentifyCandidate> {
    let Some(list) = v.get("data").and_then(|d| d.as_array()) else {
        return Vec::new();
    };
    let mut out: Vec<IdentifyCandidate> = list
        .iter()
        .filter_map(|item| {
            // 字符串/数字双兜底取值(酷狗字段类型在不同端点间不稳定)
            fn get(item: &Value, keys: &[&str]) -> String {
                for k in keys {
                    let Some(field) = item.get(*k) else { continue };
                    if let Some(s) = field.as_str() {
                        if !s.is_empty() {
                            return s.to_string();
                        }
                    }
                    if let Some(n) = field.as_i64() {
                        return n.to_string();
                    }
                }
                String::new()
            }
            let hash = get(item, &["hash", "hash_128", "FileHash"]);
            if hash.is_empty() {
                return None;
            }
            let dist = item.get("dist").and_then(|d| {
                d.as_f64()
                    .or_else(|| d.as_str().and_then(|s| s.parse().ok()))
            });
            Some(IdentifyCandidate {
                name: get(item, &["songname", "song_name", "filename", "name"]),
                singer: get(item, &["singername", "singer_name", "author_name"]),
                hash,
                album_audio_id: get(item, &["album_audio_id", "mixsongid", "audio_id"]),
                album_id: get(item, &["album_id", "albumid"]),
                album_name: get(item, &["albumname", "album_name"]),
                cover: get(item, &["union_cover", "sizable_cover", "cover", "img"]),
                duration_ms: item
                    .get("timelength")
                    .and_then(|x| x.as_i64())
                    .unwrap_or(0),
                dist: dist.unwrap_or(1.0).clamp(0.0, 1.0),
                hash_320: get(item, &["hash_320"]),
                hash_flac: get(item, &["hash_flac"]),
            })
        })
        .collect();
    out.sort_by(|a, b| a.dist.partial_cmp(&b.dist).unwrap_or(std::cmp::Ordering::Equal));
    out
}
```

修改 `rust/src/services/mod.rs`,在 `pub mod fm;` 与 `pub mod local_media;` 之间(保持字母序)加入:

```rust
pub mod identify;
```

- [ ] **Step 5: 跑测试确认通过**

```bash
pwsh -NoProfile -Command "cargo test --manifest-path rust/Cargo.toml --lib identify"
```

预期:`request_carries_identify_params_and_binary_body`、`empty_userid_becomes_zero`、`parse_candidates_*` 全部 PASS。

- [ ] **Step 6: 接入 Engine 与 api.rs**

`rust/src/engine.rs`:在 `impl KugouEngine` 的 `set_session_fields` 之后新增方法,并在文件头 `use crate::services::{...}` 列表里加 `identify`:

```rust
    /// 听歌识曲:上传 PCM,返回候选歌曲(JSON 透传,候选解析在 Dart 侧之外
    /// 统一走 identify::parse_candidates,见 api::identify_music)。
    pub async fn identify(&self, pcm: Vec<u8>) -> AppResult<Value> {
        identify::identify_music(&self.client, &self.session, pcm).await
    }
```

`rust/src/api.rs`:文件头 use 区加 `use crate::services::identify::{self, IdentifyCandidate};`,文件末尾(`cancel_local_scan` 之后)追加:

```rust
// ---- 听歌识曲 ----
//
// PCM 由平台采集层提供(桌面 = 本文件 identify_capture_snapshot,
// Android = 原生 AudioRecord 通道),识别统一走这里。

/// 听歌识曲:上传 8000Hz/16bit/单声道 PCM,按匹配度降序返回候选。
pub async fn identify_music(
    engine: &mut Engine,
    pcm: Vec<u8>,
) -> Result<Vec<IdentifyCandidate>, String> {
    let v = engine.0.identify(pcm).await.map_err(|e| e.to_string())?;
    Ok(identify::parse_candidates(&v))
}
```

- [ ] **Step 7: frb 代码生成 + 全量 Rust 测试**

```bash
pwsh -NoProfile -Command "cd D:\AllCode\flutter\shiyin-music; flutter_rust_bridge_codegen generate"
pwsh -NoProfile -Command "cargo test --manifest-path rust/Cargo.toml"
pwsh -NoProfile -Command "cd D:\AllCode\flutter\shiyin-music; flutter analyze lib\src\rust"
```

预期:codegen 无报错;`lib/src/rust/api.dart` 出现 `IdentifyCandidate` 类与 `identifyMusic`(签名:`Future<List<IdentifyCandidate>> identifyMusic({required Engine engine, required Uint8List pcm})`,字段 camelCase:`albumAudioId`/`durationMs`/`hash320`/`hashFlac`);cargo test 全绿;analyze 无新告警。

- [ ] **Step 8: Commit**

```bash
git add rust/src/services/identify.rs rust/src/services/mod.rs rust/src/engine.rs rust/src/api.rs lib/src/rust
git commit -m "feat(identify): Rust 识曲协议服务——fingerprint.service 请求构造、二进制签名上传与候选解析"
```

---

### Task 2: Rust 桌面音频采集(cpal + rubato)

**Files:**
- Modify: `rust/Cargo.toml`(新增桌面 target 依赖表)
- Create: `rust/src/services/audio_capture.rs`
- Modify: `rust/src/services/mod.rs`(加 `pub mod audio_capture;`)
- Modify: `rust/src/api.rs`(暴露 3 个采集函数)
- Generate: `lib/src/rust/*`(codegen)

**Interfaces:**
- Consumes: Task 1 的 `IdentifyCandidate`(无需直接用)。
- Produces:
  - Rust(api.rs,全平台可调用;非桌面平台为返回错误的桩): `identify_start_capture(source: String) -> Result<(), String>`(source: `"mic"` | `"system"`)、`identify_capture_snapshot(duration_ms: u32) -> Result<Vec<u8>, String>`、`identify_cancel_capture()`
  - Dart(frb 生成): `Future<void> identifyStartCapture({required String source})`、`Future<Uint8List> identifyCaptureSnapshot({required int durationMs})`(Err 抛异常)、`Future<void> identifyCancelCapture()`

- [ ] **Step 1: 加依赖(Cargo.toml)**

在 `rust/Cargo.toml` 的 `[dependencies]` 段之后、`[lints.rust]` 之前加:

```toml
# 桌面端听歌识曲音频采集:cpal 抓麦克风 / WASAPI loopback(系统内录,
# cpal 0.17+ 对默认输出设备开 input stream 即回环),rubato 重采样到
# 识曲要求的 8000Hz。仅桌面 target,Android 构建不编译这些依赖。
[target.'cfg(any(target_os = "windows", target_os = "linux", target_os = "macos"))'.dependencies]
cpal = "0.18"
rubato = "0.16"
```

- [ ] **Step 2: 写失败的单测(纯函数:下混/重采样/PCM 编码)**

创建 `rust/src/services/audio_capture.rs`:

```rust
//! 桌面端听歌识曲音频采集(Windows / Linux / macOS)。
//!
//! - mic:cpal 默认输入设备;
//! - system:Windows 对默认输出设备开 input stream(WASAPI loopback,
//!   cpal 0.17+ 支持);Linux 找 PulseAudio/PipeWire 的 monitor 源;
//!   其余平台返回错误;
//! - 采集回调里下混为单声道 f32 进环形缓冲(约 20s),快照时取末尾
//!   N 秒重采样到 8000Hz 转 s16le——酷狗识曲的 PCM 格式。
//!
//! 线程模型:cpal 回调跑在音频线程,只做"下混 + 环形缓冲追加";
//! 快照/停止在调用线程,锁粒度小,与响度分析的 AtomicBool 取消模式
//! 同级简单。cpal `Stream` drop 即停,无需显式 close。

/// 非桌面平台没有采集后端,提供一致的错误桩,保持 api.rs 签名统一。
#[cfg(not(any(target_os = "windows", target_os = "linux", target_os = "macos")))]
pub mod stub {
    pub fn start(_source: &str) -> Result<(), String> {
        Err("当前平台不支持音频采集".into())
    }
    pub fn snapshot_pcm(_duration_ms: u32) -> Result<Vec<u8>, String> {
        Err("当前平台不支持音频采集".into())
    }
    pub fn stop() {}
}

#[cfg(any(target_os = "windows", target_os = "linux", target_os = "macos"))]
pub mod desktop {
    use std::sync::{Arc, Mutex};

    /// 环形缓冲上限(秒)。识曲快照最多取 10s,留一倍余量防抖。
    const RING_SECS: usize = 20;
    /// 识曲 PCM 目标采样率(酷狗指纹服务固定 8000Hz/16bit/单声道)。
    pub const TARGET_RATE: u32 = 8000;

    struct Ring {
        /// 单声道 f32,设备采样率
        samples: Vec<f32>,
        /// 有效起点(samples 尾裁后整体前移,惰性 drain)
        start: usize,
        sample_rate: u32,
        channels: u16,
    }

    impl Ring {
        fn push_interleaved(&mut self, data: &[f32]) {
            let ch = self.channels.max(1) as usize;
            for frame in data.chunks_exact(ch) {
                let sum: f32 = frame.iter().sum();
                self.samples.push(sum / ch as f32);
            }
            let cap = RING_SECS * self.sample_rate as usize;
            let len = self.samples.len() - self.start;
            if len > cap {
                self.start = self.samples.len() - cap;
                // 起点过半时整体前移,防 Vec 无界增长
                if self.start > cap / 2 {
                    self.samples.drain(..self.start);
                    self.start = 0;
                }
            }
        }

        fn tail(&self, duration_ms: u32) -> Vec<f32> {
            let n = ((self.sample_rate as u64 * duration_ms as u64) / 1000) as usize;
            let avail = self.samples.len() - self.start;
            let take = n.min(avail);
            self.samples[self.samples.len() - take..].to_vec()
        }
    }

    struct CaptureState {
        ring: Arc<Mutex<Ring>>,
        /// 保活即采集,drop 即停止
        _stream: cpal::Stream,
    }

    static CAPTURE: Mutex<Option<CaptureState>> = Mutex::new(None);

    fn ring_from_config(sample_rate: u32, channels: u16) -> Arc<Mutex<Ring>> {
        Arc::new(Mutex::new(Ring {
            samples: Vec::new(),
            start: 0,
            sample_rate,
            channels,
        }))
    }

    fn push_mono(ring: &Arc<Mutex<Ring>>, data: &[f32]) {
        if let Ok(mut r) = ring.lock() {
            r.push_interleaved(data);
        }
    }

    /// 选设备:mic = 默认输入;system = 回环源(Win: 默认输出设备 loopback;
    /// Linux: monitor 名匹配)。
    fn select_device(
        host: &cpal::Host,
        source: &str,
    ) -> Result<(cpal::Device, cpal::SupportedStreamConfig, &'static str), String> {
        match source {
            "system" => {
                #[cfg(target_os = "windows")]
                {
                    let device = host
                        .default_output_device()
                        .ok_or("未找到默认输出设备,无法系统内录")?;
                    let config = device
                        .default_output_config()
                        .map_err(|e| format!("读取输出混音格式失败: {e}"))?;
                    Ok((device, config, "system"))
                }
                #[cfg(target_os = "linux")]
                {
                    for device in host
                        .input_devices()
                        .map_err(|e| format!("枚举输入设备失败: {e}"))?
                    {
                        let name = device.name().unwrap_or_default().to_ascii_lowercase();
                        if name.contains("monitor")
                            || name.contains("loopback")
                            || name.contains("stereo mix")
                        {
                            let config = device
                                .default_input_config()
                                .map_err(|e| format!("读取回环设备配置失败: {e}"))?;
                            return Ok((device, config, "system"));
                        }
                    }
                    Err("未找到系统回环采集源(monitor/loopback),请改用麦克风".into())
                }
                #[cfg(not(any(target_os = "windows", target_os = "linux")))]
                {
                    let _ = host;
                    Err("该平台暂不支持系统内录".into())
                }
            }
            _ => {
                let device = host.default_input_device().ok_or("未找到麦克风设备")?;
                let config = device
                    .default_input_config()
                    .map_err(|e| format!("读取麦克风配置失败: {e}"))?;
                Ok((device, config, "mic"))
            }
        }
    }

    /// 开始采集(已在采集中则幂等返回 Ok)。
    pub fn start(source: &str) -> Result<(), String> {
        let mut guard = CAPTURE.lock().map_err(|_| "采集状态锁不可用")?;
        if guard.is_some() {
            return Ok(());
        }
        let host = cpal::default_host();
        let (device, config, _) = select_device(&host, source)?;
        let ring = ring_from_config(config.sample_rate().0, config.channels());

        let err_fn = |e| tracing::warn!(error = %e, "识曲采集流错误");
        let cfg: cpal::StreamConfig = config.clone().into();
        let stream = match config.sample_format() {
            cpal::SampleFormat::F32 => device.build_input_stream(
                &cfg,
                {
                    let ring = ring.clone();
                    move |data: &[f32], _| push_mono(&ring, data)
                },
                err_fn,
                None,
            ),
            cpal::SampleFormat::I16 => device.build_input_stream(
                &cfg,
                {
                    let ring = ring.clone();
                    move |data: &[i16], _| {
                        let f: Vec<f32> = data.iter().map(|&s| s as f32 / 32768.0).collect();
                        push_mono(&ring, &f);
                    }
                },
                err_fn,
                None,
            ),
            cpal::SampleFormat::U16 => device.build_input_stream(
                &cfg,
                {
                    let ring = ring.clone();
                    move |data: &[u16], _| {
                        let f: Vec<f32> = data
                            .iter()
                            .map(|&s| (s as f32 - 32768.0) / 32768.0)
                            .collect();
                        push_mono(&ring, &f);
                    }
                },
                err_fn,
                None,
            ),
            fmt => return Err(format!("不支持的采样格式 {fmt:?}")),
        }
        .map_err(|e| format!("打开采集流失败: {e}"))?;
        stream.play().map_err(|e| format!("启动采集流失败: {e}"))?;
        *guard = Some(CaptureState {
            ring,
            _stream: stream,
        });
        Ok(())
    }

    pub fn stop() {
        if let Ok(mut guard) = CAPTURE.lock() {
            *guard = None; // Stream drop = 停止
        }
    }

    pub fn is_capturing() -> bool {
        CAPTURE.lock().map(|g| g.is_some()).unwrap_or(false)
    }

    /// 取末尾 duration_ms 的采集音频,转成 8000Hz/16bit/单声道 PCM。
    pub fn snapshot_pcm(duration_ms: u32) -> Result<Vec<u8>, String> {
        let guard = CAPTURE.lock().map_err(|_| "采集状态锁不可用")?;
        let Some(state) = guard.as_ref() else {
            return Err("采集未启动".into());
        };
        let (samples, src_rate) = {
            let r = state.ring.lock().map_err(|_| "环形缓冲锁不可用")?;
            (r.tail(duration_ms), r.sample_rate)
        };
        Ok(mono_f32_to_pcm8k(&samples, src_rate))
    }

    /// 单声道 f32(源采样率)→ 8000Hz s16le PCM。
    fn mono_f32_to_pcm8k(samples: &[f32], src_rate: u32) -> Vec<u8> {
        let resampled = if src_rate == TARGET_RATE || samples.is_empty() {
            samples.to_vec()
        } else {
            resample_fft(samples, src_rate, TARGET_RATE)
        };
        let mut out = Vec::with_capacity(resampled.len() * 2);
        for s in resampled {
            let v = (s.clamp(-1.0, 1.0) * 32767.0).round() as i16;
            out.extend_from_slice(&v.to_le_bytes());
        }
        out
    }

    /// FFT 有理比重采样(rubato),构造/处理异常时回退线性插值——
    /// 识曲指纹对高频混叠不敏感,可用性优先。
    fn resample_fft(samples: &[f32], src_rate: u32, dst_rate: u32) -> Vec<f32> {
        use rubato::{FftFixedIn, Resampler};
        let expected =
            (samples.len() as u64 * dst_rate as u64 / src_rate as u64).max(1) as usize;
        let chunk = 8192usize;
        let Ok(mut resampler) = FftFixedIn::<f32>::new(
            src_rate as usize,
            dst_rate as usize,
            chunk,
            4,
            1,
        ) else {
            return resample_linear(samples, src_rate, dst_rate);
        };
        let mut out = Vec::with_capacity(expected);
        let mut pos = 0usize;
        while pos < samples.len() {
            let take = chunk.min(samples.len() - pos);
            let mut frame = vec![vec![0.0f32; chunk]];
            frame[0][..take].copy_from_slice(&samples[pos..pos + take]);
            match resampler.process(&frame) {
                Ok(mut buf) => out.append(&mut buf[0]),
                Err(_) => return resample_linear(samples, src_rate, dst_rate),
            }
            pos += take;
        }
        out.truncate(expected);
        out
    }

    fn resample_linear(samples: &[f32], src_rate: u32, dst_rate: u32) -> Vec<f32> {
        let expected =
            (samples.len() as u64 * dst_rate as u64 / src_rate as u64).max(1) as usize;
        let mut out = Vec::with_capacity(expected);
        let step = src_rate as f64 / dst_rate as f64;
        for i in 0..expected {
            let t = i as f64 * step;
            let i0 = (t as usize).min(samples.len() - 1);
            let i1 = (i0 + 1).min(samples.len() - 1);
            let frac = (t - i0 as f64) as f32;
            out.push(samples[i0] + (samples[i1] - samples[i0]) * frac);
        }
        out
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use std::f32::consts::TAU;

        /// 440Hz 正弦波(振幅 0.5)
        fn sine(freq: f32, rate: u32, ms: u32) -> Vec<f32> {
            let n = (rate as u64 * ms as u64 / 1000) as usize;
            (0..n)
                .map(|i| 0.5 * (TAU * freq * i as f32 / rate as f32).sin())
                .collect()
        }

        fn rms(v: &[f32]) -> f32 {
            (v.iter().map(|x| x * x).sum::<f32>() / v.len().max(1) as f32).sqrt()
        }

        #[test]
        fn pcm8k_silence_length_exact() {
            // 48000Hz 整除比:500ms → 恰好 4000 个 8k 样本 = 8000 字节
            let pcm = mono_f32_to_pcm8k(&vec![0.0; 24000], 48000);
            assert_eq!(pcm.len(), 8000);
            assert!(pcm.iter().all(|&b| b == 0));
        }

        #[test]
        fn pcm8k_tone_keeps_energy_and_ratio() {
            let src = sine(440.0, 48000, 1000);
            let pcm = mono_f32_to_pcm8k(&src, 48000);
            // 1s@8k → 16000 字节(±1% 容忍整除舍入)
            assert!(
                (pcm.len() as i64 - 16000).abs() < 160,
                "len={}",
                pcm.len()
            );
            // s16le 解回 f32,能量应大体保留
            let mut back = Vec::with_capacity(pcm.len() / 2);
            for pair in pcm.chunks_exact(2) {
                back.push(i16::from_le_bytes([pair[0], pair[1]]) as f32 / 32767.0);
            }
            let r = rms(&back);
            assert!(r > 0.25 && r < 0.6, "rms={r}");
        }

        #[test]
        fn pcm8k_odd_ratio_44100() {
            let src = sine(440.0, 44100, 500);
            let pcm = mono_f32_to_pcm8k(&src, 44100);
            let expect = 8000 * 500 / 1000 * 2;
            assert!((pcm.len() as i64 - expect).abs() < 20, "len={}", pcm.len());
        }

        #[test]
        fn ring_downmixes_stereo_and_trims() {
            let mut ring = Ring {
                samples: Vec::new(),
                start: 0,
                sample_rate: 48000,
                channels: 2,
            };
            ring.push_interleaved(&[0.2, 0.6, 0.2, 0.6]);
            // f32 求和不精确,用容差断言
            assert!(ring.samples.len() == 2);
            assert!((ring.samples[0] - 0.4).abs() < 1e-6);
            assert!((ring.samples[1] - 0.4).abs() < 1e-6);
            // 20s 上限裁剪
            ring.push_interleaved(&vec![0.5; 48000 * RING_SECS * 2]);
            assert!(ring.samples.len() <= 48000 * RING_SECS + 2);
        }

        #[test]
        fn ring_tail_takes_last_n_ms() {
            let mut ring = Ring {
                samples: (0..48000).map(|i| i as f32).collect(),
                start: 0,
                sample_rate: 48000,
                channels: 1,
            };
            let tail = ring.tail(500);
            assert_eq!(tail.len(), 24000);
            assert_eq!(tail[0], 24000.0);
        }
    }
}

#[cfg(test)]
mod tests {
    /// 移动端桩:接口存在且报错(保证 api.rs 全平台可编译)。
    #[cfg(not(any(target_os = "windows", target_os = "linux", target_os = "macos")))]
    #[test]
    fn stub_errors() {
        assert!(super::stub::start("mic").is_err());
        assert!(super::stub::snapshot_pcm(1000).is_err());
    }
}
```

修改 `rust/src/services/mod.rs` 在 `pub mod album;` 之前(字母序)加:

```rust
pub mod audio_capture;
```

- [ ] **Step 3: 跑测试确认通过(先本任务单测)**

```bash
pwsh -NoProfile -Command "cargo test --manifest-path rust/Cargo.toml --lib audio_capture"
```

预期:5 个 desktop 测试 PASS(Windows 主机上 cpal/rubato 已可编译;若 rubato 0.16 的 `FftFixedIn::new`/`process` 签名与此处调用不完全一致,以编译器提示为准做最小适配,例如 `process` 需要 `&mut frame` 或输出用 `process_into_buffer`,语义保持"整块进→顺序出→truncate 到期望长度"即可)。

- [ ] **Step 4: 接入 api.rs**

`rust/src/api.rs` 头部 use 区加:

```rust
use crate::services::audio_capture;
```

文件末尾追加:

```rust
/// 听歌识曲采集(桌面真实实现,其余平台为错误桩):source = "mic" | "system"。
/// 幂等,已在采集中时再次调用直接成功。
pub fn identify_start_capture(source: String) -> Result<(), String> {
    audio_capture::start_with(&source)
}

/// 取末尾 duration_ms 的采集音频,转 8000Hz/16bit/单声道 PCM(识曲格式)。
pub fn identify_capture_snapshot(duration_ms: u32) -> Result<Vec<u8>, String> {
    audio_capture::snapshot_with(duration_ms)
}

/// 停止并释放采集(取消识别 / 页面关闭时调用)。
pub fn identify_cancel_capture() {
    audio_capture::stop_with();
}
```

`audio_capture.rs` 根级补统一入口(把桌面/桩两条路收拢,api.rs 无需 cfg):

```rust
/// 平台分发:桌面走 desktop 模块,其余走 stub。
pub fn start_with(source: &str) -> Result<(), String> {
    #[cfg(any(target_os = "windows", target_os = "linux", target_os = "macos"))]
    {
        desktop::start(source)
    }
    #[cfg(not(any(target_os = "windows", target_os = "linux", target_os = "macos")))]
    {
        let _ = source;
        stub::start(source)
    }
}

pub fn snapshot_with(duration_ms: u32) -> Result<Vec<u8>, String> {
    #[cfg(any(target_os = "windows", target_os = "linux", target_os = "macos"))]
    {
        desktop::snapshot_pcm(duration_ms)
    }
    #[cfg(not(any(target_os = "windows", target_os = "linux", target_os = "macos")))]
    {
        let _ = duration_ms;
        stub::snapshot_pcm(duration_ms)
    }
}

pub fn stop_with() {
    #[cfg(any(target_os = "windows", target_os = "linux", target_os = "macos"))]
    {
        desktop::stop()
    }
    #[cfg(not(any(target_os = "windows", target_os = "linux", target_os = "macos")))]
    {
        stub::stop()
    }
}
```

- [ ] **Step 5: codegen + 全量验证**

```bash
pwsh -NoProfile -Command "cd D:\AllCode\flutter\shiyin-music; flutter_rust_bridge_codegen generate"
pwsh -NoProfile -Command "cargo test --manifest-path rust/Cargo.toml"
pwsh -NoProfile -Command "cargo build --manifest-path rust/Cargo.toml --release"
pwsh -NoProfile -Command "cd D:\AllCode\flutter\shiyin-music; flutter analyze lib\src\rust"
```

预期:cargo test 全绿;`cargo build --release` 产出 `rust/target/release/kugou_engine.dll`(cpal 链接 WASAPI 成功);`lib/src/rust/api.dart` 出现 `identifyStartCapture`/`identifyCaptureSnapshot`/`identifyCancelCapture`。

- [ ] **Step 6: Commit**

```bash
git add rust/Cargo.toml rust/Cargo.lock rust/src/services/audio_capture.rs rust/src/services/mod.rs rust/src/api.rs lib/src/rust
git commit -m "feat(identify): 桌面音频采集——cpal 麦克风/WASAPI loopback 环形缓冲,rubato 重采样 8k PCM 快照"
```

---

### Task 3: Android 麦克风采集通道

**Files:**
- Modify: `android/app/src/main/AndroidManifest.xml`(加 RECORD_AUDIO)
- Create: `android/app/src/main/kotlin/shiyin/famlife/top/AudioCaptureHandler.kt`
- Modify: `android/app/src/main/kotlin/shiyin/famlife/top/MainActivity.kt`(注册通道 + 权限回调)

**Interfaces:**
- Produces(MethodChannel `shiyin_music/audio_capture`,Task 4 依赖):
  - `requestPermission() -> bool`(触发系统权限弹窗,用户操作后返回是否授予)
  - `start() -> null`(开始 8000Hz/16bit/单声道后台采集,环形缓冲 15s)
  - `stop({int durationMs}) -> Uint8List`(取末尾 durationMs 毫秒 PCM 并释放)
  - `cancel() -> null`(丢弃缓冲并释放)

- [ ] **Step 1: AndroidManifest.xml 加权限**

在 `<manifest>` 权限区(现有 `INTERNET` 等权限旁)加:

```xml
    <!-- 听歌识曲麦克风采集(仅识曲页使用,运行时动态申请) -->
    <uses-permission android:name="android.permission.RECORD_AUDIO" />
```

- [ ] **Step 2: 实现 AudioCaptureHandler.kt**

创建 `android/app/src/main/kotlin/shiyin/famlife/top/AudioCaptureHandler.kt`:

```kotlin
package shiyin.famlife.top

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque
import kotlin.concurrent.thread

/**
 * 听歌识曲麦克风采集(通道 shiyin_music/audio_capture 的原生实现)。
 *
 * 与桌面端 Rust cpal 采集对齐的 PCM 契约:8000Hz / 16bit / 单声道。
 * 8000Hz 由 AudioRecord 原生重采样,无需rubato——这也是 Android 不走
 * Rust 采集的原因:权限弹窗与音频焦点在原生侧更自然,且省一次重采样。
 *
 * start 后台线程持续读 AudioRecord 进有界缓冲(最多 MAX_BUFFER_MS),
 * stop 取末尾 durationMs 毫秒字节返回并释放。取消语义对齐响度分析:
 * cancel 直接丢弃,不返回数据。
 */
internal object AudioCaptureHandler {
    private const val SAMPLE_RATE = 8000
    private const val MAX_BUFFER_MS = 15_000
    /** 16bit 单声道每毫秒字节数 */
    private const val BYTES_PER_MS = SAMPLE_RATE * 2 / 1000
    private const val PERMISSION_CODE = 4101

    @Volatile private var record: AudioRecord? = null
    @Volatile private var reading = false
    private val buffer = ArrayDeque<ByteArray>()
    private var bufferedBytes = 0
    private var pendingPermissionResult: MethodChannel.Result? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    fun handle(call: MethodCall, result: MethodChannel.Result, activity: MainActivity) {
        when (call.method) {
            "requestPermission" -> requestPermission(result, activity)
            "start" -> start(result, activity)
            "stop" -> {
                val durationMs = call.argument<Int>("durationMs") ?: 10_000
                result.success(stop(durationMs))
            }
            "cancel" -> {
                release()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        grantResults: IntArray,
    ) {
        if (requestCode != PERMISSION_CODE) return
        pendingPermissionResult?.let { result ->
            mainHandler.post {
                result.success(
                    grantResults.isNotEmpty() &&
                        grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED
                )
            }
        }
        pendingPermissionResult = null
    }

    private fun requestPermission(result: MethodChannel.Result, activity: MainActivity) {
        if (activity.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        pendingPermissionResult = result
        androidx.core.app.ActivityCompat.requestPermissions(
            activity,
            arrayOf(android.Manifest.permission.RECORD_AUDIO),
            PERMISSION_CODE,
        )
    }

    @SuppressLint("MissingPermission") // start 只在权限授予后被调用
    private fun start(result: MethodChannel.Result, activity: MainActivity) {
        if (activity.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            result.error("permission", "缺少麦克风权限,请先 requestPermission", null)
            return
        }
        release()
        val minBuf = AudioRecord.getMinBufferSize(
            SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
        )
        val rec = AudioRecord(
            MediaRecorder.AudioSource.MIC, SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
            maxOf(minBuf, 8192)
        )
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            result.error("init", "AudioRecord 初始化失败", null)
            return
        }
        synchronized(buffer) { buffer.clear(); bufferedBytes = 0 }
        record = rec
        reading = true
        rec.startRecording()
        thread(name = "identify-capture") {
            val chunk = ByteArray(BYTES_PER_MS * 200) // 200ms 一块
            while (reading) {
                val n = rec.read(chunk, 0, chunk.size)
                if (n <= 0) break
                synchronized(buffer) {
                    buffer.addLast(chunk.copyOf(n))
                    bufferedBytes += n
                    val cap = BYTES_PER_MS * MAX_BUFFER_MS
                    while (bufferedBytes > cap) {
                        bufferedBytes -= buffer.removeFirst().size
                    }
                }
            }
        }
        result.success(null)
    }

    /** 取末尾 durationMs 毫秒并停止释放。缓冲不足时返回已有部分。 */
    private fun stop(durationMs: Int): ByteArray? {
        val chunks = ArrayList<ByteArray>()
        synchronized(buffer) {
            var acc = 0
            val want = BYTES_PER_MS * durationMs.coerceAtLeast(0)
            for (c in buffer.reversed()) {
                chunks.add(c)
                acc += c.size
                if (acc >= want) break
            }
            chunks.reverse()
        }
        release()
        if (chunks.isEmpty()) return null
        val total = chunks.sumOf { it.size }
        val out = ByteArray(total)
        var off = 0
        for (c in chunks) {
            c.copyInto(out, off)
            off += c.size
        }
        return out
    }

    private fun release() {
        reading = false
        synchronized(buffer) { buffer.clear(); bufferedBytes = 0 }
        record?.let {
            try { it.stop() } catch (_: IllegalStateException) {}
            it.release()
        }
        record = null
    }
}
```

- [ ] **Step 3: MainActivity.kt 注册通道与权限回调**

先读 `MainActivity.kt` 的 `configureFlutterEngine`(L96-690)确认:
1. 现有通道注册代码块末尾位置;
2. 类里**是否已有** `onRequestPermissionsResult` override(全文搜索)。

在最后一个 `MethodChannel(...).setMethodCallHandler {...}` 注册块之后追加(缩进对齐同级):

```kotlin
        // 听歌识曲麦克风采集(PCM 8000Hz/16bit/单声道,见 AudioCaptureHandler)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "shiyin_music/audio_capture")
            .setMethodCallHandler { call, result ->
                AudioCaptureHandler.handle(call, result, this)
            }
```

若类中**无** `onRequestPermissionsResult`,在 `configureFlutterEngine` 方法之后加:

```kotlin
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        AudioCaptureHandler.onRequestPermissionsResult(requestCode, grantResults)
    }
```

若已有同名 override,则只在其中追加 `AudioCaptureHandler.onRequestPermissionsResult(requestCode, grantResults)` 一行(保留原有逻辑,勿动 super 调用位置)。

- [ ] **Step 4: 编译验证**

```bash
pwsh -NoProfile -Command "cd D:\AllCode\flutter\shiyin-music; flutter build apk --debug"
```

预期:BUILD SUCCESSFUL(Kotlin 编译过 + cargo-ndk Rust arm64 编译过)。若 Android 工具链未装齐导致失败且与本次改动无关,降级为 `pwsh -NoProfile -Command "cd D:\AllCode\flutter\shiyin-music\android; .\gradlew.bat :app:compileDebugKotlin"` 并在报告中注明。

- [ ] **Step 5: Commit**

```bash
git add android/app/src/main/AndroidManifest.xml android/app/src/main/kotlin/shiyin/famlife/top/AudioCaptureHandler.kt android/app/src/main/kotlin/shiyin/famlife/top/MainActivity.kt
git commit -m "feat(identify): Android 麦克风 PCM 采集通道(8000Hz/16bit/单声道)+ RECORD_AUDIO 运行时权限"
```

---

### Task 4: Dart 识曲服务(平台分流 + 候选映射)

**Files:**
- Modify: `lib/core/rust_api_client.dart`(加 identify 透传方法)
- Create: `lib/services/identify_service.dart`
- Create: `test/services/identify_service_test.dart`

**Interfaces:**
- Consumes:
  - Task 1 生成绑定: `rust.identifyMusic(engine:..., pcm:...)`、类 `rust.IdentifyCandidate`(字段 camelCase)
  - Task 2 生成绑定: `rust.identifyStartCapture/identifyCaptureSnapshot/identifyCancelCapture`
  - Task 3 通道: `shiyin_music/audio_capture` 的 requestPermission/start/stop/cancel
  - `Song` 构造函数: `Song({required String id, required String title, required String artist, required String hash, String? albumId, String? albumAudioId, String? albumName, String? coverUrl, Duration? duration, ...})`
- Produces:
  - `class IdentifyService`(静态门面,只做"平台选择 + 纯映射",采集生命周期归 UI 持有的 backend):
    - `static bool get isSupported`(Android / Windows / Linux)
    - `static IdentifyCaptureBackend platformDefault()`
    - `static Future<List<({Song song, double confidence})>> identify(RustApiClient api, Uint8List pcm)`
    - `static ({Song song, double confidence}) candidateToSong(IdentifyCandidate c)`(纯函数,可测)
  - `RustApiClient.identify(Uint8List pcm) -> Future<List<IdentifyCandidate>>`
  - `abstract class IdentifyCaptureBackend`(UI 可注入 fake):`Future<void> start({String source = 'mic'})`(source 仅桌面后端消费:"mic"|"system")、`Future<Uint8List?> stopAndCollect({int durationMs = 10000})`、`Future<void> cancel()`

- [ ] **Step 1: RustApiClient 加透传**

先读 `lib/core/rust_api_client.dart` 全文,找到持有 `Engine` 的私有字段与现有方法风格,仿照现有方法追加:

```dart
  /// 听歌识曲:上传 PCM,返回候选(已按匹配度降序)。
  Future<List<IdentifyCandidate>> identify(Uint8List pcm) =>
      rust.identifyMusic(engine: _engine, pcm: pcm);
```

(`_engine` 字段名以文件实际为准;import 区补 `import '../src/rust/api.dart' as rust;` 与 `import '../src/rust/api.dart' show IdentifyCandidate;` 中缺的那条——若文件已 `as rust` 引入则只需补 show 或用 `rust.IdentifyCandidate` 全限定,与现有风格一致。)

- [ ] **Step 2: 写失败测试**

创建 `test/services/identify_service_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/song.dart';
import 'package:shiyin_music/services/identify_service.dart';
import 'package:shiyin_music/src/rust/api.dart' as rust;

void main() {
  group('candidateToSong', () {
    test('完整候选映射为可播放 Song,置信度 = 1 - dist', () {
      final c = rust.IdentifyCandidate(
        name: '晴天',
        singer: '周杰伦',
        hash: 'abc123',
        albumAudioId: '12345',
        albumId: '999',
        albumName: '叶惠美',
        cover: 'http://example.com/a.jpg',
        hash320: 'abc320',
        hashFlac: 'abcflac',
        durationMs: 269000,
        dist: 0.08,
      );
      final m = IdentifyService.candidateToSong(c);
      expect(m.song.hash, 'abc123');
      expect(m.song.id, '12345');
      expect(m.song.title, '晴天');
      expect(m.song.artist, '周杰伦');
      expect(m.song.albumName, '叶惠美');
      expect(m.song.duration, const Duration(milliseconds: 269000));
      expect(m.confidence, closeTo(0.92, 1e-9));
    });

    test('空字段兜底为未知歌曲/未知艺人,durationMs=0 → null', () {
      final c = rust.IdentifyCandidate(
        name: '', singer: '', hash: 'h1', albumAudioId: '', albumId: '',
        albumName: '', cover: '', hash320: '', hashFlac: '',
        durationMs: 0, dist: 1.0,
      );
      final m = IdentifyService.candidateToSong(c);
      expect(m.song.title, '未知歌曲');
      expect(m.song.artist, '未知艺人');
      expect(m.song.id, 'h1'); // 无 albumAudioId 时用 hash 兜底
      expect(m.song.duration, isNull);
      expect(m.confidence, 0.0);
    });

    test('cover 相对路径补酷狗图床前缀', () {
      final c = rust.IdentifyCandidate(
        name: 'x', singer: 'y', hash: 'h', albumAudioId: '', albumId: '',
        albumName: '', cover: 'stdmusic/20210101/a.jpg', hash320: '',
        hashFlac: '', durationMs: 0, dist: 0.5,
      );
      final m = IdentifyService.candidateToSong(c);
      expect(m.song.coverUrl, startsWith('http'));
    });
  });
}
```

注意:先打开 `lib/models/song.dart` 看 `normalizeImageUrl`(L88-91、L131 附近)的实现——若它是私有函数且能处理酷狗图床相对路径,则 `candidateToSong` 里直接复用(必要时把它改成公开,或抽到公共 util;**不要**复制粘贴第二份逻辑);若它只是简单透传,则按下述规则自行实现并注释来源。测试第 3 条断言按最终实现微调(startsWith('http') 是最低要求)。

跑:`pwsh -NoProfile -Command "cd D:\AllCode\flutter\shiyin-music; flutter test test\services\identify_service_test.dart"` → 编译失败(类不存在)。

- [ ] **Step 3: 实现 IdentifyService**

创建 `lib/services/identify_service.dart`:

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/rust_api_client.dart';
import '../models/song.dart';
import '../src/rust/api.dart' as rust;

/// 采集后端接口(UI 测试可注入 fake;生产按平台选择)。
abstract class IdentifyCaptureBackend {
  /// 开始采集。[source] 仅桌面后端消费:"mic" 麦克风 / "system" 系统内录;
  /// Android 后端忽略(只有麦克风)。
  Future<void> start({String source = 'mic'});

  /// 停止并取末尾 [durationMs] 毫秒的 PCM;数据不足时返回已有部分,
  /// 完全无数据返回 null。
  Future<Uint8List?> stopAndCollect({int durationMs = 10000});

  /// 丢弃采集(用户取消/关页)。
  Future<void> cancel();
}

/// 听歌识曲服务:平台分流采集 PCM,识别统一走 Rust
/// (fingerprint.service,协议见 rust/src/services/identify.rs)。
///
/// - Windows/Linux:Rust cpal 采集(麦克风,或 WASAPI loopback 系统内录)
/// - Android:原生 AudioRecord 通道(原生 8000Hz 采集,免重采样)
/// - iOS/macOS/Web:不支持(Rust 引擎未接入,同响度分析的平台边界)
///
/// 采集生命周期(start/stop/cancel)由 UI 持有的 [IdentifyCaptureBackend]
/// 管理,本类只负责平台选择与候选映射,静态方法均可独立测试。
class IdentifyService {
  IdentifyService._();

  static bool get isSupported {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isWindows || Platform.isLinux;
  }

  static bool get _useRustCapture =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux);

  /// 当前平台的采集后端。
  static IdentifyCaptureBackend platformDefault() =>
      _useRustCapture ? _RustCaptureBackend() : _AndroidCaptureBackend();

  /// 上传 PCM 识别,返回按置信度降序的歌曲。
  static Future<List<({Song song, double confidence})>> identify(
    RustApiClient api,
    Uint8List pcm,
  ) async {
    final candidates = await api.identify(pcm);
    final matches = candidates.map(candidateToSong).toList()
      ..sort((a, b) => b.confidence.compareTo(a.confidence));
    return matches;
  }

  /// 候选 → 可播放 Song(纯函数)。置信度 = 1 - dist(dist 是上游匹配距离)。
  static ({Song song, double confidence}) candidateToSong(
    rust.IdentifyCandidate c,
  ) {
    final song = Song(
      id: c.albumAudioId.isNotEmpty ? c.albumAudioId : c.hash,
      title: c.name.isNotEmpty ? c.name : '未知歌曲',
      artist: c.singer.isNotEmpty ? c.singer : '未知艺人',
      hash: c.hash,
      albumId: c.albumId.isNotEmpty ? c.albumId : null,
      albumAudioId: c.albumAudioId.isNotEmpty ? c.albumAudioId : null,
      albumName: c.albumName.isNotEmpty ? c.albumName : null,
      coverUrl: c.cover.isNotEmpty ? _normalizeCover(c.cover) : null,
      duration: c.durationMs > 0 ? Duration(milliseconds: c.durationMs) : null,
    );
    return (song: song, confidence: 1.0 - c.dist.clamp(0.0, 1.0));
  }

  /// 酷狗指纹接口返回的封面常是相对路径(与搜索接口的 img 字段同源),
  /// 补图床前缀;完整 URL 原样返回。与 song.dart normalizeImageUrl 的
  /// 处理对象一致(实现时若可直接复用则复用)。
  static String _normalizeCover(String raw) {
    if (raw.startsWith('http')) return raw;
    return 'https://imge.kugou.com/$raw';
  }
}

/// 桌面 Rust 采集后端。
class _RustCaptureBackend implements IdentifyCaptureBackend {
  @override
  Future<void> start({String source = 'mic'}) =>
      rust.identifyStartCapture(source: source);

  @override
  Future<Uint8List?> stopAndCollect({int durationMs = 10000}) =>
      rust.identifyCaptureSnapshot(durationMs: durationMs);

  @override
  Future<void> cancel() => rust.identifyCancelCapture();
}

/// Android 原生 AudioRecord 采集后端。
class _AndroidCaptureBackend implements IdentifyCaptureBackend {
  static const _channel = MethodChannel('shiyin_music/audio_capture');

  @override
  Future<void> start({String source = 'mic'}) async {
    final granted = await _channel.invokeMethod<bool>('requestPermission');
    if (granted != true) {
      throw Exception('麦克风权限未授权');
    }
    await _channel.invokeMethod<dynamic>('start');
  }

  @override
  Future<Uint8List?> stopAndCollect({int durationMs = 10000}) =>
      _channel.invokeMethod<Uint8List>('stop', {'durationMs': durationMs});

  @override
  Future<void> cancel() => _channel.invokeMethod<dynamic>('cancel');
}
```

实现时注意:接口方法 `start()` 若带 `source` 参数,fake 实现也要带;保持接口与上面一致。Rust 侧生成函数在 Err 时抛异常,Dart 不再包一层 try。

- [ ] **Step 4: 跑测试通过 + analyze**

```bash
pwsh -NoProfile -Command "cd D:\AllCode\flutter\shiyin-music; flutter test test\services\identify_service_test.dart"
pwsh -NoProfile -Command "cd D:\AllCode\flutter\shiyin-music; flutter analyze"
```

预期:3 个测试 PASS;analyze 无新增告警。

- [ ] **Step 5: Commit**

```bash
git add lib/core/rust_api_client.dart lib/services/identify_service.dart test/services/identify_service_test.dart
git commit -m "feat(identify): Dart 识曲服务——桌面/Android 采集分流,候选映射 Song 与置信度"
```

---

### Task 5: 识曲 UI(识别页 + 两端入口)

**Files:**
- Create: `lib/ui/pages/identify_page.dart`
- Create: `test/ui/pages/identify_page_test.dart`
- Modify: `lib/ui/pages/search_page.dart`(移动端 AppBar 入口,L520-614 附近)
- Modify: `lib/ui/desktop/desktop_shell.dart` 或 `lib/ui/desktop/desktop_title_bar.dart`(桌面入口,见 Step 3 的选点说明)

**Interfaces:**
- Consumes:
  - Task 4: `IdentifyService.isSupported / platformDefault() / candidateToSong / identify(api, pcm)`、`IdentifyCaptureBackend`
  - 播放: `PlayerController.playSong(Song song, {List<Song>? queue, ...})`(现有);可选 `openPlayerIfSameSong(context, player:..., auth:..., song:...)`(lib/ui/player/song_tap_handler.dart L17-35)
  - `RustApiClient.getInstance()`(现有单例)
- Produces: `IdentifyPage({Key? key, required PlayerController player, RustApiClient? api, IdentifyCaptureBackend? captureBackend, Future<List<({Song song, double confidence})>> Function(Uint8List)? onIdentify})` —— `api`/`captureBackend`/`onIdentify` 缺省时生产实现,测试注入 fake。

- [ ] **Step 1: 写失败的页面测试**

创建 `test/ui/pages/identify_page_test.dart`(Fake 控制器模式对齐 `test/ui/pages/settings_desktop_gate_test.dart` L320-345 的 `_FakePlayer`):

```dart
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/song.dart';
import 'package:shiyin_music/services/identify_service.dart';
import 'package:shiyin_music/src/rust/api.dart' as rust;
import 'package:shiyin_music/ui/pages/identify_page.dart';

rust.IdentifyCandidate _candidate() => rust.IdentifyCandidate(
      name: '晴天',
      singer: '周杰伦',
      hash: 'abc123',
      albumAudioId: '1',
      albumId: '',
      albumName: '',
      cover: '',
      hash320: '',
      hashFlac: '',
      durationMs: 269000,
      dist: 0.1,
    );

class _FakeCaptureBackend implements IdentifyCaptureBackend {
  int startCalls = 0;
  int cancelCalls = 0;
  String? lastSource;
  @override
  Future<void> start({String source = 'mic'}) async {
    startCalls++;
    lastSource = source;
  }

  @override
  Future<Uint8List?> stopAndCollect({int durationMs = 10000}) async =>
      Uint8List.fromList(List.filled(16000, 1));

  @override
  Future<void> cancel() async => cancelCalls++;
}

class _FakePlayer implements PlayerController {
  final List<Song> played = [];
  @override
  Future<void> playSong(Song song, {List<Song>? queue, bool isRetry = false,
      Duration? initialPosition, bool preserveClimax = false}) async {
    played.add(song);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('打开即开始采集,识别结果可点击并触发播放', (tester) async {
    final backend = _FakeCaptureBackend();
    final player = _FakePlayer();
    final result = IdentifyService.candidateToSong(_candidate());

    await tester.pumpWidget(MaterialApp(
      home: IdentifyPage(
        player: player,
        captureBackend: backend,
        onIdentify: (pcm) async => [result],
      ),
    ));
    // 注意:聆听动画是 repeat() 控制器,匹配阶段有转圈——都不能 pumpAndSettle,
    // 一律用带时长的 pump 推进。
    await tester.pump(); // 首帧:进入 listening 并 start()
    expect(backend.startCalls, 1);
    await tester.pump(const Duration(seconds: 13)); // 越过 12s 自动提交
    await tester.pump(const Duration(milliseconds: 300)); // 结果帧渲染

    // 结果列表出现歌名
    expect(find.text('晴天'), findsOneWidget);
    // 点击结果 → playSong 被调用
    await tester.tap(find.text('晴天'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(player.played.single.hash, 'abc123');
    // 后端启动过一次,正常完成路径不走 cancel
    expect(backend.startCalls, 1);
    expect(backend.cancelCalls, 0);
  });

  testWidgets('识别不到结果显示空态文案', (tester) async {
    final backend = _FakeCaptureBackend();
    await tester.pumpWidget(MaterialApp(
      home: IdentifyPage(
        player: _FakePlayer(),
        captureBackend: backend,
        onIdentify: (pcm) async => [],
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 13));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('未识别到歌曲'), findsOneWidget);
  });
}
```

`_candidate()` 辅助与 import 已在上方代码中给出,无需额外补写。若 `PlayerController` 是抽象类/带必实现成员导致 Fake 编译不过,参照 settings_desktop_gate_test 的现成 Fake 写法调整。

跑:`pwsh -NoProfile -Command "cd D:\AllCode\flutter\shiyin-music; flutter test test\ui\pages\identify_page_test.dart"` → 编译失败(页面不存在)。

- [ ] **Step 2: 实现 IdentifyPage**

创建 `lib/ui/pages/identify_page.dart`。页面结构对齐 `lib/ui/pages/playback_history_page.dart` 的惯例(文档注释 → StatefulWidget → 构造注入)。行为规格:

- 状态机:`listening`(打开页面即 `captureBackend.start()`,mic 脉冲动画 + 已采集秒数计时)→ 用户点"停止识别"或自动满 12s → `matching`(转圈,`stopAndCollect(durationMs: 10000)` → PCM 为 null/空则直接空态)→ `identify(onIdentify ?? 默认走 IdentifyService.identify(RustApiClient.getInstance() 缓存实例, pcm))` → `done`(结果列表)/`empty`(无结果,文案"未识别到歌曲,请靠近音源后重试"+ "重试"按钮 → 回 listening)/`error`(异常文案 + 重试)。
-  AppBar:标题"听歌识曲",leading 返回按钮(关页前若在 listening 先 `captureBackend.cancel()`)。
- listening 动画:居中大圆 `Icons.mic_rounded`,用 `AnimationController(repeat())` 做缩放+透明度脉冲(1.2s 周期),下方提示文字"正在聆听,请靠近音源…"(桌面 system 源为"正在识别本机播放的声音…")。
- 桌面(Windows/Linux)在 AppBar actions 放源切换:`SegmentedButton<Mic/System>` 或两个 IconButton(`mic_rounded` / `speaker_rounded`),切换即 cancel → 以新源重新 start;Android 不显示。
- 结果行:封面(若项目有现成的 `RetryableNetworkImage` 就复用,`grep -r "class RetryableNetworkImage" lib` 确认;没有就 `Image.network` + `errorBuilder`)、歌名/歌手、右侧置信度百分比文本(`(confidence*100).toStringAsFixed(0)%`,<40% 显示"较低")。onTap:`player.playSong(song, queue: results.map((m) => m.song).toList())` 然后 `Navigator.of(context).pop()`。
- PCM 为空(Uint8List 长度 < 8000,即 <0.5s)不请求网络,直接空态。
- 页面释放(`dispose`):若仍在 listening,调 `captureBackend.cancel()`;计时器/动画控制器全部 dispose。
- 所有文案硬编码中文;主题色 `Theme.of(context).colorScheme`。

- [ ] **Step 3: 移动端搜索页入口**

读 `lib/ui/pages/search_page.dart` L520-614(移动 AppBar 与搜索胶囊)。在搜索胶囊**左侧**加识曲 IconButton(高度融入现有 36 胶囊行,`visualDensity: VisualDensity.compact`,图标 `Icons.graphic_eq_rounded`,tooltip '听歌识曲'):

```dart
IconButton(
  visualDensity: VisualDensity.compact,
  tooltip: '听歌识曲',
  icon: const Icon(Icons.graphic_eq_rounded),
  onPressed: () => _openIdentify(context),
),
```

页面私有方法(放在 `_playSong` 附近):

```dart
void _openIdentify(BuildContext context) {
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => IdentifyPage(player: widget.player),
    ),
  );
}
```

(`widget.player` 的实际名称以 search_page.dart 现有字段为准——`_playSong` 用的是 `widget.player.playSong`,保持一致;若该页同时有车机横排头部布局,车机形态不加入口,保持改动最小。)

- [ ] **Step 4: 桌面入口**

读 `lib/ui/desktop/desktop_shell.dart` L440-470(搜索浮层 `DesktopSearchSuggestPanel` 的挂载处)。在搜索浮层面板内部**顶部**加一行"听歌识曲"入口(列表首项样式,`Icons.graphic_eq_rounded` + 文案 + 右侧"播放中的歌也能识别"提示小字),onPressed 关闭浮层后与移动端同款 `Navigator.of(context, rootNavigator: true).push(fullscreenDialog, IdentifyPage(player: ...))`。

选点理由:浮层面板已具备播放/控制器上下文(建议结果可直接播放),改动面最小;标题栏 40px 高度紧张不再塞按钮。实现时先确认 `DesktopSearchSuggestPanel` 的构造参数里有没有 `player`(grep 它文件内的 playSong 调用);没有则由 desktop_shell.dart 传入(它已有 controller 装配)。`IdentifyPage` 需要 `RustApiClient` 实例时用 `RustApiClient.getInstance()`(内部有单例缓存,勿重复 init)。

- [ ] **Step 5: 全量验证**

```bash
pwsh -NoProfile -Command "cd D:\AllCode\flutter\shiyin-music; flutter test test\ui\pages\identify_page_test.dart"
pwsh -NoProfile -Command "cd D:\AllCode\flutter\shiyin-music; flutter test"
pwsh -NoProfile -Command "cd D:\AllCode\flutter\shiyin-music; flutter analyze"
```

预期:新页面测试 PASS;**存量测试零回归**(全量 flutter test 全绿);analyze 无新告警。

- [ ] **Step 6: Commit**

```bash
git add lib/ui/pages/identify_page.dart lib/ui/pages/search_page.dart lib/ui/desktop test/ui/pages/identify_page_test.dart
git commit -m "feat(identify): 识曲页(聆听动画/结果播放/源切换)与移动搜索页、桌面搜索浮层入口"
```

---

### Task 6: 全链路验证与收尾

**Files:**
- 无新增(只验证,必要时修复)

- [ ] **Step 1: Windows 全量构建(验证 DLL 链接 cpal + release 产物)**

```bash
pwsh -NoProfile -Command "cd D:\AllCode\flutter\shiyin-music; flutter build windows --release"
```

预期:BUILD SUCCESSFUL,`build/windows/x64/runner/Release/kugou_engine.dll` 存在。

- [ ] **Step 2: 全部套件终跑**

```bash
pwsh -NoProfile -Command "cargo test --manifest-path rust/Cargo.toml"
pwsh -NoProfile -Command "cd D:\AllCode\flutter\shiyin-music; flutter test"
pwsh -NoProfile -Command "cd D:\AllCode\flutter\shiyin-music; flutter analyze"
```

- [ ] **Step 3: 手工冒烟指引写入报告(不自动执行)**

真实识曲需要出声环境,子代理无法替代;在任务报告中列出人工冒烟步骤:Windows `flutter run -d windows` → 搜索浮层点"听歌识曲"→ 选"系统内录"→ 播放任意歌曲 10s → 观察候选;Android 安装 debug 包 → 授权麦克风 → 播放外放音乐识别。

- [ ] **Step 4: 如有修复则 commit**

```bash
git add -A
git commit -m "fix(identify): 全链路验证修复(构建/测试问题)"
```

(无修复则跳过本步。)
