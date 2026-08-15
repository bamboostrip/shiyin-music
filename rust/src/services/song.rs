use serde_json::{json, Value};

use crate::error::AppResult;
use crate::kugou::{
    crypto,
    models::PlayUrlData,
    request::{KgRequest, SignatureType},
    session::KgSession,
    transport,
};

const MAGIC_QUALITIES: &[&str] = &["piano", "acappella", "subwoofer", "ancient", "dj", "surnay"];

fn normalize_quality(quality: Option<&str>) -> String {
    match quality {
        Some(q) if MAGIC_QUALITIES.contains(&q) => format!("magic_{q}"),
        Some(q) if !q.is_empty() => q.to_string(),
        _ => "128".to_string(),
    }
}

pub async fn get_play_url(
    client: &reqwest::Client,
    session: &KgSession,
    hash: &str,
    quality: Option<&str>,
    album_id: Option<&str>,
    album_audio_id: Option<&str>,
    free_part: bool,
) -> AppResult<Value> {
    let dfid = if session.dfid.trim().is_empty() || session.dfid == "-" {
        crypto::random_string(24)
    } else {
        session.dfid.clone()
    };
    let normalized_quality = normalize_quality(quality);

    let req = KgRequest::get("/v5/url")
        .param("album_id", album_id.unwrap_or("0"))
        .param("area_code", "1")
        .param("hash", hash.to_lowercase())
        .param("ssa_flag", "is_fromtrack")
        .param("version", "11430")
        .param("page_id", "967177915")
        .param("quality", normalized_quality)
        .param("album_audio_id", album_audio_id.unwrap_or("0"))
        .param("behavior", "play")
        .param("pid", "411")
        .param("cmd", "26")
        .param("pidversion", "3001")
        .param("IsFreePart", if free_part { "1" } else { "0" })
        .param("ppage_id", "356753938,823673182,967485191")
        .param("cdnBackup", "1")
        .param("module", "")
        .param("clientver", "11430")
        .router("trackercdn.kugou.com")
        .signature_type(SignatureType::V5)
        .specific_dfid(dfid);

    transport::send(client, session, &req).await
}

/// 试听高潮（对应 .NET RawSongApi.GetSongClimaxAsync）。
///
/// 上游接口：GET https://expendablekmrcdn.kugou.com/v1/audio_climax/audio
/// 参数 `data` 为 JSON 字符串数组，如 `[{"hash":"<hash1>"},{"hash":"<hash2>"}]`；
/// `hash` 支持逗号分隔传多个。返回上游原始 JSON 透传。
pub async fn get_song_climax(
    client: &reqwest::Client,
    session: &KgSession,
    hash: &str,
) -> AppResult<Value> {
    let data: Vec<Value> = hash
        .split(',')
        .filter(|s| !s.trim().is_empty())
        .map(|h| json!({ "hash": h.trim() }))
        .collect();
    let req = KgRequest::get("/v1/audio_climax/audio")
        .base_url("https://expendablekmrcdn.kugou.com")
        .param("data", serde_json::to_string(&data).unwrap_or_default())
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn get_play_info(
    client: &reqwest::Client,
    session: &KgSession,
    hash: &str,
    quality: Option<&str>,
    album_id: Option<&str>,
    album_audio_id: Option<&str>,
    free_part: bool,
) -> AppResult<PlayUrlData> {
    let v = get_play_url(
        client, session, hash, quality, album_id, album_audio_id, free_part,
    )
    .await?;
    let data: PlayUrlData = serde_json::from_value(v).map_err(|e| {
        crate::error::AppError::Internal(format!("解析播放链接结果失败: {e}"))
    })?;
    Ok(data)
}
