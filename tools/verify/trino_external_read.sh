#!/bin/bash
# Verification of external readers of Trino (KNIME's database nodes, BI
# tools, scheduled workflows) through the application's proxy: facts for a
# proposal, nothing decided. It shows that:
#
#   1. with the client protocol (/v1/) routed by a Traefik configured as
#      infra/traefik (TLS with a CA, plain HTTP to the coordinator,
#      forwarded headers, http-server.process-forwarded=true), a client with
#      a JWT runs SELECT with the Trino CLI, every nextUri names the proxy,
#      and a long result streams through it;
#   2. file-based rules that let an external reader (`ext-<name>`) read
#      one schema of `lake` read-only and nothing else (no source catalog,
#      no write, no CREATE CATALOG, only its own queries, no impersonation),
#      added to the rules quality::trino_rules generates (the fixture), with
#      a job's user and a person still as decision 0062 says;
#   3. a user mapping (infra/trino/etc/coordinator/user-mapping.json with
#      two rules more) that gives `ext-<name>` to such a client and refuses
#      any other subject shaped like it, a job's user among them;
#   4. a statement started with a token that expires while it runs returns
#      every page through the proxy, and the token is then refused;
#   5. the 401 challenge of the browser flow (oauth2) names the proxy's
#      /oauth2/token/ addresses, which the proxy routes. With DEV_PROBE=1 it
#      also sends ONE unauthenticated POST to the dev stack's coordinator as
#      its Traefik would (read-only: no query is created) and prints the
#      WWW-Authenticate header.
#
# Throwaway containers, network and keys only (qd-verify-trino-ext-*), all
# removed at exit; the dev stack is not touched (but for DEV_PROBE). The
# provider is a throwaway EC P-256 key (ES256); `lake` is a memory catalog,
# `src_demo` the generated TPC-H. Synthetic rows only. Run from anywhere:
#
#   bash tools/verify/trino_external_read.sh
#
# Needs docker, openssl, jq and python3.
set -u
export LC_ALL=C
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
IMAGE=${TRINO_IMAGE:-trinodb/trino:484}
PROXY_IMAGE=${PROXY_IMAGE:-traefik:v3.6}
P=qd-verify-trino-ext
NET=$P-net COORD=$P-coord PROXY=$P-proxy
HOST=proxy.verify.test
BASE=https://$HOST
ISS=https://idp.verify.test/api
LONG_ROWS=${LONG_ROWS:-300000}
D=$(mktemp -d)
chmod 700 "$D"
cleanup() {
  docker rm -f "$COORD" "$PROXY" >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
  rm -rf "$D"
}
trap cleanup EXIT
FAILED=0
ok() { printf '[OK  ] %s\n' "$*"; }
ko() { printf '[FAIL] %s\n' "$*"; FAILED=1; }
note() { printf '[NOTE] %s\n' "$*"; }
expect() { if [ "$2" = "$3" ]; then ok "$1: $3"; else ko "$1: expected '$2', got '$3'"; fi; }
denied() {
  case "$2" in
    *"Access Denied"*) ok "$1: refused ($(echo "$2" | head -1 | cut -c1-90))" ;;
    *) ko "$1: expected Access Denied, got '$(echo "$2" | head -3)'" ;;
  esac
}

# Keys, Trino, the proxy, the clients and the data: the helpers.
. "$(dirname "$0")/trino_external_read_lib.sh"


