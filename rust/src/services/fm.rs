use serde_json::{json, Value};

use crate::error::AppResult;
use crate::kugou::{config, crypto, request::{KgRequest, SignatureType}, session::KgSession, signer, transport};

/// fm.service.kugou.com 系列接口统一用**标准客户端身份**（appid=1005 + OfficialSalt）
/// 签名：歌曲列表等接口只对标准身份返回数据，Lite 身份会得到 status=1 但空 data。
fn fm_signed_body(session: &KgSession, now_ms: i64, mut body: Value) -> Value {
    if let Value::Object(ref mut map) = body {
        map.insert("appid".into(), json!(config::OFFICIAL_APP_ID));
        map.insert("clienttime".into(), json!(now_ms));
        map.insert("clientver".into(), json!(config::OFFICIAL_CLIENT_VER));
        map.insert("key".into(), json!(signer::calc_official_key(now_ms)));
        map.insert("mid".into(), json!(crypto::calc_new_mid(&session.dfid)));
    }
    body
}

pub async fn fm_recommend(client: &reqwest::Client, session: &KgSession) -> AppResult<Value> {
    let now_ms = chrono::Utc::now().timestamp_millis();
    let body = fm_signed_body(session, now_ms, json!({
        "rcmdsongcount": 1,
        "level": 0,
        "area_code": 1,
        "get_tracker": 1,
        "uid": 0
    }));
    let req = KgRequest::get("/v1/rcmd_list")
        .method(reqwest::Method::POST)
        .router("fm.service.kugou.com")
        .json_body(body)
        .signature_type(SignatureType::OfficialAndroid);
    transport::send(client, session, &req).await
}

pub async fn fm_songs(
    client: &reqwest::Client,
    session: &KgSession,
    fm_ids: &str,
    fmtype: i64,
    offset: i64,
    size: i64,
) -> AppResult<Value> {
    let now_ms = chrono::Utc::now().timestamp_millis();
    let data: Vec<Value> = fm_ids
        .split(',')
        .filter(|s| !s.trim().is_empty())
        .map(|id| {
            json!({
                "fmid": id.trim(),
                "fmtype": fmtype,
                "offset": offset,
                "size": size,
                "singername": ""
            })
        })
        .collect();

    let body = fm_signed_body(session, now_ms, json!({
        "area_code": 1,
        "data": data,
        "get_tracker": 1,
        "uid": session.userid
    }));
    let req = KgRequest::get("/v1/app_song_list_offset")
        .method(reqwest::Method::POST)
        .router("fm.service.kugou.com")
        .json_body(body)
        .signature_type(SignatureType::OfficialAndroid);
    transport::send(client, session, &req).await
}

pub async fn fm_class(client: &reqwest::Client, session: &KgSession) -> AppResult<Value> {
    let now_ms = chrono::Utc::now().timestamp_millis();
    let userid = session.userid.clone();
    let body = fm_signed_body(session, now_ms, json!({
        "kguid": userid,
        "platform": "android",
        "uid": session.userid,
        "get_tracker": 1
    }));
    let req = KgRequest::get("/v1/class_fm_song")
        .method(reqwest::Method::POST)
        .router("fm.service.kugou.com")
        .json_body(body)
        .signature_type(SignatureType::OfficialAndroid);
    transport::send(client, session, &req).await
}

pub async fn fm_image(client: &reqwest::Client, session: &KgSession, fm_ids: &str) -> AppResult<Value> {
    let now_ms = chrono::Utc::now().timestamp_millis();
    let data: Vec<Value> = fm_ids
        .split(',')
        .filter(|s| !s.trim().is_empty())
        .map(|id| {
            json!({
                "fields": "imgUrl100,imgUrl50",
                "fmid": id.trim(),
                "fmtype": 2
            })
        })
        .collect();

    let body = fm_signed_body(session, now_ms, json!({
        "data": data,
        "dfid": session.dfid
    }));
    let req = KgRequest::get("/v1/fm_info")
        .method(reqwest::Method::POST)
        .router("fm.service.kugou.com")
        .json_body(body)
        .signature_type(SignatureType::OfficialAndroid);
    transport::send(client, session, &req).await
}
