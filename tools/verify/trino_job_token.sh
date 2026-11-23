#!/bin/bash
# Verification of a Trino token per job (decision 0062): a JWT signed with
# the platform's ES256 OIDC key, whose subject names the job, mapped by
# Trino to a user that its file-based access control lets read one source
# catalog only: by pattern for a job that reads, and by a rule of its
# dataset for an extraction, which writes that dataset's bronze schema only.
#
# It runs its own throwaway Trino, from the same image as infra/trino
# (trinodb/trino:484), single node, with no network, so the shared dev
# cluster and its rules are not touched: memory catalogs stand for two
# sources (`src_alpha`, `src_beta`) and the lake (`lake`). Synthetic rows
# only. Run from the repository root:
#
#   bash tools/verify/trino_job_token.sh
#
# The user mapping is the infra's
# (infra/trino/etc/coordinator/user-mapping.json); the rules, the ones the
# API serves Trino for two datasets, `orders` from the source `alpha` and
# `loans` from `beta` (tools/verify/fixtures/trino_rules.json, which a test
# of `quality::trino_rules` keeps equal to what the API generates), read
# here from a file; from a URL, in trino_rules_http.sh. RULES and
# USER_MAPPING name other files. Needs docker, openssl, jq and
# python3; reads OIDC_SIGNING_KEY_ES256 and OIDC_ISSUER (or APP_DOMAIN)
# from QD_ENV_FILE (`./.env` by default). The key stays in files of a
# private temporary directory, removed at the end with the container.
set -u
export LC_ALL=C
cd "$(dirname "$0")/../.."
set -a; . "${QD_ENV_FILE:-./.env}"; set +a
IMAGE=${TRINO_IMAGE:-trinodb/trino:484}
NAME=qd-verify-trino-job-token
ISS=${OIDC_ISSUER:-https://${APP_DOMAIN:-localhost}/api}
RULES=${RULES:-tools/verify/fixtures/trino_rules.json}
USER_MAPPING=${USER_MAPPING:-infra/trino/etc/coordinator/user-mapping.json}
D=$(mktemp -d)
chmod 700 "$D"
trap 'docker rm -f "$NAME" >/dev/null 2>&1; rm -rf "$D"' EXIT
FAILED=0

ok() { printf '[OK  ] %s\n' "$*"; }
ko() { printf '[FAIL] %s\n' "$*"; FAILED=1; }
expect() { # NAME EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then ok "$1: $3"; else ko "$1: expected '$2', got '$3'"; fi
}
denied() { # NAME ACTUAL: refused by the access control
  case "$2" in
    *"Access Denied"*) ok "$1: refused ($(echo "$2" | cut -c1-80))" ;;
    *) ko "$1: expected Access Denied, got '$2'" ;;
  esac
}

# --- The platform's ES256 key; a throwaway one for the refused token --------
printf '%s' "${OIDC_SIGNING_KEY_ES256:?OIDC_SIGNING_KEY_ES256 is needed}" | openssl base64 -d -A |
  openssl pkey -inform DER -out "$D/qd.pem"
openssl pkey -in "$D/qd.pem" -pubout -out "$D/qd.pub.pem" 2>/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out "$D/other.pem"
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
# jwt KEY SUB TTL [AUD]: an ES256 JWT as the provider signs a job's token.
jwt() {
  now=$(date +%s)
  h=$(printf '{"alg":"ES256","kid":"verify","typ":"at+jwt"}' | b64url)
  c=$(printf '{"iss":"%s","aud":"%s","sub":"%s","iat":%s,"exp":%s}' "$ISS" "${4:-trino}" "$2" "$now" $((now + $3)) | b64url)
  printf '%s.%s' "$h" "$c" >"$D/input"
  openssl dgst -sha256 -sign "$1" -out "$D/sig.der" "$D/input"
  rs=$(openssl asn1parse -inform DER -in "$D/sig.der" | sed -n 's/.*INTEGER *:\([0-9A-F]*\).*/\1/p' | tr '\n' ' ')
  s=$(python3 -I -c 'import sys; sys.stdout.buffer.write(b"".join(bytes.fromhex(v.rjust(64, "0")) for v in sys.argv[1:]))' $rs | b64url)
  printf '%s.%s.%s' "$h" "$c" "$s"
}

# --- A throwaway Trino: the infra's authentication and access control -----
mkdir -p "$D/etc/catalog"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
  -subj /CN=localhost -keyout "$D/tls.key" -out "$D/tls.crt" 2>/dev/null