check_proxy() {
  echo "== 1. The client protocol through the proxy"
  local first next info
  first=$(raw "$EXT_TOKEN" 'SELECT * FROM lake.orders_silver.t')
  expect "a statement through the proxy is taken" 200 "$(echo "$first" | head -1)"
  next=$(echo "$first" | sed -n '/^{/,$p' | jq -r '.nextUri')
  info=$(echo "$first" | sed -n '/^{/,$p' | jq -r '.infoUri')
  case "$next" in "$BASE/v1/statement/"*) ok "nextUri names the proxy: ${next%%/v1/*}/v1/statement/…" ;;
    *) ko "nextUri does not name the proxy: $next" ;; esac
  case "$info" in "$BASE/"*) ok "infoUri names the proxy: ${info%/*}/…" ;; *) ko "infoUri: $info" ;; esac
  local out
  out=$(pages "$EXT_TOKEN" 'SELECT * FROM lake.orders_silver.lineitem LIMIT 20000')
  local n_pages n_rows hosts
  n_pages=$(echo "$out" | wc -l)
  n_rows=$(echo "$out" | jq -s '[.[].data // [] | length] | add')
  hosts=$(echo "$out" | jq -r '.nextUri // empty' | sed 's#^\(https\?://[^/]*\)/.*#\1#' | sort -u | tr '\n' ' ')
  expect "20000 rows paged through the proxy" 20000 "$n_rows"
  [ "$n_pages" -gt 2 ] && ok "in $n_pages answers" || ko "only $n_pages answers"
  expect "every nextUri's host" "$BASE " "$hosts"
  expect "the CLI through the proxy (verifying the CA)" "$(printf '"1","a"\n"2","b"\n"3","c"')" \
    "$(cli "$EXT_TOKEN" --user ext-demo --execute 'SELECT * FROM lake.orders_silver.t ORDER BY id')"
  local t0 lines
  t0=$(date +%s)
  lines=$(cli "$EXT_TOKEN" --user ext-demo --output-format TSV --execute \
    'SELECT * FROM lake.orders_silver.lineitem' | wc -l)
  expect "the CLI streams a long result through the proxy" "$LONG_ROWS" "$lines"
  note "$LONG_ROWS rows of lineitem through the proxy in $(($(date +%s) - t0)) s"
}

check_mapping() {
  echo "== 3. Who a token is (sub, then the user mapping)"
  expect "an external reader's subject is its user" ext-demo "$(tq "$EXT_TOKEN" 'SELECT current_user')"
  expect "a read job's subject is still its catalog's user" src_demo "$(tq "$JOB_TOKEN" 'SELECT current_user')"
  local s
  for s in src_demo _orders ext_demo ext-Demo ext-demo@b.test ext- "job:$TENANT:$JOB:write:src_demo"; do
    expect "a subject '$s' is refused" "ERROR: HTTP 401" "$(tq "$(jwt "$s" 300)" 'SELECT 1')"
  done
}

check_ext_rules() {
  echo "== 2. An external reader: one schema of the lake, read-only; nothing else"
  expect "reads its schema" 3 "$(tq "$EXT_TOKEN" 'SELECT count(*) FROM lake.orders_silver.t')"
  expect "sees the lake only" lake "$(tq "$EXT_TOKEN" 'SHOW CATALOGS')"
  expect "sees its schema only" orders_silver "$(tq "$EXT_TOKEN" 'SHOW SCHEMAS FROM lake' | sort)"
  denied "reads another schema of the lake" "$(tq "$EXT_TOKEN" 'SELECT count(*) FROM lake.loans_silver.t')"
  denied "reads a source's catalog" "$(tq "$EXT_TOKEN" 'SELECT count(*) FROM src_demo.tiny.nation')"
  denied "reads system" "$(tq "$EXT_TOKEN" 'SELECT count(*) FROM system.runtime.queries')"
  denied "another external reader with no table rule" "$(tq "$EXT_OTHER" 'SELECT count(*) FROM lake.orders_silver.t')"
  local s
  for s in 'CREATE TABLE lake.orders_silver.x AS SELECT 1 AS id' "INSERT INTO lake.orders_silver.t VALUES (4, 'd')" \
    'DELETE FROM lake.orders_silver.t' 'DROP TABLE lake.orders_silver.t' 'CREATE SCHEMA lake.x_silver' \
    'ALTER TABLE lake.orders_silver.t RENAME TO u' 'CREATE CATALOG ext_x USING memory' 'DROP CATALOG lake' \
    "CREATE TABLE src_demo.tiny.x AS SELECT 1 AS id"; do
    denied "$s" "$(tq "$EXT_TOKEN" "$s")"
  done
  expect "the owner may (CREATE CATALOG is on)" "" "$(tq "$API" 'CREATE CATALOG verify_tmp USING memory')"
  expect "the owner may drop it" "" "$(tq "$API" 'DROP CATALOG verify_tmp')"
}

check_impersonation() {
  echo "== 2. Impersonation and queries"
  expect "no X-Trino-User: the token's user" ext-demo "$(tq "$EXT_TOKEN" 'SELECT current_user')"
  expect "X-Trino-User equal to the token's user" ext-demo "$(tq "$EXT_TOKEN" 'SELECT current_user' 'X-Trino-User: ext-demo')"
  local u
  for u in qd-api src_demo a@b.test ext-other; do
    denied "X-Trino-User: $u" "$(tq "$EXT_TOKEN" 'SELECT current_user' "X-Trino-User: $u")"
  done
  denied "the CLI without --user (sends its OS user, trino)" "$(cli "$EXT_TOKEN" --execute 'SELECT 1')"
  local seen
  seen=$(get "$EXT_TOKEN" /v1/query | jq -r '[.[].session.user] | unique | join(",")')
  expect "it sees only its own queries (GET /v1/query)" ext-demo "$seen"
  seen=$(get "$API" /v1/query | jq -r '[.[].session.user] | unique | join(",")')
  case "$seen" in *ext-demo*qd-api*|*qd-api*ext-demo*) ok "qd-api sees everyone's: $seen" ;; *) ko "qd-api sees: $seen" ;; esac
}

