use serde_json::{json, Value};

use crate::error::AppResult;
use crate::kugou::{
    config, crypto,
    request::{KgRequest, SignatureType},
    session::KgSession,
    signer, transport,
};

const FAKE_M_PERSONAL: &str = "ca981cfc583a4c37f28d2d49000013c16a0a";
#[allow(dead_code)]
const FAKE_M_CARD: &str = "60f7ebf1f812edbac3c63a7310001701760f";

pub async fn recommend_playlists(
    client: &reqwest::Client,
    session: &KgSession,
    category_id: i64,
    page: i64,
) -> AppResult<Value> {
    let client_time = chrono::Utc::now().timestamp();
    let body = json!({
        "appid": config::APP_ID,
        "mid": crypto::md5_str(if session.dfid.is_empty() { "-" } else { &session.dfid }),
        "clientver": config::CLIENT_VER,
        "platform": "android", "clienttime": client_time,
        "userid": session.userid, "module_id": 1, "page": page, "pagesize": 30,
        "key": signer::calc_login_key(client_time),
        "special_recommend": {
            "withtag": 1, "withsong": 0, "sort": 1, "ugc": 1, "is_selected": 0,
            "withrecommend": 1, "area_code": 1, "categoryid": category_id
        },
        "req_multi": 1, "retrun_min": 5, "return_special_falg": 1
    });
    let req = KgRequest::get("/v2/special_recommend")
        .method(reqwest::Method::POST)
        .router("specialrec.service.kugou.com")
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

pub async fn new_songs(
    client: &reqwest::Client,
    session: &KgSession,
    rank_id: i64,
    page: i64,
) -> AppResult<Value> {
    let body = json!({
        "rank_id": rank_id, "userid": session.userid, "page": page, "pagesize": 30, "tags": []
    });
    let req = KgRequest::get("/musicadservice/container/v1/newsong_publish")
        .method(reqwest::Method::POST)
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

pub async fn recommend_songs(client: &reqwest::Client, session: &KgSession) -> AppResult<Value> {
    let body = json!({ "platform": "android", "userid": session.userid });
    let req = KgRequest::get("/everyday_song_recommend")
        .method(reqwest::Method::POST)
        .router("everydayrec.service.kugou.com")
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn recommend_style(client: &reqwest::Client, session: &KgSession) -> AppResult<Value> {
    let body = json!({ "platform": "android" });
    let req = KgRequest::get("/everydayrec.service/everyday_style_recommend")
        .method(reqwest::Method::POST)
        .param("tagids", "")
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

pub async fn ai_recommend(
    client: &reqwest::Client,
    session: &KgSession,
    album_audio_ids: &str,
) -> AppResult<Value> {
    let client_time_ms = chrono::Utc::now().timestamp_millis();
    let rec_source: Vec<Value> = album_audio_ids
        .split(',')
        .filter(|s| !s.trim().is_empty())
        .filter_map(|id| id.trim().parse::<i64>().ok().map(|i| json!({ "ID": i })))
        .collect();
    let body = json!({
        "platform": "ios", "clientver": config::CLIENT_VER, "clienttime": client_time_ms,
        "userid": session.userid, "client_playlist": [], "source_type": 2, "playlist_ver": 2,
        "area_code": 1, "appid": config::APP_ID,
        "key": signer::calc_login_key(client_time_ms),
        "mid": if session.mid.is_empty() { "-".to_string() } else { session.mid.clone() },
        "recommend_source": rec_source
    });
    let req = KgRequest::get("/recommend")
        .method(reqwest::Method::POST)
        .router("songlistairec.kugou.com")
        .clear_default_params()
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn yueku(client: &reqwest::Client, session: &KgSession) -> AppResult<Value> {
    let req = KgRequest::get("/v1/yueku/recommend_v2")
        .router("service.mobile.kugou.com")
        .param("operator", "7")
        .param("plat", "0")
        .param("type", "11")
        .param("area_code", "1")
        .param("req_multi", "1")
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn yueku_banner(client: &reqwest::Client, session: &KgSession) -> AppResult<Value> {
    let body = json!({
        "plat": 0, "channel": 201, "operator": 7, "networktype": 2,
        "userid": session.userid, "vip_type": 0, "m_type": 0, "tags": [],
        "apiver": 5, "ability": 2, "mode": "normal"
    });
    let req = KgRequest::get("/ads.gateway/v3/listen_banner")
        .method(reqwest::Method::POST)
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn yueku_fm(client: &reqwest::Client, session: &KgSession) -> AppResult<Value> {
    let req = KgRequest::get("/v1/time_fm_info")
        .router("fm.service.kugou.com")
        .param("operator", "7")
        .param("plat", "0")
        .param("type", "11")
        .param("area_code", "1")
        .param("req_multi", "1")
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

pub async fn top_album(
    client: &reqwest::Client,
    session: &KgSession,
    page: i64,
    pagesize: i64,
) -> AppResult<Value> {
    let body = json!({
        "apiver": 20, "token": session.token, "page": page, "pagesize": pagesize, "withpriv": 1
    });
    let req = KgRequest::get("/musicadservice/v1/mobile_newalbum_sp")
        .method(reqwest::Method::POST)
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn top_card(
    client: &reqwest::Client,
    session: &KgSession,
    card_id: i64,
) -> AppResult<Value> {
    let client_time_ms = chrono::Utc::now().timestamp_millis();
    let body = json!({
        "appid": config::APP_ID, "clientver": config::CLIENT_VER, "platform": "android",
        "clienttime": client_time_ms, "userid": session.userid,
        "key": signer::calc_login_key(client_time_ms), "fakem": FAKE_M_CARD,
        "area_code": 1, "mid": if session.mid.is_empty() { "-".to_string() } else { session.mid.clone() },
        "uuid": "-", "client_playlist": [], "u_info": "a0c35cd40af564444b5584c2754dedec"
    });
    let req = KgRequest::get("/singlecardrec.service/v1/single_card_recommend")
        .method(reqwest::Method::POST)
        .param("card_id", card_id.to_string())
        .param("fakem", FAKE_M_CARD)
        .param("area_code", "1")
        .param("platform", "ios")
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn top_ip(client: &reqwest::Client, session: &KgSession) -> AppResult<Value> {
    let req = KgRequest::get("/v1/daily_recommend")
        .method(reqwest::Method::POST)
        .base_url("http://musicadservice.kugou.com")
        .param("clientver", "12349")
        .param("area_code", "1")
        .json_body(json!({ "tags": {} }))
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn pc_diantai(client: &reqwest::Client, session: &KgSession) -> AppResult<Value> {
    let body = json!({ "isvip": 0, "userid": session.userid, "vipType": 0 });
    let req = KgRequest::get("/v3/pc_diantai")
        .method(reqwest::Method::POST)
        .base_url("https://adservice.kugou.com")
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn brush(
    client: &reqwest::Client,
    session: &KgSession,
    song_pool_id: i64,
    mode: &str,
) -> AppResult<Value> {
    let client_time_ms = chrono::Utc::now().timestamp_millis();
    let pr = json!({
        "userid": session.userid, "appid": config::APP_ID, "playlist_ver": 2,
        "clienttime": client_time_ms,
        "mid": if session.mid.is_empty() { "-".to_string() } else { session.mid.clone() },
        "new_sync_point": client_time_ms, "module_id": 1, "action": "login",
        "vip_type": session.vip_type.parse::<i64>().unwrap_or(0), "vip_flags": 3,
        "recommend_source_locked": 0, "song_pool_id": song_pool_id, "callerid": 0,
        "m_type": 1, "kguid": session.userid, "platform": "ios", "area_code": 1,
        "fakem": FAKE_M_PERSONAL, "clientver": 11850, "mode": mode, "active_swtich": "on",
        "key": signer::calc_login_key(client_time_ms)
    });
    let body = json!({
        "behaviors": [],
        "abtest": { "abtest": { "shuashua": { "commentcard": 2 } } },
        "personal_recommend_params": pr
    });
    let req = KgRequest::get("/genesisapi/v1/newepoch_song_rec/feed")
        .method(reqwest::Method::POST)
        .param("sort_type", "1")
        .param("platform", "ios")
        .param("page", "1")
        .param("content_ver", "4")
        .param("clientver", "11850")
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn everyday_history(
    client: &reqwest::Client,
    session: &KgSession,
    mode: &str,
    platform: &str,
    history_name: Option<&str>,
    date: Option<&str>,
) -> AppResult<Value> {
    let mut req = KgRequest::get("/everyday/api/v1/get_history")
        .method(reqwest::Method::POST)
        .param("mode", mode)
        .param("platform", platform)
        .router("everydayrec.service.kugou.com")
        .signature_type(SignatureType::Default);
    if let Some(h) = history_name.filter(|s| !s.is_empty()) {
        req = req.param("history_name", h);
    }
    if let Some(d) = date.filter(|s| !s.is_empty()) {
        req = req.param("date", d);
    }
    transport::send(client, session, &req).await
}

#[allow(clippy::too_many_arguments)]
pub async fn personal_fm(
    client: &reqwest::Client,
    session: &KgSession,
    hash: Option<&str>,
    songid: Option<&str>,
    playtime: Option<i64>,
    action: &str,
    mode: &str,
    song_pool_id: i64,
    is_overplay: bool,
    remain_song_cnt: i64,
) -> AppResult<Value> {
    let client_time_ms = chrono::Utc::now().timestamp_millis();
    let mut body = json!({
        "appid": config::APP_ID, "clienttime": client_time_ms,
        "mid": if session.mid.is_empty() { "-".to_string() } else { session.mid.clone() },
        "action": action, "recommend_source_locked": 0, "song_pool_id": song_pool_id,
        "callerid": 0, "m_type": 1, "platform": "android", "area_code": 1,
        "remain_songcnt": remain_song_cnt, "clientver": config::CLIENT_VER,
        "is_overplay": if is_overplay { 1 } else { 0 }, "mode": mode,
        "fakem": FAKE_M_PERSONAL, "key": signer::calc_login_key(client_time_ms)
    });
    if session.userid != "0" {
        body["userid"] = json!(session.userid.parse::<i64>().unwrap_or(0));
        body["kguid"] = json!(session.userid.parse::<i64>().unwrap_or(0));
    }
    if !session.token.is_empty() {
        body["token"] = json!(session.token);
    }
    if !session.vip_type.is_empty() {
        body["vip_type"] = json!(session.vip_type.parse::<i64>().unwrap_or(0));
    }
    if let Some(h) = hash.filter(|s| !s.is_empty()) {
        body["hash"] = json!(h);
    }
    if let Some(s) = songid.filter(|s| !s.is_empty()) {
        body["songid"] = json!(s);
    }
    if let Some(p) = playtime {
        body["playtime"] = json!(p);
    }

    let req = KgRequest::get("/v2/personal_recommend")
        .method(reqwest::Method::POST)
        .router("persnfm.service.kugou.com")
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}
