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

/// 手机号绑定多个酷狗账号时，`/v7/login_by_verifycode`（带 `support_multi=1`）
/// 返回的错误码。此时响应里带 `data.info_list` 候选账号列表，需要用户选定
/// 一个 `userid` 后重新登录。
const MULTI_ACCOUNT_ERROR_CODE: i64 = 34175;

/// 把数字或数字字符串解析为 i64（上游同一字段两种类型都出现过）。
fn value_as_i64(value: &Value) -> Option<i64> {
    value
        .as_i64()
        .or_else(|| value.as_str().and_then(|s| s.trim().parse::<i64>().ok()))
}

/// 读取上游响应信封的错误码（`error_code`，兼容网关的 `errcode` 别名）。
fn response_error_code(response: &Value) -> Option<i64> {
    response
        .get("error_code")
        .and_then(value_as_i64)
        .or_else(|| response.get("errcode").and_then(value_as_i64))
}

/// 把单个候选账号归一成前端契约的字段（userId/nickname/pic/appId/username）。
/// 缺少有效 userid 的脏数据直接丢弃。
fn normalize_account(item: &Value) -> Option<Value> {
    let obj = item.as_object()?;
    let userid = obj
        .get("userid")
        .or_else(|| obj.get("userId"))
        .and_then(value_as_i64)
        .filter(|id| *id > 0)?;
    let appid = obj
        .get("appid")
        .or_else(|| obj.get("appId"))
        .and_then(value_as_i64)
        .unwrap_or(0);
    Some(json!({
        "userId": userid,
        "nickname": obj.get("nickname").cloned().unwrap_or(Value::Null),
        "pic": obj.get("pic").or_else(|| obj.get("avatar")).cloned().unwrap_or(Value::Null),
        "appId": appid,
        "username": obj.get("username").cloned().unwrap_or(Value::Null),
    }))
}

/// 从 `data.info_list`（兼容已被提升到根节点的 `info_list`）提取候选账号。
fn multi_account_list(response: &Value) -> Vec<Value> {
    response
        .get("data")
        .and_then(|data| data.get("info_list"))
        .or_else(|| response.get("info_list"))
        .and_then(|value| value.as_array())
        .map(|items| items.iter().filter_map(normalize_account).collect())
        .unwrap_or_default()
}

/// 多账号提示文案：`data` 本身可能就是一句提示字符串，其次是常见消息字段。
fn multi_account_message(response: &Value) -> String {
    if let Some(Value::String(text)) = response.get("data") {
        let text = text.trim();
        if !text.is_empty() {
            return text.to_string();
        }
    }
    if let Some(text) = response
        .get("data")
        .and_then(|data| data.get("message").or_else(|| data.get("msg")))
        .and_then(|value| value.as_str())
    {
        let text = text.trim();
        if !text.is_empty() {
            return text.to_string();
        }
    }
    for key in ["msg", "message", "errmsg", "error_msg", "error"] {
        if let Some(Value::String(text)) = response.get(key) {
            let text = text.trim();
            if !text.is_empty() {
                return text.to_string();
            }
        }
    }
    "该手机号绑定了多个账号，请选择要登录的账号".to_string()
}

