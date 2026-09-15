//! 上游响应解包 —— 对应 .NET 的 `Adapters/Common/KgApiResponseParser.cs`。
//!
//! 酷狗响应形如：
//! ```json
//! { "status": 1, "error_code": 0, "data": { ...业务字段... } }
//! ```
//! 解包规则（与 .NET 严格一致）：
//! 1. 成功 = `status` 为成功值（`1`，或部分网关返回的 HTTP 码 `200`）**且**
//!    (`error_code` 不存在 **或** ==0)（`errcode` 作为 `error_code` 的别名）。
//! 2. 成功时把 `data` 提升为根节点（透传/反序列化都基于提升后的值）。
//!
//! 注意 `status==200` 的情形：少数端点（如 `/v1/search`、`/download`）经由
//! HTTP 网关返回时，外层信封用 `status:200, error_code:0` 表示成功（而不是
//! 内层的 `status:1`）。这里把 `200` 一并视为成功，避免这类端点被误判失败而
//! 刷屏 warn。

use serde_json::Value;

/// 解包结果：成功时给出提升后的 `data`（无 data 则原样），失败时给出错误码+消息。
#[derive(Debug)]
pub enum ParsedResponse {
    /// 成功：携带提升后的节点（成功且有 data 则是 data，否则是整个 root）
    Success(Value),
    /// 失败：root 的 status/error_code 与原始 root（便于上层报错）
    Failure {
        status: Option<i64>,
        err_code: Option<i64>,
        root: Value,
    },
}

fn replace_size_placeholders(val: &mut Value) {
    match val {
        Value::String(s) => {
            if s.contains("{size}") {
                *s = s.replace("{size}", "400");
            }
        }
        Value::Array(arr) => {
            for v in arr {
                replace_size_placeholders(v);
            }
        }
        Value::Object(obj) => {
            for (_, v) in obj {
                replace_size_placeholders(v);
            }
        }
        _ => {}
    }
}

/// 判定一组 (status, err_code) 是否代表成功。
///
/// 成功的 `status` 取值：`1`（酷狗内层信封）或 `200`（部分网关外层信封），
/// 且 `error_code` 不存在或为 `0`。
fn is_success_pair(root_status: Option<i64>, root_err_code: Option<i64>) -> bool {
    matches!(root_status, Some(1) | Some(200)) && matches!(root_err_code, None | Some(0))
}

/// 解析酷狗响应（对应 KgApiResponseParser.Parse，但只做透传语义）。
///
/// 业务层若需要强类型，可拿到 `Success(Value)` 后自行 `serde_json::from_value`。
pub fn parse(mut root: Value) -> ParsedResponse {
    replace_size_placeholders(&mut root);
    let root_status = root.get("status").and_then(|v| v.as_i64());
    let root_err_code = root
        .get("error_code")
        .and_then(|v| v.as_i64())
        .or_else(|| root.get("errcode").and_then(|v| v.as_i64()));

    let is_success = is_success_pair(root_status, root_err_code);

    if is_success {
        if let Some(data) = root.get("data") {
            if !data.is_null() {
                let mut promoted = data.clone();
                if let Some(obj) = promoted.as_object_mut() {
                    if !obj.contains_key("status") {
                        if let Some(status) = root_status {
                            obj.insert("status".to_string(), serde_json::json!(status));
                        }
                    }
                    if !obj.contains_key("error_code") && !obj.contains_key("errcode") {
                        if let Some(err_code) = root_err_code {
                            obj.insert("error_code".to_string(), serde_json::json!(err_code));
                        } else {
                            obj.insert("error_code".to_string(), serde_json::json!(0));
                        }
                    }
                }
                return ParsedResponse::Success(promoted);
            }
        }
        ParsedResponse::Success(root)
    } else {
        ParsedResponse::Failure {
            status: root_status,
            err_code: root_err_code,
            root,
        }
    }
}

/// 判断响应是否成功（便捷封装）。
#[allow(dead_code)]
pub fn is_success(root: &Value) -> bool {
    let status = root.get("status").and_then(|v| v.as_i64());
    let err = root
        .get("error_code")
        .and_then(|v| v.as_i64())
        .or_else(|| root.get("errcode").and_then(|v| v.as_i64()));
    is_success_pair(status, err)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn success_promotes_data() {
        let root = json!({ "status": 1, "error_code": 0, "data": { "lists": [1, 2, 3] } });
        match parse(root) {
            ParsedResponse::Success(v) => assert_eq!(
                v,
                json!({ "lists": [1, 2, 3], "status": 1, "error_code": 0 })
            ),
            _ => panic!("应成功"),
        }
    }

    #[test]
    fn success_without_data_returns_root() {
        let root = json!({ "status": 1 });
        match parse(root) {
            ParsedResponse::Success(v) => assert_eq!(v["status"], json!(1)),
            _ => panic!("应成功"),
        }
    }

    #[test]
    fn failure_with_error_code() {
        let root = json!({ "status": 0, "error_code": 9001, "err": "缺参" });
        match parse(root) {
            ParsedResponse::Failure {
                status, err_code, ..
            } => {
                assert_eq!(status, Some(0));
                assert_eq!(err_code, Some(9001));
            }
            _ => panic!("应失败"),
        }
    }

    #[test]
    fn errcode_alias_recognized() {
        let root = json!({ "status": 1, "errcode": 5 });
        assert!(matches!(parse(root), ParsedResponse::Failure { .. }));
    }

    #[test]
    fn status_one_err_absent_is_success() {
        let root = json!({ "status": 1, "data": "x" });
        assert!(matches!(parse(root), ParsedResponse::Success(_)));
    }

    #[test]
    fn gateway_status_200_is_success() {
        let root = json!({ "status": 200, "error_code": 0, "data": { "lists": [1] } });
        match parse(root) {
            ParsedResponse::Success(v) => {
                assert_eq!(v["lists"], json!([1]));
                assert_eq!(v["status"], json!(200));
                assert_eq!(v["error_code"], json!(0));
            }
            _ => panic!("status:200 应判为成功"),
        }
    }

    #[test]
    fn gateway_status_200_errcode_nonzero_is_failure() {
        let root = json!({ "status": 200, "error_code": 200 });
        assert!(matches!(parse(root), ParsedResponse::Failure { .. }));
    }

    #[test]
    fn status_2_is_failure() {
        let root = json!({ "status": 2 });
        assert!(matches!(
            parse(root),
            ParsedResponse::Failure {
                status: Some(2),
                ..
            }
        ));
    }

    #[test]
    fn test_replace_size_placeholders() {
        let root = json!({
            "status": 1,
            "error_code": 0,
            "data": {
                "pic": "http://img.kugou.com/cover/{size}/a.jpg",
                "nested": {
                    "avatar": "http://img.kugou.com/avatar/{size}/b.jpg"
                },
                "array": [
                    "http://img.kugou.com/array/{size}/c.jpg"
                ]
            }
        });
        match parse(root) {
            ParsedResponse::Success(v) => {
                assert_eq!(v["pic"], "http://img.kugou.com/cover/400/a.jpg");
                assert_eq!(
                    v["nested"]["avatar"],
                    "http://img.kugou.com/avatar/400/b.jpg"
                );
                assert_eq!(v["array"][0], "http://img.kugou.com/array/400/c.jpg");
            }
            _ => panic!("应成功"),
        }
    }
}
