use serde::{Deserialize, Serialize};

use crate::error::AppResult;

#[derive(Debug, Serialize, Deserialize)]
/// 序列化输出与上游 Dart `ExternalPlaylistParseResult` 对齐：
/// sourcePlatform / playlistName / songNames（Dart 只消费这三个字段）。
/// 注意 `source_playlist_name` 要映射为 `playlistName`（而非 sourcePlaylistName），
/// 因此用显式 rename，不能用 rename_all="camelCase" 一揽子转换。
pub struct ExternalPlaylistResult {
    pub success: bool,
    #[serde(rename = "errorMessage")]
    pub error_message: String,
    #[serde(rename = "sourcePlatform")]
    pub source_platform: String,
    #[serde(rename = "playlistName")]
    pub source_playlist_name: String,
    #[serde(rename = "songNames")]
    pub song_names: Vec<String>,
}

impl ExternalPlaylistResult {
    fn err(msg: impl Into<String>) -> Self {
        Self {
            success: false,
            error_message: msg.into(),
            source_platform: String::new(),
            source_playlist_name: String::new(),
            song_names: vec![],
        }
    }
    fn ok(platform: impl Into<String>, name: impl Into<String>, songs: Vec<String>) -> Self {
        Self {
            success: true,
            error_message: String::new(),
            source_platform: platform.into(),
            source_playlist_name: name.into(),
            song_names: songs,
        }
    }
}

pub async fn parse(client: &reqwest::Client, source_text: &str) -> AppResult<ExternalPlaylistResult> {
    if source_text.trim().is_empty() {
        return Ok(ExternalPlaylistResult::err("链接不能为空。"));
    }
    let url = extract_url(source_text);
    let parsed_url = match url::Url::parse(&url) {
        Ok(u) => u,
        Err(_) => return Ok(ExternalPlaylistResult::err("链接格式不正确。")),
    };
    let host = parsed_url.host_str().unwrap_or("").to_lowercase();

    if host.ends_with("music.163.com") || host == "y.music.163.com" || host == "163cn.tv" {
        Ok(netease::parse(client, parsed_url).await)
    } else if host.contains("y.qq.com") || host.contains("qqmusic.qq.com") || host.contains("music.qq.com") || host.contains("c.y.qq.com") {
        Ok(qq::parse(client, parsed_url).await)
    } else {
        Ok(ExternalPlaylistResult::err("暂只支持网易云和QQ音乐歌单链接。"))
    }
}

