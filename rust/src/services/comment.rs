use std::collections::BTreeMap;

use serde_json::Value;

use crate::error::AppResult;
use crate::kugou::{
    config,
    request::{KgRequest, SignatureType},
    session::KgSession,
    transport,
};

const CODE_SONG: &str = config::COMMENT_SONG_CODE;
#[allow(dead_code)]
const CODE_PLAYLIST: &str = config::COMMENT_PLAYLIST_CODE;
#[allow(dead_code)]
const CODE_ALBUM: &str = config::COMMENT_ALBUM_CODE;

fn official(mut params: BTreeMap<String, String>) -> BTreeMap<String, String> {
    params.insert("appid".into(), config::OFFICIAL_APP_ID.into());
    params.insert("clientver".into(), config::OFFICIAL_CLIENT_VER.into());
    params
}

macro_rules! params {
    ($($k:expr => $v:expr),* $(,)?) => {{
        let mut m: BTreeMap<String, String> = BTreeMap::new();
        $( m.insert(($k).into(), ($v).into()); )*
        m
    }};
}

pub async fn music_comments(
    client: &reqwest::Client,
    session: &KgSession,
    mixsongid: &str,
    page: i64,
    pagesize: i64,
    show_classify: i64,
    show_hotword_list: i64,
) -> AppResult<Value> {
    let params = official(params! {
        "mixsongid" => mixsongid,
        "need_show_image" => "1",
        "p" => page.to_string(),
        "pagesize" => pagesize.to_string(),
        "show_classify" => show_classify.to_string(),
        "show_hotword_list" => show_hotword_list.to_string(),
        "extdata" => "0",
        "code" => CODE_SONG,
    });
    send_comment_list(client, session, "/mcomment/v1/cmtlist", params).await
}

#[allow(dead_code)]
pub async fn playlist_comments(
    client: &reqwest::Client,
    session: &KgSession,
    id: &str,
    page: i64,
    pagesize: i64,
    show_classify: i64,
    show_hotword_list: i64,
) -> AppResult<Value> {
    let params = official(params! {
        "childrenid" => id,
        "need_show_image" => "1",
        "p" => page.to_string(),
        "pagesize" => pagesize.to_string(),
        "show_classify" => show_classify.to_string(),
        "show_hotword_list" => show_hotword_list.to_string(),
        "code" => CODE_PLAYLIST,
        "content_type" => "0",
        "tag" => "5",
    });
    send_comment_list(client, session, "/m.comment.service/v1/cmtlist", params).await
}

#[allow(dead_code)]
pub async fn album_comments(
    client: &reqwest::Client,
    session: &KgSession,
    id: &str,
    page: i64,
    pagesize: i64,
    show_classify: i64,
    show_hotword_list: i64,
) -> AppResult<Value> {
    let params = official(params! {
        "childrenid" => id,
        "need_show_image" => "1",
        "p" => page.to_string(),
        "pagesize" => pagesize.to_string(),
        "show_classify" => show_classify.to_string(),
        "show_hotword_list" => show_hotword_list.to_string(),
        "code" => CODE_ALBUM,
    });
    send_comment_list(client, session, "/m.comment.service/v1/cmtlist", params).await
}

#[allow(dead_code)]
pub async fn comment_count(
    client: &reqwest::Client,
    session: &KgSession,
    hash: Option<&str>,
    special_id: Option<&str>,
) -> AppResult<Value> {
    let mut params = params! {
        "appid" => config::OFFICIAL_APP_ID,
        "clientver" => config::OFFICIAL_CLIENT_VER,
        "r" => "comments/getcommentsnum",
        "code" => CODE_SONG,
    };
    if let Some(h) = hash.filter(|s| !s.trim().is_empty()) {
        params.insert("hash".into(), h.into());
    } else if let Some(s) = special_id.filter(|s| !s.trim().is_empty()) {
        params.insert("childrenid".into(), s.into());
    }
    let req = KgRequest::get("/index.php")
        .router("sum.comment.service.kugou.com")
        .signature_type(SignatureType::Web);
    let mut req = req;
    for (k, v) in params {
        req = req.param(k, v);
    }
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub struct FloorCommentsParams<'a> {
    pub special_id: Option<&'a str>,
    pub tid: &'a str,
    pub mixsongid: Option<&'a str>,
    pub resource_type: &'a str,
    pub page: i64,
    pub pagesize: i64,
    pub show_classify: i64,
    pub show_hotword_list: i64,
    pub code: Option<&'a str>,
}

