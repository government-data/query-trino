#!/bin/bash
# Verification of Trino's access-control rules read from a URL (decision
# 0062): `security.config-file=https://…` with a trust store and a secret in
# the query string, a rule per dataset, how soon a new rule applies, what
# Trino does while the URL does not answer, and what it sends when it asks.
#
# It runs its own throwaway Trino, from the same image as infra/trino
# (trinodb/trino:484), single node, on Docker's default bridge, and a rules
# server of its own on this machine (python3, HTTPS with a throwaway CA),
# bound to the bridge's address; the shared dev cluster is not touched.
# Memory catalogs stand for two sources (`src_alpha`, `src_beta`) and the
# lake. Synthetic rows only. Run from the repository root:
#
#   bash tools/verify/trino_rules_http.sh
#
# The rules served are the API's for two datasets (`orders` from `alpha`,
# `loans` from `beta`): tools/verify/fixtures/trino_rules.json, which a test
# of `quality::trino_rules` keeps equal to what the API generates. Trino has
# no authentication here (the user is `X-Trino-User`): who a token is, is
# trino_job_token.sh's. Needs docker, openssl, jq, curl and python3.
set -u
export LC_ALL=C
cd "$(dirname "$0")/../.."
IMAGE=${TRINO_IMAGE:-trinodb/trino:484}
NAME=qd-verify-trino-rules-http
RULES=${RULES:-tools/verify/fixtures/trino_rules.json}
HOST=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}')
PORT=${PORT:-18931}
REFRESH=5
D=$(mktemp -d)
chmod 700 "$D"
SRV=""
trap 'kill $SRV 2>/dev/null; docker rm -f "$NAME" >/dev/null 2>&1; rm -rf "$D"' EXIT
FAILED=0
KEY=$(openssl rand -hex 24)

ok() { printf '[OK  ] %s\n' "$*"; }
ko() { printf '[FAIL] %s\n' "$*"; FAILED=1; }
expect() { # NAME EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then ok "$1: $3"; else ko "$1: expected '$2', got '$3'"; fi
}
like() { # NAME PATTERN ACTUAL
  case "$3" in
    *"$2"*) ok "$1: $(echo "${3//$KEY/<the secret>}" | cut -c1-110)" ;;
    *) ko "$1: expected '$2', got '$3'" ;;
  esac
}

# --- The rules server: HTTPS, 404 without the secret in the query ----------
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
  -subj "/CN=qd verify CA" -keyout "$D/ca.key" -out "$D/ca.crt" 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj "/CN=$HOST" \
  -keyout "$D/tls.key" -out "$D/tls.csr" 2>/dev/null
printf 'subjectAltName=IP:%s\n' "$HOST" >"$D/san"
openssl x509 -req -in "$D/tls.csr" -CA "$D/ca.crt" -CAkey "$D/ca.key" -CAcreateserial \
  -days 1 -extfile "$D/san" -out "$D/tls.crt" 2>/dev/null
cat >"$D/server.py" <<'EOF'
"""Serves ./rules.json to a request with ?key=<KEY> (404 without); 503
while ./down exists, no JSON while ./garbage exists. Each request's path
(without the key's value) and header names go to ./requests.log."""
import http.server, json, os, ssl, sys
from urllib.parse import urlsplit, parse_qs
HOST, PORT, KEY = sys.argv[1], int(sys.argv[2]), os.environ["KEY"]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlsplit(self.path)
        keyed = parse_qs(url.query).get("key") == [KEY]
        with open("requests.log", "a") as f:
            f.write(json.dumps({"path": url.path, "keyed": keyed, "headers": sorted(k.lower() for k in self.headers)}) + "\n")
        if not keyed:
            return self.answer(404, b"")
        if os.path.exists("down"):
            return self.answer(503, b"")
        self.answer(200, b"not json {" if os.path.exists("garbage") else open("rules.json", "rb").read())
    def answer(self, code, body):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
s = http.server.ThreadingHTTPServer((HOST, PORT), H)
c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
c.load_cert_chain("tls.crt", "tls.key")
s.socket = c.wrap_socket(s.socket, server_side=True)
s.serve_forever()
EOF
serve() { (cd "$D" && KEY=$KEY exec python3 -I server.py "$HOST" "$PORT") & SRV=$!; sleep 1; }
# The rules without the dataset `loans`, then with it.
jq 'with_entries(.value |= map(select(.user != "_loans")))' "$RULES" >"$D/rules.json"
serve

