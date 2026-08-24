//! 酷狗请求签名 —— 1:1 对应 .NET 的 `util/KGSigner.cs`。
//!
//! 4 种活跃签名策略：
//! - [`calc_post_signature`] —— Default/V5/Register/OfficialAndroid 共用，
//!   `md5(salt + 排序后"k=v"无分隔符拼接 + body + salt)`，小写 hex。
//!   V5 只是在此之外**额外**加一个 `key` 参数（见 [`calc_v5_key`]）。
//! - [`calc_web_qr_signature`] —— Web（扫码登录/迷你乐库），
//!   `md5(webSalt + 排序 k=v + webSalt)`，**body 不参与**。
//! - [`calc_v5_key`] —— V5 播放链接的 `key` 参数，`md5(hash + V5KeySalt + AppId + mid + userid)`。
//! - [`calc_login_key`] / [`calc_cloud_key`] —— raw api 内联用的辅助签名。
//!
//! 关键易错点（迁移时务必逐条对齐）：
//! 1. 排序用**字节序**：Rust `str`/`String` 的 `Ord` 默认即字节序，等价 C# `StringComparer.Ordinal`。
//! 2. k=v 对之间**无分隔符**：是 `saltk1=v1k2=v2bodysalt`，不是 `&` 连接。
//!    （`BuildSortedParamString` 才用 `&` 或空串分隔，那是另一套，别混。）
//! 3. 签名 hex **小写**；RSA 的 pk/p 才是大写（Phase 4）。
//! 4. 签名作为**查询参数** `signature=` 传，不是 header。

use std::collections::BTreeMap;

use crate::kugou::{config, crypto};

/// 把参数按 key 字节序排序后，拼成无分隔符的 `k1=v1k2=v2...`（.NET 主签名格式）。
///
/// 用 `BTreeMap<String,String>`：其键天然按字节序排列，等价 `.OrderBy(x => x.Key, StringComparer.Ordinal)`。
fn sorted_kv_concat(params: &BTreeMap<String, String>) -> String {
    let mut sb = String::new();
    for (k, v) in params {
        sb.push_str(k);
        sb.push('=');
        sb.push_str(v);
    }
    sb
}

/// KgSigner.CalcPostSignature（字符串 body 版）。
///
/// `md5(salt + sorted(k=v) + body + salt)`。body 为空则不附加。
pub fn calc_post_signature(
    query_params: &BTreeMap<String, String>,
    json_body: &str,
    salt: &str,
) -> String {
    let mut sb = String::new();
    sb.push_str(salt);
    sb.push_str(&sorted_kv_concat(query_params));
    if !json_body.is_empty() {
        sb.push_str(json_body);
    }
    sb.push_str(salt);
    crypto::md5_str(&sb)
}

/// KgSigner.CalcPostSignature（二进制 body 版，听歌识曲 PCM 用）。
///
/// 二进制 body **总是**参与（即使为空也按 0 长度处理，与字符串版不同）。
/// 等价于把所有字节流式喂给同一个 md5。
pub fn calc_post_signature_binary(
    query_params: &BTreeMap<String, String>,
    binary_body: &[u8],
    salt: &str,
) -> String {
    use md5::Md5;
    use digest::Digest;

    let mut hasher = Md5::new();
    hasher.update(salt.as_bytes());
    for (k, v) in query_params {
        hasher.update(k.as_bytes());
        hasher.update(b"=");
        hasher.update(v.as_bytes());
    }
    hasher.update(binary_body);
    hasher.update(salt.as_bytes());
    hex::encode(hasher.finalize())
}

/// KgSigner.CalcV5Key —— V5 播放链接的额外 `key` 参数。
///
/// `md5(hash + V5KeySalt + AppId + mid + userid)`。
/// 这个 key 和 signature 是两个独立的查询参数。
pub fn calc_v5_key(hash: &str, userid: &str, mid: &str) -> String {
    let raw = format!("{}{}{}{}{}", hash, config::V5_KEY_SALT, config::APP_ID, mid, userid);
    crypto::md5_str(&raw)
}

/// KgSigner.CalcWebQrSignature —— Web（扫码登录/迷你乐库）签名。
///
/// `md5(webSalt + sorted(k=v) + webSalt)`，**body 不参与**。
pub fn calc_web_qr_signature(params: &BTreeMap<String, String>) -> String {
    let mut sb = String::new();
    sb.push_str(config::WEB_SIGNATURE_SALT);
    sb.push_str(&sorted_kv_concat(params));
    sb.push_str(config::WEB_SIGNATURE_SALT);
    crypto::md5_str(&sb)
}

/// KgSigner.CalcLoginKey —— 登录/部分 raw api 内联用。
///
/// `md5(AppId + LiteSalt + ClientVer + clienttime)`。
/// 调用方负责传入正确单位：
/// - `login_by_mobile` 传**毫秒**（与 clienttime_ms 字段一致）
/// - `user_cloud` 传**秒**（与 .NET RawUserApi.GetCloudAsync 一致）
pub fn calc_login_key(clienttime: i64) -> String {
    let raw = format!("{}{}{}{}", config::APP_ID, config::LITE_SALT, config::CLIENT_VER, clienttime);
    crypto::md5_str(&raw)
}

