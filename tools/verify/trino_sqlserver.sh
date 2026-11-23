#!/bin/bash
# Verification of reading a SQL Server source through Trino (decisions
# 0029 point 3, 0036 point 2, 0048): a SQL Server in a container on the
# edge network, a read-only login, the source made a dynamic Trino catalog
# with `CREATE CATALOG`, its tables and types listed, a table read whole and
# written to the lake's bronze stamped with its cut, the cut written again
# replacing its rows, the login unable to write, and the catalog dropped.
# Synthetic rows only. Run from the repository root with the dev stack and
# the Trino cluster up (`task trino:up`):
#
#   bash tools/verify/trino_sqlserver.sh
#
# Needs jq, curl and uv. The queries run as the dev machine client
# `qd-worker-dev` (QD_WORKER_DEV_CLIENT_SECRET). The SQL Server passwords
# are made here, kept in the environment of this run and of the containers,
# never printed; the container and the lake's test table are removed at the
# end.
set -u
export LC_ALL=C
cd "$(dirname "$0")/../.."
set -a; . ./.env; set +a
COORD=${TRINO_COORDINATOR:-data-quality-trino-coordinator-1}
EDGE=${EDGE_CONTAINER:-data-quality-traefik-1}
NET=$(docker inspect "$EDGE" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}')
MSSQL=qd-verify-mssql
IMAGE=${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}
ISS=${OIDC_ISSUER:-https://${APP_DOMAIN:-localhost}/api}
NS=verify_mssql_bronze
CUT=2026-11-03
SA="Qd-$(openssl rand -hex 12)!A1"
READER="Qr-$(openssl rand -hex 12)!B2"
FAILED=0

ok() { printf '[OK  ] %s\n' "$*"; }
ko() { printf '[FAIL] %s\n' "$*"; FAILED=1; }
expect() { # NAME EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then ok "$1: $3"; else ko "$1: expected '$2', got '$3'"; fi
}
cleanup() {
  docker rm -f "$MSSQL" >/dev/null 2>&1
  uv run --quiet --with 'pyiceberg[pyarrow]>=0.9' --with requests --with botocore --with pyyaml python -I -c "
import sys; sys.path.insert(0, 'tools/dev')
from lake_load import catalog
cat = catalog('${TRINO_LAKE_WAREHOUSE:-qd-tenant-00000000000000000000000000000001}')
for t in cat.list_tables('$NS') if ('$NS',) in cat.list_namespaces() else []:
    cat.purge_table(t)
if ('$NS',) in cat.list_namespaces(): cat.drop_namespace('$NS')
" 2>/dev/null
}
trap cleanup EXIT

# sqlserver SQL: as sa, inside the container.
sqlserver() {
  docker exec -e SQLCMDPASSWORD="$SA" "$MSSQL" /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -b -h -1 -W -Q "SET NOCOUNT ON; $1"
}

# --- Trino, as in trino_cluster_check.sh ---------------------------------------
TOKEN=$(curl -s --cacert infra/traefik/certs/dev-ca.crt -u "qd-worker-dev:${QD_WORKER_DEV_CLIENT_SECRET:?QD_WORKER_DEV_CLIENT_SECRET is needed}" \
  -d grant_type=client_credentials -d audience=trino "$ISS/oauth/token" | jq -r '.access_token // empty')
POLL='code=$(curl -s --cacert /etc/trino/extra-ca.crt -o /tmp/r -w "%{http_code}" -H "Authorization: Bearer $TOKEN" --data-binary "$Q" https://localhost:8490/v1/statement)
[ "$code" = 200 ] || { echo "HTTP $code"; exit 0; }
r=$(</tmp/r)
while :; do
  printf "%s\n" "$r"
  [[ $r =~ \"nextUri\":\"([^\"]+)\" ]] || break
  r=$(curl -s --cacert /etc/trino/extra-ca.crt -H "Authorization: Bearer $TOKEN" "${BASH_REMATCH[1]}")
done'
q() {
  docker exec -e TOKEN="$TOKEN" -e Q="$1" "$COORD" bash -c "$POLL" |
    jq -rR '(fromjson? // {"error": {"message": .}}) |
      (.data // [] | .[] | map(tostring) | join("\t")), (.error.message // empty | "ERROR: " + .)'
}

echo "== SQL Server in a container ($IMAGE, network $NET)"
docker rm -f "$MSSQL" >/dev/null 2>&1
docker run -d --name "$MSSQL" --network "$NET" -e ACCEPT_EULA=Y -e MSSQL_PID=Developer \
  -e MSSQL_SA_PASSWORD="$SA" "$IMAGE" >/dev/null || { ko "container did not start"; exit 1; }
for _ in $(seq 60); do sqlserver "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
expect "up" "1" "$(sqlserver 'SELECT 1' 2>&1 | tr -d '\r')"
ok "version: $(sqlserver "SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(20))" | tr -d '\r')"
sqlserver "CREATE DATABASE qd_verify" >/dev/null
sqlserver "USE qd_verify;
  CREATE TABLE dbo.clients (id INT PRIMARY KEY, code VARCHAR(10), name NVARCHAR(60), opened DATE,
    amount DECIMAL(12,2), active BIT, updated DATETIME2);
  INSERT INTO dbo.clients VALUES
    (1, '007', N'Cliente Uno', '2020-01-15', 1500.50, 1, '2026-10-01T08:00:00'),
    (2, '120', N'Cliente Dos', NULL, 0, 0, '2026-10-02T09:30:00'),
    (3, ' ', N'Cliente Tres', '2031-12-31', -10, 1, NULL);
  CREATE LOGIN qd_reader WITH PASSWORD = '$READER';
  CREATE USER qd_reader FOR LOGIN qd_reader;
  GRANT SELECT ON SCHEMA::dbo TO qd_reader;" >/dev/null
expect "synthetic rows" "3" "$(sqlserver 'SELECT count(*) FROM qd_verify.dbo.clients' | tr -d '\r')"

echo "== The source as a dynamic Trino catalog (0029 point 3)"
expect "create catalog" "" "$(q "CREATE CATALOG qd_verify_mssql USING sqlserver WITH (\"connection-url\" = 'jdbc:sqlserver://$MSSQL:1433;databaseName=qd_verify;encrypt=false', \"connection-user\" = 'qd_reader', \"connection-password\" = '$READER')")"
expect "its tables" "clients" "$(q 'SHOW TABLES FROM qd_verify_mssql.dbo')"
ok "its types: $(q 'DESCRIBE qd_verify_mssql.dbo.clients' | cut -f1,2 | tr '\t\n' ': ' )"
expect "read whole" "3" "$(q 'SELECT count(*) FROM qd_verify_mssql.dbo.clients')"
expect "a code keeps its leading zeros" "007" "$(q 'SELECT code FROM qd_verify_mssql.dbo.clients WHERE id = 1')"
case "$(q "INSERT INTO qd_verify_mssql.dbo.clients (id) VALUES (9)")" in
  ERROR:*) ok "the read-only login cannot write" ;;
  *) ko "the read-only login wrote" ;;
esac
# A page of records (0049 point 3, quality::source_records): one more
# than asked, in the order asked, after an offset.
expect "a page of records, last first" "3,2," "$(q "SELECT * FROM qd_verify_mssql.\"dbo\".\"clients\" ORDER BY \"id\" DESC OFFSET 0 LIMIT 2" | cut -f1 | tr '\n' ',')"
expect "the next page" "1," "$(q "SELECT * FROM qd_verify_mssql.\"dbo\".\"clients\" ORDER BY \"id\" DESC OFFSET 2 LIMIT 2" | cut -f1 | tr '\n' ',')"
# What a `tables` job sees (0048 point 2): the schemas with columns, for the
# system's ones a listing leaves out.
ok "schemas with columns: $(q "SELECT DISTINCT table_schema FROM qd_verify_mssql.information_schema.columns ORDER BY 1" | tr '\n' ' ')"
ok "a column as listed: $(q "SELECT table_schema, table_name, column_name, data_type FROM qd_verify_mssql.information_schema.columns WHERE table_name = 'clients' ORDER BY ordinal_position LIMIT 2" | tr '\t\n' ', ')"

