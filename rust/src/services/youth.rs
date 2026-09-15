use serde_json::{json, Value};

use crate::error::AppResult;
use crate::kugou::{
    request::{KgRequest, SignatureType},
    session::KgSession,
    transport,
};

fn require_login(session: &KgSession) -> AppResult<()> {
    if !session.is_logged_in() {
        return Err(crate::error::AppError::Unauthorized(
            "此接口需要登录".into(),
        ));
    }
    Ok(())
}

fn today_str() -> String {
    chrono::Local::now().format("%Y-%m-%d").to_string()
}

#[allow(dead_code)]
pub async fn channel_all(
    client: &reqwest::Client,
    session: &KgSession,
    page: i64,
    pagesize: i64,
) -> AppResult<Value> {
    let req = KgRequest::get("/youth/v2/channel/channel_all_list")
        .param("page", page.to_string())
        .param("pagesize", pagesize.to_string())
        .param("type", "1")
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn channel_amway(
    client: &reqwest::Client,
    session: &KgSession,
    global_collection_id: &str,
) -> AppResult<Value> {
    let req = KgRequest::get("/youth/api/amway/v2/index")
        .param("global_collection_id", global_collection_id)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn channel_detail(
    client: &reqwest::Client,
    session: &KgSession,
    global_collection_ids: &str,
) -> AppResult<Value> {
    let data: Vec<Value> = global_collection_ids
        .split(',')
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .map(|id| json!({ "global_collection_id": id }))
        .collect();
    let req = KgRequest::get("/youth/api/channel/v1/channel_list_by_id")
        .method(reqwest::Method::POST)
        .json_body(json!({ "data": data }))
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn channel_similar(
    client: &reqwest::Client,
    session: &KgSession,
    channel_id: &str,
) -> AppResult<Value> {
    let vip_type: i64 = session.vip_type.parse().unwrap_or(0);
    let req = KgRequest::get("/youth/v1/channel/get_friendly_channel")
        .method(reqwest::Method::POST)
        .param("channel_id", channel_id)
        .json_body(json!({
            "area_code": 1,
            "playlist_ver": 2,
            "vip_type": vip_type,
            "platform": "ios",
        }))
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn channel_songs(
    client: &reqwest::Client,
    session: &KgSession,
    global_collection_id: &str,
    page: i64,
    pagesize: i64,
) -> AppResult<Value> {
    let req = KgRequest::get("/youth/api/channel/v1/channel_get_song_audit_passed")
        .param("global_collection_id", global_collection_id)
        .param("pagesize", pagesize.to_string())
        .param("page", page.to_string())
        .param("is_filter", "0")
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn channel_song_detail(
    client: &reqwest::Client,
    session: &KgSession,
    global_collection_id: &str,
    fileid: &str,
) -> AppResult<Value> {
    let req = KgRequest::get("/youth/v2/post/get_song_detail")
        .param("global_collection_id", global_collection_id)
        .param("fileid", fileid)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn channel_subscription(
    client: &reqwest::Client,
    session: &KgSession,
    global_collection_id: &str,
    subscribe: bool,
) -> AppResult<Value> {
    let path = if subscribe {
        "/youth/v1/channel_subscribe"
    } else {
        "/youth/v1/channel_unsubscribe"
    };
    let mut req = KgRequest::get(path);
    req.method = if subscribe {
        reqwest::Method::POST
    } else {
        reqwest::Method::DELETE
    };
    let req = req
        .param("global_collection_id", global_collection_id)
        .param("source", "1")
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn dynamic(client: &reqwest::Client, session: &KgSession) -> AppResult<Value> {
    let req = KgRequest::get("/youth/v3/user/get_dynamic").signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn dynamic_recent(client: &reqwest::Client, session: &KgSession) -> AppResult<Value> {
    let req =
        KgRequest::get("/youth/v3/user/recent_dynamic").signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn report_listen_song(
    client: &reqwest::Client,
    session: &KgSession,
    mixsongid: i64,
) -> AppResult<Value> {
    let req = KgRequest::get("/youth/v2/report/listen_song")
        .method(reqwest::Method::POST)
        .param("clientver", "10566")
        .json_body(json!({ "mixsongid": mixsongid }))
        .custom_header(
            "user-agent",
            "Android13-1070-10566-201-0-ReportPlaySongToServerProtocol-wifi",
        )
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn union_vip(client: &reqwest::Client, session: &KgSession) -> AppResult<Value> {
    let req = KgRequest::get("/v1/get_union_vip")
        .base_url("https://kugouvip.kugou.com")
        .param("busi_type", "concept")
        .param("opt_product_types", "dvip,qvip")
        .param("product_type", "svip")
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn user_songs(
    client: &reqwest::Client,
    session: &KgSession,
    userid: Option<&str>,
    page: i64,
    pagesize: i64,
    list_type: i64,
) -> AppResult<Value> {
    let uid = userid.filter(|s| !s.is_empty()).unwrap_or(&session.userid);
    let req = KgRequest::get("/youth/v1/get_user_song_public")
        .param("filter_video", "0")
        .param("type", list_type.to_string())
        .param("userid", uid)
        .param("pagesize", pagesize.to_string())
        .param("page", page.to_string())
        .param("is_filter", "0")
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn report_vip_ad_play(client: &reqwest::Client, session: &KgSession) -> AppResult<Value> {
    let time_ms = chrono::Utc::now().timestamp_millis();
    let req = KgRequest::get("/youth/v1/ad/play_report")
        .method(reqwest::Method::POST)
        .json_body(json!({
            "ad_id": 12307537187_i64,
            "play_end": time_ms,
            "play_start": time_ms - 30000,
        }))
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

pub async fn receive_one_day_vip(
    client: &reqwest::Client,
    session: &KgSession,
) -> AppResult<Value> {
    require_login(session)?;
    let req = KgRequest::get("/youth/v1/recharge/receive_vip_listen_song")
        .method(reqwest::Method::POST)
        .param("source_id", "90139")
        .param("receive_day", today_str())
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

pub async fn upgrade_vip(client: &reqwest::Client, session: &KgSession) -> AppResult<Value> {
    require_login(session)?;
    let req = KgRequest::get("/youth/v1/listen_song/upgrade_vip_reward")
        .method(reqwest::Method::POST)
        .param("kugouid", &session.userid)
        .param("ad_type", "1")
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

pub async fn month_vip_record(client: &reqwest::Client, session: &KgSession) -> AppResult<Value> {
    let req = KgRequest::get("/youth/v1/activity/get_month_vip_record")
        .param("latest_limit", "100")
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}
