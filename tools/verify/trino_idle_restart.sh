#!/bin/bash
# Verification of the idle restart of Trino's coordinator (decision 0066,
# point 9): how an agent on the machine asks Trino whether it runs or queues a
# query, what a client sees when the coordinator stops and starts under it,
# whether a coordinator can refuse new queries first, how long a restart takes,
# and that after it Trino presents its renewed certificate to the rules server.
#
# A throwaway Trino (trinodb/trino:484, single node, 1536 MB) on Docker's
# default bridge, set up as infra/trino: HTTPS with JWT, no client over plain
# HTTP, file-based access control read with a client certificate from a rules
# server of its own (python3, HTTPS with a throwaway CA). A resource group of
# one query at a time makes a second query wait. Synthetic users only, no rows.
# The shared dev cluster is not touched. Run from the repository root:
#
#   bash tools/verify/trino_idle_restart.sh
#
# Needs docker, openssl, jq, curl and python3.
set -u
export LC_ALL=C
IMAGE=${TRINO_IMAGE:-trinodb/trino:484}
NAME=qd-verify-trino-idle
HOST=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}')
PORT=${PORT:-18943}
REFRESH=5
LONG='SELECT sum(quantity) FROM tpch.sf30.lineitem' # about 40 s on one node
D=$(mktemp -d)
chmod 700 "$D"
SRV=""
trap 'kill $SRV 2>/dev/null; docker rm -f "$NAME" >/dev/null 2>&1; rm -rf "$D"' EXIT
FAILED=0

ok() { printf '[OK  ] %s\n' "$*"; }
ko() { printf '[FAIL] %s\n' "$*"; FAILED=1; }
expect() { if [ "$2" = "$3" ]; then ok "$1: $3"; else ko "$1: expected '$2', got '$3'"; fi; }
like() { case "$3" in *"$2"*) ok "$1: $(echo "$3" | head -1 | cut -c1-110)" ;; *) ko "$1: expected '$2', got '$3'" ;; esac; }

# --- Certificates and tokens (as trino_mtls.sh) ------------------------------------
ca() {
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
    -subj "/CN=qd verify $1" -addext "basicConstraints=critical,CA:TRUE" \
    -keyout "$D/$1.key" -out "$D/$1.crt" 2>/dev/null
}
cert() { # FILE CA SUBJECT SAN
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj "$3" \
    -keyout "$D/$1.key" -out "$D/$1.csr" 2>/dev/null
  printf 'basicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth,clientAuth\nsubjectAltName=%s\n' "$4" >"$D/ext"
  openssl x509 -req -in "$D/$1.csr" -CA "$D/$2.crt" -CAkey "$D/$2.key" -CAcreateserial \
    -days 1 -extfile "$D/ext" -out "$D/$1.crt" 2>/dev/null
  cat "$D/$1.crt" "$D/$1.key" >"$D/$1.pem"
}
ca ca
cert rules ca "/CN=$HOST" "IP:$HOST"
cert trino ca "/O=qd/OU=trino/CN=trino-1" "DNS:localhost"
cert trino2 ca "/O=qd/OU=trino/CN=trino-1-renewed" "DNS:localhost"
openssl genrsa -out "$D/jwt.key" 2048 2>/dev/null
openssl rsa -in "$D/jwt.key" -pubout -out "$D/jwt.pub" 2>/dev/null
b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
jwt() { # SUBJECT
  local h p
  h=$(printf '{"alg":"RS256","typ":"JWT"}' | b64)
  p=$(printf '{"sub":"%s","exp":%s}' "$1" "$(($(date +%s) + 3600))" | b64)
  printf '%s.%s.%s' "$h" "$p" "$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -sign "$D/jwt.key" | b64)"
}

