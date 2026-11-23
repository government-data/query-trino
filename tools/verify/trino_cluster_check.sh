#!/bin/sh
# Verification of the Trino cluster (infra/trino; decisions 0018, 0029 point
# 3, 0030): both nodes active, the lake catalog writes and reads Iceberg on
# RustFS, a dynamic catalog is created and dropped from SQL, clients
# authenticate with JWTs of Quality Data's OIDC provider, and people sign
# in to the Web UI with Quality Data, through Traefik. Synthetic rows
# only. Run from the repository root against the dev stack (watch mode) with
# the cluster up (`task trino:up`):
#
#   sh tools/verify/trino_cluster_check.sh
#
# Needs openssl, jq, curl and python3. A real token of the provider, of the
# dev machine client `qd-worker-dev` (client credentials, ES256;
# QD_WORKER_DEV_CLIENT_SECRET), is checked to run nothing (decision 0062).
# The statements run as the API's own client, `qd-api`, with a token made
# here with the provider's ES256 key (OIDC_SIGNING_KEY_ES256), as the API
# signs its own. The refused tokens are made here with the provider's keys
# (OIDC_SIGNING_KEY, Ed25519, which Trino 484 cannot verify;
# OIDC_SIGNING_KEY_ES256 for another audience) or with a throwaway key. Secrets stay in the environment and in files of a private
# temporary directory, removed at the end.
set -u
export LC_ALL=C
cd "$(dirname "$0")/../.."
set -a; . ./.env; set +a
COORD=${TRINO_COORDINATOR:-data-quality-trino-coordinator-1}
BASE=https://${APP_DOMAIN:-localhost}
ISS=${OIDC_ISSUER:-$BASE/api}
WAREHOUSE=${TRINO_LAKE_WAREHOUSE:-qd-tenant-00000000000000000000000000000001}
D=$(mktemp -d)
chmod 700 "$D"
trap 'rm -rf "$D"' EXIT
FAILED=0

ok() { printf '[OK  ] %s\n' "$*"; }
ko() { printf '[FAIL] %s\n' "$*"; FAILED=1; }
expect() { # NAME EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then ok "$1: $3"; else ko "$1: expected '$2', got '$3'"; fi
}

# --- JWTs ---------------------------------------------------------------------
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
claims() { # AUD [SUB]
  now=$(date +%s)
  printf '{"iss":"%s","aud":"%s","sub":"%s","iat":%s,"exp":%s}' "$ISS" "$1" "${2:-qd-verify}" "$now" $((now + 300)) | b64url
}
# eddsa KEY.der KID AUD: a JWT as the provider signs them today.
eddsa() {
  h=$(printf '{"alg":"EdDSA","kid":"%s","typ":"JWT"}' "$2" | b64url)
  c=$(claims "$3")
  printf '%s.%s' "$h" "$c" >"$D/input"
  printf '%s.%s.%s' "$h" "$c" "$(openssl pkeyutl -sign -inkey "$1" -keyform DER -rawin -in "$D/input" | b64url)"
}
# es256 KEY.pem KID AUD [SUB]: the same with ES256 (the signature as r || s).
es256() {
  h=$(printf '{"alg":"ES256","kid":"%s","typ":"JWT"}' "$2" | b64url)
  c=$(claims "$3" "${4:-}")
  printf '%s.%s' "$h" "$c" >"$D/input"
  openssl dgst -sha256 -sign "$1" -out "$D/sig.der" "$D/input"
  rs=$(openssl asn1parse -inform DER -in "$D/sig.der" | sed -n 's/.*INTEGER *:\([0-9A-F]*\).*/\1/p' | tr '\n' ' ')
  s=$(python3 -I -c 'import sys; sys.stdout.buffer.write(b"".join(bytes.fromhex(v.rjust(64, "0")) for v in sys.argv[1:]))' $rs | b64url)
  printf '%s.%s.%s' "$h" "$c" "$s"
}
printf '%s' "${OIDC_SIGNING_KEY:?OIDC_SIGNING_KEY is needed}" | openssl base64 -d -A >"$D/qd.der"
printf '%s' "${OIDC_SIGNING_KEY_ES256:?OIDC_SIGNING_KEY_ES256 is needed}" | openssl base64 -d -A |
  openssl pkey -inform DER -out "$D/qd-es256.pem"