# --- A throwaway Trino whose rules are that URL -----------------------------
mkdir -p "$D/etc/catalog"
cp "$D/ca.crt" "$D/etc/rules-ca.crt"
cat >"$D/etc/config.properties" <<EOF
coordinator=true
node-scheduler.include-coordinator=true
http-server.http.port=8080
discovery.uri=http://localhost:8080
query.max-memory=256MB
query.max-memory-per-node=256MB
EOF
printf 'node.environment=verify\nnode.id=verify\nnode.data-dir=/tmp/trino\n' >"$D/etc/node.properties"
printf -- '-server\n-Xmx1G\n-XX:+ExitOnOutOfMemoryError\n' >"$D/etc/jvm.config"
for c in lake src_alpha src_beta; do echo connector.name=memory >"$D/etc/catalog/$c.properties"; done
# access URL [PROPERTY...]: access-control.properties, the secret from the
# environment (${ENV:…}), as infra/trino has it.
access() {
  { printf 'access-control.name=file\nsecurity.config-file=%s\nsecurity.refresh-period=%ss\n' "$1" "$REFRESH"
    shift; printf '%s\n' "$@"; } >"$D/etc/access-control.properties"
  chmod -R a+rX "$D/etc"
}
# start [DOCKER OPTION...]: 0 once Trino serves; 1 if its container exited or it took too long.
start() {
  docker rm -f "$NAME" >/dev/null 2>&1
  docker run -d --name "$NAME" --memory 1536m -e RULES_URL="https://$HOST:$PORT/rules" -e RULES_KEY="$KEY" "$@" -v "$D/etc:/etc/trino:ro" "$IMAGE" >/dev/null ||
    { echo "could not start $IMAGE"; exit 1; }
  for _ in $(seq 90); do
    docker exec "$NAME" curl -s http://localhost:8080/v1/info 2>/dev/null | grep -q '"starting":false' && return 0
    docker ps -q -f "name=$NAME" | grep -q . || return 1
    sleep 2
  done
  return 1
}
why() { docker logs "$NAME" 2>&1 | grep -oE "PKIX path building failed|Connection refused|Configuration property '[^']+' was not used" | head -1; }
# q USER SQL: the rows as TSV, or "ERROR: …", every page followed.
q() {
  docker exec -e U="$1" -e Q="$2" "$NAME" bash -c '
    r=$(curl -s -H "X-Trino-User: $U" --data-binary "$Q" http://localhost:8080/v1/statement)
    while :; do
      printf "%s\n" "$r"
      [[ $r =~ \"nextUri\":\"([^\"]+)\" ]] || break
      r=$(curl -s -H "X-Trino-User: $U" "${BASH_REMATCH[1]}")
    done' |
    jq -rR '(fromjson? // {"error": {"message": .}}) |
      (.data // [] | .[] | map(tostring) | join("\t")), (.error.message // empty | "ERROR: " + .)'
}
leaks() { case "$1" in *"$KEY"*) echo yes ;; *) echo no ;; esac; }
URL="\${ENV:RULES_URL}?key=\${ENV:RULES_KEY}"
TRUST=system-access-control.http-client.trust-store-path=/etc/trino/rules-ca.crt

echo "== HTTPS: the rules' certificate must be trusted"
access "$URL"
if start; then ko "starts without the CA of the rules' URL"; else expect "without a trust store, Trino does not start" "PKIX path building failed" "$(why)"; fi
access "https://someone:synthetic@$HOST:$PORT/rules?key=\${ENV:RULES_KEY}" "$TRUST"
if start; then ok "with $TRUST (a PEM file), it starts"; else ko "does not start with the trust store: $(why)"; exit 1; fi
# The JVM's own trust store, as infra/trino/entrypoint.sh builds it with the
# development CA: whether the rules' client reads it too.
mkdir "$D/jvm"; chmod 777 "$D/jvm"
docker run --rm --network none --entrypoint bash -v "$D/jvm:/w" -v "$D/ca.crt:/ca.crt:ro" "$IMAGE" -c \
  'cp "$JAVA_HOME/lib/security/cacerts" /w/trust.jks && keytool -importcert -noprompt -alias extra-ca -file /ca.crt -keystore /w/trust.jks -storepass changeit' >/dev/null 2>&1
access "$URL"
if start -v "$D/jvm/trust.jks:/trust.jks:ro" -e JAVA_TOOL_OPTIONS="-Djavax.net.ssl.trustStore=/trust.jks -Djavax.net.ssl.trustStorePassword=changeit"; then
  ok "with the CA in the JVM's trust store only (javax.net.ssl.trustStore), it starts"
else ko "the JVM's trust store is not read: $(why)"; fi
access "https://someone:synthetic@$HOST:$PORT/rules?key=\${ENV:RULES_KEY}" "$TRUST"
start || { ko "does not start again: $(why)"; exit 1; }
VERSION=$(docker exec "$NAME" curl -s http://localhost:8080/v1/info | jq -r '.nodeVersion.version')
echo "== Trino $VERSION, rules from https://$HOST:$PORT/rules?key=…"

echo "== What Trino sends when it asks, and the secret"
expect "every request carried the secret, from \${ENV:…}, in the query" true "$(jq -s 'length > 0 and all(.keyed)' "$D/requests.log")"
expect "its headers: no Authorization, though the URL had user:password@" "" "$(jq -r '.headers[]' "$D/requests.log" | sort -u | grep -ix authorization)"
echo "       headers sent: $(jq -r '.headers[]' "$D/requests.log" | sort -u | tr '\n' ' ')"
expect "without the secret, the server answers" 404 "$(curl -s -o /dev/null -w '%{http_code}' --cacert "$D/ca.crt" "https://$HOST:$PORT/rules")"
expect "with a wrong one" 404 "$(curl -s -o /dev/null -w '%{http_code}' --cacert "$D/ca.crt" "https://$HOST:$PORT/rules?key=wrong")"

echo "== A rule per dataset"
for s in "CREATE SCHEMA lake.orders_bronze" "CREATE SCHEMA lake.loans_bronze" "CREATE SCHEMA lake.orders_silver"; do
  expect "qd-api: $s" "" "$(q qd-api "$s")"
done
expect "qd-api: synthetic rows in src_alpha" 3 "$(q qd-api "CREATE TABLE src_alpha.default.t AS SELECT * FROM (VALUES 1, 2, 3) v(id)")"
expect "qd-api: synthetic rows in src_beta" 1 "$(q qd-api "CREATE TABLE src_beta.default.t AS SELECT * FROM (VALUES 7) v(id)")"
expect "_orders creates its bronze table from its source" 3 "$(q _orders 'CREATE TABLE lake.orders_bronze.t AS SELECT * FROM src_alpha.default.t')"
expect "_orders finds it in the lake's information_schema" t "$(q _orders "SELECT table_name FROM lake.information_schema.tables WHERE table_schema = 'orders_bronze'")"
like "_orders, another dataset's bronze" "Access Denied" "$(q _orders 'CREATE TABLE lake.loans_bronze.t AS SELECT * FROM src_alpha.default.t')"
expect "its error's name, as a client reads it" PERMISSION_DENIED "$(docker exec "$NAME" bash -c '
  r=$(curl -s -H "X-Trino-User: _orders" --data-binary "SELECT count(*) FROM src_beta.default.t" http://localhost:8080/v1/statement)
  while [[ $r =~ \"nextUri\":\"([^\"]+)\" ]]; do r=$(curl -s -H "X-Trino-User: _orders" "${BASH_REMATCH[1]}"); done
  [[ $r =~ \"errorName\":\"([A-Z_]+)\" ]] && echo "${BASH_REMATCH[1]}"')"
like "_orders, its own silver" "Access Denied" "$(q _orders 'CREATE TABLE lake.orders_silver.t AS SELECT * FROM src_alpha.default.t')"
like "_orders, another source" "Access Denied" "$(q _orders 'SELECT count(*) FROM src_beta.default.t')"
like "_orders, writing its source" "Access Denied" "$(q _orders 'INSERT INTO src_alpha.default.t VALUES 4')"
like "_loans, a dataset not in the rules yet" "Access Denied" "$(q _loans 'SELECT count(*) FROM src_beta.default.t')"
like "_alpha, a source's name (the user of before)" "Access Denied" "$(q _alpha 'SELECT count(*) FROM src_alpha.default.t')"
expect "src_alpha, a read job, still reads its catalog" 3 "$(q src_alpha 'SELECT count(*) FROM src_alpha.default.t')"

echo "== A dataset just mapped: when its rule applies (refresh period ${REFRESH}s)"
asked=$(jq -s length "$D/requests.log")
sleep $((REFRESH * 3))
expect "no query, no request: Trino asks when a query comes, not on a timer" "$asked" "$(jq -s length "$D/requests.log")"
# The worst case: Trino has just read the rules when the new ones are served.
q qd-api 'SELECT 1' >/dev/null
cp "$RULES" "$D/rules.json"
t0=$(date +%s)
for _ in $(seq 30); do
  r=$(q _loans 'CREATE TABLE IF NOT EXISTS lake.loans_bronze.t AS SELECT * FROM src_beta.default.t')
  case "$r" in ERROR*) sleep 1 ;; *) break ;; esac
done
took=$(($(date +%s) - t0))
if [ "$r" = 1 ] && [ "$took" -ge $((REFRESH - 2)) ] && [ "$took" -le $((REFRESH + 3)) ]; then
  ok "_loans, refused until then, may extract ${took}s after its rule is served"
else ko "_loans after ${took}s: $r"; fi

echo "== The URL does not answer: Trino fails closed"
touch "$D/down"; sleep $((REFRESH + 2))
r=$(q _orders 'SELECT count(*) FROM lake.orders_bronze.t')
like "503: a query that was allowed" "ERROR" "$r"
expect "503: the error a client gets names the URL, its secret too" yes "$(leaks "$r")"
like "503: qd-api too" "ERROR" "$(q qd-api 'SELECT 1')"
rm "$D/down"; touch "$D/garbage"; sleep $((REFRESH + 2))
r=$(q _orders 'SELECT count(*) FROM lake.orders_bronze.t')
like "no JSON" "ERROR" "$r"
expect "no JSON: the error carries the secret" no "$(leaks "$r")"
rm "$D/garbage"; sleep $((REFRESH + 2))
expect "answering again, the rules are back" 3 "$(q _orders 'SELECT count(*) FROM lake.orders_bronze.t')"
kill "$SRV"; sleep $((REFRESH + 2))
r=$(q _orders 'SELECT count(*) FROM lake.orders_bronze.t')
like "connection refused" "ERROR" "$r"
expect "connection refused: the error carries the secret" no "$(leaks "$r")"
expect "Trino's own log carries the secret" yes "$(leaks "$(docker logs "$NAME" 2>&1)")"
if start; then ko "starts while the rules' URL is gone"; else expect "restarted while the URL is gone, Trino does not start" "Connection refused" "$(why)"; fi
serve
if start; then ok "with the URL back, it starts"; else ko "does not start with the URL back: $(why)"; fi

echo "== The infra's own access-control.properties"
cp infra/trino/etc/coordinator/access-control.properties "$D/etc/access-control.properties"
chmod -R a+rX "$D/etc"
if start -e TRINO_RULES_URL="https://$HOST:$PORT/rules" -e TRINO_RULES_KEY="$KEY" -v "$D/jvm/trust.jks:/trust.jks:ro" \
  -e JAVA_TOOL_OPTIONS="-Djavax.net.ssl.trustStore=/trust.jks -Djavax.net.ssl.trustStorePassword=changeit"; then
  expect "with it, the URL and the secret from the environment, qd-api runs" 1 "$(q qd-api 'SELECT 1')"
  like "and a machine client runs nothing" "Access Denied" "$(q qd-worker-dev 'SELECT 1')"
else ko "does not start with the infra's access-control.properties: $(why)"; fi

# --- Traefik, through which Trino reaches the API: its access log ----------
# A throwaway Traefik with no network and no backend (502): what its access
# log keeps of a request, and of one whose router turns the log off.
TRAEFIK=${TRAEFIK_IMAGE:-traefik:v3.6}
echo "== Traefik's access log and the secret in the query ($TRAEFIK)"
docker rm -f "$NAME" >/dev/null 2>&1
cat >"$D/dyn.yml" <<'EOF'
http:
  routers:
    api:
      rule: "PathPrefix(`/api`)"
      entryPoints: [web]
      priority: 100
      service: gone
    rules:
      rule: "Path(`/api/internal/trino/rules`)"
      entryPoints: [web]
      priority: 300
      service: gone
      observability:
        accessLogs: false
  services:
    gone:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:9"
EOF
chmod a+rx "$D"; chmod a+r "$D/dyn.yml"
docker run -d --name "$NAME" --network none --memory 256m -v "$D/dyn.yml:/dyn.yml:ro" "$TRAEFIK" \
  --providers.file.filename=/dyn.yml --accesslog=true --entrypoints.web.address=:8080 >/dev/null ||
  { echo "could not start $TRAEFIK"; exit 1; }
sleep 4
for path in /api/other /api/internal/trino/rules; do
  docker exec "$NAME" wget -q -O /dev/null "http://127.0.0.1:8080$path?key=$KEY" 2>/dev/null
done
sleep 1
log=$(docker logs "$NAME" 2>&1)
like "a request's query is in the access log" "GET /api/other?key=$KEY" "$log"
expect "a router with observability.accessLogs: false leaves none" 0 "$(echo "$log" | grep -c /api/internal/trino/rules)"

[ "$FAILED" = 0 ] && echo "All checks passed." || { echo "Some checks failed."; exit 1; }
