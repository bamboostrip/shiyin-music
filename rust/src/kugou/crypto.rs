//! 加密/编码原语 —— 1:1 对应 .NET 的 `util/KGUtils.cs` + `util/KGCrypto.cs`。
//!
//! Phase 0 只实现签名链路用到的：[`md5_str`] / [`random_string`] / [`calc_new_mid`] /
//! [`decode_lyrics`]（KRC）。AES-256/128（登录 t1/t2、设备注册）和 RSA（登录 pk）
//! 留到 Phase 4（注释见文末），届时在 Cargo.toml 解开 aes/cbc/cipher/rsa/num-bigint。
//
// cipher 0.5 的 `Array::from_slice` 被标记 deprecated（建议 TryFrom），但它在此处
// 用法正确且无替代更简洁，故模块级静默。
#![allow(deprecated)]

use std::io::Read;

use base64::Engine;
use digest::Digest;
use md5::Md5;

/// KgUtils.RandomString 用的字符表
const RANDOM_CHARS: &[u8] = b"1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ";

/// KgUtils.RandomString —— 生成指定长度的随机字符串（大写字母+数字）。
pub fn random_string(length: usize) -> String {
    (0..length)
        .map(|_| {
            let idx = rand::random_range(0..RANDOM_CHARS.len());
            RANDOM_CHARS[idx] as char
        })
        .collect()
}

/// KgUtils.Md5 —— 小写 hex MD5。
///
/// **怪癖**：空串返回空串（与 .NET 一致，标准 md5 会返回
/// `d41d8cd98f00b204e9800998ecf8427e`）。调用方注意：`mid` 派生时若 dfid 为空
/// 会走到这里，要和 .NET 行为对齐。
pub fn md5_str(input: &str) -> String {
    if input.is_empty() {
        return String::new();
    }
    let mut hasher = Md5::new();
    hasher.update(input.as_bytes());
    hex::encode(hasher.finalize())
}

/// KgUtils.CalcNewMid —— 把 guid(d5(dfid)) 视为 128 位无符号整数，
/// 输出其十进制字符串。
///
/// .NET 用 `BigInteger.Parse("0"+md5hex, HexNumber)`，前置 "0" 仅是为了规避
/// 负数符号；md5 恰好 128 位，用 u128 等价且无需 num-bigint。
pub fn calc_new_mid(guid: &str) -> String {
    let md5_hex = md5_str(guid);
    if md5_hex.is_empty() {
        return "0".to_string();
    }
    u128::from_str_radix(&md5_hex, 16)
        .expect("md5 hex 必然是合法的 128 位十六进制")
        .to_string()
}

// ===== KRC 歌词解码 =====

/// KGCrypto.DecodeLyrics —— KRC 歌词解密。
///
/// 流程：base64 解码 → 丢弃前 4 字节 → 用 16 字节循环 key 异或 → zlib 解压 → UTF-8。
/// 任何一步失败返回空串（与 .NET 的 try/catch 一致）。
pub fn decode_lyrics(base64_str: &str) -> String {
    if base64_str.is_empty() {
        return String::new();
    }
    let bytes = match base64::engine::general_purpose::STANDARD.decode(base64_str) {
        Ok(b) => b,
        Err(_) => return String::new(),
    };
    if bytes.len() <= 4 {
        return String::new();
    }

    let en_key: [u8; 16] = [64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105];

    let krc: Vec<u8> = bytes[4..]
        .iter()
        .enumerate()
        .map(|(i, &b)| b ^ en_key[i % en_key.len()])
        .collect();

    use flate2::read::ZlibDecoder;
    let mut decoder = ZlibDecoder::new(&krc[..]);
    let mut out = String::new();
    if decoder.read_to_string(&mut out).is_err() {
        return String::new();
    }
    out
}

// ===== Phase 4：AES + RSA（登录 / 设备注册 / 歌单删除）=====

use aes::cipher::{Array, BlockCipherDecrypt, BlockCipherEncrypt, KeyInit};
use aes::{Aes128, Aes256};

