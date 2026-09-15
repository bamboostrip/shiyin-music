use base64::Engine;
use serde_json::{json, Value};

use crate::error::AppResult;
use crate::kugou::{
    crypto,
    request::{KgRequest, SignatureType},
    session::KgSession,
    transport,
};

const LYRIC_HOST: &str = "https://lyrics.kugou.com";

pub async fn search_lyric(
    client: &reqwest::Client,
    session: &KgSession,
    hash: Option<&str>,
    album_audio_id: Option<&str>,
    keyword: Option<&str>,
    man: Option<&str>,
) -> AppResult<Value> {
    let req = KgRequest::get("/v1/search")
        .base_url(LYRIC_HOST)
        .param("album_audio_id", album_audio_id.unwrap_or("0"))
        .param("duration", "0")
        .param("hash", hash.unwrap_or(""))
        .param("keyword", keyword.unwrap_or(""))
        .param("lrctxt", "1")
        .param("man", man.unwrap_or("no"))
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

pub async fn get_lyric(
    client: &reqwest::Client,
    session: &KgSession,
    id: &str,
    accesskey: &str,
    fmt: &str,
    decode: bool,
) -> AppResult<Value> {
    let req = KgRequest::get("/download")
        .base_url(LYRIC_HOST)
        .param("ver", "1")
        .param("client", "android")
        .param("id", id)
        .param("accesskey", accesskey)
        .param("fmt", fmt)
        .param("charset", "utf8")
        .signature_type(SignatureType::Default);
    let raw = transport::send(client, session, &req).await?;

    let raw_content = raw
        .get("content")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    let (decoded_content, decoded_trans) = if decode {
        let content_type = raw.get("contenttype").and_then(|v| v.as_i64()).unwrap_or(0);
        let decoded_content = raw_content.as_deref().and_then(|b64| {
            if b64.is_empty() {
                None
            } else if fmt == "lrc" || content_type != 0 {
                base64_decode_utf8(b64).ok()
            } else {
                Some(crypto::decode_lyrics(b64))
            }
        });
        let decoded_trans = raw
            .get("trans")
            .and_then(|v| v.as_str())
            .and_then(|s| base64_decode_utf8(s).ok());
        (decoded_content, decoded_trans)
    } else {
        (None, None)
    };

    Ok(json!({
        "raw_content": raw_content,
        "rawContent": raw_content,
        "decoded_content": decoded_content,
        "decodedContent": decoded_content,
        "decoded_translation": decoded_trans,
        "decodedTranslation": decoded_trans,
        "raw": raw,
        "rawJson": raw,
    }))
}

fn base64_decode_utf8(s: &str) -> Result<String, ()> {
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(s)
        .map_err(|_| ())?;
    String::from_utf8(bytes).map_err(|_| ())
}
