use std::collections::HashMap;

use serde_json::{json, Value};

use crate::error::{AppError, AppResult};
use crate::kugou::session::KgSession;
use crate::kugou::session_store::FileSessionStore;
use crate::services::{
    album, artist, comment, discover, fm, login, lyric, playlist, rank, report, search, song,
    user, youth,
};

pub struct KugouEngine {
    client: reqwest::Client,
    session: KgSession,
    store: FileSessionStore,
}

impl KugouEngine {
    pub async fn new(data_dir: String) -> Self {
        let _ = rustls::crypto::ring::default_provider().install_default();

        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(15))
            .pool_max_idle_per_host(3)
            .pool_idle_timeout(std::time::Duration::from_secs(10))
            .gzip(true)
            .build()
            .expect("failed to build reqwest client");

        let store = FileSessionStore::new(&data_dir);
        let mut session = store.load().unwrap_or_default();
        session.normalize();
        store.save(&session);

        Self {
            client,
            session,
            store,
        }
    }

    pub async fn request(
        &mut self,
        method: &str,
        path: &str,
        query: &str,
        body: Option<&str>,
    ) -> AppResult<String> {
        let mut params: HashMap<String, String> = if query.is_empty() {
            HashMap::new()
        } else {
            serde_json::from_str(query).unwrap_or_default()
        };

        // 将 body 中的字段也合并到 params，兼容前端通过 body 传参的情况
        if let Some(body_str) = body {
            if let Ok(body_map) = serde_json::from_str::<HashMap<String, Value>>(body_str) {
                for (k, v) in body_map {
                    let val = match v {
                        Value::String(s) => s,
                        other => other.to_string(),
                    };
                    params.entry(k).or_insert(val);
                }
            }
        }

        let result = self.dispatch(method, path, &params, body).await?;
        serde_json::to_string(&result).map_err(|e| AppError::Internal(e.to_string()))
    }

    pub fn set_session_fields(&mut self, userid: &str, token: &str, t1: &str) {
        if userid.is_empty() || token.is_empty() {
            self.session.logout();
        } else {
            self.session.update_auth(userid, token, "", "", t1);
        }
        self.store.save(&self.session);
    }

    async fn dispatch(
        &mut self,
        method: &str,
        path: &str,
        params: &HashMap<String, String>,
        body: Option<&str>,
    ) -> AppResult<Value> {
        let result = self.dispatch_inner(method, path, params, body).await?;

        // 会话失效（status=0 + 20xxx 错误码）时自动刷新 token 并重放一次。
        // 酷狗 token 会在长期未使用 / 多端登录后被上游作废，车机长时间待机后
        // 首次播放/加载歌单常命中此情况；此前只能靠用户手动重新登录恢复。
        // 刷新成功则重放原请求，对用户完全无感；失败则返回原始失败响应。
        if !Self::is_session_invalid_response(&result)
            || path.starts_with("/login/")
            || path.starts_with("/captcha/")
        {
            return Ok(result);
        }
        let refreshed = login::refresh_token(&self.client, "", &self.session).await;
        match refreshed {
            Ok(resp) => {
                self.persist_login(&resp);
                tracing::info!(path, "会话已失效，自动刷新 token 后重试原请求");
                self.dispatch_inner(method, path, params, body).await
            }
            Err(e) => {
                tracing::warn!(path, error = %e, "会话失效且 token 刷新失败，保持原响应");
                Ok(result)
            }
        }
    }

    /// 判断上游响应是否为"会话失效/需要登录"（status=0 + 20xxx 错误码）。
    ///
    /// 实测：/song/url 返回 `{"errcode":20028,"error":"本次请求需要验证","status":0}`，
    /// /user/playlist 返回 `{"error_code":20017,"status":0}`；20xxx 系列均为登录态类错误。
    fn is_session_invalid_response(v: &Value) -> bool {
        if v.get("status").and_then(|s| s.as_i64()) != Some(0) {
            return false;
        }
        let code = v
            .get("error_code")
            .and_then(|c| c.as_i64())
            .or_else(|| v.get("errcode").and_then(|c| c.as_i64()));
        matches!(code, Some(c) if (20000..20100).contains(&c))
    }

    async fn dispatch_inner(
        &mut self,
        method: &str,
        path: &str,
        params: &HashMap<String, String>,
        body: Option<&str>,
    ) -> AppResult<Value> {
        let client = &self.client;
        let session = &self.session;

        match (method, path) {
            ("POST", "/captcha/sent") => {
                let mobile = params.get("mobile").map(|s| s.as_str()).unwrap_or("");
                login::send_sms_code(client, session, mobile).await
            }
            ("POST", "/login/cellphone") => {
                let mobile = params.get("mobile").map(|s| s.as_str()).unwrap_or("");
                let code = params.get("code").map(|s| s.as_str()).unwrap_or("");
                let userid = params.get("userid").map(|s| s.as_str());
                let resp =
                    login::login_by_mobile(client, "", session, mobile, code, userid).await?;
                self.persist_login(&resp);
                Ok(resp)
            }
            ("POST", "/login/token") => {
                let resp = login::refresh_token(client, "", session).await?;
                self.persist_login(&resp);
                Ok(resp)
            }
            ("POST", "/login/logout") => {
                login::logout(client, "", session).await;
                self.session.logout();
                self.store.save(&self.session);
                Ok(json!(null))
            }
            ("GET", "/login/qr/key") => login::get_qr_key(client, session).await,
            ("GET", "/login/qr/check") => {
                let key = params.get("key").map(|s| s.as_str()).unwrap_or("");
                let resp = login::check_qr_status(client, "", session, key).await?;
                self.persist_login(&resp);
                Ok(resp)
            }

            ("GET", "/search") => {
                let keyword = params
                    .get("keywords")
                    .or_else(|| params.get("keyword"))
                    .map(|s| s.as_str())
                    .unwrap_or("");
                let page = params
                    .get("page")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(1i64);
                let pagesize = params
                    .get("pagesize")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(30i64);
                let search_type = params.get("type").map(|s| s.as_str()).unwrap_or("song");
                search::search_raw(client, session, keyword, page, pagesize, search_type).await
            }
            ("GET", "/search/hot") => search::search_hot(client, session).await,
            ("GET", "/search/suggest") => {
                let keyword = params
                    .get("keywords")
                    .or_else(|| params.get("keyword"))
                    .map(|s| s.as_str())
                    .unwrap_or("");
                search::search_suggest(client, session, keyword, 0, 0, 0, 10).await
            }

            ("GET", "/song/url") => {
                let hash = params.get("hash").map(|s| s.as_str()).unwrap_or("");
                let quality = params.get("quality").map(|s| s.as_str());
                let album_id = params.get("album_id").map(|s| s.as_str());
                let album_audio_id = params.get("album_audio_id").map(|s| s.as_str());
                let free_part = params
                    .get("free_part")
                    .map(|s| s == "1" || s == "true")
                    .unwrap_or(false);
                song::get_play_url(client, session, hash, quality, album_id, album_audio_id, free_part)
                    .await
            }

            ("GET", "/search/lyric") => {
                let hash = params.get("hash").map(|s| s.as_str());
                let album_audio_id = params.get("album_audio_id").map(|s| s.as_str());
                let keyword = params.get("keyword").map(|s| s.as_str());
                let man = params.get("man").map(|s| s.as_str());
                lyric::search_lyric(client, session, hash, album_audio_id, keyword, man).await
            }
            ("GET", "/lyric") => {
                let id = params.get("id").map(|s| s.as_str()).unwrap_or("");
                let accesskey = params.get("accesskey").map(|s| s.as_str()).unwrap_or("");
                let fmt = params.get("fmt").map(|s| s.as_str()).unwrap_or("krc");
                let decode = params
                    .get("decode")
                    .map(|s| s != "0" && s != "false")
                    .unwrap_or(true);
                lyric::get_lyric(client, session, id, accesskey, fmt, decode).await
            }

            ("GET", "/user/detail") => user::user_detail(client, session).await,
            ("GET", "/user/playlist") => {
                let page = params
                    .get("page")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(1i64);
                let pagesize = params
                    .get("pagesize")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(30i64);
                user::user_playlist(client, session, page, pagesize).await
            }
            ("GET", "/user/cloud") => {
                let page = params
                    .get("page")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(1i64);
                let pagesize = params
                    .get("pagesize")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(30i64);
                user::user_cloud(client, session, page, pagesize).await
            }
            ("GET", "/user/cloud/url") => {
                let hash = params.get("hash").map(|s| s.as_str()).unwrap_or("");
                let album_audio_id = params.get("album_audio_id").map(|s| s.as_str());
                let audio_id = params.get("audio_id").map(|s| s.as_str());
                let name = params.get("name").map(|s| s.as_str());
                user::user_cloud_url(client, session, hash, album_audio_id, audio_id, name).await
            }

            ("GET", "/top/playlist") => {
                let category_id = params
                    .get("category_id")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0i64);
                let page = params
                    .get("page")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(1i64);
                discover::recommend_playlists(client, session, category_id, page).await
            }
            ("GET", "/top/song") => {
                let rank_id = params
                    .get("rank_id")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0i64);
                let page = params
                    .get("page")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(1i64);
                discover::new_songs(client, session, rank_id, page).await
            }
            ("GET", "/top/album") => {
                let page = params
                    .get("page")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(1i64);
                let pagesize = params
                    .get("pagesize")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(30i64);
                discover::top_album(client, session, page, pagesize).await
            }
            ("GET", "/recommend/songs") => discover::recommend_songs(client, session).await,
            ("GET", "/ai/recommend") => {
                let album_audio_ids =
                    params.get("album_audio_ids").map(|s| s.as_str()).unwrap_or("");
                discover::ai_recommend(client, session, album_audio_ids).await
            }
            ("GET", "/personal/fm") => {
                let hash = params.get("hash").map(|s| s.as_str());
                let songid = params.get("songid").map(|s| s.as_str());
                let playtime = params.get("playtime").and_then(|s| s.parse().ok());
                let action = params.get("action").map(|s| s.as_str()).unwrap_or("refresh");
                let mode = params.get("mode").map(|s| s.as_str()).unwrap_or("normal");
                let song_pool_id = params
                    .get("song_pool_id")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0i64);
                let is_overplay = params
                    .get("is_overplay")
                    .map(|s| s == "1" || s == "true")
                    .unwrap_or(false);
                let remain_song_cnt = params
                    .get("remain_song_cnt")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0i64);
                discover::personal_fm(
                    client,
                    session,
                    hash,
                    songid,
                    playtime,
                    action,
                    mode,
                    song_pool_id,
                    is_overplay,
                    remain_song_cnt,
                )
                .await
            }

            ("GET", "/rank/list") => {
                let withsong = params
                    .get("withsong")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0i64);
                rank::rank_list(client, session, withsong).await
            }
            ("GET", "/rank/info") => {
                let rankid = params
                    .get("rankid")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0i64);
                let rank_cid = params
                    .get("rank_cid")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0i64);
                let album_img = params
                    .get("album_img")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(1i64);
                let zone = params.get("zone").map(|s| s.as_str()).unwrap_or("");
                rank::rank_info(client, session, rankid, rank_cid, album_img, zone).await
            }
            ("GET", "/rank/audio") => {
                let rankid = params
                    .get("rankid")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0i64);
                let rank_cid = params
                    .get("rank_cid")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0i64);
                let page = params
                    .get("page")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(1i64);
                let pagesize = params
                    .get("pagesize")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(30i64);
                rank::rank_audio(client, session, rankid, rank_cid, page, pagesize).await
            }
            ("GET", "/rank/top") => rank::rank_top(client, session).await,

            ("GET", "/album/shop") => album::album_shop(client, session).await,
            ("GET", "/album/songs") => {
                let album_id = params.get("album_id").map(|s| s.as_str()).unwrap_or("");
                let page = params
                    .get("page")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(1i64);
                let pagesize = params
                    .get("pagesize")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(30i64);
                album::album_songs(client, session, album_id, page, pagesize).await
            }

            ("GET", "/fm/recommend") => fm::fm_recommend(client, session).await,
            ("GET", "/fm/songs") => {
                let fm_ids = params.get("fm_ids").map(|s| s.as_str()).unwrap_or("");
                let fmtype = params
                    .get("fmtype")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(2i64);
                let offset = params
                    .get("offset")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(0i64);
                let size = params
                    .get("size")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(30i64);
                fm::fm_songs(client, session, fm_ids, fmtype, offset, size).await
            }
            ("GET", "/fm/class") => fm::fm_class(client, session).await,
            ("GET", "/fm/image") => {
                let fm_ids = params.get("fm_ids").map(|s| s.as_str()).unwrap_or("");
                fm::fm_image(client, session, fm_ids).await
            }

            ("GET", "/playlist/detail") => {
                // Dart: ids；兼容 id
                let id = params
                    .get("ids")
                    .or_else(|| params.get("id"))
                    .map(|s| s.as_str())
                    .unwrap_or("");
                playlist::playlist_info(client, session, id).await
            }
            ("GET", "/playlist/track/all") => {
                let id = params.get("id").map(|s| s.as_str()).unwrap_or("");
                let pagesize = params
                    .get("pagesize")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(30i64);
                // 酷狗接口用 begin_idx（起始下标），.NET: beginIdx = (page-1)*pageSize
                // Dart 传 page；兼容直接传 begin_idx
                let begin_idx = params
                    .get("begin_idx")
                    .and_then(|s| s.parse().ok())
                    .or_else(|| {
                        params.get("page").and_then(|s| s.parse::<i64>().ok()).map(|page| {
                            let p = if page < 1 { 1 } else { page };
                            (p - 1) * pagesize
                        })
                    })
                    .unwrap_or(0i64);
                playlist::playlist_tracks(client, session, id, begin_idx, pagesize).await
            }
            ("POST", "/playlist/create") => {
                // Dart 走 query: name / type；兼容 body: name / is_pri
                let body_val: Value =
                    serde_json::from_str(body.unwrap_or("{}")).unwrap_or_default();
                let name = first_str(
                    &[&body_val],
                    params,
                    &["name"],
                )
                .unwrap_or_else(|| "新歌单".into());
                let is_pri = first_i64(&[&body_val], params, &["is_pri", "type"]).unwrap_or(0);
                playlist::create_playlist(client, session, &name, is_pri).await
            }
            ("POST", "/playlist/add") => {
                // Dart 走 query: name / list_create_gid
                let body_val: Value =
                    serde_json::from_str(body.unwrap_or("{}")).unwrap_or_default();
                let name = first_str(&[&body_val], params, &["name"]).unwrap_or_default();
                let global_collection_id = first_str(
                    &[&body_val],
                    params,
                    &["list_create_gid", "global_collection_id"],
                )
                .unwrap_or_default();
                playlist::collect_playlist(client, session, &name, &global_collection_id).await
            }
            ("POST", "/playlist/del") => {
                // Dart 走 query: listid
                let body_val: Value =
                    serde_json::from_str(body.unwrap_or("{}")).unwrap_or_default();
                let listid =
                    first_str(&[&body_val], params, &["listid", "listId"]).unwrap_or_default();
                playlist::delete_playlist(client, session, &listid).await
            }
            ("POST", "/playlist/tracks/add") => {
                // Dart body: { listId, songs: [{ name, hash, albumId, mixSongId }] }
                let body_val: Value =
                    serde_json::from_str(body.unwrap_or("{}")).unwrap_or_default();
                let listid =
                    first_str(&[&body_val], params, &["listId", "listid"]).unwrap_or_default();
                let songs = parse_add_songs(body_val.get("songs"));
                playlist::add_tracks(client, session, &listid, &songs).await
            }
            ("POST", "/playlist/tracks/del") => {
                // Dart: query listid + fileids（逗号分隔）；兼容 body listid + file_ids 数组
                let body_val: Value =
                    serde_json::from_str(body.unwrap_or("{}")).unwrap_or_default();
                let listid =
                    first_str(&[&body_val], params, &["listid", "listId"]).unwrap_or_default();
                let file_ids = parse_file_ids(&body_val, params);
                playlist::remove_tracks(client, session, &listid, &file_ids).await
            }

            ("GET", "/artist/detail") => {
                let id = params.get("id").map(|s| s.as_str()).unwrap_or("");
                artist::artist_detail(client, session, id).await
            }
            ("GET", "/artist/audios") => {
                let id = params.get("id").map(|s| s.as_str()).unwrap_or("");
                let page = params
                    .get("page")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(1i64);
                let pagesize = params
                    .get("pagesize")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(30i64);
                let sort = params.get("sort").map(|s| s.as_str()).unwrap_or("hot");
                artist::artist_audios(client, session, id, page, pagesize, sort).await
            }

            ("GET", "/comment/music") => {
                let mixsongid = params.get("mixsongid").map(|s| s.as_str()).unwrap_or("");
                let page = params
                    .get("page")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(1i64);
                let pagesize = params
                    .get("pagesize")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(20i64);
                let show_classify = params
                    .get("show_classify")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(1i64);
                let show_hotword_list = params
                    .get("show_hotword_list")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(1i64);
                comment::music_comments(
                    client,
                    session,
                    mixsongid,
                    page,
                    pagesize,
                    show_classify,
                    show_hotword_list,
                )
                .await
            }

            ("GET", "/user/vip/detail") => user::user_vip_detail(client, session).await,
            ("GET", "/youth/month/vip/record") => youth::month_vip_record(client, session).await,
            ("GET", "/youth/day/vip") => youth::receive_one_day_vip(client, session).await,
            ("GET", "/youth/day/vip/upgrade") => youth::upgrade_vip(client, session).await,

            ("POST", "/listen/timeadd") => report::listen_time_add(client, session).await,

            _ => Err(AppError::Other(format!(
                "Unknown route: {} {}",
                method, path
            ))),
        }
    }

    fn persist_login(&mut self, resp: &Value) {
        let userid = resp
            .get("userid")
            .and_then(|v| v.as_i64().map(|i| i.to_string()).or_else(|| v.as_str().map(|s| s.to_string())))
            .unwrap_or_default();
        let token = resp
            .get("token")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        if userid.is_empty() || userid == "0" || token.is_empty() {
            return;
        }
        let vip_type = resp
            .get("vip_type")
            .and_then(|v| v.as_i64().map(|i| i.to_string()).or_else(|| v.as_str().map(|s| s.to_string())))
            .unwrap_or_else(|| "0".to_string());
        let vip_token = resp
            .get("vip_token")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        let t1 = resp
            .get("t1")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        self.session
            .update_auth(&userid, token, &vip_type, vip_token, t1);
        self.store.save(&self.session);
    }
}

