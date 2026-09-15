use serde_json::{json, Value};

use crate::error::{AppError, AppResult};
use crate::kugou::{
    crypto,
    request::{KgRequest, SignatureType},
    session::KgSession,
    signer, transport,
};

const LITE_T1_KEY: &str = "5e4ef500e9597fe004bd09a46d8add98";
const LITE_T1_IV: &str = "04bd09a46d8add98";
const LITE_T2_KEY: &str = "fd14b35e3f81af3817a20ae7adae7020";
const LITE_T2_IV: &str = "17a20ae7adae7020";
const T2_FIXED_HASH: &str = "0f607264fc6318a92b9e13c65db7cd3c";
const LITE_APP_KEY: &str = "c24f74ca2820225badc01946dba4fdf7";
const LITE_APP_IV: &str = "adc01946dba4fdf7";

const API_HOST: &str = "http://login.user.kugou.com";
const LOGIN_ROUTER: &str = "login.user.kugou.com";
const LOGIN_RETRY_HOST: &str = "https://loginserviceretry.kugou.com";
const WEB_HOST: &str = "https://login-user.kugou.com";

fn try_decrypt_response(response: Value, aes_key: Option<&str>) -> Value {
    let Some(aes_key) = aes_key else {
        return response;
    };
    let secu = match response.get("secu_params").and_then(|v| v.as_str()) {
        Some(s) if !s.is_empty() => s,
        _ => return response,
    };
    let plain = crypto::aes_decrypt(secu, aes_key);
    let decrypted_json = match serde_json::from_str::<Value>(&plain) {
        Ok(v) => v,
        Err(e) => {
            tracing::warn!(error = %e, "[login] 解密 secu_params 失败");
            return response;
        }
    };

    let mut root = response;
    if let (Some(root_obj), Some(dec_obj)) = (root.as_object_mut(), decrypted_json.as_object()) {
        for (k, v) in dec_obj {
            root_obj.insert(k.clone(), v.clone());
        }
    }
    root
}

pub async fn send_sms_code(
    client: &reqwest::Client,
    session: &KgSession,
    mobile: &str,
) -> AppResult<Value> {
    let body = json!({ "businessid": 5, "mobile": mobile, "plat": 3 });
    let req = KgRequest::get("/v7/send_mobile_code")
        .method(reqwest::Method::POST)
        .base_url(API_HOST)
        .router(LOGIN_ROUTER)
        .json_body(body)
        .signature_type(SignatureType::Default);
    transport::send(client, session, &req).await
}

pub async fn login_by_mobile(
    client: &reqwest::Client,
    _session_key: &str,
    session: &KgSession,
    mobile: &str,
    code: &str,
    userid: Option<&str>,
) -> AppResult<Value> {
    let date_ms = chrono::Utc::now().timestamp_millis();

    let t1_raw = format!("|{date_ms}");
    let t1_enc = crypto::aes_encrypt(&t1_raw, Some(LITE_T1_KEY), Some(LITE_T1_IV)).cipher_text;

    let t2_raw = format!(
        "{}|{T2_FIXED_HASH}|{}|{}|{date_ms}",
        session.install_guid, session.install_mac, session.install_dev
    );
    let t2_enc = crypto::aes_encrypt(&t2_raw, Some(LITE_T2_KEY), Some(LITE_T2_IV)).cipher_text;

    let aes_payload = json!({ "mobile": mobile, "code": code });
    let payload_enc = crypto::aes_encrypt(&aes_payload.to_string(), None, None);

    let pk_data = json!({ "clienttime_ms": date_ms, "key": payload_enc.temp_key });
    let pk = crypto::rsa_encrypt_no_padding(&pk_data.to_string(), true).to_uppercase();

    let masked = if mobile.chars().count() > 10 {
        let chars: Vec<char> = mobile.chars().collect();
        format!(
            "{}*****{}",
            chars[..2].iter().collect::<String>(),
            chars[10]
        )
    } else {
        mobile.to_string()
    };

    let mut body = json!({
        "plat": 1,
        "support_multi": 1,
        "t1": t1_enc,
        "t2": t2_enc,
        "clienttime_ms": date_ms,
        "mobile": masked,
        "key": signer::calc_login_key(date_ms),
        "pk": pk,
        "params": payload_enc.cipher_text,
        "dfid": "-",
        "dev": session.install_dev,
        "gitversion": "5f0b7c4"
    });

    let login_userid = userid.filter(|s| !s.is_empty()).unwrap_or(&session.userid);
    if !login_userid.is_empty() && login_userid != "0" {
        body["userid"] = json!(login_userid.parse::<i64>().unwrap_or(0));
    }

    let req = KgRequest::get("/v7/login_by_verifycode")
        .method(reqwest::Method::POST)
        .base_url(LOGIN_RETRY_HOST)
        .router(LOGIN_ROUTER)
        .json_body(body)
        .custom_header("support-calm", "1")
        .signature_type(SignatureType::Default);

    let resp = transport::send(client, session, &req).await?;
    let resp = try_decrypt_response(resp, Some(&payload_enc.temp_key));

    Ok(resp)
}