JWKS=$(curl -sf --cacert infra/traefik/certs/dev-ca.crt "$ISS/oauth/jwks")
KID=$(echo "$JWKS" | jq -r '.keys[] | select(.alg == "EdDSA") | .kid' | head -1)
ES_KID=$(echo "$JWKS" | jq -r '.keys[] | select(.alg == "ES256") | .kid' | head -1)
openssl ecparam -name prime256v1 -genkey -noout -out "$D/other.pem"
# The worker machine's token, from the provider (client credentials).
WORKER=$(curl -s --cacert infra/traefik/certs/dev-ca.crt -u "qd-worker-dev:${QD_WORKER_DEV_CLIENT_SECRET:?QD_WORKER_DEV_CLIENT_SECRET is needed}" \
  -d grant_type=client_credentials -d audience=trino "$ISS/oauth/token" | jq -r '.access_token // empty')
EDDSA=$(eddsa "$D/qd.der" "$KID" trino)
WRONG_AUD=$(es256 "$D/qd-es256.pem" "$ES_KID" rustfs)
OTHER_KEY=$(es256 "$D/other.pem" "$ES_KID" trino)
# The API's own client, which owns every catalog (the rules the API serves).
TOKEN=$(es256 "$D/qd-es256.pem" "$ES_KID" trino qd-api)

