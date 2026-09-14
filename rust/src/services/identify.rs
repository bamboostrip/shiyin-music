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
