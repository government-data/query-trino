//! What a job runner needs of Trino's protocol (decision 0090, points 6.2,
//! 7.5 and 7.6) against a stand-in coordinator: extra credentials with the
//! statement only, the query id before the next page, the answer's columns
//! and update type, a gone `nextUri`, killing a query, and errors that never
//! show Trino's message. No Trino.

use std::sync::{Arc, Mutex};

use common::{coordinator, coordinator_heads, two_pages};
use serde_json::json;
use trino_client::{Column, TrinoClient, TrinoError};

mod common;

#[tokio::test]
async fn extra_credentials_go_with_the_statement_only() {
    let (base, _, heads) = coordinator_heads(two_pages()).await;
    let client = TrinoClient::new(&base, None).unwrap();
    let extra = [("src_loans_password", "p a=ß,1")];
    client.run("t0k", "SELECT 1", &extra, |_| {}).await.unwrap();
    let heads = heads.lock().unwrap().clone();
    let credential = |h: &str| {
        h.lines()
            .filter(|l| {
                l.to_ascii_lowercase()
                    .starts_with("x-trino-extra-credential:")
            })
            .map(|l| l.split_once(':').unwrap().1.trim().to_string())
            .collect::<Vec<_>>()
    };
    assert_eq!(
        credential(&heads[0]),
        ["src_loans_password=p%20a%3D%C3%9F%2C1"]
    );
    assert!(credential(&heads[1]).is_empty(), "not on the next page");
}

#[tokio::test]
async fn the_query_id_comes_before_the_next_page_and_the_answer_is_typed() {
    let order = Arc::new(Mutex::new(Vec::<String>::new()));
    let seen = order.clone();
    let base = coordinator(Arc::new(move |base, path, _| {
        seen.lock().unwrap().push(path.to_string());
        match path {
            "/v1/statement" => (
                200,
                json!({ "id": "20261125_000000_00007_aaaaa", "nextUri": format!("{base}/1") })
                    .to_string(),
            ),
            "/1" => (
                200,
                json!({
                    "columns": [{ "name": "rows", "type": "bigint" }],
                    "data": [[3]],
                    "updateType": "INSERT",
                    "updateCount": 3
                })
                .to_string(),
            ),
            _ => (404, String::new()),
        }
    }))
    .await;
    let client = TrinoClient::new(&base, None).unwrap();
    let pages = order.clone();
    let answer = client
        .run("t0k", "INSERT INTO t SELECT 1", &[], |id| {
            pages.lock().unwrap().push(format!("id {id}"));
        })
        .await
        .unwrap();
    assert_eq!(
        *order.lock().unwrap(),
        ["/v1/statement", "id 20261125_000000_00007_aaaaa", "/1"]
    );
    assert_eq!(answer.update_type.as_deref(), Some("INSERT"));
    assert_eq!(answer.update_count, Some(3));
    assert_eq!(
        answer.columns,
        [Column {
            name: "rows".into(),
            type_name: "bigint".into()
        }]
    );
    assert_eq!(answer.rows, [vec![json!(3)]]);
}

#[tokio::test]
async fn a_gone_next_page_is_said_as_gone() {
    let base = coordinator(Arc::new(|base, path, _| match path {
        "/v1/statement" => (200, json!({ "nextUri": format!("{base}/1") }).to_string()),
        _ => (404, String::new()),
    }))
    .await;
    let client = TrinoClient::new(&base, None).unwrap();
    let err = client.execute("t0k", "SELECT 1").await.unwrap_err();
    assert_eq!(err, TrinoError::Gone);
    assert_eq!(err.kind(), "gone");
}

#[tokio::test]
async fn a_query_is_killed_and_its_end_read() {
    let (base, seen, heads) = coordinator_heads(Arc::new(|_, path, _| match path {
        "/v1/query/q_1" => (200, json!({ "state": "RUNNING" }).to_string()),
        "/v1/query/q_2" => (200, json!({ "state": "FAILED" }).to_string()),
        _ => (404, String::new()),
    }))
    .await;
    let client = TrinoClient::new(&base, None).unwrap();
    client.kill("t0k", "q_1").await.unwrap();
    client.kill("t0k", "q_gone").await.unwrap();
    assert_eq!(heads.lock().unwrap()[0].split(' ').next(), Some("DELETE"));
    assert!(!client.query_ended("t0k", "q_1").await.unwrap());
    assert!(client.query_ended("t0k", "q_2").await.unwrap());
    assert!(client.query_ended("t0k", "q_gone").await.unwrap());
    assert!(client.kill("t0k", "../x").await.is_err(), "not a query id");
    assert_eq!(seen.lock().unwrap().len(), 5, "nothing sent for ../x");
}

#[test]
fn an_error_shows_its_name_and_type_never_its_message() {
    let err = TrinoError::Failed {
        name: "INVALID_CAST_ARGUMENT".into(),
        error_type: "USER_ERROR".into(),
        message: "Cannot cast 'marker-123' to INT".into(),
    };
    assert_eq!(err.to_string(), "trino: INVALID_CAST_ARGUMENT (USER_ERROR)");
    assert!(!format!("{err:?}").contains("marker"));
    assert_eq!(err.kind(), "INVALID_CAST_ARGUMENT");
}