check_existing() {
  echo "== 2. The users of decision 0062, unchanged"
  expect "a read job reads its catalog" 25 "$(tq "$JOB_TOKEN" 'SELECT count(*) FROM src_demo.tiny.nation')"
  expect "a read job sees its catalog only" src_demo "$(tq "$JOB_TOKEN" 'SHOW CATALOGS')"
  denied "a read job reads the lake" "$(tq "$JOB_TOKEN" 'SELECT count(*) FROM lake.orders_silver.t')"
  denied "a read job writes" "$(tq "$JOB_TOKEN" 'CREATE TABLE src_demo.tiny.x AS SELECT 1 AS id')"
  denied "a person runs no query" "$(tq "$PERSON" 'SELECT count(*) FROM lake.orders_silver.t')"
  local seen
  seen=$(get "$PERSON" /v1/query | jq -r '[.[].session.user] | unique | join(",")')
  case "$seen" in *qd-api*) ok "a person sees others' queries: $seen" ;; *) ko "a person sees: $seen" ;; esac
  denied "a worker's machine client runs nothing" "$(tq "$(jwt qd-worker-dev 300)" 'SELECT 1')"
}

check_expiry() {
  echo "== 4. A token that expires while its statement runs, through the proxy"
  local short first next state rows page
  short=$(jwt ext-demo 5)
  first=$(raw "$short" 'SELECT * FROM lake.orders_silver.lineitem' | sed -n '/^{/,$p')
  next=$(echo "$first" | jq -r '.nextUri // empty')
  [ -n "$next" ] && ok "taken while the token lives ($(echo "$first" | jq -r '.stats.state'))" || ko "not taken: $first"
  sleep 8
  rows=$(docker exec -e T="$short" -e U="$next" "$COORD" bash -c '
    u=$U; n=0
    while [ -n "$u" ]; do
      r=$(curl -s --cacert /etc/trino/ca.crt -H "Authorization: Bearer $T" "$u")
      [[ $r =~ \"nextUri\":\"([^\"]+)\" ]] && u=${BASH_REMATCH[1]} || u=""
      printf "%s\n" "$r"
    done' | jq -s '[.[].data // [] | length] | add')
  expect "every page followed after the token expired" "$LONG_ROWS" "$rows"
  expect "the expired token is refused for the next statement" "ERROR: HTTP 401" "$(tq "$short" 'SELECT 1')"
  local out
  out=$(cli "$short" --user ext-demo --execute 'SELECT 1')
  case "$out" in *401*|*Unauthorized*|*"Authentication failed"*) ok "the CLI is refused too: $(echo "$out" | head -1 | cut -c1-90)" ;;
    *) ko "the CLI with the expired token: $(echo "$out" | head -2)" ;; esac
}

check_oauth_challenge() {
  echo "== 5. The browser flow's challenge, through the proxy"
  local ans auth redirect token
  ans=$(raw "" 'SELECT 1')
  expect "an unauthenticated statement" 401 "$(echo "$ans" | head -1)"
  auth=$(echo "$ans" | grep -i '^www-authenticate:' | tr -d '\r')
  printf '       %s\n' "$auth"
  redirect=$(echo "$auth" | sed -n 's/.*x_redirect_server="\([^"]*\)".*/\1/p')
  token=$(echo "$auth" | sed -n 's/.*x_token_server="\([^"]*\)".*/\1/p')
  case "$redirect" in "$BASE/oauth2/token/initiate/"*) ok "x_redirect_server names the proxy" ;; *) ko "x_redirect_server: '$redirect'" ;; esac
  case "$token" in "$BASE/oauth2/token/"*) ok "x_token_server names the proxy" ;; *) ko "x_token_server: '$token'" ;; esac
  local loc
  loc=$(docker exec -e U="$redirect" "$COORD" bash -c 'curl -s --cacert /etc/trino/ca.crt -o /dev/null -w "%{http_code} %{redirect_url}" "$U"')
  case "$loc" in "303 $ISS/oauth/authorize"*"redirect_uri=https%3A%2F%2F$HOST%2Foauth2%2Fcallback"*)
    ok "x_redirect_server, through the proxy, sends the browser to the provider with redirect_uri $BASE/oauth2/callback" ;;
    *) ko "x_redirect_server answered: $(echo "$loc" | cut -c1-200)" ;; esac
  # Trino holds the poll open until the sign-in ends (or its own wait does):
  # a timeout here is Trino waiting; a 404 at once would be the proxy.
  local poll
  poll=$(docker exec -e U="$token" "$COORD" bash -c \
    'curl -s --cacert /etc/trino/ca.crt -m 5 -o /tmp/p -w "%{http_code}" "$U"; echo " $(head -c 200 /tmp/p 2>/dev/null)"')
  case "$poll" in "000 "*|"200 "*'"nextUri"'*) ok "x_token_server, polled through the proxy, is held by Trino until the sign-in (${poll%% *})" ;;
    *) ko "x_token_server answered: $poll" ;; esac
}

