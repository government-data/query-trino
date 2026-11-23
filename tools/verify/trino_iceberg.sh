#!/bin/sh
# Verification for decision 0018: Trino reads and writes the lake's Iceberg
# tables through RustFS's REST catalog (SigV4), and DuckDB reads what Trino
# writes. Synthetic data (Trino's tpch connector). Run from the repository
# root against the dev stack (watch mode); it starts a throwaway Trino on
# port 8099 and removes it at the end. Credentials stay in the environment.
#
#   sh tools/verify/trino_iceberg.sh
#
# The tables it creates are dropped with DuckDB (tools/verify/lake_iceberg.py
# has the setup): Trino drops with purge, which RustFS does not support.
set -e
export LC_ALL=C
set -a; . ./.env; set +a
D=$(mktemp -d)
trap 'docker rm -f qd-trino-test >/dev/null 2>&1; rm -rf "$D"' EXIT
mkdir -p "$D/catalog"
cp infra/traefik/certs/dev-ca.crt "$D/dev-ca.crt"

# The JVM's default truststore plus the dev CA.
docker run --rm -u root -v "$D:/work" --entrypoint sh trinodb/trino:latest -c '
  cp "$JAVA_HOME/lib/security/cacerts" /work/truststore.jks &&
  keytool -importcert -noprompt -alias qd-dev-ca -file /work/dev-ca.crt \
    -keystore /work/truststore.jks -storepass changeit >/dev/null &&
  chmod 644 /work/truststore.jks'

cat > "$D/config.properties" <<'P'
coordinator=true
node-scheduler.include-coordinator=true
http-server.http.port=8099
discovery.uri=http://localhost:8099
P
cat > "$D/catalog/lake.properties" <<'P'
connector.name=iceberg
iceberg.catalog.type=rest
iceberg.rest-catalog.uri=https://localhost/iceberg
iceberg.rest-catalog.warehouse=qd-test-lake
iceberg.rest-catalog.security=SIGV4
iceberg.rest-catalog.signing-name=s3
fs.native-s3.enabled=true
s3.endpoint=https://localhost
s3.region=us-east-1
s3.path-style-access=true
s3.aws-access-key=${ENV:RUSTFS_ACCESS_KEY}
s3.aws-secret-key=${ENV:RUSTFS_SECRET_KEY}
# Only for this test: production keeps Trino's 7-day minimum.
iceberg.expire-snapshots.min-retention=0s
iceberg.remove-orphan-files.min-retention=0s
P
printf 'connector.name=tpch\n' > "$D/catalog/tpch.properties"

docker run -d --name qd-trino-test --network host \
  -e RUSTFS_ACCESS_KEY -e RUSTFS_SECRET_KEY \
  -e JAVA_TOOL_OPTIONS="-Djavax.net.ssl.trustStore=/etc/trino/truststore.jks -Djavax.net.ssl.trustStorePassword=changeit" \
  -v "$D/config.properties:/etc/trino/config.properties:ro" \
  -v "$D/catalog:/etc/trino/catalog:ro" \
  -v "$D/truststore.jks:/etc/trino/truststore.jks:ro" \
  trinodb/trino:latest >/dev/null
for i in $(seq 1 90); do
  docker logs qd-trino-test 2>&1 | grep -q "SERVER STARTED" && break
  sleep 2
done
set +e

trino() {
  docker exec qd-trino-test trino --server localhost:8099 --output-format TSV --execute "$1" 2>&1 | grep -v '^Picked up'
}
q() {
  start=$(date +%s.%N)
  out=$(trino "$2"); rc=$?
  case "$out" in *"failed:"*) rc=1 ;; esac
  secs=$(echo "$(date +%s.%N) - $start" | bc)
  [ $rc -eq 0 ] && st="OK  " || st="FAIL"
  printf "[%s] %-48s %6.1fs  %s\n" "$st" "$1" "$secs" "$(echo "$out" | tr '\n' ' ' | cut -c1-160)"
}