fn first_str(
    bodies: &[&Value],
    params: &HashMap<String, String>,
    keys: &[&str],
) -> Option<String> {
    for key in keys {
        for body in bodies {
            if let Some(v) = body.get(*key) {
                if let Some(s) = v.as_str() {
                    if !s.is_empty() {
                        return Some(s.to_string());
                    }
                }
                if let Some(n) = v.as_i64() {
                    return Some(n.to_string());
                }
                if let Some(n) = v.as_u64() {
                    return Some(n.to_string());
                }
            }
        }
        if let Some(s) = params.get(*key) {
            if !s.is_empty() {
                return Some(s.clone());
            }
        }
    }
    None
}

fn first_i64(
    bodies: &[&Value],
    params: &HashMap<String, String>,
    keys: &[&str],
) -> Option<i64> {
    for key in keys {
        for body in bodies {
            if let Some(v) = body.get(*key) {
                if let Some(n) = v.as_i64() {
                    return Some(n);
                }
                if let Some(s) = v.as_str() {
                    if let Ok(n) = s.parse::<i64>() {
                        return Some(n);
                    }
                }
            }
        }
        if let Some(s) = params.get(*key) {
            if let Ok(n) = s.parse::<i64>() {
                return Some(n);
            }
        }
    }
    None
}

