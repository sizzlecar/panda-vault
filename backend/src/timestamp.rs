/// 全局 NaiveDateTime <-> Unix timestamp (f64) 序列化
/// 用法: #[serde(serialize_with = "crate::timestamp::serialize")]
///       #[serde(serialize_with = "crate::timestamp::serialize_opt")]
use chrono::NaiveDateTime;
use serde::Serializer;

pub fn serialize<S: Serializer>(dt: &NaiveDateTime, s: S) -> Result<S::Ok, S::Error> {
    s.serialize_f64(dt.and_utc().timestamp() as f64)
}

pub fn serialize_opt<S: Serializer>(dt: &Option<NaiveDateTime>, s: S) -> Result<S::Ok, S::Error> {
    match dt {
        Some(dt) => s.serialize_f64(dt.and_utc().timestamp() as f64),
        None => s.serialize_none(),
    }
}