# --- The rules server: the server of trino_mtls.sh, requiring a certificate ------------
sed -n '/^"""Serves/,/^s.serve_forever()/p' "$(dirname "$0")/trino_mtls.sh" >"$D/server.py"
# rules AGENT_QUERIES JOBS_QUERIES: qd-api runs, sees and kills; node-agent reads
# and writes system information (the management endpoints).
rules() { write_rules "$@"; sleep $((REFRESH + 1)); api node-agent GET /v1/info/state >/dev/null; } # the next check reloads
write_rules() {
  printf '{"catalogs":[{"allow":"all"}],"queries":[{"user":"qd-api","allow":["execute","view","kill"]},%s{"user":"job-.*","allow":%s}],"system_information":[{"user":"node-agent","allow":["read","write"]}]}\n' \
    "${1:+{\"user\":\"node-agent\",\"allow\":$1\},}" "$2" >"$D/rules.json"
}
(cd "$D" && exec python3 -I server.py "$HOST" "$PORT" mtls) & SRV=$!
last() { tail -1 "$D/requests.log" 2>/dev/null; }

# --- A throwaway Trino -------------------------------------------------------------
mkdir -p "$D/etc/catalog" "$D/etc/tls"
cp "$D/ca.crt" "$D/jwt.pub" "$D/etc/"
cp "$D/trino.pem" "$D/etc/tls/server.pem"
cp "$D/trino.pem" "$D/etc/tls/client.pem"
printf 'node.environment=verify\nnode.id=verify\nnode.data-dir=/tmp/trino\n' >"$D/etc/node.properties"
printf -- '-server\n-Xmx1G\n-XX:+ExitOnOutOfMemoryError\n' >"$D/etc/jvm.config"
echo connector.name=tpch >"$D/etc/catalog/tpch.properties"
cat >"$D/etc/config.properties" <<EOF
coordinator=true
node-scheduler.include-coordinator=true
http-server.http.port=8080
discovery.uri=http://localhost:8080
query.max-memory=256MB
query.max-memory-per-node=256MB
internal-communication.shared-secret=$(openssl rand -hex 24)
http-server.https.enabled=true
http-server.https.port=8443
http-server.https.keystore.path=/etc/trino/tls/server.pem
http-server.authentication.type=jwt
http-server.authentication.jwt.key-file=/etc/trino/jwt.pub
http-server.authentication.allow-insecure-over-http=false
EOF
printf 'access-control.name=file\nsecurity.config-file=https://%s:%s/rules\nsecurity.refresh-period=%ss\n' "$HOST" "$PORT" "$REFRESH" >"$D/etc/access-control.properties"
printf 'system-access-control.http-client.%s\n' trust-store-path=/etc/trino/ca.crt key-store-path=/etc/trino/tls/client.pem >>"$D/etc/access-control.properties"
printf 'resource-groups.configuration-manager=file\nresource-groups.config-file=/etc/trino/groups.json\n' >"$D/etc/resource-groups.properties"
echo '{"rootGroups":[{"name":"all","softMemoryLimit":"100%","hardConcurrencyLimit":1,"maxQueued":10}],"selectors":[{"group":"all"}]}' >"$D/etc/groups.json"
chmod -R a+rX "$D/etc"
write_rules '["view"]' '["execute"]'
docker run -d --name "$NAME" --memory 1536m -v "$D/etc:/etc/trino:ro" "$IMAGE" >/dev/null || { echo "could not start $IMAGE"; exit 1; }
IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$NAME")
info() { curl -s -m 2 "http://$IP:8080/v1/info"; }
for _ in $(seq 90); do info | grep -q '"starting":false' && break; sleep 2; done
info | grep -q '"starting":false' || { echo "Trino did not start"; docker logs "$NAME" 2>&1 | tail -5; exit 1; }

