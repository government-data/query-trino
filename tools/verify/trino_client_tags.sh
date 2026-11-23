#!/bin/bash
# Verification of Trino's client tags (decision 0026, point 1): a statement
# sent with `X-Trino-Client-Tags: job:<uuid>,run:<uuid>` (and
# `X-Trino-Client-Info`) is accepted; which characters a tag may have, and
# what Trino does with one it would not take; whether the tags must go on
# the `nextUri` follow-ups too; where they are visible afterwards
# (`/v1/query/{id}`, `/v1/query`, `system.runtime.queries`) and to whom;
# and whether Trino's own log (console, JSON as infra/trino has it, and the
# HTTP request log file) carries them or the query's id, which a client's
# own line can then carry.
#
# It runs its own throwaway Trino, from the same image as infra/trino
# (trinodb/trino:484), single node, with no network, so the shared dev
# cluster is not touched. No authentication (the user is `X-Trino-User`);
# the access control is the file the API generates for two datasets
# (tools/verify/fixtures/trino_rules.json), so who may view a query is as
# in the cluster. Memory catalogs stand for the sources and the lake; the
# only statement is `SELECT 1`. Needs docker and jq. Run from the
# repository root:
#
#   bash tools/verify/trino_client_tags.sh
set -u
export LC_ALL=C
cd "$(dirname "$0")/../.."
IMAGE=${TRINO_IMAGE:-trinodb/trino:484}
NAME=qd-verify-trino-client-tags
RULES=${RULES:-tools/verify/fixtures/trino_rules.json}
D=$(mktemp -d)
chmod 700 "$D"
trap 'docker rm -f "$NAME" >/dev/null 2>&1; rm -rf "$D"' EXIT
FAILED=0

ok() { printf '[OK  ] %s\n' "$*"; }
ko() { printf '[FAIL] %s\n' "$*"; FAILED=1; }
expect() { # NAME EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then ok "$1: $3"; else ko "$1: expected '$2', got '$3'"; fi
}

# --- A throwaway Trino, logging JSON to the console as infra/trino ----------
mkdir -p "$D/etc/catalog"
cat >"$D/etc/config.properties" <<EOF
coordinator=true
node-scheduler.include-coordinator=true
http-server.http.port=8080
discovery.uri=http://localhost:8080
query.max-memory=256MB
query.max-memory-per-node=256MB
log.console-format=json
EOF
printf 'node.environment=verify\nnode.id=verify\nnode.data-dir=/tmp/trino\n' >"$D/etc/node.properties"
printf -- '-server\n-Xmx1G\n-XX:+ExitOnOutOfMemoryError\n' >"$D/etc/jvm.config"
printf 'io.trino=INFO\n' >"$D/etc/log.properties"
cp "$RULES" "$D/etc/rules.json"
printf 'access-control.name=file\nsecurity.config-file=/etc/trino/rules.json\n' >"$D/etc/access-control.properties"
for c in lake src_alpha src_beta; do echo connector.name=memory >"$D/etc/catalog/$c.properties"; done
chmod a+rx "$D"
chmod -R a+rX "$D/etc"
docker run -d --name "$NAME" --network none --memory 1536m -v "$D/etc:/etc/trino:ro" "$IMAGE" >/dev/null ||
  { echo "could not start $IMAGE"; exit 1; }
for _ in $(seq 90); do
  docker exec "$NAME" curl -s http://localhost:8080/v1/info 2>/dev/null | grep -q '"starting":false' && break
  sleep 2
done
docker exec "$NAME" curl -s http://localhost:8080/v1/info | grep -q '"starting":false' ||
  { echo "Trino did not start"; docker logs "$NAME" 2>&1 | tail -5; exit 1; }
echo "Trino $(docker exec "$NAME" curl -s http://localhost:8080/v1/info | jq -r .nodeVersion.version)"