/// 把酷狗「手机号绑定多个账号」的失败响应归一成前端契约：
/// `{status, error_code, errorCode, requiresUserSelection, message, accounts}`。
///
/// 上游 KA Music 的 HTTP API 服务会做这层包装，Dart 侧只认 `accounts`；
/// 本仓库由 Rust 引擎直连酷狗，若不归一，`unwrapData` 会丢掉根节点的
/// `error_code`，前端就按普通失败提示「没有注册账号」。
/// 注意：响应中不能保留 `data` 字段——Dart 的 `unwrapData` 会把 Map 形态的
/// `data` 展开成根节点，导致上面的状态字段丢失。
fn normalize_multi_account_response(response: Value) -> Value {
    if response_error_code(&response) != Some(MULTI_ACCOUNT_ERROR_CODE) {
        return response;
    }
    let accounts = multi_account_list(&response);
    if accounts.is_empty() {
        return response;
    }
    let status = response.get("status").cloned().unwrap_or_else(|| json!(0));
    let message = multi_account_message(&response);
    tracing::info!(
        count = accounts.len(),
        "[login] 手机号绑定了多个账号，返回候选账号列表"
    );
    json!({
        "status": status,
        "error_code": MULTI_ACCOUNT_ERROR_CODE,
        "errorCode": MULTI_ACCOUNT_ERROR_CODE,
        "requiresUserSelection": true,
        "message": message,
        "accounts": accounts,
    })
}

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
        // 多账号二次登录：与 .NET 参考实现一致，userid 以字符串下发（
        // 酷狗同一字段既接受数字也接受字符串，字符串可避免前导 0 / 超长
        // id 被 JSON 数字精度截断）。
        body["userid"] = json!(login_userid);
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

    Ok(normalize_multi_account_response(resp))
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn multi_account_failure_is_normalized_into_account_selection_contract() {
        // 酷狗实测形态：status=0 + error_code=34175 + data.info_list。
        let raw = json!({
            "status": 0,
            "error_code": 34175,
            "data": {
                "info_list": [
                    {
                        "userid": 1001,
                        "nickname": "甲",
                        "pic": "https://img.example/1.jpg",
                        "appid": 3116,
                        "username": "acc1"
                    },
                    {
                        "userid": "1002",
                        "nickname": "乙",
                        "pic": null,
                        "appid": "1001",
                        "username": "acc2"
                    },
                    { "userid": 0, "nickname": "无效账号" }
                ]
            }
        });

        let normalized = normalize_multi_account_response(raw);

        // Dart 侧 `_requiresUserSelection` 与 `PhoneLoginResult` 依赖的字段。
        assert_eq!(normalized["requiresUserSelection"], json!(true));
        assert_eq!(normalized["errorCode"], json!(34175));
        assert_eq!(normalized["error_code"], json!(34175));
        assert_eq!(normalized["status"], json!(0));
        // 必须去掉 data：Dart 的 unwrapData 会把 Map 形态的 data 展开并丢掉根字段。
        assert!(normalized.get("data").is_none());

        let accounts = normalized["accounts"].as_array().expect("accounts 数组");
        assert_eq!(accounts.len(), 2, "userid 无效的脏数据应被过滤");
        assert_eq!(accounts[0]["userId"], json!(1001));
        assert_eq!(accounts[0]["nickname"], json!("甲"));
        assert_eq!(accounts[0]["pic"], json!("https://img.example/1.jpg"));
        assert_eq!(accounts[0]["appId"], json!(3116));
        assert_eq!(accounts[0]["username"], json!("acc1"));
        // 字符串形态的 userid/appid 也要能归一成数字。
        assert_eq!(accounts[1]["userId"], json!(1002));
        assert_eq!(accounts[1]["appId"], json!(1001));
    }

    #[test]
    fn multi_account_message_prefers_upstream_text_and_falls_back() {
        let with_text = normalize_multi_account_response(json!({
            "status": 0,
            "errcode": "34175",
            "data": {
                "info_list": [{ "userid": 1 }]
            },
            "msg": "该手机号绑定了多个账号"
        }));
        assert_eq!(with_text["message"], json!("该手机号绑定了多个账号"));

        let without_text = normalize_multi_account_response(json!({
            "status": 0,
            "error_code": 34175,
            "data": {
                "info_list": [{ "userid": 2 }]
            }
        }));
        assert_eq!(
            without_text["message"],
            json!("该手机号绑定了多个账号，请选择要登录的账号")
        );
    }

    #[test]
    fn data_string_message_is_propagated() {
        // 部分网关把 data 直接下成提示字符串（无 info_list），不构成选账号。
        let raw = json!({
            "status": 0,
            "error_code": 34175,
            "data": "请选择需要登录的账号"
        });
        let normalized = normalize_multi_account_response(raw.clone());
        assert_eq!(
            normalized, raw,
            "没有候选账号时保持原响应，交由普通登录失败提示"
        );
    }

    #[test]
    fn non_multi_account_responses_are_untouched() {
        let failure = json!({
            "status": 0,
            "error_code": 34174,
            "msg": "验证码错误"
        });
        assert_eq!(normalize_multi_account_response(failure.clone()), failure);

        let success = json!({
            "status": 1,
            "error_code": 0,
            "userid": 1001,
            "token": "token",
            "t1": "t1"
        });
        assert_eq!(normalize_multi_account_response(success.clone()), success);

        // 错误码对但 info_list 为空：不能当成选账号，否则前端会卡在空列表。
        let empty_list = json!({
            "status": 0,
            "error_code": 34175,
            "data": { "info_list": [] }
        });
        assert_eq!(
            normalize_multi_account_response(empty_list.clone()),
            empty_list
        );
    }
}
