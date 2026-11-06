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

/// 是否是多账号（34175）响应。
///
/// 错误码可能在根上，也可能被代理放进 `data.error_code`。判定对齐
/// `root_error_code || data.error_code` 语义：根上的非零错误码优先，
/// 根为 0/缺失时才看 `data`，避免根上的其他错误被误判成多账号。
fn is_multi_account_response(response: &Value) -> bool {
    let root = response
        .get("error_code")
        .and_then(value_as_i64)
        .or_else(|| response.get("errcode").and_then(value_as_i64));
    let nested = response
        .get("data")
        .and_then(|data| data.get("error_code").or_else(|| data.get("errcode")))
        .and_then(value_as_i64);
    match root {
        Some(MULTI_ACCOUNT_ERROR_CODE) => true,
        Some(0) | None => nested == Some(MULTI_ACCOUNT_ERROR_CODE),
        Some(_) => false,
    }
}

/// 取对象里第一个存在、非 null 且非空白字符串的字段。
/// （`"pic": null` 不应挡住 `avatar`，空串同样视为未提供。）
fn first_non_null<'a>(obj: &'a serde_json::Map<String, Value>, keys: &[&str]) -> Option<&'a Value> {
    keys.iter().find_map(|key| {
        obj.get(*key).filter(|value| {
            !value.is_null() && !value.as_str().is_some_and(|text| text.trim().is_empty())
        })
    })
}