# --- A Trino client: the REST protocol from inside the coordinator's
# namespace (its ports are not published), over HTTPS, followed until the
# last page.
POLL='auth=(); [ -n "$TOKEN" ] && auth=(-H "Authorization: Bearer $TOKEN")
code=$(curl -s --cacert /etc/trino/extra-ca.crt -o /tmp/r -w "%{http_code}" "${auth[@]}" --data-binary "$Q" https://localhost:8490/v1/statement)
[ "$code" = 200 ] || { echo "HTTP $code"; exit 0; }
r=$(</tmp/r)
while :; do
  printf "%s\n" "$r"
  [[ $r =~ \"nextUri\":\"([^\"]+)\" ]] || break
  r=$(curl -s --cacert /etc/trino/extra-ca.crt -H "Authorization: Bearer $TOKEN" "${BASH_REMATCH[1]}")
done'
# tq TOKEN SQL: the rows as TSV, or "ERROR: …" / "HTTP …".
tq() {
  docker exec -e TOKEN="$1" -e Q="$2" "$COORD" bash -c "$POLL" |
    jq -rR '(fromjson? // {"error": {"message": .}}) |
      (.data // [] | .[] | map(tostring) | join("\t")), (.error.message // empty | "ERROR: " + .)'
}
q() { tq "$TOKEN" "$1"; }

echo "== JWT authentication (decision 0030)"
if docker exec "$COORD" test -f "/data/trino/jwks/$ES_KID.pem"; then
  ok "the provider's ES256 key $ES_KID written for Trino from its JWKS"
else
  ko "no key file for the provider's ES256 key ${ES_KID:-?}"
fi
if [ -n "$WORKER" ]; then ok "a machine token from the provider (qd-worker-dev, client credentials)"; else ko "no machine token from the provider"; fi
expect "plain HTTP with a user name only, refused" 403 \
  "$(docker exec "$COORD" curl -s -o /dev/null -w '%{http_code}' -H 'X-Trino-User: someone' --data-binary 'SELECT 1' http://127.0.0.1:8090/v1/statement)"
expect "without a token" "ERROR: HTTP 401" "$(tq "" 'SELECT 1')"
expect "an EdDSA token (Trino reads RSA and EC keys only)" "ERROR: HTTP 401" "$(tq "$EDDSA" 'SELECT 1')"
expect "an ES256 token for another audience" "ERROR: HTTP 401" "$(tq "$WRONG_AUD" 'SELECT 1')"
expect "an ES256 token signed by another key" "ERROR: HTTP 401" "$(tq "$OTHER_KEY" 'SELECT 1')"
expect "a worker machine's token runs nothing (decision 0062)" "ERROR: Access Denied: Cannot execute query" "$(tq "$WORKER" 'SELECT current_user')"
expect "the API's own client is the user" "qd-api" "$(q 'SELECT current_user')"


echo "== The cluster"
expect "active nodes (coordinator + worker)" "$(printf 'false\tactive\ntrue\tactive')" \
  "$(q 'SELECT coordinator, state FROM system.runtime.nodes ORDER BY coordinator')"

echo "== The lake catalog (Iceberg REST on RustFS, SigV4, Trino's own user)"
expect "create schema" "" "$(q 'CREATE SCHEMA IF NOT EXISTS lake.qd_verify')"
expect "create table" "" "$(q 'CREATE TABLE lake.qd_verify.readings (id bigint, label varchar, amount double, day date) WITH (partitioning = ARRAY['"'"'day'"'"'])')"
expect "insert synthetic rows" "1000" "$(q "INSERT INTO lake.qd_verify.readings SELECT n, 'synthetic-' || CAST(n % 7 AS varchar), n * 1.5, DATE '2026-01-01' + n % 10 * INTERVAL '1' DAY FROM UNNEST(sequence(1, 1000)) AS t(n)")"
expect "read back: rows, total, days" "$(printf '1000\t750750.0\t10')" \
  "$(q 'SELECT count(*), sum(amount), count(DISTINCT day) FROM lake.qd_verify.readings')"
# Trino drops with purgeRequested=true, which RustFS refuses (406, decision
# 0018): the table goes through the catalog without purge and its files with
# S3, as the platform will drop them (signed here with the root credentials;
# Trino's own user cannot drop tables).
drop=$(q 'DROP TABLE lake.qd_verify.readings')
case "$drop" in
  "") ok "drop table from Trino" ;;
  *)
    ok "drop table from Trino refused, as known: $(echo "$drop" | cut -c1-90)"
    lake() { # METHOD PATH: signed as the platform, from Trino's namespace
      docker exec -e K="$RUSTFS_ACCESS_KEY:$RUSTFS_SECRET_KEY" "$COORD" bash -c \
        "curl -s -o /tmp/l -w '%{http_code}' -X $1 --aws-sigv4 aws:amz:us-east-1:s3 --user \"\$K\" 'http://127.0.0.1:9000$2'; cat /tmp/l >&2" 2>"$D/lake"
    }
    loc=$(q 'SELECT "$path" FROM lake.qd_verify.readings LIMIT 1')
    expect "drop through the catalog, without purge" 204 "$(lake DELETE "/iceberg/v1/$WAREHOUSE/namespaces/qd_verify/tables/readings")"
    prefix=$(echo "$loc" | sed -n "s|^s3://$WAREHOUSE/\(.*\)/data/.*|\1|p")
    n=0
    if [ -n "$prefix" ]; then
      lake GET "/$WAREHOUSE?list-type=2&prefix=$prefix/" >/dev/null
      for key in $(grep -o '<Key>[^<]*</Key>' "$D/lake" | sed 's/<Key>\(.*\)<\/Key>/\1/'); do
        [ "$(lake DELETE "/$WAREHOUSE/$key")" = 204 ] && n=$((n + 1))
      done
    fi
    if [ "$n" -gt 0 ]; then ok "the table's files deleted with S3: $n under $prefix/"; else ko "no files deleted (prefix: ${prefix:-?})"; fi
    ;;
esac
expect "drop schema" "" "$(q 'DROP SCHEMA lake.qd_verify')"

echo "== A dynamic catalog (decision 0029, point 3)"
expect "create catalog" "" "$(q 'CREATE CATALOG qd_verify_mem USING memory')"
if docker exec "$COORD" test -f /data/trino/catalog/qd_verify_mem.properties; then
  ok "stored as a file in the catalog directory"
else
  ko "no file for the new catalog"
fi
expect "create table in it" "3" "$(q 'CREATE TABLE qd_verify_mem.default.t AS SELECT * FROM (VALUES 1, 2, 3) AS v(n)')"
expect "query it (on the worker)" "6" "$(q 'SELECT sum(n) FROM qd_verify_mem.default.t')"
expect "drop catalog" "" "$(q 'DROP CATALOG qd_verify_mem')"
if docker exec "$COORD" test -f /data/trino/catalog/qd_verify_mem.properties; then
  ko "its file is still there"
else
  ok "its file removed"
fi
expect "catalogs left" "$(printf 'lake\nsystem')" "$(q 'SHOW CATALOGS')"

echo "== The Web UI through Traefik, signing in with Quality Data"
c() { curl -s --cacert infra/traefik/certs/dev-ca.crt "$@"; }
start=$(c -o /dev/null -w '%{http_code} %{redirect_url}' -H 'Accept: text/html' "$BASE/ui/")
case "$start" in
  "303 $ISS/oauth/authorize?"*client_id=trino*)
    case "$start" in
      *code_challenge*) ko "the sign-in sends PKCE (Trino does not): $start" ;;
      *) ok "a page without a session goes to Quality Data's authorize, without PKCE" ;;
    esac ;;
  *) ko "a page without a session: $start" ;;