/// 兼容 Dart camelCase payload 与 Rust snake_case 字段。
fn parse_add_songs(raw: Option<&Value>) -> Vec<playlist::AddSongItem> {
    let Some(arr) = raw.and_then(|v| v.as_array()) else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|item| {
            let name = item
                .get("name")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let hash = item
                .get("hash")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            if name.is_empty() || hash.is_empty() {
                return None;
            }
            let album_id = item
                .get("albumId")
                .or_else(|| item.get("album_id"))
                .map(value_to_string)
                .unwrap_or_default();
            let mix_song_id = item
                .get("mixSongId")
                .or_else(|| item.get("mixsongid"))
                .or_else(|| item.get("mix_song_id"))
                .map(value_to_string)
                .unwrap_or_default();
            Some(playlist::AddSongItem {
                name,
                hash,
                album_id,
                mix_song_id,
            })
        })
        .collect()
}

fn parse_file_ids(body: &Value, params: &HashMap<String, String>) -> Vec<i64> {
    if let Some(arr) = body
        .get("file_ids")
        .or_else(|| body.get("fileids"))
        .and_then(|v| v.as_array())
    {
        return arr
            .iter()
            .filter_map(|v| {
                v.as_i64()
                    .or_else(|| v.as_str().and_then(|s| s.parse().ok()))
            })
            .collect();
    }
    let raw = params
        .get("fileids")
        .or_else(|| params.get("file_ids"))
        .cloned()
        .or_else(|| {
            body.get("fileids")
                .or_else(|| body.get("file_ids"))
                .and_then(|v| v.as_str().map(|s| s.to_string()))
        })
        .unwrap_or_default();
    raw.split(',')
        .filter_map(|s| s.trim().parse::<i64>().ok())
        .collect()
}

