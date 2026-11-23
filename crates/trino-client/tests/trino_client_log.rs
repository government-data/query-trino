//! A statement's query id in the log, in the caller's span (decision 0026,
//! point 1): a binary of its own, as a callsite first reached without a
//! subscriber by a test on another thread would stay silent here.

use common::{coordinator, two_pages};
use trino_client::TrinoClient;

mod common;

#[test]
fn a_statements_query_id_is_logged_in_the_callers_span() {
    let lines = logging::json_lines("worker", || {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async {
            let base = coordinator(two_pages()).await;
            let client = TrinoClient::new(&base, None).unwrap();
            let span = tracing::info_span!("job", job_id = "00000000-0000-4000-8000-00000000000a");
            let _in = span.enter();
            client.execute("t0k", "SELECT 'not logged'").await.unwrap();
        });
    });
    let started: Vec<_> = lines
        .iter()
        .filter(|l| l["msg"] == "trino query started")
        .collect();
    assert_eq!(started.len(), 1, "{lines:?}");
    assert_eq!(started[0]["trino_query_id"], "20261112_000000_00001_abcde");
    assert_eq!(started[0]["job_id"], "00000000-0000-4000-8000-00000000000a");
    assert!(!format!("{lines:?}").contains("not logged"));
}