pub async fn get_qr_key(client: &reqwest::Client, session: &KgSession) -> AppResult<Value> {
    let req = KgRequest::get("/v2/qrcode")
        .base_url(WEB_HOST)
        .param("appid", "1001")
        .param("clientver", "11040")
        .param("type", "1")
        .param("plat", "4")
        .param("srcappid", "2919")
        .param(
            "qrcode_txt",
            "https://h5.kugou.com/apps/loginQRCode/html/index.html?appid=3116&",
        )
        .signature_type(SignatureType::Web);
    transport::send(client, session, &req).await
}

pub async fn check_qr_status(
    client: &reqwest::Client,
    _session_key: &str,
    session: &KgSession,
    key: &str,
) -> AppResult<Value> {
    let req = KgRequest::get("/v2/get_userinfo_qrcode")
        .base_url(WEB_HOST)
        .param("plat", "4")
        .param("appid", "3116")
        .param("srcappid", "2919")
        .param("qrcode", key)
        .signature_type(SignatureType::Web);
    let resp = transport::send(client, session, &req).await?;

    Ok(resp)
}

pub async fn refresh_token(
    client: &reqwest::Client,
    _session_key: &str,
    session: &KgSession,
) -> AppResult<Value> {
    if session.token.is_empty() || session.userid == "0" {
        return Err(AppError::Unauthorized("本地无有效 Token，无法刷新".into()));
    }

    let date_ms = chrono::Utc::now().timestamp_millis();
    let clienttime_sec = date_ms / 1000;

    let t1_raw = if session.t1.is_empty() {
        format!("|{date_ms}")
    } else {
        format!("{}|{date_ms}", session.t1)
    };
    let t1_enc = crypto::aes_encrypt(&t1_raw, Some(LITE_T1_KEY), Some(LITE_T1_IV)).cipher_text;

    let t2_raw = format!(
        "{}|{T2_FIXED_HASH}|{}|{}|{date_ms}",
        session.install_guid, session.install_mac, session.install_dev
    );
    let t2_enc = crypto::aes_encrypt(&t2_raw, Some(LITE_T2_KEY), Some(LITE_T2_IV)).cipher_text;

    let p3_data = json!({ "clienttime": clienttime_sec, "token": session.token });
    let p3_enc = crypto::aes_encrypt(&p3_data.to_string(), Some(LITE_APP_KEY), Some(LITE_APP_IV))
        .cipher_text;

    let params_enc = crypto::aes_encrypt("{}", None, None);

    let pk_data = json!({ "clienttime_ms": date_ms, "key": params_enc.temp_key });
    let pk = crypto::rsa_encrypt_no_padding(&pk_data.to_string(), true).to_uppercase();

    let body = json!({
        "dfid": "-",
        "p3": p3_enc,
        "plat": 1,
        "t1": t1_enc,
        "t2": t2_enc,
        "t3": "MCwwLDAsMCwwLDAsMCwwLDA=",
        "pk": pk,
        "params": params_enc.cipher_text,
        "userid": session.userid,
        "clienttime_ms": date_ms,
        "dev": session.install_dev
    });

    let req = KgRequest::get("/v5/login_by_token")
        .method(reqwest::Method::POST)
        .base_url(API_HOST)
        .router(LOGIN_ROUTER)
        .json_body(body)
        .signature_type(SignatureType::Default);

    let resp = transport::send(client, session, &req).await?;
    let resp = try_decrypt_response(resp, Some(&params_enc.temp_key));

    Ok(resp)
}

pub async fn logout(client: &reqwest::Client, _session_key: &str, session: &KgSession) {
    let _ = (client, session);
}