check_access_log() {
  echo "== The proxy's access log"
  local log
  log=$(docker logs "$PROXY" 2>&1)
  note "lines: $(echo "$log" | grep -c '/v1/statement')"
  note "a line: $(echo "$log" | grep '/v1/statement/executing' | head -1 | sed 's#/executing/\([^/]*\)/[^/]*/#/executing/\1/<slug>/#' | cut -c1-220)"
  case "$log" in *"$EXT_TOKEN"*) ko "a token is in the access log" ;; *) ok "no token in the access log" ;; esac
  case "$log" in *"lake.orders_silver"*) ko "SQL is in the access log" ;; *) ok "no SQL in the access log" ;; esac
  echo "$log" | grep -q '/v1/statement/executing/[^/ ]*/[^/ ]*/' &&
    note "the access log records each page's path: query id, its slug and token (secrets of that query's result)"
}

# DEV_PROBE=1: one unauthenticated POST to the dev stack's coordinator, as
# its Traefik sends it; the answer is a 401 and no query is created.
probe_dev_stack() {
  [ "${DEV_PROBE:-0}" = 1 ] || { note "dev stack probe skipped (DEV_PROBE=1 runs it)"; return; }
  echo "== 5. The dev stack's coordinator, asked as its Traefik would"
  local domain
  domain=$(grep -E '^APP_DOMAIN=' "$ROOT/.env" 2>/dev/null | cut -d= -f2-)
  domain=${domain:-localhost}
  docker run --rm --network container:data-quality-traefik-1 curlimages/curl:8.11.1 \
    -s -o /dev/null -D - -X POST --data-binary 'SELECT 1' \
    -H "X-Forwarded-Proto: https" -H "X-Forwarded-Host: $domain" -H "X-Forwarded-Port: 443" \
    http://127.0.0.1:8090/v1/statement | grep -iE '^(HTTP|www-authenticate)' | tr -d '\r' | sed 's/^/       /'
}

show_proposal() {
  echo "== The rules added to the fixture (quality::trino_rules' output)"
  jq -c --arg ext "$EXT" '{catalogs: [.catalogs[] | select((.user // "") | test("^ext"))],
    tables: [.tables[] | select(.user | test("^ext"))], queries: [.queries[] | select(.user | test("^ext"))]}' "$D/etc/rules.json"
  echo "== The user mapping"
  jq -c '.rules[]' "$D/etc/user-mapping.json"
}

main() {
  docker rm -f "$COORD" "$PROXY" >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
  docker network create "$NET" >/dev/null || { echo "no network"; exit 1; }
  make_keys; write_rules; write_mapping; write_trino_config; write_proxy_config
  start_trino; start_proxy; wait_ready
  echo "== Trino $(docker exec "$COORD" curl -s http://localhost:8080/v1/info | jq -r .nodeVersion.version), $PROXY_IMAGE in front"
  API=$(jwt qd-api 600); EXT_TOKEN=$(jwt ext-demo 600); EXT_OTHER=$(jwt ext-other 600)
  JOB_TOKEN=$(jwt "job:$TENANT:$JOB:read:src_demo" 600); PERSON=$(jwt a@b.test 600)
  setup_data; check_proxy; check_mapping; check_ext_rules; check_impersonation
  check_existing; check_expiry; check_oauth_challenge; check_access_log; probe_dev_stack
  show_proposal
  [ "$FAILED" = 0 ] && echo "All checks passed." || { echo "Some checks failed."; exit 1; }
}
main
