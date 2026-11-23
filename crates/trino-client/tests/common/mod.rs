//! A stand-in coordinator for the tests of Trino's REST protocol.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use serde_json::json;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

pub(crate) type Answer = dyn Fn(&str, &str, usize) -> (u16, String) + Send + Sync;

/// Each request's path and `X-Trino-Client-Tags`, in order.
pub(crate) type Seen = Arc<Mutex<Vec<(String, Option<String>)>>>;

/// A coordinator answering `answer(base, path, hits so far)`, with the
/// token `t0k` only.
pub(crate) async fn coordinator(answer: Arc<Answer>) -> String {
    coordinator_seen(answer).await.0
}

/// As [`coordinator`], and what it was sent.
pub(crate) async fn coordinator_seen(answer: Arc<Answer>) -> (String, Seen) {
    let seen = Seen::default();
    let saw = seen.clone();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let hits = Arc::new(AtomicUsize::new(0));
    let at = base.clone();
    tokio::spawn(async move {
        while let Ok((mut socket, _)) = listener.accept().await {
            let (hits, answer, at) = (hits.clone(), answer.clone(), at.clone());
            let saw = saw.clone();
            tokio::spawn(async move {
                let mut buf = vec![0u8; 8192];
                let n = socket.read(&mut buf).await.unwrap_or(0);
                let head = String::from_utf8_lossy(&buf[..n]).to_string();
                let path = head.split_whitespace().nth(1).unwrap_or("/").to_string();
                let tags = head.lines().find_map(|l| {
                    let (name, value) = l.split_once(':')?;
                    name.eq_ignore_ascii_case("x-trino-client-tags")
                        .then(|| value.trim().to_string())
                });
                saw.lock().unwrap().push((path.clone(), tags));
                let token = head
                    .lines()
                    .any(|l| l.eq_ignore_ascii_case("authorization: Bearer t0k"));
                let (status, body) = if token {
                    answer(&at, &path, hits.fetch_add(1, Ordering::SeqCst))
                } else {
                    (401, String::new())
                };
                let reply = format!(
                    "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = socket.write_all(reply.as_bytes()).await;
            });
        }
    });
    (base, seen)
}

/// A statement of two pages, the first naming its query.
pub(crate) fn two_pages() -> Arc<Answer> {
    Arc::new(|base, path, _| match path {
        "/v1/statement" => (
            200,
            json!({ "id": "20261112_000000_00001_abcde", "nextUri": format!("{base}/1") })
                .to_string(),
        ),
        "/1" => (200, json!({ "data": [[1]] }).to_string()),
        _ => (404, String::new()),
    })
}