esac
expect "its API without a session" 401 "$(c -o /dev/null -w '%{http_code}' "$BASE/ui/api/cluster")"
login=$(jq -n --arg e "${ADMIN_BOOTSTRAP_EMAIL:-}" --arg p "${ADMIN_BOOTSTRAP_PASSWORD:-}" '{email: $e, password: $p}' |
  c -o /dev/null -w '%{http_code}' -c "$D/jar" -H 'content-type: application/json' --data-binary @- "$BASE/api/auth/login")
if [ "$login" = 200 ]; then
  ok "signed in to Quality Data as the bootstrap administrator"
  # authorize -> /oauth2/callback -> /ui/: Trino's own session cookie.
  c -L -D "$D/h" -o "$D/ui.html" -b "$D/jar" -c "$D/jar" -H 'Accept: text/html' "$BASE/ui/"
  expect "the UI after signing in with Quality Data" 200 "$(grep '^HTTP' "$D/h" | tail -1 | cut -d' ' -f2)"
  expect "Trino's user: the person's e-mail" "true ${ADMIN_BOOTSTRAP_EMAIL:-}" \
    "$(c -b "$D/jar" "$BASE/ui/auth/info" | jq -r '"\(.authenticated) \(.username)"')"
  expect "its assets (absolute /ui/ paths)" 200 \
    "$(c -o /dev/null -w '%{http_code}' -b "$D/jar" "$BASE$(grep -o '/ui/assets/index-[^"]*\.js' "$D/ui.html" | head -1)")"
  expect "the cluster's figures, as the UI asks: coordinators, workers" "1 1" \
    "$(c -b "$D/jar" "$BASE/ui/api/stats" | jq -r '"\(.activeCoordinators) \(.activeWorkers)"')"
  expect "only this domain may frame it" "SAMEORIGIN frame-ancestors 'self'" \
    "$(tr -d '\r' <"$D/h" | awk -F': ' '/^HTTP/{x="";p=""} tolower($1)=="x-frame-options"{x=$2} tolower($1)=="content-security-policy"{p=$2} END{print x, p}')"
  apps=$(c -b "$D/jar" "$BASE/api/settings/account/apps")
  expect "listed in «Aplicaciones» as rustfs is (kind, fields)" \
    "$(echo "$apps" | jq -c '.apps[] | select(.id == "rustfs") | [.kind, (keys | join(","))]')" \
    "$(echo "$apps" | jq -c '.apps[] | select(.id == "trino") | [.kind, (keys | join(","))]')"
else
  ko "could not sign in as ADMIN_BOOTSTRAP_EMAIL (HTTP $login): the signed-in checks were skipped"
fi

[ "$FAILED" = 0 ] && echo "All checks passed." || { echo "Some checks failed."; exit 1; }
