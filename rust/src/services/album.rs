use serde_json::{json, Value};

use crate::error::AppResult;
use crate::kugou::{
    config, crypto,
    request::{KgRequest, SignatureType},
    session::KgSession,
    signer, transport,
};

pub async fn album_shop(client: &reqwest::Client, session: &KgSession) -> AppResult<Value> {
    let req = KgRequest::get("/zhuanjidata/v3/album_shop_v2/get_classify_data")
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn album_info(
    client: &reqwest::Client,
    session: &KgSession,
    album_ids: &str,
    fields: Option<&str>,
) -> AppResult<Value> {
    let client_time_ms = chrono::Utc::now().timestamp_millis();
    let data: Vec<Value> = album_ids
        .split(',')
        .filter(|s| !s.trim().is_empty())
        .map(|id| json!({ "album_id": id.trim(), "album_name": "", "author_name": "" }))
        .collect();

    let body = json!({
        "appid": config::APP_ID,
        "clienttime": client_time_ms,
        "clientver": config::CLIENT_VER,
        "data": data,
        "dfid": "-",
        "fields": fields.unwrap_or(""),
        "key": signer::calc_login_key(client_time_ms),
        "mid": crypto::calc_new_mid("-"),
    });

    let req = KgRequest::get("/v1/album")
        .method(reqwest::Method::POST)
        .base_url("http://kmr.service.kugou.com")
        .router("kmr.service.kugou.com")
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn album_detail(
    client: &reqwest::Client,
    session: &KgSession,
    album_id: &str,
) -> AppResult<Value> {
    let body = json!({
        "data": [{ "album_id": album_id }],
        "is_buy": 0,
        "fields": "album_id,album_name,publish_date,sizable_cover,intro,language,is_publish,heat,type,quality,authors,exclusive,author_name,trans_param"
    });
    let req = KgRequest::get("/kmr/v2/albums")
        .method(reqwest::Method::POST)
        .router("openapi.kugou.com")
        .json_body(body)
        .custom_header("kg-tid", "255")
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

pub async fn album_songs(
    client: &reqwest::Client,
    session: &KgSession,
    album_id: &str,
    page: i64,
    pagesize: i64,
) -> AppResult<Value> {
    let body = json!({
        "album_id": album_id,
        "is_buy": 0,
        "page": page,
        "pagesize": pagesize
    });
    let req = KgRequest::get("/v1/album_audio/lite")
        .method(reqwest::Method::POST)
        .router("openapi.kugou.com")
        .json_body(body)
        .custom_header("kg-tid", "255")
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}
