//! A client of Trino's REST protocol (decision 0048): a statement posted to
//! `/v1/statement` with a bearer token, its pages followed by `nextUri` to
//! the last; its rows as JSON values, or Trino's error. A page Trino asks
//! to be asked again (503) is, a few times. A client may be tagged for one
//! job (decision 0026, point 1): its statements carry Trino's client tags,
//! and each one's query id is logged as it starts.

use std::time::Duration;

use serde_json::Value;

/// Why a statement gave no rows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TrinoError {
    /// Trino could not be reached, or answered what is not its protocol.
    Unavailable(String),
    /// Trino refused the token (401) or the statement (403).
    Refused(u16),
    /// The statement failed: Trino's error name and message.
    Failed { name: String, message: String },
}

impl std::fmt::Display for TrinoError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unavailable(why) => write!(f, "trino unavailable: {why}"),
            Self::Refused(code) => write!(f, "trino refused: {code}"),
            Self::Failed { name, message } => write!(f, "trino: {name}: {message}"),
        }
    }
}

impl std::error::Error for TrinoError {}

/// Trino's coordinator, at `base` (`https://…:8490`).
#[derive(Debug, Clone)]
pub struct TrinoClient {
    http: reqwest::Client,
    base: String,
    /// `X-Trino-Client-Tags`, if the client is tagged ([`Self::tagged`]).
    tags: Option<String>,
}

/// How many times a page Trino asks to be asked again is.
const RETRIES: u32 = 5;

impl TrinoClient {
    /// A client of the coordinator at `base`, trusting `ca` (PEM) too.
    pub fn new(base: &str, ca: Option<&[u8]>) -> Result<Self, String> {
        let mut http = reqwest::Client::builder().timeout(Duration::from_secs(300));
        if let Some(pem) = ca {
            let cert = reqwest::Certificate::from_pem(pem).map_err(|e| e.to_string())?;
            http = http.add_root_certificate(cert);
        }
        Ok(Self {
            http: http.build().map_err(|e| e.to_string())?,
            base: base.trim_end_matches('/').to_string(),
            tags: None,
        })
    }

    /// This client, its statements sent with `tags` as Trino's client tags
    /// (`X-Trino-Client-Tags`), each `name:value`: for a job, `job:<id>`
    /// and `run:<cut id>`. Ids only, never a value read. Trino takes any
    /// character but the comma, trims spaces and reads the header as
    /// Latin-1 (verified, `tools/verify/trino_client_tags.sh`); a tag whose
    /// name or value is empty or has anything but ASCII letters, digits,
    /// `-`, `_` and `.` is left out. With none left, no header is sent.
    #[must_use]
    pub fn tagged<V: AsRef<str>>(&self, tags: &[(&str, V)]) -> Self {
        let safe = |s: &str| {
            !s.is_empty()
                && s.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
        };
        let tags: Vec<String> = tags
            .iter()
            .filter(|(name, value)| safe(name) && safe(value.as_ref()))
            .map(|(name, value)| format!("{name}:{}", value.as_ref()))
            .collect();
        Self {
            tags: (!tags.is_empty()).then(|| tags.join(",")),
            ..self.clone()
        }
    }

    /// One page: Trino's answer, asked again while it says so (503).
    async fn page(&self, token: &str, next: Option<&str>, sql: &str) -> Result<Value, TrinoError> {
        let mut tries = 0;
        loop {
            // The tags go with the statement only: Trino keeps the
            // session's and ignores them on the follow-ups (verified).
            let request = match next {
                Some(uri) => self.http.get(uri),
                None => {
                    let post = self
                        .http
                        .post(format!("{}/v1/statement", self.base))
                        .body(sql.to_string());
                    match &self.tags {
                        Some(tags) => post.header("X-Trino-Client-Tags", tags),
                        None => post,
                    }
                }
            };
            let res = request
                .bearer_auth(token)
                .header("X-Trino-Source", "quality-data")
                .send()
                .await
                .map_err(|e| TrinoError::Unavailable(e.to_string()))?;
            let status = res.status().as_u16();
            match status {
                200 => {
                    return res
                        .json()
                        .await
                        .map_err(|e| TrinoError::Unavailable(e.to_string()))
                }
                401 | 403 => return Err(TrinoError::Refused(status)),
                502..=504 if tries < RETRIES => {
                    tries += 1;
                    tokio::time::sleep(Duration::from_millis(100 * u64::from(tries))).await;
                }
                _ => return Err(TrinoError::Unavailable(format!("HTTP {status}"))),
            }
        }
    }