fn value_to_string(v: &Value) -> String {
    if let Some(s) = v.as_str() {
        return s.to_string();
    }
    if let Some(n) = v.as_i64() {
        return n.to_string();
    }
    if let Some(n) = v.as_u64() {
        return n.to_string();
    }
    String::new()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn session_invalid_detection() {
        // 实测形态：/song/url 用失效 token
        assert!(KugouEngine::is_session_invalid_response(&json!({
            "errcode": 20028, "error": "本次请求需要验证", "status": 0
        })));
        // 实测形态：/user/playlist 用失效 token
        assert!(KugouEngine::is_session_invalid_response(&json!({
            "error_code": 20017, "status": 0
        })));
        // 成功响应不应误判
        assert!(!KugouEngine::is_session_invalid_response(&json!({
            "status": 1, "error_code": 0, "url": "https://example.com/a.mp3"
        })));
        // 非登录类错误码不应触发刷新
        assert!(!KugouEngine::is_session_invalid_response(&json!({
            "status": 0, "error_code": 9001, "err": "缺参"
        })));
        // 缺 status 或 status 非 0 不应触发
        assert!(!KugouEngine::is_session_invalid_response(&json!({
            "error_code": 20017
        })));
        assert!(!KugouEngine::is_session_invalid_response(&json!({
            "status": 2, "error_code": 20017
        })));
        // 无错误码时不应触发
        assert!(!KugouEngine::is_session_invalid_response(&json!({
            "status": 0, "msg": "服务内部错误"
        })));
    }
}
