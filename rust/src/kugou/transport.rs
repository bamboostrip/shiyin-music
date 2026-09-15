//! 上游传输层 —— 对应 .NET 的 `KgSignatureHandler`（注入逻辑）+ `KgHttpTransport`（发送）。
//!
//! 这是整个代理的"心脏"：把一个 [`KgRequest`]（描述要怎么打酷狗）加上
//! **设备身份 / 默认参数 / 签名 / 反风控 header**，真正发出去并拿回 JSON。
//!
//! 注入顺序严格对齐 .NET（错一步签名就废）：
//! 1. 解析设备身份 dfid → mid → uuid（dfid 优先级：override > specific > session）
//! 2. 注入默认参数 appid/clientver/dfid/mid/uuid/userid/clienttime/token（除非 clear_default_params）
//! 3. V5 端点额外加 `key` 参数（md5(hash+V5KeySalt+AppId+mid+userid)）
//! 4. 重建 POST body（JSON / raw / binary）作为签名输入
//! 5. 按 SignatureType 计算签名，写入 params["signature"]
//! 6. 用合并后的参数重写查询串
//! 7. 注入 header：x-router / User-Agent / dfid / mid / clienttime / kg-rc / kg-thash / kg-rec / kg-rf
//! 8. 发送，读响应字节，解析为 JSON

use std::collections::BTreeMap;
use std::time::{SystemTime, UNIX_EPOCH};

use reqwest::{Client, Method};

use crate::error::{AppError, AppResult};
use crate::kugou::{
    api_response, config,
    request::{KgRequest, SignatureType},
    session::KgSession,
    signer,
};

/// 当前 Unix 秒。供注入 clienttime（秒）用。
pub fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// 把合并后的参数编码为查询串：`k1=v1&k2=v2`，value 做 RFC3986 转义。
/// .NET 用 `Uri.EscapeDataString`，等价 reqwest 的 percent-encoding（默认即 RFC3986）。
fn build_query(params: &BTreeMap<String, String>) -> String {
    params
        .iter()
        .map(|(k, v)| {
            format!(
                "{}={}",
                percent_encode_rfc3986(k),
                percent_encode_rfc3986(v)
            )
        })
        .collect::<Vec<_>>()
        .join("&")
}

/// RFC3986 percent-encoding：未保留字符 [A-Za-z0-9-._~] 不转义，其余全部 %HH。
/// 等价 .NET `Uri.EscapeDataString`。
fn percent_encode_rfc3986(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for &b in s.as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(b as char);
            }
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