    /// How many queries Trino lists as neither `FINISHED` nor `FAILED`
    /// (`GET /v1/query`), of those the token's user may view: queued,
    /// planning, running, finishing… (decision 0066, point 9).
    pub async fn active_queries(&self, token: &str) -> Result<u64, TrinoError> {
        let res = self
            .http
            .get(format!("{}/v1/query", self.base))
            .bearer_auth(token)
            .header("X-Trino-Source", "quality-data")
            .timeout(Duration::from_secs(10))
            .send()
            .await
            .map_err(|e| TrinoError::Unavailable(e.to_string()))?;
        let status = res.status().as_u16();
        match status {
            200 => {}
            401 | 403 => return Err(TrinoError::Refused(status)),
            _ => return Err(TrinoError::Unavailable(format!("HTTP {status}"))),
        }
        let list: Value = res
            .json()
            .await
            .map_err(|e| TrinoError::Unavailable(e.to_string()))?;
        active(&list).ok_or_else(|| TrinoError::Unavailable("not a list of queries".into()))
    }

    /// Runs `sql` with `token`: every row of every page, in order. Its
    /// query's id is logged once Trino gives it (`trino_query_id`), in the
    /// caller's span, never the statement; Trino's own line for the query
    /// (`TIMELINE: Query <id> :: …`) names the same id.
    pub async fn execute(&self, token: &str, sql: &str) -> Result<Vec<Vec<Value>>, TrinoError> {
        let mut rows = Vec::new();
        let mut next: Option<String> = None;
        loop {
            let page = self.page(token, next.as_deref(), sql).await?;
            if next.is_none() {
                if let Some(id) = page.get("id").and_then(Value::as_str) {
                    tracing::info!(trino_query_id = id, "trino query started");
                }
            }
            if let Some(error) = page.get("error") {
                let text = |key: &str| {
                    error
                        .get(key)
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string()
                };
                return Err(TrinoError::Failed {
                    name: text("errorName"),
                    message: text("message"),
                });
            }
            if let Some(Value::Array(data)) = page.get("data") {
                rows.extend(data.iter().filter_map(|r| r.as_array().cloned()));
            }
            match page.get("nextUri").and_then(Value::as_str) {
                Some(uri) => next = Some(uri.to_string()),
                None => return Ok(rows),
            }
        }
    }
}

/// The queries of `/v1/query`'s answer that are not done: any state but
/// `FINISHED` and `FAILED`, one without a state included. `None` if it is
/// not a list.
fn active(list: &Value) -> Option<u64> {
    let done = |q: &Value| {
        matches!(
            q.get("state").and_then(Value::as_str),
            Some("FINISHED" | "FAILED")
        )
    };
    let n = list.as_array()?.iter().filter(|q| !done(q)).count();
    u64::try_from(n).ok()
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::active;

    #[test]
    fn active_queries_are_those_not_finished_nor_failed() {
        let list = json!([
            { "queryId": "1", "state": "FINISHED" },
            { "queryId": "2", "state": "FAILED" },
            { "queryId": "3", "state": "RUNNING" },
            { "queryId": "4", "state": "QUEUED" },
            { "queryId": "5", "state": "FINISHING" },
            { "queryId": "6" }
        ]);
        assert_eq!(active(&list), Some(4));
        assert_eq!(active(&json!([])), Some(0));
        assert_eq!(active(&json!({ "error": "x" })), None);
    }
}
