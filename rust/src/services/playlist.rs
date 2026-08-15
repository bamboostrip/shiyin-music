use serde_json::{json, Value};

use crate::error::{AppError, AppResult};
use crate::kugou::{
    config, crypto,
    request::{KgRequest, SignatureType},
    session::KgSession,
    signer,
    transport,
};

fn require_login(session: &KgSession) -> AppResult<()> {
    if !session.is_logged_in() {
        return Err(AppError::Unauthorized("歌单写操作需要登录".into()));
    }
    Ok(())
}

pub async fn collect_playlist(
    client: &reqwest::Client,
    session: &KgSession,
    name: &str,
    list_create_gid: &str,
) -> AppResult<Value> {
    require_login(session)?;
    let client_time = chrono::Utc::now().timestamp();
    let body = json!({
        "userid": session.userid, "token": session.token, "total_ver": 0,
        "name": name, "type": 1, "source": 1, "is_pri": 0,
        "list_create_userid": session.userid, "list_create_listid": "1",
        "list_create_gid": list_create_gid, "from_shupinmv": 0
    });
    let req = KgRequest::get("/cloudlist.service/v5/add_list")
        .method(reqwest::Method::POST)
        .param("last_time", client_time.to_string())
        .param("last_area", "gztx")
        .param("userid", &session.userid)
        .param("token", &session.token)
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

pub async fn create_playlist(
    client: &reqwest::Client,
    session: &KgSession,
    name: &str,
    is_pri: i64,
) -> AppResult<Value> {
    require_login(session)?;
    let client_time = chrono::Utc::now().timestamp();
    let body = json!({
        "userid": session.userid, "token": session.token, "total_ver": 0,
        "name": name, "type": 0, "source": 1, "is_pri": is_pri,
        "list_create_userid": session.userid, "list_create_listid": "1",
        "list_create_gid": "", "from_shupinmv": 0
    });
    let req = KgRequest::get("/cloudlist.service/v5/add_list")
        .method(reqwest::Method::POST)
        .param("last_time", client_time.to_string())
        .param("last_area", "gztx")
        .param("userid", &session.userid)
        .param("token", &session.token)
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

pub async fn delete_playlist(
    client: &reqwest::Client,
    session: &KgSession,
    listid: &str,
) -> AppResult<Value> {
    require_login(session)?;
    let client_time = chrono::Utc::now().timestamp();

    let data_map = json!({ "listid": listid.parse::<i64>().unwrap_or(0), "total_ver": 0, "type": 1 });
    let aes = crypto::playlist_aes_encrypt(&data_map.to_string());

    let key_data = json!({ "aes": aes.temp_key, "uid": session.userid, "token": session.token });
    let p = crypto::rsa_encrypt_pkcs1(&key_data.to_string(), true).to_uppercase();

    let sign_key = signer::calc_login_key(client_time);

    let req = KgRequest::get("/v2/delete_list")
        .method(reqwest::Method::POST)
        .param("clienttime", client_time.to_string())
        .param("key", sign_key)
        .param("last_area", "gztx")
        .param("clientver", config::CLIENT_VER)
        .param("appid", config::APP_ID)
        .param("last_time", client_time.to_string())
        .param("p", p)
        .raw_body(aes.cipher_text.clone())
        .router("cloudlist.service.kugou.com")
        .signature_type(SignatureType::Default);

    let resp = transport::send(client, session, &req).await?;

    let encrypted = resp
        .get("__raw_base64__")
        .and_then(|v| v.as_str())
        .or_else(|| resp.get("data").and_then(|v| v.as_str()))
        .or_else(|| resp.as_str());
    if let Some(enc) = encrypted.filter(|s| !s.is_empty()) {
        if let Ok(dec) = serde_json::from_str::<Value>(&crypto::playlist_aes_decrypt(enc, &aes.temp_key)) {
            return Ok(dec);
        }
    }
    Ok(resp)
}

pub async fn add_tracks(
    client: &reqwest::Client,
    session: &KgSession,
    listid: &str,
    songs: &[AddSongItem],
) -> AppResult<Value> {
    require_login(session)?;
    if songs.is_empty() {
        return Err(AppError::Validation("歌曲列表不能为空".into()));
    }
    let client_time = chrono::Utc::now().timestamp();
    let data: Vec<Value> = songs
        .iter()
        .map(|s| json!({
            "number": 1, "name": s.name, "hash": s.hash, "size": 0, "sort": 0,
            "timelen": 0, "bitrate": 0,
            "album_id": s.album_id.parse::<i64>().unwrap_or(0),
            "mixsongid": s.mix_song_id.parse::<i64>().unwrap_or(0)
        }))
        .collect();

    let body = json!({
        "userid": session.userid, "token": session.token, "listid": listid,
        "list_ver": 0, "type": 0, "slow_upload": 1, "scene": "false;null", "data": data
    });
    let req = KgRequest::get("/cloudlist.service/v6/add_song")
        .method(reqwest::Method::POST)
        .param("last_time", client_time.to_string())
        .param("last_area", "gztx")
        .param("userid", &session.userid)
        .param("token", &session.token)
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

pub async fn remove_tracks(
    client: &reqwest::Client,
    session: &KgSession,
    listid: &str,
    file_ids: &[i64],
) -> AppResult<Value> {
    require_login(session)?;
    let data: Vec<Value> = file_ids.iter().map(|fid| json!({ "fileid": fid })).collect();
    let body = json!({
        "listid": listid, "userid": session.userid, "data": data,
        "type": 0, "token": session.token, "list_ver": 0
    });
    let req = KgRequest::get("/v4/delete_songs")
        .method(reqwest::Method::POST)
        .router("cloudlist.service.kugou.com")
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[derive(Debug, serde::Deserialize, serde::Serialize)]
pub struct AddSongItem {
    pub name: String,
    pub hash: String,
    pub album_id: String,
    #[serde(rename = "mixsongid")]
    pub mix_song_id: String,
}

#[allow(dead_code)]
pub async fn sheet_collection(client: &reqwest::Client, session: &KgSession, position: i64) -> AppResult<Value> {
    let req = KgRequest::get("/miniyueku/v1/opern_square/get_home_module_config")
        .param("srcappid", "2919")
        .param("position", position.to_string())
        .signature_type(SignatureType::Web);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn sheet_collection_detail(client: &reqwest::Client, session: &KgSession, collection_id: &str, page: i64) -> AppResult<Value> {
    let req = KgRequest::get("/miniyueku/v1/opern_square/collection_detail")
        .param("srcappid", "2919")
        .param("page", page.to_string())
        .param("collection_id", collection_id)
        .signature_type(SignatureType::Web);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn sheet_detail(client: &reqwest::Client, session: &KgSession, id: &str, source: &str) -> AppResult<Value> {
    let req = KgRequest::get("/v1/opern/detail")
        .base_url("https://miniyueku.kugou.com")
        .param("id", id)
        .param("source", source)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn sheet_hot(client: &reqwest::Client, session: &KgSession, opern_type: i64) -> AppResult<Value> {
    let req = KgRequest::get("/miniyueku/v1/opern_square/get_home_hot_opern")
        .param("srcappid", "2919")
        .param("opern_type", opern_type.to_string())
        .signature_type(SignatureType::Web);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn sheet_list(client: &reqwest::Client, session: &KgSession, album_audio_id: &str, opern_type: i64, page: i64, pagesize: i64) -> AppResult<Value> {
    let req = KgRequest::get("/miniyueku/v1/opern/list")
        .param("album_audio_id", album_audio_id)
        .param("opern_type", opern_type.to_string())
        .param("page", page.to_string())
        .param("pagesize", pagesize.to_string())
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

pub async fn playlist_info(client: &reqwest::Client, session: &KgSession, playlist_id: &str) -> AppResult<Value> {
    let body = json!({
        "data": [{ "global_collection_id": playlist_id }],
        "userid": session.userid, "token": session.token
    });
    let req = KgRequest::get("/v3/get_list_info")
        .method(reqwest::Method::POST)
        .router("pubsongs.kugou.com")
        .json_body(body)
        .signature_type(SignatureType::Default);
    let mut resp = transport::send(client, session, &req).await?;

    if let Some(arr) = resp.as_array_mut() {
        if !arr.is_empty() {
            return Ok(arr.remove(0));
        }
    }
    Ok(resp)
}

#[allow(dead_code)]
pub async fn playlist_tags(client: &reqwest::Client, session: &KgSession) -> AppResult<Value> {
    let body = json!({ "tag_type": "collection", "tag_id": 0, "source": 3 });
    let req = KgRequest::get("/pubsongs/v1/get_tags_by_type")
        .method(reqwest::Method::POST)
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

pub async fn playlist_tracks(client: &reqwest::Client, session: &KgSession, playlist_id: &str, begin_idx: i64, pagesize: i64) -> AppResult<Value> {
    let req = KgRequest::get("/pubsongs/v2/get_other_list_file_nofilt")
        .param("area_code", "1")
        .param("begin_idx", begin_idx.to_string())
        .param("plat", "1")
        .param("type", "1")
        .param("mode", "1")
        .param("personal_switch", "1")
        .param("extend_fields", "abtags,hot_cmt,popularization")
        .param("pagesize", pagesize.to_string())
        .param("global_collection_id", playlist_id)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn playlist_tracks_new(client: &reqwest::Client, session: &KgSession, list_id: &str, page: i64, pagesize: i64) -> AppResult<Value> {
    let body = json!({
        "listid": list_id, "userid": session.userid, "area_code": 1, "show_relate_goods": 0,
        "pagesize": pagesize, "allplatform": 1, "show_cover": 1, "type": 0,
        "token": session.token, "page": page
    });
    let req = KgRequest::get("/v4/get_list_all_file")
        .method(reqwest::Method::POST)
        .router("cloudlist.service.kugou.com")
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

pub async fn playlist_similar(client: &reqwest::Client, session: &KgSession, ids: &str) -> AppResult<Value> {
    let client_time_ms = chrono::Utc::now().timestamp_millis();
    let data: Vec<Value> = ids.split(',').filter(|s| !s.trim().is_empty())
        .map(|id| json!({ "global_collection_id": id.trim() })).collect();
    let body = json!({
        "appid": config::APP_ID, "clientver": config::CLIENT_VER, "clienttime": client_time_ms,
        "key": signer::calc_login_key(client_time_ms), "userid": session.userid,
        "ugc": 1, "show_list": 1, "need_songs": 1, "data": data
    });
    let req = KgRequest::get("/pubsongs/v1/kmr_get_similar_lists")
        .method(reqwest::Method::POST)
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn playlist_effect(client: &reqwest::Client, session: &KgSession, page: i64, pagesize: i64) -> AppResult<Value> {
    let body = json!({ "page": page, "pagesize": pagesize });
    let req = KgRequest::get("/pubsongs/v1/get_sound_effect_list")
        .method(reqwest::Method::POST)
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}