cat "$D/tls.crt" "$D/tls.key" >"$D/etc/https.pem"
cp "$D/qd.pub.pem" "$D/etc/jwt.pem"
cp "$RULES" "$D/etc/rules.json"
cp "$USER_MAPPING" "$D/etc/user-mapping.json"
cat >"$D/etc/config.properties" <<EOF
coordinator=true
node-scheduler.include-coordinator=true
http-server.http.port=8080
discovery.uri=http://localhost:8080
query.max-memory=256MB
query.max-memory-per-node=256MB
http-server.https.enabled=true
http-server.https.port=8443
http-server.https.keystore.path=/etc/trino/https.pem
internal-communication.shared-secret=verify-only
http-server.authentication.type=jwt
http-server.authentication.jwt.key-file=/etc/trino/jwt.pem
http-server.authentication.jwt.required-issuer=$ISS
http-server.authentication.jwt.required-audience=trino
http-server.authentication.jwt.user-mapping.file=/etc/trino/user-mapping.json
EOF
printf 'node.environment=verify\nnode.id=verify\nnode.data-dir=/tmp/trino\n' >"$D/etc/node.properties"
printf -- '-server\n-Xmx1G\n-XX:+ExitOnOutOfMemoryError\n-Djdk.attach.allowAttachSelf=true\n' >"$D/etc/jvm.config"
printf 'access-control.name=file\nsecurity.config-file=/etc/trino/rules.json\n' >"$D/etc/access-control.properties"
for c in lake src_alpha src_beta; do echo connector.name=memory >"$D/etc/catalog/$c.properties"; done
chmod -R a+rX "$D/etc"
docker rm -f "$NAME" >/dev/null 2>&1
docker run -d --name "$NAME" --network none --memory 1536m -v "$D/etc:/etc/trino:ro" "$IMAGE" >/dev/null ||
  { echo "could not start $IMAGE"; exit 1; }
for _ in $(seq 90); do
  docker exec "$NAME" curl -s http://localhost:8080/v1/info 2>/dev/null | grep -q '"starting":false' && break
  sleep 2
