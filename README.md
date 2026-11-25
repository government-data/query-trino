# query-trino

The Trino workers of Quality Data as a module (quality-sdk decision 0011):
the machines of the role `trino-worker` run Trino's worker at the exact
release of engine-trino's coordinator (the capability `trino-cluster`),
from the same image digest. The coordinator, Trino's access rules and the
job runners are engine-trino's, in the orchestrator's repository
(`modules/engine-trino`), with the coordinator's verification scripts.

What is here:

- `crates/trino-client`: a client of Trino's REST protocol for the
  consumers of `sql-query` (a statement's pages followed to the last, the
  query id before the next page, extra credentials, kill, Trino's errors
  without their message, client tags).

The worker's manifest, compose and configuration come next.

## Checks

```sh
cargo fmt --all -- --check
cargo clippy -p trino-client --all-targets --locked -- -D warnings
cargo test -p trino-client --locked
```