# run USER TAGS [FOLLOW_TAGS [SQL]]: posts SQL (`SELECT 1`) as USER with the client tags
# TAGS (none if empty) and client info `qd-verify`, follows every page
# (with FOLLOW_TAGS as the tags header if given); prints the first answer's
# HTTP status, the query id, the final state, the rows and the error, one
# per line.
run() {
  docker exec -e U="$1" -e T="$2" -e F="${3:-}" -e Q="${4:-SELECT 1}" "$NAME" bash -c '
    tags=(); [ -n "$T" ] && tags=(-H "X-Trino-Client-Tags: $T")
    follow=(); [ -n "$F" ] && follow=(-H "X-Trino-Client-Tags: $F")
    r=$(curl -s -w "\n%{http_code}" -H "X-Trino-User: $U" -H "X-Trino-Source: quality-data" \
      -H "X-Trino-Client-Info: qd-verify" "${tags[@]}" --data-binary "$Q" \
      http://localhost:8080/v1/statement)
    echo "${r##*$'\''\n'\''}"; r=${r%$'\''\n'\''*}
    while :; do
      printf "%s\n" "$r"
      [[ $r =~ \"nextUri\":\"([^\"]+)\" ]] || break
      r=$(curl -s -H "X-Trino-User: $U" "${follow[@]}" "${BASH_REMATCH[1]}")
    done' |
    { read -r status; echo "$status"; jq -rs 'if length == 0 then "-", "-", "-", "-" else
        (.[0].id // "-"), (.[-1].stats.state // "-"),
        ([.[] | .data // [] | .[] | map(tostring) | join(",")] | join(";") | if . == "" then "-" else . end),
        (.[-1].error.message // "-") end' 2>/dev/null; }
}
# info USER ID: `/v1/query/ID` as USER: the HTTP status, then the session's
# client tags and client info.
info() {
  docker exec "$NAME" curl -s -w '\n%{http_code}' -H "X-Trino-User: $1" "http://localhost:8080/v1/query/$2" |
    { body=$(cat); status=${body##*$'\n'}; body=${body%$'\n'*}; echo "$status"
      echo "$body" | jq -c '[.session.clientTags, .session.clientInfo]' 2>/dev/null || echo -; }
}
JOB=00000000-0000-4000-8000-00000000000a
RUN=00000000-0000-4000-8000-00000000000b

echo "== A statement with a job's and a run's tag"
mapfile -t A < <(run src_alpha "job:$JOB,run:$RUN")
expect "accepted" 200 "${A[0]}"
expect "it runs" "FINISHED 1" "${A[2]} ${A[3]}"
ID=${A[1]}
mapfile -t I < <(info src_alpha "$ID")
expect "/v1/query/{id}: session.clientTags and clientInfo, as its owner" \
  "[[\"job:$JOB\",\"run:$RUN\"],\"qd-verify\"]" "${I[1]}"
listed=$(docker exec "$NAME" curl -s -H 'X-Trino-User: qd-api' http://localhost:8080/v1/query |
  jq -c --arg id "$ID" '[.[] | select(.queryId == $id) | .session.clientTags]')
expect "/v1/query lists them too (session.clientTags)" "[[\"job:$JOB\",\"run:$RUN\"]]" "$listed"
cols=$(docker exec "$NAME" bash -c '
    q="SELECT column_name FROM system.information_schema.columns WHERE table_schema = '\''runtime'\'' AND table_name = '\''queries'\'' ORDER BY ordinal_position"
    r=$(curl -s -H "X-Trino-User: qd-api" --data-binary "$q" http://localhost:8080/v1/statement)
    while [[ $r =~ \"nextUri\":\"([^\"]+)\" ]]; do
      printf "%s\n" "$r"; r=$(curl -s -H "X-Trino-User: qd-api" "${BASH_REMATCH[1]}"); done
    printf "%s\n" "$r"' | jq -rs '[.[] | .data // [] | .[][0]] | join(",")')
echo "     system.runtime.queries columns: $cols"
case ",$cols," in
  *tag*) ko "system.runtime.queries has a tags column: $cols" ;;
  ,source,* | *,source,*) ok "system.runtime.queries has no tags column (it has source)" ;;
  *) ko "system.runtime.queries columns not read: '$cols'" ;;
esac

echo "== Who may see them: the rules' view of queries"
expect "an admin (.*@.*) may view the query" 200 "$(info admin@example.com "$ID" | head -1)"
expect "the API's client may view it" 200 "$(info qd-api "$ID" | head -1)"
expect "another job's user may not" 403 "$(info src_beta "$ID" | head -1)"

echo "== The follow-up requests"
mapfile -t B < <(run src_alpha "job:$JOB" "job:other,run:other")
expect "tags only on the POST, other tags on the follow-ups: the POST's are kept" \
  "[[\"job:$JOB\"],\"qd-verify\"]" "$(info qd-api "${B[1]}" | sed -n 2p)"
mapfile -t C < <(run src_alpha "")
expect "no header: no tags" '[[],"qd-verify"]' "$(info qd-api "${C[1]}" | sed -n 2p)"

echo "== Characters"
# tagged TAGS: the state and the tags Trino kept, or the refusal.
tagged() {
  mapfile -t R < <(run src_alpha "$1")
  if [ "${R[1]}" = "-" ] || [ "${R[2]}" != FINISHED ]; then
    echo "HTTP ${R[0]}, ${R[2]}: ${R[4]}" | cut -c1-120
  else
    info qd-api "${R[1]}" | sed -n 2p | jq -c '.[0]'
  fi
}
for t in "job:$JOB" "a_b.c-d:e/f" "a,,b" " a , b " "a b" "a=b;c" "jöb" "$(printf 'x%.0s' $(seq 300))"; do
  printf '     %-22s -> %s\n' "'$(echo "$t" | cut -c1-20)'" "$(tagged "$t" | cut -c1-70)"
done
expect "':' and '-' kept as they are" "[\"job:$JOB\"]" "$(tagged "job:$JOB")"

echo "== Trino's own log"
mapfile -t E < <(run src_alpha "job:$JOB" "" "SELECT * FROM src_alpha.s.missing")
expect "a failed statement has an id too" FAILED "${E[2]}"
sleep 2
docker logs "$NAME" 2>&1 | grep '^{' >"$D/console.log"
docker exec "$NAME" bash -c 'cat /tmp/trino/var/log/* 2>/dev/null' >"$D/files.log"
expect "the console log does not carry the tags" 0 "$(grep -c "$JOB" "$D/console.log")"
# timeline ID: the logger and the state of the console's lines naming ID.
timeline() {
  grep -F "$1" "$D/console.log" | jq -r '"\(.level) \(.logger) \(.message | capture(":: (?<s>[A-Z]+)").s)"' | sort -u
}
expect "a query's one line, its timeline, names its id and state" \
  "INFO io.trino.event.QueryMonitor FINISHED" "$(timeline "$ID")"
expect "a failed query's too" "INFO io.trino.event.QueryMonitor FAILED" "$(timeline "${E[1]}")"
echo "     e.g. $(grep -F "$ID" "$D/console.log" | jq -r .message | cut -c1-110)"
expect "the files under var/log do not carry the tags" 0 "$(grep -c "$JOB" "$D/files.log")"
echo "     the files under var/log: $(docker exec "$NAME" ls /tmp/trino/var/log 2>/dev/null | tr '\n' ' ')($(wc -l <"$D/files.log") lines)"
echo "     the HTTP request log's lines naming the query: $(grep -cF "$ID" "$D/files.log"); with a client tag or info header: $(grep -cE "qd-verify|$JOB" "$D/files.log")"

[ "$FAILED" = 0 ] && echo "All checks passed." || { echo "Some checks failed."; exit 1; }
