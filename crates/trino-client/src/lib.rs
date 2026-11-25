//! A client of Trino's REST protocol (decision 0048): a statement posted to
//! `/v1/statement` with a bearer token, its pages followed by `nextUri` to
//! the last; its rows as JSON values, or Trino's error. A page Trino asks
//! to be asked again (503) is, a few times. A client may be tagged for one
//! job (decision 0026, point 1): its statements carry Trino's client tags,
//! and each one's query id is logged as it starts.
//!
//! For a job runner (decision 0090, points 6.2 and 7.5): [`TrinoClient::run`]
//! sends a source's secrets as extra credentials, hands the query id to the
//! caller before the first page is followed, and answers the statement's
//! columns and update type; [`TrinoClient::kill`] ends a query by id.

use std::time::Duration;

use serde_json::Value;

mod answer;
mod error;

pub use answer::{Answer, Column};
pub use error::TrinoError;

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
    async fn page(
        &self,
        token: &str,
        next: Option<&str>,
        sql: &str,
        extra: &[(&str, &str)],
    ) -> Result<Value, TrinoError> {
        let mut tries = 0;
        loop {
            // The tags go with the statement only: Trino keeps the
            // session's and ignores them on the follow-ups (verified).
            let request = match next {
                Some(uri) => self.http.get(uri),
                None => {
                    let mut post = self
                        .http
                        .post(format!("{}/v1/statement", self.base))
                        .body(sql.to_string());
                    for (name, value) in extra {
                        post = post.header("X-Trino-Extra-Credential", credential(name, value));
                    }
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
                .map_err(|e| TrinoError::Unavailable(e.without_url().to_string()))?;
            let status = res.status().as_u16();
            match status {
                200 => {
                    return res
                        .json()
                        .await
                        .map_err(|e| TrinoError::Unavailable(e.without_url().to_string()))
                }
                401 | 403 => return Err(TrinoError::Refused(status)),
                // The query is gone from the coordinator (a restart).
                404 if next.is_some() => return Err(TrinoError::Gone),
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
            .map_err(|e| TrinoError::Unavailable(e.without_url().to_string()))?;
        let status = res.status().as_u16();
        match status {
            200 => {}
            401 | 403 => return Err(TrinoError::Refused(status)),
            _ => return Err(TrinoError::Unavailable(format!("HTTP {status}"))),
        }
        let list: Value = res
            .json()
            .await
            .map_err(|e| TrinoError::Unavailable(e.without_url().to_string()))?;
        active(&list).ok_or_else(|| TrinoError::Unavailable("not a list of queries".into()))
    }

    /// Runs `sql` with `token`: every row of every page, in order. Its
    /// query's id is logged once Trino gives it (`trino_query_id`), in the
    /// caller's span, never the statement; Trino's own line for the query
    /// (`TIMELINE: Query <id> :: …`) names the same id.
    pub async fn execute(&self, token: &str, sql: &str) -> Result<Vec<Vec<Value>>, TrinoError> {
        Ok(self.run(token, sql, &[], |_| {}).await?.rows)
    }

    /// Runs `sql` with `token`, sending `extra` as Trino's extra credentials
    /// (`name=value`, the value percent-encoded) with the statement only.
    /// `started` gets the query id before any page is followed, so a caller
    /// can store it first; the answer has the columns, the update type and
    /// every row.
    pub async fn run(
        &self,
        token: &str,
        sql: &str,
        extra: &[(&str, &str)],
        mut started: impl FnMut(&str) + Send,
    ) -> Result<Answer, TrinoError> {
        let mut answer = Answer::default();
        let mut next: Option<String> = None;
        loop {
            let page = self.page(token, next.as_deref(), sql, extra).await?;
            if next.is_none() {
                if let Some(id) = page.get("id").and_then(Value::as_str) {
                    tracing::info!(trino_query_id = id, "trino query started");
                    answer.query_id = Some(id.to_string());
                    started(id);
                }
            }
            if let Some(error) = page.get("error") {
                return Err(TrinoError::from_error(error));
            }
            answer.read_page(&page);
            match page.get("nextUri").and_then(Value::as_str) {
                Some(uri) => next = Some(uri.to_string()),
                None => return Ok(answer),
            }
        }
    }

    /// Ends the query `id` (`DELETE /v1/query/{id}`); one already gone is
    /// ended too.
    pub async fn kill(&self, token: &str, id: &str) -> Result<(), TrinoError> {
        let status = self.query_call(reqwest::Method::DELETE, token, id).await?;
        match status {
            200..=299 | 404 | 410 => Ok(()),
            401 | 403 => Err(TrinoError::Refused(status)),
            _ => Err(TrinoError::Unavailable(format!("HTTP {status}"))),
        }
    }

    /// Whether the query `id` is gone or done (`GET /v1/query/{id}`): a
    /// retry waits for it before it starts again.
    pub async fn query_ended(&self, token: &str, id: &str) -> Result<bool, TrinoError> {
        let res = self
            .http
            .get(self.query_url(id)?)
            .bearer_auth(token)
            .header("X-Trino-Source", "quality-data")
            .timeout(Duration::from_secs(10))
            .send()
            .await
            .map_err(|e| TrinoError::Unavailable(e.without_url().to_string()))?;
        let status = res.status().as_u16();
        match status {
            404 | 410 => return Ok(true),
            200 => {}
            401 | 403 => return Err(TrinoError::Refused(status)),
            _ => return Err(TrinoError::Unavailable(format!("HTTP {status}"))),
        }
        let info: Value = res
            .json()
            .await
            .map_err(|e| TrinoError::Unavailable(e.without_url().to_string()))?;
        Ok(matches!(
            info.get("state").and_then(Value::as_str),
            Some("FINISHED" | "FAILED")
        ))
    }

    fn query_url(&self, id: &str) -> Result<String, TrinoError> {
        let safe = !id.is_empty() && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_');
        if !safe {
            return Err(TrinoError::Unavailable("not a query id".into()));
        }
        Ok(format!("{}/v1/query/{id}", self.base))
    }

    async fn query_call(
        &self,
        method: reqwest::Method,
        token: &str,
        id: &str,
    ) -> Result<u16, TrinoError> {
        let res = self
            .http
            .request(method, self.query_url(id)?)
            .bearer_auth(token)
            .header("X-Trino-Source", "quality-data")
            .timeout(Duration::from_secs(10))
            .send()
            .await
            .map_err(|e| TrinoError::Unavailable(e.without_url().to_string()))?;
        Ok(res.status().as_u16())
    }
}

/// `name=value` for `X-Trino-Extra-Credential`, the value percent-encoded
/// but for unreserved characters, as Trino's own clients send it.
fn credential(name: &str, value: &str) -> String {
    let mut out = format!("{name}=");
    for b in value.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
            out.push(char::from(b));
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
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