fn extract_url(text: &str) -> String {
    let re = regex::Regex::new(r"(?i)https?://[^\s]+").unwrap();
    match re.find(text) {
        Some(m) => m.as_str().trim().to_string(),
        None => text.trim().to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 输出字段必须为 camelCase，与上游 Dart ExternalPlaylistParseResult
    /// （sourcePlatform / playlistName / songNames）一致。
    #[test]
    fn result_serializes_camel_case() {
        let r = ExternalPlaylistResult::ok(
            "网易云",
            "我的歌单",
            vec!["歌一".to_string(), "歌二".to_string()],
        );
        let v = serde_json::to_value(&r).unwrap();
        assert_eq!(v["sourcePlatform"], "网易云");
        assert_eq!(v["playlistName"], "我的歌单");
        assert_eq!(v["songNames"], serde_json::json!(["歌一", "歌二"]));
        assert_eq!(v["success"], true);
        assert!(v.get("source_platform").is_none());
        assert!(v.get("playlistName_error").is_none());
    }

    #[test]
    fn error_result_has_error_message() {
        let r = ExternalPlaylistResult::err("链接不能为空。");
        let v = serde_json::to_value(&r).unwrap();
        assert_eq!(v["success"], false);
        assert_eq!(v["errorMessage"], "链接不能为空。");
        assert_eq!(v["songNames"], serde_json::json!([]));
    }

    #[test]
    fn extract_url_finds_http_link_in_text() {
        let text = "分享歌单 https://music.163.com/playlist?id=123 快来听";
        assert_eq!(
            extract_url(text),
            "https://music.163.com/playlist?id=123"
        );
        assert_eq!(extract_url("not a url"), "not a url");
    }
}

mod netease {
    use super::ExternalPlaylistResult;

    const PLAYLIST_DETAIL_API: &str = "https://music.163.com/api/v6/playlist/detail";
    const SONG_DETAIL_API: &str = "https://music.163.com/api/v3/song/detail";
    const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0 Safari/537.36";

    pub async fn parse(client: &reqwest::Client, uri: url::Url) -> ExternalPlaylistResult {
        let resolved = resolve_short_link(client, uri.clone()).await;
        let playlist_id = match extract_playlist_id(&resolved) {
            Some(id) => id,
            None => return ExternalPlaylistResult::err("未在网易云链接中解析到歌单ID。"),
        };

        let form = [("id", playlist_id.as_str())];
        let resp = match client
            .post(PLAYLIST_DETAIL_API)
            .header("Referer", "https://music.163.com/")
            .header("User-Agent", UA)
            .form(&form)
            .send()
            .await
        {
            Ok(r) => r,
            Err(e) => return ExternalPlaylistResult::err(format!("解析网易云歌单失败：{e}")),
        };
        let body: serde_json::Value = match resp.json().await {
            Ok(v) => v,
            Err(e) => return ExternalPlaylistResult::err(format!("网易云响应格式异常：{e}")),
        };

        let playlist = match body.get("playlist") {
            Some(p) => p,
            None => return ExternalPlaylistResult::err("网易云响应格式异常，未找到歌单信息。"),
        };
        let name = playlist.get("name").and_then(|v| v.as_str()).unwrap_or("导入歌单").to_string();

        let track_ids: Vec<i64> = playlist
            .get("trackIds")
            .and_then(|v| v.as_array())
            .map(|arr| arr.iter().filter_map(|t| t.get("id").and_then(|i| i.as_i64())).collect())
            .unwrap_or_default();

        let songs = if !track_ids.is_empty() {
            load_song_names(client, &track_ids).await
        } else {
            playlist
                .get("tracks")
                .and_then(|v| v.as_array())
                .map(|arr| arr.iter().filter_map(|t| t.get("name").and_then(|n| n.as_str()).map(|s| s.trim().to_string())).filter(|s| !s.is_empty()).collect())
                .unwrap_or_default()
        };

        let mut seen = std::collections::HashSet::new();
        let songs: Vec<String> = songs.into_iter().filter(|s| !s.is_empty() && seen.insert(s.clone())).collect();
        if songs.is_empty() {
            return ExternalPlaylistResult::err("网易云歌单未解析到歌曲名称，可能是私密歌单或接口受限。");
        }
        ExternalPlaylistResult::ok("网易云", name, songs)
    }

    async fn resolve_short_link(client: &reqwest::Client, uri: url::Url) -> url::Url {
        if uri.host_str().map(|h| h.eq_ignore_ascii_case("163cn.tv")).unwrap_or(false) {
            if let Ok(resp) = client.get(uri.as_str()).send().await {
                if let Ok(loc) = resp.url().as_str().parse() {
                    return loc;
                }
            }
        }
        uri
    }

    fn extract_playlist_id(uri: &url::Url) -> Option<String> {
        if let Some((_, id)) = uri.query_pairs().find(|(k, _)| k == "id") {
            if !id.is_empty() {
                return Some(id.into_owned());
            }
        }
        if let Some(frag) = uri.fragment() {
            let f = frag.trim_start_matches('/');
            if let Some(q_idx) = f.find('?') {
                let fq = &f[q_idx + 1..];
                if let Some((_, id)) = url::form_urlencoded::parse(fq.as_bytes()).find(|(k, _)| k == "id") {
                    if !id.is_empty() {
                        return Some(id.into_owned());
                    }
                }
            }
        }
        let full = uri.to_string();
        let re = regex::Regex::new(r"(?i)(?:playlist|songlist)\?id=(\d+)").unwrap();
        re.captures(&full).map(|c| c[1].to_string())
    }

    async fn load_song_names(client: &reqwest::Client, track_ids: &[i64]) -> Vec<String> {
        let mut songs = Vec::with_capacity(track_ids.len());
        for chunk in track_ids.chunks(400) {
            let payload = format!(
                "[{}]",
                chunk.iter().map(|id| format!("{{\"id\":{id}}}")).collect::<Vec<_>>().join(",")
            );
            let form = [("c", payload.as_str())];
            let resp = match client.post(SONG_DETAIL_API).header("Referer", "https://music.163.com/").header("User-Agent", UA).form(&form).send().await {
                Ok(r) => r,
                Err(_) => continue,
            };
            let body: serde_json::Value = match resp.json().await {
                Ok(v) => v,
                Err(_) => continue,
            };
            if let Some(arr) = body.get("songs").and_then(|v| v.as_array()) {
                for s in arr {
                    if let Some(name) = s.get("name").and_then(|n| n.as_str()) {
                        let n = name.trim();
                        if !n.is_empty() {
                            songs.push(n.to_string());
                        }
                    }
                }
            }
        }
        songs
    }
}

mod qq {
    use super::ExternalPlaylistResult;

    const QQ_API: &str = "https://u6.y.qq.com/cgi-bin/musics.fcg";
    const PAGE_SIZE: i64 = 30;
    const MAX_SONGS: i64 = 10000;
    const PLATFORMS: &[&str] = &["-1", "android", "iphone", "h5", "wxfshare", "iphone_wx", "windows"];

    pub async fn parse(client: &reqwest::Client, uri: url::Url) -> ExternalPlaylistResult {
        let playlist_id = match extract_playlist_id(&uri) {
            Some(id) if id > 0 => id,
            _ => return ExternalPlaylistResult::err("未在QQ音乐链接中解析到歌单ID。"),
        };

        let first = match fetch_page(client, playlist_id, 0, PAGE_SIZE).await {
            Some(p) => p,
            None => return ExternalPlaylistResult::err("QQ音乐歌单数据获取失败，请稍后重试。"),
        };
        if first.song_names.is_empty() && first.total <= 0 {
            return ExternalPlaylistResult::err("QQ音乐歌单数据获取失败，请稍后重试。");
        }
        let playlist_name = if first.title.is_empty() { "导入歌单".to_string() } else { first.title.clone() };
        let total = first.total.min(MAX_SONGS);

        let mut all = first.song_names;
        let page_count = (total + PAGE_SIZE - 1) / PAGE_SIZE;
        for page in 1..page_count {
            let begin = page * PAGE_SIZE;
            let num = PAGE_SIZE.min(total - begin).max(0);
            if num <= 0 {
                break;
            }
            if let Some(p) = fetch_page(client, playlist_id, begin, num).await {
                all.extend(p.song_names);
            }
        }

        let mut seen = std::collections::HashSet::new();
        let all: Vec<String> = all.into_iter().filter(|s| !s.is_empty() && seen.insert(s.clone())).collect();
        if all.is_empty() {
            return ExternalPlaylistResult::err("QQ音乐歌单未解析到歌曲名称。");
        }
        let _ = total;
        ExternalPlaylistResult::ok("QQ音乐", playlist_name, all)
    }

    fn extract_playlist_id(uri: &url::Url) -> Option<i64> {
        let full = uri.to_string();
        let re_path = regex::Regex::new(r"(?i)playlist/(\d+)").unwrap();
        if let Some(c) = re_path.captures(&full) {
            if let Ok(id) = c[1].parse() {
                return Some(id);
            }
        }
        if let Some((_, id)) = uri.query_pairs().find(|(k, _)| k == "id") {
            if let Ok(v) = id.parse() {
                return Some(v);
            }
        }
        let re_id = regex::Regex::new(r"(?i)[?&]id=(\d+)").unwrap();
        re_id.captures(&full).and_then(|c| c[1].parse().ok())
    }

    struct PageData {
        title: String,
        total: i64,
        song_names: Vec<String>,
    }

    async fn fetch_page(client: &reqwest::Client, playlist_id: i64, begin: i64, num: i64) -> Option<PageData> {
        for platform in PLATFORMS {
            let body = build_request_json(playlist_id, platform, begin, num);
            let sign = build_qq_sign(&body);
            let url = format!("{QQ_API}?sign={sign}&_={}", chrono::Utc::now().timestamp_millis());
            let resp = match client.post(&url).header("Content-Type", "application/x-www-form-urlencoded").body(body.clone()).send().await {
                Ok(r) => r,
                Err(_) => continue,
            };
            if !resp.status().is_success() {
                continue;
            }
            let text = resp.text().await.ok()?;
            if let Some(parsed) = parse_page(&text) {
                return Some(parsed);
            }
        }
        None
    }

    fn parse_page(json: &str) -> Option<PageData> {
        let root: serde_json::Value = serde_json::from_str(json).ok()?;
        if root.get("code").and_then(|v| v.as_i64()) != Some(0) {
            return None;
        }
        let data = root.get("req_0")?.get("data")?;
        let (title, total) = if let Some(dirinfo) = data.get("dirinfo") {
            (
                dirinfo.get("title").and_then(|v| v.as_str()).unwrap_or("").to_string(),
                dirinfo.get("songnum").and_then(|v| v.as_i64()).unwrap_or(0),
            )
        } else {
            (String::new(), 0)
        };
        let songs = data
            .get("songlist")
            .and_then(|v| v.as_array())
            .map(|arr| arr.iter().filter_map(|s| s.get("name").and_then(|n| n.as_str()).map(|n| n.trim().to_string()).filter(|n| !n.is_empty())).collect())
            .unwrap_or_default();
        Some(PageData { title, total, song_names: songs })
    }

    fn build_request_json(playlist_id: i64, platform: &str, begin: i64, num: i64) -> String {
        format!(
            r#"{{"req_0":{{"module":"music.srfDissInfo.aiDissInfo","method":"uniform_get_Dissinfo","param":{{"disstid":{playlist_id},"enc_host_uin":"","tag":1,"userinfo":1,"song_begin":{begin},"song_num":{num}}}}},"comm":{{"g_tk":5381,"uin":0,"format":"json","platform":"{platform}"}}}}"#
        )
    }

    fn build_qq_sign(param: &str) -> String {
        let l1 = [212, 45, 80, 68, 195, 163, 163, 203, 157, 220, 254, 91, 204, 79, 104, 6];
        const T: &str = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=";

        let md5_bytes = md5_upper(param);
        let t1 = select_chars(&md5_bytes, &[21, 4, 9, 26, 16, 20, 27, 30]);
        let t3 = select_chars(&md5_bytes, &[18, 11, 3, 2, 1, 7, 6, 25]);

        let mut ls2 = Vec::with_capacity(16);
        for (i, &l1v) in l1.iter().enumerate() {
            let x1 = hex_value(md5_bytes.as_bytes()[i * 2]);
            let x2 = hex_value(md5_bytes.as_bytes()[i * 2 + 1]);
            ls2.push((x1 * 16) ^ x2 ^ l1v);
        }

        let bytes: Vec<char> = T.chars().collect();
        let mut ls3 = String::new();
        for i in 0..6 {
            if i == 5 {
                ls3.push(bytes[(ls2[15] >> 2) as usize]);
                ls3.push(bytes[((ls2[15] & 3) << 4) as usize]);
            } else {
                let x4 = ls2[i * 3] >> 2;
                let x5 = (ls2[i * 3 + 1] >> 4) ^ ((ls2[i * 3] & 3) << 4);
                let x6 = (ls2[i * 3 + 2] >> 6) ^ ((ls2[i * 3 + 1] & 15) << 2);
                let x7 = 63 & ls2[i * 3 + 2];
                ls3.push(bytes[x4 as usize]);
                ls3.push(bytes[x5 as usize]);
                ls3.push(bytes[x6 as usize]);
                ls3.push(bytes[x7 as usize]);
            }
        }
        let t2 = ls3.chars().filter(|&c| c != '/' && c != '+').collect::<String>();
        format!("zzb{}", (t1 + &t2 + &t3).to_lowercase())
    }

    fn md5_upper(input: &str) -> String {
        crate::kugou::crypto::md5_str(input).to_uppercase()
    }

    fn select_chars(source: &str, indexes: &[usize]) -> String {
        let chars: Vec<char> = source.chars().collect();
        indexes.iter().map(|&i| chars[i]).collect()
    }

    fn hex_value(c: u8) -> i64 {
        match c {
            b'0'..=b'9' => (c - b'0') as i64,
            b'A'..=b'F' => (c - b'A' + 10) as i64,
            b'a'..=b'f' => (c - b'a' + 10) as i64,
            _ => 0,
        }
    }
}
