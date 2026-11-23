//! Trino's REST protocol (decision 0048) against a stand-in coordinator: a
//! statement's pages followed to the last, its rows in order, a page asked
//! again when Trino says so, Trino's error and a refused token; a tagged
//! client's tags and its query's id in the log. No Trino.

use std::sync::Arc;

use common::{coordinator, coordinator_seen, two_pages};
use serde_json::json;
use trino_client::{TrinoClient, TrinoError};

mod common;

#[tokio::test]
async fn a_statements_pages_are_followed_to_the_last_in_order() {
    let base = coordinator(Arc::new(|base, path, hits| match (path, hits) {
        // Trino asks the first page to be asked again.
        ("/v1/statement", 0) => (503, String::new()),
        ("/v1/statement", _) => (200, json!({ "nextUri": format!("{base}/1") }).to_string()),
        ("/1", _) => (
            200,
            json!({ "data": [[1, "007"]], "nextUri": format!("{base}/2") }).to_string(),
        ),
        ("/2", _) => (200, json!({ "data": [[2, "120"]] }).to_string()),
        _ => (404, String::new()),
    }))
    .await;
    let client = TrinoClient::new(&base, None).unwrap();
    let rows = client.execute("t0k", "SELECT 1").await.unwrap();
    assert_eq!(
        rows,
        [vec![json!(1), json!("007")], vec![json!(2), json!("120")]]
    );
}

#[tokio::test]
async fn trinos_error_and_a_refused_token_are_said() {
    let base = coordinator(Arc::new(|_, _, _| {
        let error = json!({ "error": { "errorName": "TABLE_NOT_FOUND", "message": "no t" } });
        (200, error.to_string())
    }))
    .await;
    let client = TrinoClient::new(&base, None).unwrap();
    assert_eq!(
        client.execute("t0k", "SELECT * FROM t").await,
        Err(TrinoError::Failed {
            name: "TABLE_NOT_FOUND".into(),
            message: "no t".into()
        })
    );
    assert_eq!(
        client.execute("other", "SELECT 1").await,
        Err(TrinoError::Refused(401))
    );
}

#[tokio::test]
async fn a_tagged_client_sends_its_tags_with_the_statement_only() {
    let (base, seen) = coordinator_seen(two_pages()).await;
    let client = TrinoClient::new(&base, None).unwrap();
    let job = "00000000-0000-4000-8000-00000000000a";
    let run = "00000000-0000-4000-8000-00000000000b";
    let tagged = client.tagged(&[("job", job), ("run", run)]);
    tagged.execute("t0k", "SELECT 1").await.unwrap();
    // Untagged, and tagged with none that is safe: no header.
    client.execute("t0k", "SELECT 1").await.unwrap();
    let unsafe_tags = [
        ("job", "a,b"),
        ("run", "x y"),
        ("", "1"),
        ("job", ""),
        ("jöb", "1"),
    ];
    client
        .tagged(&unsafe_tags)
        .execute("t0k", "SELECT 1")
        .await
        .unwrap();
    // A safe one is kept beside an unsafe one.
    client
        .tagged(&[("job", job), ("run", "a:b")])
        .execute("t0k", "SELECT 1")
        .await
        .unwrap();
    let seen = seen.lock().unwrap().clone();
    let tags = Some(format!("job:{job},run:{run}"));
    let only_job = Some(format!("job:{job}"));
    let want: Vec<(String, Option<String>)> = [
        ("/v1/statement", tags),
        ("/1", None),
        ("/v1/statement", None),
        ("/1", None),
        ("/v1/statement", None),
        ("/1", None),
        ("/v1/statement", only_job),
        ("/1", None),
    ]
    .into_iter()
    .map(|(p, t)| (p.to_string(), t))
    .collect();
    assert_eq!(seen, want);
}