/// 把单个候选账号归一成前端契约的字段（userId/nickname/pic/appId/username）。
/// 缺少有效 userid 的脏数据直接丢弃。
fn normalize_account(item: &Value) -> Option<Value> {
    let obj = item.as_object()?;
    let userid =
        first_non_null(obj, &["userid", "userId", "user_id", "id"]).and_then(value_as_i64)?;
    if userid <= 0 {
        return None;
    }
    let appid = first_non_null(obj, &["appid", "appId"])
        .and_then(value_as_i64)
        .unwrap_or(0);
    Some(json!({
        "userId": userid,
        "nickname": first_non_null(obj, &["nickname", "name"]).cloned().unwrap_or(Value::Null),
        "pic": first_non_null(obj, &["pic", "avatar", "headpic", "img", "imgurl"])
            .cloned()
            .unwrap_or(Value::Null),
        "appId": appid,
        "username": first_non_null(obj, &["username"]).cloned().unwrap_or(Value::Null),
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
/// `data` 展开成根节点，导致上面的状态字段丢失；即使拿不到候选账号，也要
/// 返回不带 `data` 的失败信封，让前端能按 34175 给出准确文案。
fn normalize_multi_account_response(response: Value) -> Value {
    if !is_multi_account_response(&response) {
        return response;
    }
    let status = response.get("status").cloned().unwrap_or_else(|| json!(0));
    let message = multi_account_message(&response);
    let accounts = multi_account_list(&response);
    if accounts.is_empty() {
        // 统一置 status=0：Dart 的 _isSuccess 只看 status，若保留上游的
        // status=1，会被当成登录成功并拿到空 session。
        return json!({
            "status": 0,
            "error_code": MULTI_ACCOUNT_ERROR_CODE,
            "errorCode": MULTI_ACCOUNT_ERROR_CODE,
            "requiresUserSelection": false,
            "message": message,
        });
    }
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

/// 解密 `container.secu_params`（AES 随机 key 那一套）并把明文字段合并回
/// 同一对象。返回是否成功解密并合并（无字段 / 形状不符 / 非对象明文 → false）。
///
/// 用 [`crypto::try_aes_decrypt`] 而不是会 panic 的 `aes_decrypt`：这是对
/// 不可信上游响应的解析，脏密文/错误 key 只应降级为“解不出”，不能打崩引擎。
fn decrypt_secu_params_into(container: &mut Value, aes_key: &str) -> bool {
    let Some(secu) = container
        .get("secu_params")
        .and_then(|v| v.as_str())
        .map(str::to_owned)
    else {
        return false;
    };
    let Some(plain) = crypto::try_aes_decrypt(&secu, aes_key) else {
        tracing::warn!("[login] 解密 secu_params 失败（密文损坏或密钥不匹配）");
        return false;
    };
    let decrypted = match serde_json::from_str::<Value>(&plain) {
        Ok(v) => v,
        Err(e) => {
            tracing::warn!(error = %e, "[login] secu_params 解密结果不是合法 JSON");
            return false;
        }
    };
    let Some(dec_obj) = decrypted.as_object() else {
        // 兼容旧协议：明文可能直接是 token 字符串，本函数只处理对象字段。
        return false;
    };
    let Some(obj) = container.as_object_mut() else {
        return false;
    };
    for (k, v) in dec_obj {
        obj.insert(k.clone(), v.clone());
    }
    true
}

/// 解密登录响应里的 `secu_params`。
///
/// 两种响应形态都要覆盖（与 .NET `RawLoginApi.TryDecryptResponse` 一致）：
/// - 成功登录：`transport` 已把 `data` 提升到根节点，密文在根级 `secu_params`；
/// - `status=1` 但 `error_code != 0`（例如多账号 34175）：`transport` 不解包，
///   密文仍在 `data.secu_params` 里，账号列表可能藏在解密后的字段中。
fn try_decrypt_response(mut response: Value, aes_key: Option<&str>) -> Value {
    let Some(aes_key) = aes_key else {
        return response;
    };
    if decrypt_secu_params_into(&mut response, aes_key) {
        return response;
    }
    if let Some(data) = response.get_mut("data") {
        decrypt_secu_params_into(data, aes_key);
    }
    response
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

/// 登录成功信封：`status=1` 且 `error_code` 缺失或为 0。
fn is_success_envelope(response: &Value) -> bool {
    response.get("status").and_then(|v| v.as_i64()) == Some(1)
        && matches!(
            response.get("error_code").and_then(|v| v.as_i64()),
            None | Some(0)
        )
}

fn has_login_token(response: &Value) -> bool {
    response
        .get("token")
        .and_then(|v| v.as_str())
        .is_some_and(|token| !token.is_empty())
}

fn has_login_userid(response: &Value) -> bool {
    response.get("userid").is_some_and(|value| {
        value.as_i64().is_some_and(|id| id != 0)
            || value.as_str().is_some_and(|id| !id.is_empty() && id != "0")
    })
}

/// 成功信封却缺少 token/userid：说明 `secu_params` 没解开或上游响应异常。
/// 必须降级成失败，否则 Dart 会当成「成功但空凭证」的登录——界面既不进
/// 主页也不报错，用户只会看到点了没反应。
fn ensure_login_credentials_or_failure(response: Value) -> Value {
    if !is_success_envelope(&response) {
        return response;
    }
    if has_login_token(&response) && has_login_userid(&response) {
        return response;
    }
    json!({
        "status": 0,
        "error_code": 0,
        "msg": "登录响应缺少凭证，请重试",
    })
}

/// 登录响应处理流水线（transport 之后）：解密 → 多账号归一 → 凭证守卫。
/// 抽成纯函数，测试可按真实顺序覆盖各种响应形态，避免遗漏步骤或顺序错误。
fn process_login_response(response: Value, aes_key: &str) -> Value {
    let response = try_decrypt_response(response, Some(aes_key));
    let response = normalize_multi_account_response(response);
    ensure_login_credentials_or_failure(response)
}

/// 把多账号二次登录选中的 userid 写入上游 body。
///
/// 与 .NET 参考实现一致以**字符串**下发（酷狗同一字段既接受数字也接受
/// 字符串，字符串可避免超长 userid 的 JSON 数字精度问题）；空值 / "0" 不写，
/// 未显式传时回退当前会话 userid。
fn apply_login_userid(body: &mut Value, userid: Option<&str>, session_userid: &str) {
    let login_userid = userid.filter(|s| !s.is_empty()).unwrap_or(session_userid);
    if !login_userid.is_empty() && login_userid != "0" {
        body["userid"] = json!(login_userid);
    }
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

    apply_login_userid(&mut body, userid, &session.userid);

    let req = KgRequest::get("/v7/login_by_verifycode")
        .method(reqwest::Method::POST)
        .base_url(LOGIN_RETRY_HOST)
        .router(LOGIN_ROUTER)
        .json_body(body)
        .custom_header("support-calm", "1")
        .signature_type(SignatureType::Default);

    let resp = transport::send(client, session, &req).await?;

    Ok(process_login_response(resp, &payload_enc.temp_key))
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

    /// 按 transport 的语义处理上游响应（成功提升 data，失败保留根信封）。
    fn after_transport(raw: Value) -> Value {
        match crate::kugou::api_response::parse(raw) {
            crate::kugou::api_response::ParsedResponse::Success(v) => v,
            crate::kugou::api_response::ParsedResponse::Failure { root, .. } => root,
        }
    }

    #[test]
    fn multi_account_failure_is_normalized_into_account_selection_contract() {
        // 参考实现（.NET / KuGouMusicApi）的多账号响应形态：
        // status=0 + error_code=34175 + data.info_list。
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
    fn data_string_message_is_normalized_into_failure_without_data() {
        // 部分网关把 data 直接下成提示字符串（无 info_list）：不能选账号，
        // 但仍要去掉 data，避免 Dart 的 unwrapData 吞掉根 error_code。
        let raw = json!({
            "status": 0,
            "error_code": 34175,
            "data": "请选择需要登录的账号"
        });
        let normalized = normalize_multi_account_response(raw);
        assert_eq!(normalized["errorCode"], json!(34175));
        assert_eq!(normalized["requiresUserSelection"], json!(false));
        assert_eq!(normalized["message"], json!("请选择需要登录的账号"));
        assert!(normalized.get("data").is_none());
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
    }

    #[test]
    fn empty_multi_account_list_becomes_failure_without_data() {
        // 错误码对但 info_list 为空：不能当成选账号，否则前端会卡在空列表；
        // 归一成不带 data 的失败信封，让 Dart 按 34175 给出准确文案。
        let empty_list = json!({
            "status": 0,
            "error_code": 34175,
            "data": { "info_list": [] }
        });
        let normalized = normalize_multi_account_response(empty_list);
        assert_eq!(normalized["errorCode"], json!(34175));
        assert_eq!(normalized["requiresUserSelection"], json!(false));
        assert!(normalized.get("data").is_none());
    }

    #[test]
    fn status_one_multi_account_without_accounts_fails_instead_of_fake_success() {
        // Dart 的 _isSuccess 只看 status==1；34175 却没账号时必须降级成失败，
        // 否则会返回一个没有 token 的「成功」session。
        let raw = json!({
            "status": 1,
            "error_code": 34175,
            "data": { "info_list": [] }
        });
        let normalized = normalize_multi_account_response(raw);
        assert_eq!(normalized["status"], json!(0));
        assert_eq!(normalized["errorCode"], json!(34175));
        assert_eq!(normalized["requiresUserSelection"], json!(false));
    }

    #[test]
    fn plaintext_multi_account_survives_transport_envelope() {
        // status=0 + 根 error_code=34175：transport 不解包 data，正常化要能识别。
        let raw = json!({
            "status": 0,
            "error_code": 34175,
            "data": { "info_list": [{ "userid": 1001, "nickname": "甲" }] }
        });
        let normalized = normalize_multi_account_response(after_transport(raw));
        assert_eq!(normalized["requiresUserSelection"], json!(true));
        assert_eq!(normalized["accounts"].as_array().unwrap().len(), 1);
        assert!(normalized.get("data").is_none());
    }

    #[test]
    fn encrypted_status_one_multi_account_is_decrypted_then_normalized() {
        // .NET/JS 参考实现对 status=1（即使 error_code=34175）的
        // data.secu_params 也会解密；若真实响应是加密形态，必须同样覆盖。
        let secret = json!({
            "info_list": [
                { "userid": "1002", "nickname": "乙", "pic": "https://img.example/2.jpg" }
            ]
        });
        let enc = crate::kugou::crypto::aes_encrypt(&secret.to_string(), None, None);
        let raw = json!({
            "status": 1,
            "error_code": 34175,
            "data": { "secu_params": enc.cipher_text }
        });

        let decrypted = try_decrypt_response(raw, Some(&enc.temp_key));
        assert!(
            decrypted
                .get("data")
                .and_then(|data| data.get("info_list"))
                .is_some(),
            "data.secu_params 解密后应把 info_list 合并回 data"
        );

        let normalized = normalize_multi_account_response(decrypted);
        assert_eq!(normalized["requiresUserSelection"], json!(true));
        assert_eq!(normalized["accounts"][0]["userId"], json!(1002));
        assert_eq!(
            normalized["accounts"][0]["pic"],
            json!("https://img.example/2.jpg")
        );
    }

    #[test]
    fn root_level_secu_params_still_decrypts_successful_login() {
        // 成功登录时 transport 已把 data 提升到根，secu_params 在根级；
        // 提取解密 helper 后这条主路径必须保持原行为。
        let secret = json!({ "userid": 1001, "token": "tk", "t1": "t1" });
        let enc = crate::kugou::crypto::aes_encrypt(&secret.to_string(), None, None);
        let promoted = json!({
            "status": 1,
            "error_code": 0,
            "secu_params": enc.cipher_text
        });

        let decrypted = try_decrypt_response(promoted, Some(&enc.temp_key));
        assert_eq!(decrypted["userid"], json!(1001));
        assert_eq!(decrypted["token"], json!("tk"));
        assert_eq!(decrypted["t1"], json!("t1"));
        assert_eq!(decrypted["status"], json!(1));
    }

    #[test]
    fn success_envelope_without_credentials_is_downgraded_to_failure() {
        let raw = json!({
            "status": 1,
            "error_code": 0,
            "secu_params": "00".repeat(16)
        });
        let out = ensure_login_credentials_or_failure(raw);
        assert_eq!(out["status"], json!(0));
        assert!(
            out["msg"].as_str().unwrap().contains("缺少凭证"),
            "应给出可读的失败原因，而不是让前端拿到空 session"
        );
    }

    #[test]
    fn undecryptable_success_response_is_downgraded_to_failure() {
        // 合法长度但填充被破坏：try_aes_decrypt 返回 None，登录不能当成功。
        let enc = crate::kugou::crypto::aes_encrypt("123456789012345", None, None);
        let mut raw_bytes = hex::decode(&enc.cipher_text).expect("hex");
        *raw_bytes.last_mut().expect("non-empty") ^= 0xFF;
        let tampered = hex::encode(raw_bytes);
        let promoted = json!({
            "status": 1,
            "error_code": 0,
            "secu_params": tampered
        });

        let decrypted = try_decrypt_response(promoted, Some(&enc.temp_key));
        assert!(decrypted.get("token").is_none(), "坏密文不应解出 token");

        let out = ensure_login_credentials_or_failure(decrypted);
        assert_eq!(out["status"], json!(0));
    }

    #[test]
    fn success_envelope_with_credentials_is_untouched() {
        let raw = json!({
            "status": 1,
            "error_code": 0,
            "userid": 1001,
            "token": "tk",
            "t1": "t1"
        });
        assert_eq!(ensure_login_credentials_or_failure(raw.clone()), raw);
    }

    #[test]
    fn account_selection_envelope_is_not_downgraded_by_credential_guard() {
        // 选账号信封可能带 status=1，但 error_code=34175；凭证校验不能误伤。
        let raw = json!({
            "status": 1,
            "error_code": 34175,
            "data": { "info_list": [{ "userid": 1001 }] }
        });
        let out = ensure_login_credentials_or_failure(normalize_multi_account_response(raw));
        assert_eq!(out["requiresUserSelection"], json!(true));
        assert_eq!(out["accounts"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn root_level_info_list_is_supported() {
        let raw = json!({
            "status": 0,
            "error_code": 34175,
            "info_list": [{ "userid": 1001 }]
        });
        let normalized = normalize_multi_account_response(raw);
        assert_eq!(normalized["requiresUserSelection"], json!(true));
    }

    #[test]
    fn null_pic_does_not_shadow_avatar() {
        let account = normalize_account(&json!({
            "userid": 1001,
            "nickname": null,
            "pic": null,
            "avatar": "https://img.example/a.jpg",
            "appid": null,
            "appId": 3116
        }))
        .expect("account");

        assert_eq!(account["pic"], json!("https://img.example/a.jpg"));
        assert_eq!(account["nickname"], json!(null));
        assert_eq!(account["appId"], json!(3116));
    }

    #[test]
    fn login_userid_is_written_as_string_and_skips_empty_values() {
        let mut body = json!({});
        apply_login_userid(&mut body, Some("1002"), "0");
        assert_eq!(body["userid"], json!("1002"));
        assert!(
            body["userid"].is_string(),
            "userid 应与 .NET 参考实现一致以字符串下发"
        );

        let mut body = json!({});
        apply_login_userid(&mut body, None, "0");
        assert!(body.get("userid").is_none());

        let mut body = json!({});
        apply_login_userid(&mut body, Some(""), "0");
        assert!(body.get("userid").is_none());

        // 未显式传时回退会话 userid（保留原有行为）。
        let mut body = json!({});
        apply_login_userid(&mut body, None, "1003");
        assert_eq!(body["userid"], json!("1003"));
    }

    #[test]
    fn malformed_secu_params_does_not_break_response() {
        // 形状不符的脏字段不能进入 aes_decrypt 触发 panic。
        let raw = json!({
            "status": 0,
            "error_code": 34175,
            "data": { "secu_params": "not-hex" }
        });
        let decrypted = try_decrypt_response(raw.clone(), Some("key"));
        assert_eq!(decrypted, raw);
    }

    #[test]
    fn account_field_aliases_are_normalized() {
        // 不同客户端/代理观察到过 user_id/id、name、headpic 等别名。
        let account = normalize_account(&json!({
            "user_id": "1003",
            "name": "丙",
            "headpic": "https://img.example/3.jpg",
            "appid": 3116
        }))
        .expect("account");

        assert_eq!(account["userId"], json!(1003));
        assert_eq!(account["nickname"], json!("丙"));
        assert_eq!(account["pic"], json!("https://img.example/3.jpg"));
    }

    #[test]
    fn empty_primary_fields_fall_through_to_aliases() {
        let account = normalize_account(&json!({
            "userid": "",
            "userId": 1004,
            "nickname": "   ",
            "name": "丁",
            "pic": "",
            "avatar": "https://img.example/4.jpg"
        }))
        .expect("account");

        assert_eq!(account["userId"], json!(1004));
        assert_eq!(account["nickname"], json!("丁"));
        assert_eq!(account["pic"], json!("https://img.example/4.jpg"));
    }

    #[test]
    fn root_nonzero_error_code_wins_over_nested_34175() {
        // 根上已有其他非零错误码时，data.error_code 的 34175 不应抢占语义。
        let raw = json!({
            "status": 0,
            "error_code": 34174,
            "data": {
                "error_code": 34175,
                "info_list": [{ "userid": 1001 }]
            }
        });

        let output = process_login_response(after_transport(raw.clone()), "any-key");
        assert!(output.get("requiresUserSelection").is_none());
        assert!(output.get("accounts").is_none());
        assert_eq!(output, raw);
    }

    #[test]
    fn raw_multi_account_pipeline_yields_account_selection() {
        // 按真实顺序覆盖：transport 信封 → 解密 → 归一 → 凭证守卫。
        let raw = json!({
            "status": 0,
            "error_code": 34175,
            "data": {
                "info_list": [
                    { "userid": 1001, "nickname": "甲" },
                    { "userid": "1002", "nickname": "乙" }
                ]
            }
        });

        let output = process_login_response(after_transport(raw), "any-key");
        assert_eq!(output["requiresUserSelection"], json!(true));
        assert_eq!(output["accounts"].as_array().unwrap().len(), 2);
        assert!(output.get("data").is_none());
    }

    #[test]
    fn nested_data_error_code_pipeline_yields_account_selection() {
        // 部分代理把错误码放在 data.error_code，且根上可能是 0：两处都要看，
        // 不能被根上的 0 盖住。
        let raw = json!({
            "status": 0,
            "error_code": 0,
            "data": {
                "error_code": 34175,
                "info_list": [{ "userid": 1001, "nickname": "甲" }]
            }
        });

        let output = process_login_response(after_transport(raw), "any-key");
        assert_eq!(output["requiresUserSelection"], json!(true));
        assert_eq!(output["accounts"][0]["userId"], json!(1001));
    }

    #[test]
    fn raw_encrypted_success_pipeline_yields_credentials() {
        let secret = json!({ "userid": 1001, "token": "tk", "t1": "t1" });
        let enc = crate::kugou::crypto::aes_encrypt(&secret.to_string(), None, None);
        let raw = json!({
            "status": 1,
            "error_code": 0,
            "data": { "secu_params": enc.cipher_text }
        });

        let output = process_login_response(after_transport(raw), &enc.temp_key);
        assert_eq!(output["status"], json!(1));
        assert_eq!(output["userid"], json!(1001));
        assert_eq!(output["token"], json!("tk"));
    }

    #[test]
    fn raw_success_with_broken_ciphertext_pipeline_fails_clearly() {
        // 成功信封但密文解不开：流水线最后一步必须降级为失败，不能空凭证成功。
        let enc = crate::kugou::crypto::aes_encrypt("123456789012345", None, None);
        let mut bytes = hex::decode(&enc.cipher_text).expect("hex");
        *bytes.last_mut().expect("non-empty") ^= 0xFF;
        let raw = json!({
            "status": 1,
            "error_code": 0,
            "data": { "secu_params": hex::encode(bytes) }
        });

        let output = process_login_response(after_transport(raw), &enc.temp_key);
        assert_eq!(output["status"], json!(0));
        assert!(output["msg"].as_str().unwrap().contains("缺少凭证"));
    }
}