/// 发送一个 [`KgRequest`]，返回上游响应 JSON（已做 data 提升的透传语义）。
///
/// 对应 .NET 的 `KgHttpTransport.SendAsync` + `KgSignatureHandler.SendAsync` 合体。
/// `client` 是共享的 reqwest 连接池，`session` 是当前调用方的会话。
pub async fn send(
    client: &Client,
    session: &KgSession,
    req: &KgRequest,
) -> AppResult<serde_json::Value> {
    let now = now_secs();

    // ===== 步骤 1：解析设备身份 =====
    let dfid = req
        .session_overrides
        .as_ref()
        .and_then(|o| o.get("dfid"))
        .cloned()
        .or_else(|| req.specific_dfid.clone())
        .unwrap_or_else(|| session.dfid.clone());
    let (mid, uuid) = KgSession::derive_device_identity(&dfid);

    let userid = req
        .session_overrides
        .as_ref()
        .and_then(|o| o.get("userid"))
        .cloned()
        .unwrap_or_else(|| session.userid.clone());
    let token = req
        .session_overrides
        .as_ref()
        .and_then(|o| o.get("token"))
        .cloned()
        .unwrap_or_else(|| session.token.clone());

    // ===== 步骤 2：合并参数 + 注入默认参数 =====
    let mut merged: BTreeMap<String, String> = req.params.clone();
    if !req.clear_default_params {
        merged
            .entry("appid".into())
            .or_insert_with(|| config::APP_ID.into());
        merged
            .entry("clientver".into())
            .or_insert_with(|| config::CLIENT_VER.into());
        merged.entry("dfid".into()).or_insert(dfid.clone());
        merged.entry("mid".into()).or_insert(mid.clone());
        merged.entry("uuid".into()).or_insert(uuid.clone());
        merged.entry("userid".into()).or_insert(userid.clone());
        merged
            .entry("clienttime".into())
            .or_insert_with(|| now.to_string());
        if !token.is_empty() {
            merged.entry("token".into()).or_insert(token.clone());
        }
    }

    // ===== 步骤 3：V5 额外 key 参数 =====
    if req.signature_type == SignatureType::V5 && merged.contains_key("hash") {
        let param_mid = merged.get("mid").cloned().unwrap_or_else(|| mid.clone());
        let param_userid = merged
            .get("userid")
            .cloned()
            .unwrap_or_else(|| userid.clone());
        let hash = merged.get("hash").cloned().unwrap_or_default();
        merged.insert(
            "key".into(),
            signer::calc_v5_key(&hash, &param_userid, &param_mid),
        );
    }

    // ===== 步骤 4：重建 body 作为签名输入 =====
    let json_body: String = if let Some(raw) = &req.raw_body {
        raw.clone()
    } else if let Some(bin) = &req.binary_body {
        use base64::Engine;
        base64::engine::general_purpose::STANDARD.encode(bin)
    } else if let Some(body) = &req.body {
        serde_json::to_string(body).unwrap_or_default()
    } else {
        String::new()
    };

    // ===== 步骤 5：签名 =====
    if !req.not_signature && req.signature_type != SignatureType::None {
        let salt = if req.signature_type == SignatureType::OfficialAndroid {
            config::OFFICIAL_SALT
        } else {
            config::LITE_SALT
        };
        let signature = if req.signature_type == SignatureType::Web {
            signer::calc_web_qr_signature(&merged)
        } else if req.binary_body.is_some() {
            let bin = req.binary_body.as_ref().unwrap();
            signer::calc_post_signature_binary(&merged, bin, salt)
        } else {
            signer::calc_post_signature(&merged, &json_body, salt)
        };
        if !signature.is_empty() {
            merged.insert("signature".into(), signature);
        }
    }

    // ===== 步骤 6：构建 URL =====
    let base = req
        .base_url
        .clone()
        .unwrap_or_else(|| config::DEFAULT_GATEWAY.to_string());
    let base = base.trim_end_matches('/');
    let path = req.path.trim_start_matches('/');
    let query = build_query(&merged);
    let url = format!("{}/{}?{}", base, path, query);

    // ===== 步骤 7：构建请求 + header =====
    let method = if req.method == Method::GET {
        reqwest::Method::GET
    } else {
        reqwest::Method::POST
    };
    let mut builder = client.request(method, &url);

    if let Some(router) = &req.specific_router {
        builder = builder.header("x-router", router);
    }
    let has_custom_ua = req
        .custom_headers
        .as_ref()
        .map(|h| h.keys().any(|k| k.eq_ignore_ascii_case("user-agent")))
        .unwrap_or(false);
    if !has_custom_ua {
        builder = builder.header("User-Agent", config::USER_AGENT);
    }
    builder = builder.header("dfid", &dfid).header("mid", &mid);
    if let Some(ct) = merged.get("clienttime") {
        builder = builder.header("clienttime", ct);
    }
    builder = builder
        .header("kg-rc", config::KG_RC)
        .header("kg-thash", config::KG_THASH)
        .header("kg-rec", config::KG_REC)
        .header("kg-rf", config::KG_RF);

    let cookie = format!(
        "userid={uid}; token={tok}; vip_type={vt}; vip_token={vtt}",
        uid = session.userid,
        tok = session.token,
        vt = session.vip_type,
        vtt = session.vip_token,
    );
    builder = builder.header("Cookie", cookie);

    if let Some(custom) = &req.custom_headers {
        for (k, v) in custom {
            builder = builder.header(k, v);
        }
    }

    if req.method != Method::GET {
        if let Some(bin) = &req.binary_body {
            builder = builder
                .header("Content-Type", &req.content_type)
                .body(bin.clone());
        } else if let Some(raw) = &req.raw_body {
            builder = builder
                .header("Content-Type", &req.content_type)
                .body(raw.clone());
        } else if let Some(body) = &req.body {
            builder = builder
                .header("Content-Type", &req.content_type)
                .body(serde_json::to_vec(body).unwrap_or_default());
        }
    }

    // ===== 步骤 8：发送 =====
    let resp = builder
        .send()
        .await
        .map_err(|e| AppError::Upstream(format!("HTTP 发送失败: {e}")))?;

    let bytes = resp
        .bytes()
        .await
        .map_err(|e| AppError::Upstream(format!("读取响应失败: {e}")))?;

    let root: serde_json::Value = serde_json::from_slice(&bytes).unwrap_or_else(|_| {
        use base64::Engine;
        serde_json::json!({ "__raw_base64__": base64::engine::general_purpose::STANDARD.encode(&bytes) })
    });

    Ok(match api_response::parse(root) {
        api_response::ParsedResponse::Success(v) => v,
        api_response::ParsedResponse::Failure {
            status,
            err_code,
            root,
        } => {
            tracing::warn!(
                path = %req.path,
                status = ?status,
                err_code = ?err_code,
                "上游酷狗返回非成功状态"
            );
            root
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rfc3986_encoding_matches_uri_escapedatastring() {
        assert_eq!(percent_encode_rfc3986("abc-_."), "abc-_.");
        assert_eq!(percent_encode_rfc3986("a b"), "a%20b");
        assert_eq!(percent_encode_rfc3986("a&b"), "a%26b");
        assert_eq!(percent_encode_rfc3986("中"), "%E4%B8%AD");
    }

    #[test]
    fn build_query_sorts_and_encodes() {
        let mut m = BTreeMap::new();
        m.insert("q".into(), "周杰伦".into());
        m.insert("page".into(), "1".into());
        let q = build_query(&m);
        assert_eq!(q, "page=1&q=%E5%91%A8%E6%9D%B0%E4%BC%A6");
    }
}