/// 通用 AES 加密结果（对应 .NET 返回的 (hexStr/base64Str, tempKey)）。
pub struct AesEncryptResult {
    /// 密文（AesEncrypt 小写 hex；PlaylistAesEncrypt base64）
    pub cipher_text: String,
    /// 临时 key（明文回传给对端，由它用 RSA 加密传输）
    pub temp_key: String,
}

/// KGCrypto.AesEncrypt（AES-256-CBC，PKCS7）。
///
/// 不传 key/iv 时：随机生成 tempKey(16 字符)，key=md5(tempKey) 的 32 字符 hex 作
/// 32 字节 AES key，iv=该 hex 末 16 字符作 16 字节 IV，密文小写 hex。
/// 显式传 key+iv 时（登录 t1/t2/p3），直接用其 UTF-8 字节。
pub fn aes_encrypt(data: &str, key: Option<&str>, iv: Option<&str>) -> AesEncryptResult {
    let (actual_key, actual_iv, temp_key): (String, String, String) = match (key, iv) {
        (Some(k), Some(iv)) if !k.is_empty() && !iv.is_empty() => {
            (k.to_string(), iv.to_string(), k.to_string())
        }
        _ => {
            let tk = match key {
                Some(k) if !k.is_empty() => k.to_string(),
                _ => random_string(16).to_lowercase(),
            };
            let md5k = md5_str(&tk);
            let iv = md5k[md5k.len() - 16..].to_string();
            (md5k, iv, tk)
        }
    };

    let cipher = cbc_encrypt::<Aes256>(data.as_bytes(), actual_key.as_bytes(), actual_iv.as_bytes());
    AesEncryptResult {
        cipher_text: hex::encode(cipher),
        temp_key,
    }
}

/// KGCrypto.AesDecrypt（AES-256-CBC，hex 密文，key 为 tempKey 明文）。
pub fn aes_decrypt(hex_data: &str, key: &str) -> String {
    let md5k = md5_str(key);
    let iv = md5k[md5k.len() - 16..].to_string();
    let cipher = hex::decode(hex_data).expect("AES 解密输入须为合法 hex");
    let plain = cbc_decrypt::<Aes256>(&cipher, md5k.as_bytes(), iv.as_bytes());
    String::from_utf8(plain).expect("AES 解密结果须为合法 UTF-8")
}

/// KGCrypto.PlaylistAesEncrypt（AES-128-CBC，base64 密文）。
///
/// 设备注册/歌单删除用：key=随机 6 字符，encryptKey=md5(key) 前 16 字符，
/// iv=后 16 字符，密文 base64。
pub fn playlist_aes_encrypt(json: &str) -> AesEncryptResult {
    let key = random_string(6).to_lowercase();
    let md5k = md5_str(&key);
    let encrypt_key = &md5k[..16];
    let iv = &md5k[16..32];
    let cipher = cbc_encrypt::<Aes128>(json.as_bytes(), encrypt_key.as_bytes(), iv.as_bytes());
    AesEncryptResult {
        cipher_text: base64::engine::general_purpose::STANDARD.encode(cipher),
        temp_key: key,
    }
}

/// KGCrypto.PlaylistAesDecrypt（AES-128-CBC，base64 密文）。
pub fn playlist_aes_decrypt(base64_data: &str, key: &str) -> String {
    let md5k = md5_str(key);
    let encrypt_key = &md5k[..16];
    let iv = &md5k[16..32];
    let cipher = base64::engine::general_purpose::STANDARD
        .decode(base64_data)
        .expect("Playlist AES 解密输入须为合法 base64");
    let plain = cbc_decrypt::<Aes128>(&cipher, encrypt_key.as_bytes(), iv.as_bytes());
    String::from_utf8(plain).expect("Playlist AES 解密结果须为合法 UTF-8")
}

const BLOCK_SIZE: usize = 16;

/// PKCS7 填充。
fn pkcs7_pad(data: &[u8]) -> Vec<u8> {
    let pad = BLOCK_SIZE - (data.len() % BLOCK_SIZE);
    let mut out = data.to_vec();
    out.extend(std::iter::repeat_n(pad as u8, pad));
    out
}