# api USER METHOD PATH [CURL ARG...]: the body, then the HTTP status.
api() {
  local u=$1 m=$2 p=$3; shift 3
  curl -sk -m 10 -X "$m" -H "Authorization: Bearer $(jwt "$u")" -w '\n%{http_code}' "$@" "https://$IP:8443$p"
}
code() { api "$@" -o /dev/null | tail -1; }
put_state() { api node-agent PUT /v1/info/state -H 'Content-Type: application/json' -d "\"$1\"" | head -1 | cut -c1-80; }
# stmt USER SQL [ID FILE]: runs a statement to its end; prints FINISHED, Trino's
# error name, "HTTP n" or "curl exit n" (what a worker would retry on).
stmt() {
  local t r c next; t=$(jwt "$1")
  r=$(curl -sk -m 10 -H "Authorization: Bearer $t" --data-binary "$2" -w '\n%{http_code}' "https://$IP:8443/v1/statement") || { echo "curl exit $?"; return; }
  while :; do
    c=${r##*$'\n'}; r=${r%$'\n'*}
    [ "$c" = 200 ] || { echo "HTTP $c $(echo "$r" | head -c 60)"; return; }
    next=$(echo "$r" | jq -r '.nextUri // empty')
    [ -n "${3:-}" ] && { echo "$r" | jq -r '.id' >"$3"; [ -z "$next" ] || echo "$next" >"$3.next"; }
    [ -n "$next" ] || break
    r=$(curl -sk -m 10 -H "Authorization: Bearer $t" -w '\n%{http_code}' "$next") || { echo "curl exit $?"; return; }
  done
  echo "$r" | jq -r '.error.errorName // .stats.state'
}
# busy: the states of the queries not done, as the agent sees them in /v1/query.
busy() { api node-agent GET /v1/query | sed '$d' | jq -r '[.[].state | select(. != "FINISHED" and . != "FAILED")] | sort | join(" ")'; }
metric() { api node-agent GET /metrics | grep -E "^trino_execution_name_QueryManager_${1}Queries " | awk '{print int($2)}'; }
kill_all() { for id in $(api qd-api GET /v1/query | sed '$d' | jq -r '.[] | select(.state != "FINISHED" and .state != "FAILED") | .queryId'); do code qd-api DELETE "/v1/query/$id" >/dev/null; done; }
stmt qd-api 'SELECT 1' >/dev/null
VERSION=$(info | jq -r '.nodeVersion.version')

echo "== (a) Asking Trino $VERSION whether it is idle"
expect "/v1/info: public, its state, no count of queries" "ACTIVE false" "$(info | jq -r '"\(.state) \(has("runningQueries"))"')"
expect "/v1/status: public, memory and CPU only" false "$(curl -s "http://$IP:8080/v1/status" | jq 'has("runningQueries")')"
expect "/v1/query with no token" 401 "$(curl -sk -o /dev/null -w '%{http_code}' "https://$IP:8443/v1/query")"
expect "/v1/query over plain HTTP, no client allowed there" 403 "$(curl -s -o /dev/null -w '%{http_code}' -H 'X-Trino-User: node-agent' "http://$IP:8080/v1/query")"
expect "/metrics as a job's user (no system_information read)" 403 "$(code job-1 GET /metrics)"
expect "nothing running: busy states in /v1/query as node-agent" "" "$(busy)"
expect "nothing running: the finished queries are still listed (expire after 15 min)" true "$(api node-agent GET /v1/query | sed '$d' | jq 'length > 0')"
stmt job-1 "$LONG" "$D/q1" >"$D/q1.out" &
sleep 3
stmt job-2 "$LONG" >/dev/null &
sleep 4
expect "one running, one queued: /v1/query as node-agent with queries allow [view]" "QUEUED RUNNING" "$(busy)"
expect "the same in /metrics (system_information read): Running and Queued" "1 1" "$(metric Running) $(metric Queued)"
rules '' '["execute"]'
expect "node-agent without a queries rule sees none of them in /v1/query" "" "$(busy)"
expect "system.runtime.queries needs execute: as node-agent" PERMISSION_DENIED "$(stmt node-agent 'SELECT count(*) FROM system.runtime.queries')"
rules '["view"]' '["execute"]'
kill_all

echo "== (b) Refusing new queries before a restart, and a restart under a query"
like "PUT /v1/info/state SHUTTING_DOWN on the coordinator" "Cannot shutdown coordinator" "$(put_state SHUTTING_DOWN)"
like "PUT /v1/info/state DRAINING on the coordinator" "Cannot drain coordinator" "$(put_state DRAINING)"
expect "it stays ACTIVE and runs a new query" "ACTIVE FINISHED" "$(info | jq -r .state) $(stmt job-3 'SELECT 1')"
expect "rules that let only qd-api execute (from the API, ${REFRESH}s refresh): a job is refused" PERMISSION_DENIED "$(rules '["view"]' '[]'; stmt job-3 'SELECT 1')"
expect "the rules restored: it runs" FINISHED "$(rules '["view"]' '["execute"]'; stmt job-3 'SELECT 1')"
stmt job-1 "$LONG" "$D/q1" >"$D/q1.out" & LONGPID=$!
sleep 6
expect "a query is running" RUNNING "$(busy)"
cp "$D/trino2.pem" "$D/etc/tls/client.pem" # renewed while it runs
t0=$(date +%s.%N)
docker restart "$NAME" >/dev/null & RESTARTPID=$!
sleep 0.5
# Probe every 0.3 s; each change of outcome with its time.
prev="" trace="" n=0 down=0
while :; do
  o=$(stmt job-9 'SELECT 1' | cut -d' ' -f1-3)
  s=$(info | jq -r '.starting' 2>/dev/null); s=${s:-down} # nothing: not listening
  [ "$o" = FINISHED ] || down=1
  [ "$down" = 1 ] && [ "$o $s" != "$prev" ] && { printf '   %5.1fs  %-20s starting=%s\n' "$(echo "$(date +%s.%N) - $t0" | bc)" "$o" "$s"; trace="$trace|$o"; prev="$o $s"; }
  [ "$down" = 1 ] && [ "$o" = FINISHED ] && [ "$s" = false ] && break
  n=$((n + 1)); [ $n -gt 600 ] && break
  sleep 0.3
done
T=$(echo "$(date +%s.%N) - $t0" | bc | cut -d. -f1)
wait "$LONGPID" "$RESTARTPID"
like "the running query's client, polling, when the coordinator stops" "curl exit" "$(cat "$D/q1.out")"
expect "its nextUri after the restart" "Error 404 Not Found: Query not found (404)" "$(curl -sk -w ' (%{http_code})' -H "Authorization: Bearer $(jwt job-1)" "$(cat "$D/q1.next")")"
expect "the query in /v1/query/{id}: gone" 410 "$(curl -sk -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(jwt qd-api)" "https://$IP:8443/v1/query/$(cat "$D/q1")")"

