use serde_json::{json, Value};

use crate::error::AppResult;
use crate::kugou::{
    config, crypto,
    request::{KgRequest, SignatureType},
    session::KgSession,
    signer, transport,
};

#[allow(dead_code)]
pub async fn upload_play_history(
    client: &reqwest::Client,
    session: &KgSession,
    mix_song_id: i64,
    timestamp: Option<i64>,
    play_count: i64,
) -> AppResult<Value> {
    let body = json!({
        "songs": [{ "mxid": mix_song_id, "op": 1, "ot": timestamp.unwrap_or_else(|| chrono::Utc::now().timestamp()), "pc": play_count }],
        "token": session.token, "userid": session.userid
    });
    let req = KgRequest::get("/playhistory/v1/upload_songs")
        .method(reqwest::Method::POST)
        .param("plat", "3")
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn latest_songs(
    client: &reqwest::Client,
    session: &KgSession,
    pagesize: i64,
) -> AppResult<Value> {
    let body = json!({
        "area_code": "1", "sources": ["pc", "mobile", "tv", "car"],
        "userid": session.userid.parse::<i64>().unwrap_or(0), "ret_info": 1,
        "token": session.token, "pagesize": pagesize
    });
    let req = KgRequest::get("/playque/devque/v1/get_latest_songs")
        .method(reqwest::Method::POST)
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

pub async fn listen_time_add(client: &reqwest::Client, session: &KgSession) -> AppResult<Value> {
    let client_time = chrono::Utc::now().timestamp();
    let p_data = json!({ "token": session.token, "clienttime_ms": client_time });
    let p = crypto::rsa_encrypt_no_padding(&p_data.to_string(), true).to_uppercase();
    let body = json!({
        "p": p, "appid": config::APP_ID, "mid": session.mid,
        "clientver": config::CLIENT_VER, "clienttime": client_time,
        "type": "1", "uuid": "", "userid": session.userid,
        "key": signer::calc_login_key(client_time)
    });
    let req = KgRequest::get("/v2/get_grade_info")
        .method(reqwest::Method::POST)
        .base_url("http://userinfo.user.kugou.com")
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}