/// PKCS7 去填充（失败 panic，与 .NET TransformFinalBlock 一致）。
fn pkcs7_unpad(data: &[u8]) -> Vec<u8> {
    let pad = *data.last().expect("PKCS7 去填充：空数据") as usize;
    assert!(pad > 0 && pad <= BLOCK_SIZE, "PKCS7 去填充：非法填充值 {pad}");
    data[..data.len() - pad].to_vec()
}

/// 手写 CBC 加密（PKCS7）：用 aes 的逐块原语，避免 cbc 0.2 不稳定的上层 API。
fn cbc_encrypt<Aes>(data: &[u8], key: &[u8], iv: &[u8]) -> Vec<u8>
where
    Aes: BlockCipherEncrypt + KeyInit,
{
    let cipher = Aes::new(Array::from_slice(key));
    let iv_arr: [u8; BLOCK_SIZE] = iv[..BLOCK_SIZE].try_into().expect("IV 须为 16 字节");
    let padded = pkcs7_pad(data);

    let mut prev = iv_arr;
    let mut out = Vec::with_capacity(padded.len());
    for chunk in padded.chunks(BLOCK_SIZE) {
        let mut block: [u8; BLOCK_SIZE] = chunk.try_into().expect("块大小");
        for i in 0..BLOCK_SIZE {
            block[i] ^= prev[i];
        }
        let block_ga = Array::from_mut_slice(&mut block);
        cipher.encrypt_block(block_ga);
        out.extend_from_slice(&block);
        prev = block;
    }
    out
}

/// 手写 CBC 解密（PKCS7）。
fn cbc_decrypt<Aes>(cipher_data: &[u8], key: &[u8], iv: &[u8]) -> Vec<u8>
where
    Aes: BlockCipherDecrypt + KeyInit,
{
    let cipher = Aes::new(Array::from_slice(key));
    let iv_arr: [u8; BLOCK_SIZE] = iv[..BLOCK_SIZE].try_into().expect("IV 须为 16 字节");

    let mut prev = iv_arr;
    let mut out = Vec::with_capacity(cipher_data.len());
    for chunk in cipher_data.chunks(BLOCK_SIZE) {
        let ct: [u8; BLOCK_SIZE] = chunk.try_into().expect("密文须为 16 字节倍数");
        let mut block = ct;
        let block_ga = Array::from_mut_slice(&mut block);
        cipher.decrypt_block(block_ga);
        for i in 0..BLOCK_SIZE {
            block[i] ^= prev[i];
        }
        out.extend_from_slice(&block);
        prev = ct;
    }
    pkcs7_unpad(&out)
}

// ===== RSA（登录 pk 裸模幂 / 设备注册 PKCS1）=====

use num_bigint::BigUint;
use rsa::{pkcs8::DecodePublicKey, traits::PublicKeyParts, RsaPublicKey};

/// 从 PEM 取 (n, e, key_size_bytes)。用 rsa crate 解析公钥。
fn rsa_pubkey(is_lite: bool) -> (BigUint, BigUint, usize) {
    let pem = if is_lite {
        crate::kugou::config::PUBLIC_LITE_RSA_KEY_PEM
    } else {
        crate::kugou::config::PUBLIC_RSA_KEY_PEM
    };
    let pub_key = RsaPublicKey::from_public_key_pem(&rewrap_pem(pem)).expect("解析 RSA 公钥失败");
    let bits = pub_key.n().bits();
    let key_size = bits.div_ceil(8);
    let n = BigUint::from_bytes_be(&pub_key.n().to_bytes_be());
    let e = BigUint::from_bytes_be(&pub_key.e().to_bytes_be());
    (n, e, key_size)
}

/// 把单行 base64 的 PEM 体重排成每行 64 字符（PEM 标准），避免 pem crate 拒绝。
fn rewrap_pem(pem: &str) -> String {
    let lines: Vec<&str> = pem.lines().collect();
    let header = lines.first().copied().unwrap_or("");
    let footer = lines.last().copied().unwrap_or("");
    let body: String = lines
        .iter()
        .skip(1)
        .take(lines.len().saturating_sub(2))
        .flat_map(|s| s.chars())
        .collect();
    let mut out = String::from(header);
    out.push('\n');
    for chunk in body.as_bytes().chunks(64) {
        out.push_str(std::str::from_utf8(chunk).unwrap_or_default());
        out.push('\n');
    }
    out.push_str(footer);
    out
}