echo "== (c) and (d) What a client sees, and how long it takes"
expect "outcomes in order: refused (curl 7) while down, SERVER_STARTING_UP while starting" "curl exit 7|SERVER_STARTING_UP|FINISHED" "$(echo "$trace" | tr '|' '\n' | grep -v '^$' | grep -v '^curl exit [^7]' | uniq | paste -sd'|')"
if [ "$T" -le 90 ]; then ok "docker restart until a query finishes: ${T}s"; else ko "restart took ${T}s"; fi
expect "after the restart, the rules server saw" trino-1-renewed "$(last)"
t0=$(date +%s); docker stop "$NAME" >/dev/null; ts=$(($(date +%s) - t0))
if [ "$ts" -le 5 ]; then ok "docker stop (SIGTERM): exits in ${ts}s, no wait for queries"; else ko "docker stop took ${ts}s"; fi
docker start "$NAME" >/dev/null
for _ in $(seq 300); do [ "$(stmt job-9 'SELECT 1')" = FINISHED ] && break; sleep 0.3; done
T=$(($(date +%s) - t0))
if [ "$T" -le 90 ]; then ok "docker stop then start until a query finishes: ${T}s"; else ko "stop and start took ${T}s"; fi

[ "$FAILED" = 0 ] && echo "All checks passed." || { echo "Some checks failed."; exit 1; }
