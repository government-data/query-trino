# query-trino

Trino as a module of Quality Data: it provides the capability `sql-query`
to the modules that consume it (the orchestrator), over the protocols
Trino speaks: its client protocol with a JWT per statement, access rules
read over HTTP from the consumer, the lake through Iceberg REST, S3 and
STS, and mTLS on the installation's internal entry point.

What is here today:

- `crates/trino-client`: a client of Trino's REST protocol for the
  module's consumers (a statement's pages followed to the last, Trino's
  errors, client tags, the query id in the caller's log span).

The module's manifest, compose and Trino configuration follow.

## Checks

```sh
cargo fmt --all -- --check
cargo clippy -p trino-client --all-targets --locked -- -D warnings
cargo test -p trino-client --locked
```