/// fm.service.kugou.com 专用 key（标准客户端身份）。
///
/// 对应 KuGouMusicApi 的 `signParamsKey`（非 lite 平台）：
/// `md5(officialAppid + OfficialSalt + officialClientver + clienttime)`。
/// fm.service 的歌曲列表接口只对标准客户端身份（appid=1005）返回数据，
/// Lite 身份（appid=3116）会得到 status=1 但 data 为空的响应。
pub fn calc_official_key(clienttime: i64) -> String {
    let raw = format!(
        "{}{}{}{}",
        config::OFFICIAL_APP_ID,
        config::OFFICIAL_SALT,
        config::OFFICIAL_CLIENT_VER,
        clienttime
    );
    crypto::md5_str(&raw)
}

/// KgSigner.CalcCloudKey —— 云盘 key。
///
/// `md5("musicclound" + hash + pid + salt)`，salt 为硬编码常量。
pub fn calc_cloud_key(hash: &str, pid: i64) -> String {
    const CLOUD_SALT: &str = "ebd1ac3134c880bda6a2194537843caa0162e2e7";
    crypto::md5_str(&format!("musicclound{}{}{}", hash, pid, CLOUD_SALT))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn md5_empty_string_quirk() {
        assert_eq!(crypto::md5_str(""), "");
        assert_eq!(crypto::md5_str("abc"), "900150983cd24fb0d6963f7d28e17f72");
    }

    #[test]
    fn default_signature_is_deterministic() {
        let mut params = BTreeMap::new();
        params.insert("b".into(), "2".into());
        params.insert("a".into(), "1".into());
        let sig = calc_post_signature(&params, "", config::LITE_SALT);
        let expected_input = format!("{}a=1b=2{}", config::LITE_SALT, config::LITE_SALT);
        assert_eq!(sig, crypto::md5_str(&expected_input));
        assert_eq!(sig.len(), 32);
    }

    #[test]
    fn official_signature_uses_official_salt() {
        let mut params = BTreeMap::new();
        params.insert("appid".into(), config::OFFICIAL_APP_ID.into());
        let sig_official = calc_post_signature(&params, "", config::OFFICIAL_SALT);
        let sig_lite = calc_post_signature(&params, "", config::LITE_SALT);
        assert_ne!(sig_official, sig_lite);
    }

    #[test]
    fn v5_key_format() {
        let key = calc_v5_key("abc123", "user1", "mid456");
        let expected = crypto::md5_str(&format!(
            "{}{}{}{}{}",
            "abc123", config::V5_KEY_SALT, config::APP_ID, "mid456", "user1"
        ));
        assert_eq!(key, expected);
        assert_eq!(key.len(), 32);
    }

    #[test]
    fn web_signature_ignores_body() {
        let mut params = BTreeMap::new();
        params.insert("key".into(), "qrcode_value".into());
        let sig = calc_web_qr_signature(&params);
        let expected_input = format!(
            "{}key=qrcode_value{}",
            config::WEB_SIGNATURE_SALT, config::WEB_SIGNATURE_SALT
        );
        assert_eq!(sig, crypto::md5_str(&expected_input));
    }

    #[test]
    fn byte_order_sort() {
        let mut params = BTreeMap::new();
        params.insert("b".into(), "1".into());
        params.insert("A".into(), "2".into());
        params.insert("a".into(), "3".into());
        let concat = sorted_kv_concat(&params);
        assert_eq!(concat, "A=2a=3b=1");
    }

    #[test]
    fn binary_signature_equivalent_to_concat() {
        let mut params = BTreeMap::new();
        params.insert("a".into(), "1".into());
        let body = b"binarypayload";
        let sig_bin = calc_post_signature_binary(&params, body, config::LITE_SALT);
        let mut manual = Vec::new();
        manual.extend_from_slice(config::LITE_SALT.as_bytes());
        manual.extend_from_slice(b"a=1");
        manual.extend_from_slice(body);
        manual.extend_from_slice(config::LITE_SALT.as_bytes());
        use md5::Md5;
        use digest::Digest;
        let mut h = Md5::new();
        h.update(&manual);
        assert_eq!(sig_bin, hex::encode(h.finalize()));
    }

    #[test]
    fn calc_new_mid_decimal_of_md5() {
        let mid = crypto::calc_new_mid("testdfid");
        let md5_hex = crypto::md5_str("testdfid");
        let expected = u128::from_str_radix(&md5_hex, 16).unwrap().to_string();
        assert_eq!(mid, expected);
        assert!(mid.chars().all(|c| c.is_ascii_digit()));
    }

    #[test]
    fn login_key_uses_ms_timestamp() {
        let ms: i64 = 1_700_000_000_000;
        let k = calc_login_key(ms);
        let expected = crypto::md5_str(&format!(
            "{}{}{}{}",
            config::APP_ID, config::LITE_SALT, config::CLIENT_VER, ms
        ));
        assert_eq!(k, expected);
    }

    #[test]
    fn official_key_uses_official_identity() {
        let ms: i64 = 1_700_000_000_000;
        let k = calc_official_key(ms);
        let expected = crypto::md5_str(&format!(
            "{}{}{}{}",
            config::OFFICIAL_APP_ID, config::OFFICIAL_SALT, config::OFFICIAL_CLIENT_VER, ms
        ));
        assert_eq!(k, expected);
        // 与 Lite 身份的 key 不同（salt/appid/clientver 均不同）
        assert_ne!(k, calc_login_key(ms));
    }
}