/// KGCrypto.RsaEncryptNoPadding —— 裸 RSA 模幂（教科书 RSA，无 padding）。
///
/// .NET 行为：明文右填充 0 到 key_size 字节（数据在前，0 在后），作为
/// **大端无符号**整数 m；c = m^e mod n；结果**左填充** 0 到 key_size 字节；
/// 输出小写 hex（调用方按需 .to_uppercase()）。
pub fn rsa_encrypt_no_padding(data: &str, is_lite: bool) -> String {
    let (n, e, key_size) = rsa_pubkey(is_lite);
    let data_bytes = data.as_bytes();

    let mut padded = vec![0u8; key_size];
    let copy_len = data_bytes.len().min(key_size);
    padded[..copy_len].copy_from_slice(&data_bytes[..copy_len]);

    let m = BigUint::from_bytes_be(&padded);
    let c = m.modpow(&e, &n);
    let res_bytes = c.to_bytes_be();

    let mut out = vec![0u8; key_size];
    let r = res_bytes.len().min(key_size);
    out[key_size - r..].copy_from_slice(&res_bytes[..r]);
    hex::encode(out)
}

/// KGCrypto.RsaEncryptPkcs1 —— 标准 PKCS#1 v1.5。
///
/// 设备注册/歌单删除的 `p` 参数用这个。输出小写 hex（调用方 .to_uppercase()）。
pub fn rsa_encrypt_pkcs1(data: &str, is_lite: bool) -> String {
    let pem = if is_lite {
        crate::kugou::config::PUBLIC_LITE_RSA_KEY_PEM
    } else {
        crate::kugou::config::PUBLIC_RSA_KEY_PEM
    };
    let pub_key = RsaPublicKey::from_public_key_pem(&rewrap_pem(pem)).expect("解析 RSA 公钥失败");
    let mut rng = rsa::rand_core::OsRng;
    let encrypted = pub_key
        .encrypt(&mut rng, rsa::Pkcs1v15Encrypt, data.as_bytes())
        .expect("RSA PKCS1 加密失败");
    hex::encode(encrypted)
}

#[cfg(test)]
mod crypto_tests {
    use super::*;

    #[test]
    fn aes256_roundtrip_with_random_key() {
        let plain = "hello 酷狗 🎵";
        let enc = aes_encrypt(plain, None, None);
        let dec = aes_decrypt(&enc.cipher_text, &enc.temp_key);
        assert_eq!(dec, plain);
    }

    #[test]
    fn aes256_explicit_key_produces_valid_hex() {
        let key = "5e4ef500e9597fe004bd09a46d8add98";
        let iv = "04bd09a46d8add98";
        let plain = "|1700000000000";
        let enc = aes_encrypt(plain, Some(key), Some(iv));
        assert!(enc.cipher_text.chars().all(|c| c.is_ascii_hexdigit()));
        assert!(enc.cipher_text.len().is_multiple_of(32));
    }

    #[test]
    fn playlist_aes128_roundtrip() {
        let json = r#"{"brand":"Redmi","imei":"abc123"}"#;
        let enc = playlist_aes_encrypt(json);
        let dec = playlist_aes_decrypt(&enc.cipher_text, &enc.temp_key);
        assert_eq!(dec, json);
    }

    #[test]
    fn rsa_no_padding_is_128_bytes_hex() {
        let out = rsa_encrypt_no_padding(r#"{"clienttime_ms":1,"key":"abc"}"#, true);
        assert_eq!(out.len(), 256);
        assert!(out.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn rsa_pkcs1_is_128_bytes_hex() {
        let out = rsa_encrypt_pkcs1(r#"{"aes":"abc","uid":"0","token":""}"#, true);
        assert_eq!(out.len(), 256);
        assert!(out.chars().all(|c| c.is_ascii_hexdigit()));
    }
}