done
VERSION=$(docker exec "$NAME" curl -s http://localhost:8080/v1/info | jq -r '.nodeVersion.version')
echo "== Trino $VERSION, with $RULES and $USER_MAPPING"

# post TOKEN SQL: the first answer of a statement (HTTP code, then body).
post() {
  docker exec -e T="$1" -e Q="$2" "$NAME" bash -c \
    'curl -sk -o /tmp/r -w "%{http_code}" -H "Authorization: Bearer $T" --data-binary "$Q" https://localhost:8443/v1/statement; echo; cat /tmp/r'
}
# tq TOKEN SQL: the rows as TSV, or "ERROR: …" / "HTTP …", every page followed.
tq() {
  docker exec -e T="$1" -e Q="$2" "$NAME" bash -c '
    code=$(curl -sk -o /tmp/r -w "%{http_code}" -H "Authorization: Bearer $T" --data-binary "$Q" https://localhost:8443/v1/statement)
    [ "$code" = 200 ] || { echo "{\"error\":{\"message\":\"HTTP $code\"}}"; exit 0; }
    r=$(</tmp/r)
    while :; do
      printf "%s\n" "$r"
      [[ $r =~ \"nextUri\":\"([^\"]+)\" ]] || break
      r=$(curl -sk -H "Authorization: Bearer $T" "${BASH_REMATCH[1]}")
    done' |
    jq -rR '(fromjson? // {"error": {"message": .}}) |
      (.data // [] | .[] | map(tostring) | join("\t")), (.error.message // empty | "ERROR: " + .)'
}

TENANT=00000000-0000-0000-0000-000000000001
JOB=7f0c2a52-1c1e-4c43-9a55-0d2f1e0b6a10
API=$(jwt "$D/qd.pem" qd-api 300)
WORKER=$(jwt "$D/qd.pem" qd-worker-dev 300)
READ=$(jwt "$D/qd.pem" "job:$TENANT:$JOB:read:src_alpha" 300)
EXTRACT=$(jwt "$D/qd.pem" "job:$TENANT:$JOB:extract:orders" 300)
# A dataset the rules do not name (just mapped, or none), and one named as
# a source's catalog.
UNRULED=$(jwt "$D/qd.pem" "job:$TENANT:$JOB:extract:clients" 300)
AS_SOURCE=$(jwt "$D/qd.pem" "job:$TENANT:$JOB:extract:src_alpha" 300)

echo "== The platform's own client sets up the stand-ins"
for s in "CREATE SCHEMA src_alpha.dbo" "CREATE SCHEMA src_beta.dbo" "CREATE SCHEMA lake.orders_bronze" "CREATE SCHEMA lake.loans_bronze" "CREATE SCHEMA lake.orders_silver"; do
  expect "qd-api: $s" "" "$(tq "$API" "$s")"
done
expect "qd-api: synthetic rows in src_alpha" 3 "$(tq "$API" "CREATE TABLE src_alpha.dbo.t AS SELECT * FROM (VALUES (1, 'a'), (2, 'b'), (3, 'c')) v(id, code)")"
expect "qd-api: synthetic rows in src_beta" 2 "$(tq "$API" "CREATE TABLE src_beta.dbo.t AS SELECT * FROM (VALUES (1, 'x'), (2, 'y')) v(id, code)")"
expect "qd-api: a silver table" 1 "$(tq "$API" "CREATE TABLE lake.orders_silver.t AS SELECT 1 AS id")"

echo "== Who a token is (principal-field: sub, then the user mapping)"
expect "a job's read token is the user of its catalog" src_alpha "$(tq "$READ" 'SELECT current_user')"
expect "an extraction's token is its dataset after an underscore" _orders "$(tq "$EXTRACT" 'SELECT current_user')"
expect "a dataset named as a source's catalog is still a dataset's user" _src_alpha "$(tq "$AS_SOURCE" 'SELECT current_user')"
expect "an extraction's subject naming a bad dataset, refused" "ERROR: HTTP 401" "$(tq "$(jwt "$D/qd.pem" "job:$TENANT:$JOB:extract:Orders" 300)" 'SELECT 1')"
denied "a machine token (a worker's) executes nothing" "$(tq "$WORKER" 'SELECT current_user')"
expect "a token whose subject looks like a job's user, refused" "ERROR: HTTP 401" "$(tq "$(jwt "$D/qd.pem" src_alpha 300)" 'SELECT 1')"
expect "a job subject of no known shape, refused" "ERROR: HTTP 401" "$(tq "$(jwt "$D/qd.pem" "job:$TENANT:$JOB:write:src_alpha" 300)" 'SELECT 1')"
expect "a job subject naming a bad catalog, refused" "ERROR: HTTP 401" "$(tq "$(jwt "$D/qd.pem" "job:$TENANT:$JOB:read:src_Alpha.x" 300)" 'SELECT 1')"
expect "a job token signed by another key, refused" "ERROR: HTTP 401" "$(tq "$(jwt "$D/other.pem" "job:$TENANT:$JOB:read:src_alpha" 300)" 'SELECT 1')"
expect "a job token for another audience, refused" "ERROR: HTTP 401" "$(tq "$(jwt "$D/qd.pem" "job:$TENANT:$JOB:read:src_alpha" 300 quality-api)" 'SELECT 1')"

echo "== A read job: its catalog, read-only; nothing else"
expect "reads its catalog" 3 "$(tq "$READ" 'SELECT count(*) FROM src_alpha.dbo.t')"
expect "lists its catalog's columns" "$(printf 'id\ncode')" "$(tq "$READ" "SELECT column_name FROM src_alpha.information_schema.columns WHERE table_name = 't' ORDER BY ordinal_position")"
expect "sees its catalog only" src_alpha "$(tq "$READ" 'SHOW CATALOGS')"
denied "reads another source's catalog" "$(tq "$READ" 'SELECT count(*) FROM src_beta.dbo.t')"
denied "writes its catalog" "$(tq "$READ" 'INSERT INTO src_alpha.dbo.t VALUES (4, '"'d'"')')"
denied "reads the lake" "$(tq "$READ" 'SELECT count(*) FROM lake.orders_silver.t')"
denied "writes bronze" "$(tq "$READ" 'CREATE TABLE lake.orders_bronze.r AS SELECT 1 AS id')"

echo "== An extraction: its dataset's source read-only, its dataset's bronze schema only"
expect "creates a bronze table from its catalog" 3 "$(tq "$EXTRACT" 'CREATE TABLE lake.orders_bronze.t AS SELECT *, DATE '"'2026-11-10'"' AS cut FROM src_alpha.dbo.t')"
expect "inserts into it" 3 "$(tq "$EXTRACT" 'INSERT INTO lake.orders_bronze.t SELECT *, DATE '"'2026-11-10'"' FROM src_alpha.dbo.t')"
expect "reads it" 6 "$(tq "$EXTRACT" 'SELECT count(*) FROM lake.orders_bronze.t')"
expect "finds it in the lake's information_schema" t "$(tq "$EXTRACT" "SELECT table_name FROM lake.information_schema.tables WHERE table_schema = 'orders_bronze'")"
case "$(tq "$EXTRACT" 'DELETE FROM lake.orders_bronze.t WHERE id = 1')" in
  *"Access Denied"*) ko "deletes from bronze: refused by the access control" ;;
  *) ok "deletes from bronze: not refused by the access control (the memory connector may not delete)" ;;
esac
expect "sees its catalog and the lake" "$(printf 'lake\nsrc_alpha')" "$(tq "$EXTRACT" 'SHOW CATALOGS')"
denied "reads another source's catalog" "$(tq "$EXTRACT" 'SELECT count(*) FROM src_beta.dbo.t')"
denied "writes its catalog" "$(tq "$EXTRACT" 'INSERT INTO src_alpha.dbo.t VALUES (4, '"'d'"')')"
denied "reads silver" "$(tq "$EXTRACT" 'SELECT count(*) FROM lake.orders_silver.t')"
denied "writes another dataset's bronze" "$(tq "$EXTRACT" 'CREATE TABLE lake.loans_bronze.t AS SELECT * FROM src_alpha.dbo.t')"
denied "a dataset the rules do not name: its first statement, the source's columns" "$(tq "$UNRULED" "SELECT column_name, data_type FROM src_alpha.information_schema.columns WHERE table_schema = 'dbo' AND table_name = 't'")"
denied "a dataset the rules do not name: the lake" "$(tq "$UNRULED" 'CREATE TABLE lake.orders_bronze.u AS SELECT 1 AS id')"
denied "a dataset named as a source's catalog reads no catalog" "$(tq "$AS_SOURCE" 'SELECT count(*) FROM src_alpha.dbo.t')"
denied "creates a schema" "$(tq "$EXTRACT" 'CREATE SCHEMA lake.other_bronze')"
# Creating a table needs OWNERSHIP in the file-based rules (without it,
# CREATE TABLE AS is refused), and OWNERSHIP lets it drop one too; on the
# real lake, Trino's RustFS user may not drop a table (decision 0048).
case "$(tq "$EXTRACT" 'DROP TABLE lake.orders_bronze.t')" in
  *"Access Denied"*) ko "drops a bronze table: refused, though OWNERSHIP was expected to allow it" ;;
  *) ok "drops a bronze table: allowed by the rules (OWNERSHIP, which CREATE TABLE needs)" ;;
esac

echo "== A worker's machine token: nothing"
denied "reads a source's catalog" "$(tq "$WORKER" 'SELECT count(*) FROM src_alpha.dbo.t')"
denied "reads the lake" "$(tq "$WORKER" 'SELECT count(*) FROM lake.orders_bronze.t')"
denied "lists the catalogs" "$(tq "$WORKER" 'SHOW CATALOGS')"

echo "== A token that expires while its statement runs"
SHORT=$(jwt "$D/qd.pem" "job:$TENANT:$JOB:read:src_alpha" 4)
first=$(post "$SHORT" 'SELECT count(*) FROM src_alpha.dbo.t')
next=$(echo "$first" | tail -n +2 | jq -r '.nextUri // empty')
expect "the statement is taken while the token lives" 200 "$(echo "$first" | head -1)"
sleep 8
expect "the token, expired, is refused for a new statement" "ERROR: HTTP 401" "$(tq "$SHORT" 'SELECT 1')"
rows=""
while [ -n "$next" ]; do
  page=$(docker exec -e T="$SHORT" -e U="$next" "$NAME" bash -c 'curl -sk -H "Authorization: Bearer $T" "$U"')
  rows="$rows$(echo "$page" | jq -r '(.data // [])[] | map(tostring) | join("\t")' 2>/dev/null)"
  next=$(echo "$page" | jq -r '.nextUri // empty' 2>/dev/null)
  [ -z "$next" ] && [ -z "$rows" ] && rows="ERROR: $(echo "$page" | cut -c1-80)"
done
expect "its pages are still followed after it expired (nextUri is not re-authenticated)" 3 "$rows"

[ "$FAILED" = 0 ] && echo "All checks passed." || { echo "Some checks failed."; exit 1; }