q "version" "SELECT node_version FROM system.runtime.nodes"
q "catalog reachable with SigV4" "SHOW SCHEMAS FROM lake"
q "create schema" "CREATE SCHEMA IF NOT EXISTS lake.qd_trino"
q "create table by month + bucket" "CREATE TABLE lake.qd_trino.tx (cut varchar, doc varchar, amount double, ts date) WITH (partitioning = ARRAY['month(ts)', 'bucket(doc, 8)'])"
q "insert 1.5M rows" "INSERT INTO lake.qd_trino.tx SELECT '2026-06', lpad(CAST(custkey AS varchar), 10, '0'), totalprice, orderdate FROM tpch.sf1.orders"
q "read back: rows, months" "SELECT count(*), count(DISTINCT date_trunc('month', ts)) FROM lake.qd_trino.tx"
q "files and partitions" "SELECT count(*), count(DISTINCT partition) FROM lake.qd_trino.\"tx\$files\""
q "partition pruning (one month)" "SELECT count(*) FROM lake.qd_trino.tx WHERE ts >= DATE '1995-03-01' AND ts < DATE '1995-04-01'"
q "update" "UPDATE lake.qd_trino.tx SET amount = 0 WHERE ts < DATE '1992-02-01'"
q "delete" "DELETE FROM lake.qd_trino.tx WHERE ts >= DATE '1998-08-01'"
first=$(trino "SELECT min_by(snapshot_id, committed_at) FROM lake.qd_trino.\"tx\$snapshots\"")
q "time travel to the first snapshot" "SELECT count(*) FROM lake.qd_trino.tx FOR VERSION AS OF $first"
q "compaction (optimize)" "ALTER TABLE lake.qd_trino.tx EXECUTE optimize"
q "expire snapshots" "ALTER TABLE lake.qd_trino.tx EXECUTE expire_snapshots(retention_threshold => '0s')"
q "remove orphan files" "ALTER TABLE lake.qd_trino.tx EXECUTE remove_orphan_files(retention_threshold => '0s')"
q "after maintenance: rows, files, snapshots" "SELECT (SELECT count(*) FROM lake.qd_trino.tx), (SELECT count(*) FROM lake.qd_trino.\"tx\$files\"), (SELECT count(*) FROM lake.qd_trino.\"tx\$snapshots\")"
q "schema evolution: add column" "ALTER TABLE lake.qd_trino.tx ADD COLUMN channel varchar"
q "totals (to compare with DuckDB)" "SELECT count(*), round(sum(amount)) FROM lake.qd_trino.tx"
q "drop table (expected to fail: purge)" "DROP TABLE lake.qd_trino.tx"

# DuckDB reads what Trino wrote, then drops it (without purge). QD_PY is a
# Python with duckdb (see tools/verify/lake_iceberg.py).
"${QD_PY:-python3}" -I - <<'PY'
import os, duckdb
c = duckdb.connect()
c.execute("INSTALL iceberg; LOAD iceberg; INSTALL httpfs; LOAD httpfs;")
c.execute("SET ca_cert_file='infra/traefik/certs/dev-ca.crt'")
c.execute(f"""CREATE SECRET s3 (TYPE s3, KEY_ID '{os.environ["RUSTFS_ACCESS_KEY"]}',
              SECRET '{os.environ["RUSTFS_SECRET_KEY"]}', REGION 'us-east-1', ENDPOINT 'localhost',
              URL_STYLE 'path', USE_SSL true)""")
c.execute("""ATTACH 'qd-test-lake' AS lake (TYPE iceberg, URI 'https://localhost/iceberg',
             AUTHORIZATION_TYPE 'sigv4', SIGV4_SERVICE 's3', SIGV4_REGION 'us-east-1', SECRET s3)""")
print("[OK  ] duckdb reads Trino's table, totals:", c.execute("SELECT count(*), round(sum(amount)) FROM lake.qd_trino.tx").fetchone())
c.execute("DROP TABLE lake.qd_trino.tx")
c.execute("DROP SCHEMA lake.qd_trino")
print("[OK  ] dropped with duckdb; schemas left:", c.execute("SELECT DISTINCT table_schema FROM information_schema.tables WHERE table_catalog='lake'").fetchall())
PY