echo "== A map's profile through Trino (0053, quality::trino_profile)"
sqlserver "USE qd_verify;
  CREATE TABLE dbo.profiled (id INT PRIMARY KEY, email NVARCHAR(60) NULL, doc VARCHAR(12) NOT NULL);
  INSERT INTO dbo.profiled VALUES
    (1, N'a@example.org', '12345678'), (2, NULL, '9876543'),
    (3, NCHAR(160), '00123'), (4, N'b@example.org', '12345678'), (5, N' ', '555555');" >/dev/null
expect "its columns, types and nullability" "id integer NO,email varchar(60) YES,doc varchar(12) NO," \
  "$(q "SELECT column_name, data_type, is_nullable FROM qd_verify_mssql.information_schema.columns WHERE table_schema = 'dbo' AND table_name = 'profiled' ORDER BY ordinal_position" | tr '\t' ' ' | tr '\n' ',')"
# As quality::trino_profile writes it: empty is NULL or blank, U+00A0
# too; a pattern is anchored; the sample is the first rows; distinct
# values approximated, exact for so few.
V='CAST("email" AS varchar)'
E="($V IS NULL OR regexp_like($V, '^[\\s\\x{00A0}]*\$'))"
D='CAST("doc" AS varchar)'
DE="($D IS NULL OR regexp_like($D, '^[\\s\\x{00A0}]*\$'))"
expect "the sample's aggregates" "5,3,2,13,13,2,0,4,5,8,5" \
  "$(q "WITH s AS (SELECT * FROM qd_verify_mssql.\"dbo\".\"profiled\" LIMIT 10)
        SELECT count(*), count(*) FILTER (WHERE $E), approx_distinct(CASE WHEN NOT $E THEN \"email\" END),
          min(length($V)) FILTER (WHERE NOT $E), max(length($V)) FILTER (WHERE NOT $E),
          count(*) FILTER (WHERE regexp_like($V, '^(?:[^@\\s]+@[^@\\s]+\\.[A-Za-z]{2,})\$')),
          count(*) FILTER (WHERE $DE), approx_distinct(CASE WHEN NOT $DE THEN \"doc\" END),
          min(length($D)) FILTER (WHERE NOT $DE), max(length($D)) FILTER (WHERE NOT $DE),
          count(*) FILTER (WHERE regexp_like($D, '^(?:\\d{5,12})\$'))
        FROM s" | tr '\t' ',')"
expect "a sample smaller than the table" "2" "$(q "WITH s AS (SELECT * FROM qd_verify_mssql.\"dbo\".\"profiled\" LIMIT 2) SELECT count(*) FROM s")"
expect "a partial match is not a match" "0" "$(q "SELECT count(*) FILTER (WHERE regexp_like('x12345678x', '^(?:\\d{5,12})\$')) FROM (VALUES 1) t(x)")"

# The file CREATE CATALOG writes holds the password (umask 022: 644), in a
# directory only Trino may enter (the entrypoint's chmod 700).
case "$(docker exec "$COORD" sh -c 'ls -ld /data/trino/catalog' 2>&1)" in
  "drwx------ "*" trino trino "*) ok "the catalog's directory is Trino's alone" ;;
  *) ko "catalog directory: $(docker exec "$COORD" sh -c 'ls -ld /data/trino/catalog' 2>&1)" ;;
esac

echo "== Extraction into bronze, stamped with the cut (0036 point 5, 0048 point 3)"
expect "namespace" "" "$(q "CREATE SCHEMA IF NOT EXISTS lake.$NS")"
B="lake.\"$NS\".\"clients\""
COLS='"id", "code", "name", "opened", "amount", "active", "updated"'
expect "the source's columns, in order" "id integer,code varchar(10)," "$(q "SELECT column_name, data_type FROM qd_verify_mssql.information_schema.columns WHERE table_schema = 'dbo' AND table_name = 'clients' ORDER BY ordinal_position LIMIT 2" | tr '\t\n' ' ,')"
# As the worker does (quality::trino_extract), twice: a retried extraction
# leaves the same rows. A run before this one may have left the table (the
# loader cannot drop it).
for attempt in 1 2; do
  case "$(q "SELECT count(*) FROM lake.information_schema.tables WHERE table_schema = '$NS' AND table_name = 'clients'")" in
    0) expect "[$attempt] first cut, the table created" "3" "$(q "CREATE TABLE $B WITH (partitioning = ARRAY['cut']) AS SELECT s.*, DATE '$CUT' AS cut FROM qd_verify_mssql.\"dbo\".\"clients\" s")" ;;
    1)
      # RustFS refuses a commit that deletes nothing: only a cut with rows is deleted.
      [ "$(q "SELECT count(*) FROM $B WHERE cut = DATE '$CUT'")" = 0 ] ||
        expect "[$attempt] the cut's rows deleted" "3" "$(q "DELETE FROM $B WHERE cut = DATE '$CUT'")"
      expect "[$attempt] the cut inserted column by column" "3" "$(q "INSERT INTO $B ($COLS, cut) SELECT $COLS, DATE '$CUT' FROM qd_verify_mssql.\"dbo\".\"clients\"")" ;;
    *) ko "[$attempt] the bronze table: neither there nor missing" ;;
  esac
  expect "[$attempt] one cut's rows, not two" "3" "$(q "SELECT count(*) FROM $B WHERE cut = DATE '$CUT'")"
done
case "$(q "DELETE FROM $B WHERE cut = DATE '1999-01-01'")" in
  ERROR:*) ok "a delete of no row is refused, as the worker expects" ;;
  *) ok "a delete of no row is taken (the worker's count is then only careful)" ;;
esac
ok "bronze types: $(q "DESCRIBE $B" | cut -f1,2 | tr '\t\n' ': ')"
expect "leading zeros in bronze" "007" "$(q "SELECT code FROM $B WHERE id = 1")"
snap=$(q "SELECT CAST(snapshot_id AS varchar) FROM lake.\"$NS\".\"clients\$snapshots\" ORDER BY committed_at DESC LIMIT 1")
case "$snap" in
  ''|*[!0-9-]*) ko "the last snapshot: $snap" ;;
  *) ok "the last snapshot is a number" ;;
esac
echo "== Dropped"
expect "drop catalog" "" "$(q 'DROP CATALOG qd_verify_mssql')"
case "$(q 'SHOW TABLES FROM qd_verify_mssql.dbo')" in ERROR:*) ok "gone" ;; *) ko "still there" ;; esac

[ "$FAILED" = 0 ] && echo "== all checks passed" || echo "== some checks FAILED"
exit "$FAILED"
