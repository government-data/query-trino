#!/bin/sh
# Verification for decision 0039's open question: reclaiming the files a
# compaction replaced, which DuckDB leaves named as DELETED in the table's
# manifests (RustFS refuses a commit if one of them is gone). Can Trino
# rewrite the manifests (optimize_manifests) so those files are named no
# more, and then delete them (expire_snapshots, remove_orphan_files), the
# table still taking writes? Synthetic data only, in the dev warehouse,
# table verify_reclaim_bronze.events_<time>. A throwaway Trino 484 (the
# dev stack's version) on port 8099, as the dev lake loader's RustFS user
# (never root); removed at the end. Counts only.
#
#   sh tools/verify/trino_reclaim.sh
set -e
export LC_ALL=C
set -a; . ./.env; set +a
: "${LAKE_LOADER_ACCESS_KEY:?run tools/dev/lake-load.sh once first}"
W=qd-tenant-00000000000000000000000000000001
T="events_$(date +%s)"
D=$(mktemp -d)
trap 'docker rm -f qd-trino-reclaim >/dev/null 2>&1; rm -rf "$D"' EXIT
mkdir -p "$D/catalog"
cp infra/traefik/certs/dev-ca.crt "$D/dev-ca.crt"
IMAGE=trinodb/trino:484

docker run --rm -u root -v "$D:/work" --entrypoint sh "$IMAGE" -c '
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
cat > "$D/catalog/lake.properties" <<P
connector.name=iceberg
iceberg.catalog.type=rest
iceberg.rest-catalog.uri=https://localhost/iceberg
iceberg.rest-catalog.warehouse=$W
iceberg.rest-catalog.security=SIGV4
iceberg.rest-catalog.signing-name=s3
fs.native-s3.enabled=true
s3.endpoint=https://localhost
s3.region=us-east-1
s3.path-style-access=true
s3.aws-access-key=\${ENV:LAKE_LOADER_ACCESS_KEY}
s3.aws-secret-key=\${ENV:LAKE_LOADER_SECRET_KEY}
# Only for this test: production keeps Trino's 7-day minimum.
iceberg.expire-snapshots.min-retention=0s
iceberg.remove-orphan-files.min-retention=0s
P
docker run -d --name qd-trino-reclaim --network host \
  -e LAKE_LOADER_ACCESS_KEY -e LAKE_LOADER_SECRET_KEY \
  -e JAVA_TOOL_OPTIONS="-Djavax.net.ssl.trustStore=/etc/trino/truststore.jks -Djavax.net.ssl.trustStorePassword=changeit" \
  -v "$D/config.properties:/etc/trino/config.properties:ro" \
  -v "$D/catalog:/etc/trino/catalog:ro" \
  -v "$D/truststore.jks:/etc/trino/truststore.jks:ro" \
  "$IMAGE" >/dev/null
for i in $(seq 1 90); do
  docker logs qd-trino-reclaim 2>&1 | grep -q "SERVER STARTED" && break
  sleep 2
done
set +e

q() {
  out=$(docker exec qd-trino-reclaim trino --server localhost:8099 --output-format TSV --execute "$2" 2>&1 | grep -v '^Picked up')
  case "$out" in *"failed:"* | *"Error"*) st=FAIL ;; *) st="OK  " ;; esac
  printf "[%s] %-58s %s\n" "$st" "$1" "$(echo "$out" | tr '\n' ' ' | cut -c1-200)"
}
# DuckDB, the worker's engine: as a maintain job leaves the table.
duck() {
  uv run --quiet --with duckdb==2.0.0 python3 -I - "$W" "$T" "$1" <<'PY'
import os, sys, duckdb
W, T, what = sys.argv[1], sys.argv[2], sys.argv[3]
c = duckdb.connect()
c.execute("INSTALL avro; LOAD avro; INSTALL iceberg; LOAD iceberg; INSTALL httpfs; LOAD httpfs;")
c.execute("SET ca_cert_file='infra/traefik/certs/dev-ca.crt'")
c.execute(f"""CREATE SECRET s3 (TYPE s3, KEY_ID '{os.environ["LAKE_LOADER_ACCESS_KEY"]}',
              SECRET '{os.environ["LAKE_LOADER_SECRET_KEY"]}', REGION 'us-east-1', ENDPOINT 'localhost',
              URL_STYLE 'path', USE_SSL true)""")
c.execute(f"""ATTACH '{W}' AS lake (TYPE iceberg, URI 'https://localhost/iceberg',
             AUTHORIZATION_TYPE 'sigv4', SIGV4_SERVICE 's3', SIGV4_REGION 'us-east-1', SECRET s3)""")
t = f"lake.verify_reclaim_bronze.{T}"
def named():
    cur = c.execute(f"SELECT snapshot_id FROM iceberg_snapshots({t}) ORDER BY sequence_number DESC LIMIT 1").fetchone()[0]
    return c.execute(f"SELECT count(DISTINCT file_path) FROM iceberg_metadata({t}, snapshot_from_id => {cur}) WHERE manifest_content = 'DATA'").fetchone()[0]
if what == "setup":
    c.execute("CREATE SCHEMA IF NOT EXISTS lake.verify_reclaim_bronze")
    c.execute(f"CREATE TABLE {t} (id INTEGER, amount DECIMAL(12,2), cut DATE) PARTITIONED BY (cut)")
    for i in range(10):
        c.execute(f"INSERT INTO {t} SELECT g, g * 1.5, DATE '2026-10-31' FROM range({i * 50}, {(i + 1) * 50}) t(g)")
    c.execute(f"SELECT * FROM iceberg_rewrite_data_files('{t}', min_input_files => 2)").fetchall()
    print(f"[OK  ] duckdb: 10 inserts, compacted; named by the current manifests: {named()}; rows", c.execute(f"SELECT count(*), sum(amount) FROM {t}").fetchone())
else:
    print(f"[OK  ] duckdb: named by the current manifests now: {named()}; rows", c.execute(f"SELECT count(*), sum(amount) FROM {t}").fetchone())
    try:
        c.execute(f"INSERT INTO {t} VALUES (999999, 1.00, DATE '2026-10-31')")
        print("[OK  ] duckdb: a write after it commits")
    except Exception as e:
        print("[FAIL] duckdb: a write after it:", str(e).replace("\n", " ")[:200])
PY
}
objects() {
  docker exec qd-trino-reclaim trino --server localhost:8099 --output-format TSV --execute \
    "SELECT count(*) FROM lake.verify_reclaim_bronze.\"$T\$files\"" 2>&1 | grep -v '^Picked up'
}

q "version" "SELECT node_version FROM system.runtime.nodes"
duck setup
q "trino: live files before" "SELECT count(*) FROM lake.verify_reclaim_bronze.\"$T\$files\""
q "trino: optimize_manifests" "ALTER TABLE lake.verify_reclaim_bronze.\"$T\" EXECUTE optimize_manifests"
q "trino: expire_snapshots (all but the current)" "ALTER TABLE lake.verify_reclaim_bronze.\"$T\" EXECUTE expire_snapshots(retention_threshold => '0s')"
q "trino: remove_orphan_files" "ALTER TABLE lake.verify_reclaim_bronze.\"$T\" EXECUTE remove_orphan_files(retention_threshold => '0s')"
q "trino: rows and live files after" "SELECT (SELECT count(*) FROM lake.verify_reclaim_bronze.\"$T\"), (SELECT count(*) FROM lake.verify_reclaim_bronze.\"$T\$files\")"
duck after