#[allow(dead_code)]
pub async fn floor_comments(
    client: &reqwest::Client,
    session: &KgSession,
    p: &FloorCommentsParams<'_>,
) -> AppResult<Value> {
    let normalized = p.resource_type.to_lowercase();
    let resolved_code =
        p.code
            .filter(|s| !s.trim().is_empty())
            .unwrap_or(match normalized.as_str() {
                "playlist" => CODE_PLAYLIST,
                "album" => CODE_ALBUM,
                _ => CODE_SONG,
            });
    let use_service = normalized == "playlist"
        || normalized == "album"
        || resolved_code == CODE_PLAYLIST
        || resolved_code == CODE_ALBUM;
    let path = if use_service {
        "/m.comment.service/v1/hot_replylist"
    } else {
        "/mcomment/v1/hot_replylist"
    };

    let mut params = official(params! {
        "childrenid" => p.special_id.unwrap_or(""),
        "need_show_image" => "1",
        "p" => p.page.to_string(),
        "pagesize" => p.pagesize.to_string(),
        "show_classify" => p.show_classify.to_string(),
        "show_hotword_list" => p.show_hotword_list.to_string(),
        "code" => resolved_code,
        "tid" => p.tid,
    });
    if let Some(m) = p.mixsongid.filter(|s| !s.trim().is_empty()) {
        params.insert("mixsongid".into(), m.into());
    }

    let mut req = KgRequest::get(path)
        .method(reqwest::Method::POST)
        .signature_type(SignatureType::OfficialAndroid);
    for (k, v) in params {
        req = req.param(k, v);
    }
    transport::send(client, session, &req).await
}

#[allow(dead_code)]
pub async fn music_comment_classify(
    client: &reqwest::Client,
    session: &KgSession,
    mixsongid: &str,
    type_id: &str,
    page: i64,
    pagesize: i64,
    sort: i64,
) -> AppResult<Value> {
    let params = official(params! {
        "mixsongid" => mixsongid,
        "need_show_image" => "1",
        "page" => page.to_string(),
        "pagesize" => pagesize.to_string(),
        "type_id" => type_id,
        "extdata" => "0",
        "code" => CODE_SONG,
        "sort_method" => if sort == 2 { "2" } else { "1" },
    });
    send_comment_list(client, session, "/mcomment/v1/cmt_classify_list", params).await
}

#[allow(dead_code)]
pub async fn music_comment_hotword(
    client: &reqwest::Client,
    session: &KgSession,
    mixsongid: &str,
    hot_word: &str,
    page: i64,
    pagesize: i64,
) -> AppResult<Value> {
    let params = official(params! {
        "mixsongid" => mixsongid,
        "need_show_image" => "1",
        "p" => page.to_string(),
        "pagesize" => pagesize.to_string(),
        "hot_word" => hot_word,
        "extdata" => "0",
        "code" => CODE_SONG,
    });
    send_comment_list(client, session, "/mcomment/v1/get_hot_word", params).await
}

async fn send_comment_list(
    client: &reqwest::Client,
    session: &KgSession,
    path: &str,
    params: BTreeMap<String, String>,
) -> AppResult<Value> {
    let mut req = KgRequest::get(path)
        .method(reqwest::Method::POST)
        .signature_type(SignatureType::OfficialAndroid);
    for (k, v) in params {
        req = req.param(k, v);
    }
    transport::send(client, session, &req).await
}
