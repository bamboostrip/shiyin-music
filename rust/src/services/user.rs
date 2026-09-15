use serde_json::{json, Value};

use crate::error::{AppError, AppResult};
use crate::kugou::{
    config, crypto,
    request::{KgRequest, SignatureType},
    session::KgSession,
    signer, transport,
};
use base64::Engine;

fn require_login(session: &KgSession) -> AppResult<()> {
    if !session.is_logged_in() {
        return Err(AppError::Unauthorized("此接口需要登录".into()));
    }
    Ok(())
}

pub async fn user_detail(client: &reqwest::Client, session: &KgSession) -> AppResult<Value> {
    require_login(session)?;
    let client_time = chrono::Utc::now().timestamp();
    let pk_data = json!({ "token": session.token, "clienttime": client_time });
    let pk = crypto::rsa_encrypt_no_padding(&pk_data.to_string(), true).to_uppercase();
    let body = json!({
        "visit_time": client_time, "usertype": 1, "p": pk,
        "userid": session.userid.parse::<i64>().unwrap_or(0)
    });
    let req = KgRequest::get("/v3/get_my_info")
        .method(reqwest::Method::POST)
        .base_url(config::DEFAULT_GATEWAY)
        .router("usercenter.kugou.com")
        .param("plat", "1")
        .param("clienttime", client_time.to_string())
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

pub async fn user_vip_detail(client: &reqwest::Client, session: &KgSession) -> AppResult<Value> {
    let req = KgRequest::get("/v1/get_union_vip")
        .base_url("https://kugouvip.kugou.com")
        .param("busi_type", "concept")
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

pub async fn user_playlist(
    client: &reqwest::Client,
    session: &KgSession,
    page: i64,
    pagesize: i64,
) -> AppResult<Value> {
    require_login(session)?;
    let body = json!({
        "userid": session.userid, "token": session.token,
        "total_ver": 979, "type": 2, "page": page, "pagesize": pagesize
    });
    let req = KgRequest::get("/v7/get_all_list")
        .method(reqwest::Method::POST)
        .router("cloudlist.service.kugou.com")
        .param("plat", "1")
        .param("userid", &session.userid)
        .param("token", &session.token)
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn user_history(client: &reqwest::Client, session: &KgSession) -> AppResult<Value> {
    require_login(session)?;
    let body = json!({
        "token": session.token, "userid": session.userid,
        "source_classify": "app", "to_subdivide_sr": 1
    });
    let req = KgRequest::get("/playhistory/v1/get_songs")
        .method(reqwest::Method::POST)
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn user_listen(
    client: &reqwest::Client,
    session: &KgSession,
    list_type: i64,
) -> AppResult<Value> {
    require_login(session)?;
    let client_time = chrono::Utc::now().timestamp();
    let pk_data = json!({ "clienttime": client_time, "token": session.token });
    let p = crypto::rsa_encrypt_no_padding(&pk_data.to_string(), true).to_uppercase();
    let body = json!({
        "t_userid": session.userid, "userid": session.userid,
        "list_type": list_type, "area_code": 1, "cover": 2, "p": p
    });
    let req = KgRequest::get("/v2/get_list")
        .method(reqwest::Method::POST)
        .base_url("https://listenservice.kugou.com")
        .param("plat", "0")
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn user_follow(client: &reqwest::Client, session: &KgSession) -> AppResult<Value> {
    require_login(session)?;
    let client_time = chrono::Utc::now().timestamp();
    let pk_data = json!({ "clienttime": client_time, "token": session.token });
    let p = crypto::rsa_encrypt_no_padding(&pk_data.to_string(), true).to_uppercase();
    let body = json!({
        "merge": 2, "need_iden_type": 1, "ext_params": "k_pic,jumptype,singerid,score",
        "userid": session.userid, "type": 0, "id_type": 0, "p": p
    });
    let req = KgRequest::get("/v4/follow_list")
        .method(reqwest::Method::POST)
        .router("relationuser.kugou.com")
        .param("plat", "1")
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

pub async fn user_cloud(
    client: &reqwest::Client,
    session: &KgSession,
    page: i64,
    pagesize: i64,
) -> AppResult<Value> {
    require_login(session)?;
    let client_time = chrono::Utc::now().timestamp();
    let body = json!({ "page": page, "pagesize": pagesize, "getkmr": 1 });
    let aes = crypto::playlist_aes_encrypt(&body.to_string());
    let p_data = json!({ "aes": aes.temp_key, "uid": session.userid, "token": session.token });
    let p = crypto::rsa_encrypt_pkcs1(&p_data.to_string(), true).to_uppercase();

    let req = KgRequest::get("/v1/get_list")
        .method(reqwest::Method::POST)
        .base_url("https://mcloudservice.kugou.com")
        .param("clienttime", client_time.to_string())
        .param("mid", &session.mid)
        .param("key", signer::calc_login_key(client_time))
        .param("clientver", config::CLIENT_VER)
        .param("appid", config::APP_ID)
        .param("p", p)
        .clear_default_params()
        .not_signature()
        .signature_type(SignatureType::Default);

    let bin = base64::engine::general_purpose::STANDARD
        .decode(&aes.cipher_text)
        .map_err(|e| AppError::Internal(format!("云盘 body 解码失败: {e}")))?;
    let req = req.binary_body(bin);

    let resp = transport::send(client, session, &req).await?;
    if let Some(raw) = resp
        .get("__raw_base64__")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
    {
        if let Ok(dec) =
            serde_json::from_str::<Value>(&crypto::playlist_aes_decrypt(raw, &aes.temp_key))
        {
            return Ok(dec);
        }
    }
    Ok(resp)
}

pub async fn user_cloud_url(
    client: &reqwest::Client,
    session: &KgSession,
    hash: &str,
    album_audio_id: Option<&str>,
    audio_id: Option<&str>,
    name: Option<&str>,
) -> AppResult<Value> {
    let h = hash.to_lowercase();
    const PID: i64 = 20026;
    let req = KgRequest::get("/bsstrackercdngz/v2/query_musicclound_url")
        .param("hash", &h)
        .param("ssa_flag", "is_fromtrack")
        .param("version", "20102")
        .param("ssl", "0")
        .param("album_audio_id", album_audio_id.unwrap_or("0"))
        .param("pid", PID.to_string())
        .param("audio_id", audio_id.unwrap_or("0"))
        .param("kv_id", "2")
        .param("key", signer::calc_cloud_key(&h, PID))
        .param("bucket", "musicclound")
        .param("name", name.unwrap_or(""))
        .param("with_res_tag", "0")
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn user_follow_message(
    client: &reqwest::Client,
    session: &KgSession,
    artist_id: &str,
    pagesize: i64,
) -> AppResult<Value> {
    require_login(session)?;
    let req = KgRequest::get("/msg.mobile/v3/msgtag/history")
        .param("filter", "1")
        .param("maxid", "0")
        .param("pagesize", pagesize.to_string())
        .param("tag", format!("chat:{}_{}", session.userid, artist_id))
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn user_video_collect(
    client: &reqwest::Client,
    session: &KgSession,
    page: i64,
    pagesize: i64,
) -> AppResult<Value> {
    require_login(session)?;
    let body = json!({ "userid": session.userid, "token": session.token, "page": page, "pagesize": pagesize });
    let req = KgRequest::get("/collectservice/v2/collect_list_mixvideo")
        .method(reqwest::Method::POST)
        .param("plat", "1")
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn user_video_love(
    client: &reqwest::Client,
    session: &KgSession,
    pagesize: i64,
) -> AppResult<Value> {
    let req = KgRequest::get("/m.comment.service/v1/get_user_like_video")
        .param("kugouid", &session.userid)
        .param("pagesize", pagesize.to_string())
        .param("load_video_info", "1")
        .param("p", "1")
        .param("plat", "1")
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn favorite_count(
    client: &reqwest::Client,
    session: &KgSession,
    mixsongids: &str,
) -> AppResult<Value> {
    let req = KgRequest::get("/count/v1/audio/mget_collect")
        .param("mixsongids", mixsongids)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn server_now(client: &reqwest::Client, session: &KgSession) -> AppResult<Value> {
    let body = json!({ "token": session.token, "userid": session.userid });
    let req = KgRequest::get("/v1/server_now")
        .method(reqwest::Method::POST)
        .param("plat", "3")
        .router("usercenter.kugou.com")
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}
