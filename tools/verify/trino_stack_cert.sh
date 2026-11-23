#!/bin/bash
# Verification of Trino with the machines' certificates (decision 0066, step
# 9), with the repository's own files for an installation with certificates:
# infra/trino/etc/coordinator/access-control.certificate.properties as it is,
# etc/worker/config.certificate.properties as it is, and
# etc/coordinator/config.certificate.properties without its Web UI's OAuth 2.0
# lines (no OIDC provider here; clients keep the JWT), and infra/trino's
# entrypoint.sh. It shows that:
#
#   (a) the coordinator starts reading its rules with the node agent's
#       machine.pem and no key, and nothing with a key is in its log;
#   (b) coordinator and worker talk HTTPS only, by their machine names, and a
#       query that runs on the worker succeeds;
#   (c) a worker's certificate replaced in its file is served within the
#       refresh, without a restart, and the cluster keeps working;
#   (d) Trino reads the agent's 0600 file as the same uid (1000), and not as
#       another;
#   (e) qd-node trino-ready and trino-restart (if built: target/debug/qd-node)
#       against it: the hold with the old certificate, the coordinator
#       restarted and back, the rules read and the release made with the new.
#
# Its own containers and network (qd-verify-trino-cert-*), a throwaway CA, a
# rules and machines' server of its own on this machine (python3, HTTPS that
# requires a client certificate: the API's routes as Traefik's internal entry
# point would pass them), memory capped at 1.5 GB per node; the dev stack is
# not touched. No rows but TPC-H's generated ones. Run from the repository
# root:
#
#   bash tools/verify/trino_stack_cert.sh
#
# Needs docker, openssl, curl, jq and python3.
set -u
export LC_ALL=C
IMAGE=${TRINO_IMAGE:-trinodb/trino:484}
P=qd-verify-trino-cert
NET=$P-net COORD=$P-coord WORKER=$P-worker
PORT=${PORT:-18947}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
QD_NODE=${QD_NODE:-$ROOT/target/debug/qd-node}
[ -x "$QD_NODE" ] || QD_NODE=${CARGO_TARGET_DIR:-/nonexistent}/debug/qd-node
D=$(mktemp -d)
chmod 700 "$D"
SRV=""
cleanup() {
  kill $SRV 2>/dev/null
  docker rm -f "$COORD" "$WORKER" "$P-other" >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
  # What the nodes wrote as uid 1001 is not this user's to remove.
  [ -d "$D/other-etc-data" ] && docker run --rm --user 0 -v "$D:/d" --entrypoint rm "$IMAGE" -rf /d/other-etc-data
  rm -rf "$D"
}
trap cleanup EXIT
FAILED=0
ok() { printf '[OK  ] %s\n' "$*"; }
ko() { printf '[FAIL] %s\n' "$*"; FAILED=1; }
note() { printf '[NOTE] %s\n' "$*"; }
expect() { if [ "$2" = "$3" ]; then ok "$1: $3"; else ko "$1: expected '$2', got '$3'"; fi; }

docker network rm "$NET" >/dev/null 2>&1
docker network create "$NET" >/dev/null || { echo "no network"; exit 1; }
GW=$(docker network inspect "$NET" -f '{{(index .IPAM.Config 0).Gateway}}')

# --- The CA and the machines' files, as the node agent writes them ------------
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
  -subj "/O=qd/CN=qd verify CA" -addext "basicConstraints=critical,CA:TRUE" \
  -keyout "$D/ca.key" -out "$D/ca.crt" 2>/dev/null
cert() { # FILE SUBJECT SAN: FILE.pem (certificate then key, as machine.pem)
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj "$2" \
    -keyout "$D/$1.key" -out "$D/$1.csr" 2>/dev/null
  printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=serverAuth,clientAuth\nsubjectAltName=%s\n' "$3" >"$D/ext"
  openssl x509 -req -in "$D/$1.csr" -CA "$D/ca.crt" -CAkey "$D/ca.key" -CAcreateserial \
    -days 1 -extfile "$D/ext" -out "$D/$1.crt" 2>/dev/null
  cat "$D/$1.crt" "$D/$1.key" >"$D/$1.pem"
}
serial() { openssl x509 -noout -serial -in "$1" | cut -d= -f2 | tr 'A-F' 'a-f'; }
cert rules "/CN=$GW" "IP:$GW"
cert coord "/O=qd/OU=trino-coordinator/CN=$COORD" "DNS:$COORD"
cert coord2 "/O=qd/OU=trino-coordinator/CN=$COORD" "DNS:$COORD"
cert worker "/O=qd/OU=trino-worker/CN=$WORKER" "DNS:$WORKER"
cert worker2 "/O=qd/OU=trino-worker/CN=$WORKER" "DNS:$WORKER"
agent_dir() { # NAME PEM: an agent's directory, 0700, machine.pem 0600
  mkdir -p "$D/$1"
  chmod 700 "$D/$1"
  cp "$D/ca.crt" "$D/$1/ca.crt" && chmod 644 "$D/$1/ca.crt"
  install -m 600 "$D/$2.pem" "$D/$1/machine.pem"
}
replace() { install -m 600 "$D/$2.pem" "$D/$1/.next" && mv -f "$D/$1/.next" "$D/$1/machine.pem"; }
agent_dir coord-agent coord
agent_dir worker-agent worker

# A token for the API's client, qd-api (RS256, as trino_mtls.sh's).
openssl genrsa -out "$D/jwt.key" 2048 2>/dev/null
b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
ISSUER=https://verify.example/api
jwt() {
  local h p
  h=$(printf '{"alg":"RS256","typ":"JWT","kid":"verify"}' | b64)
  p=$(printf '{"sub":"qd-api","iss":"%s","aud":"trino","exp":%s}' "$ISSUER" "$(($(date +%s) + 3600))" | b64)
  printf '%s.%s.%s' "$h" "$p" "$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -sign "$D/jwt.key" | b64)"
}

# --- The API's routes as the internal entry point passes them -----------------
cat >"$D/server.py" <<'EOF'
"""HTTPS requiring a client certificate of ./ca.crt: GET .../trino/rules
answers ./rules.json, POST .../trino/hold and .../release answer as the API
would. Each request goes to ./requests.log: method, path with its query,
the client's CN and serial."""
import http.server, ssl, sys
HOST, PORT = sys.argv[1], int(sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
    def log(self):
        peer = self.connection.getpeercert() or {}
        cn = [v for rdn in peer.get("subject", ()) for k, v in rdn if k == "commonName"]
        with open("requests.log", "a") as f:
            f.write("%s %s %s %s\n" % (self.command, self.path, cn[0] if cn else "-",
                                       peer.get("serialNumber", "-").lower()))
    def answer(self, body):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        self.log()
        self.answer(open("rules.json", "rb").read())
    def do_POST(self):
        self.log()
        if self.path.endswith("/trino/hold"):
            self.answer(b'{"free":true,"running_jobs":0,"running_queries":0}')
        else:
            self.answer(b'{"released":true}')
    def log_message(self, *a):
        pass
s = http.server.ThreadingHTTPServer((HOST, PORT), H)
c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
c.load_cert_chain("rules.crt", "rules.key")
c.load_verify_locations("ca.crt")
c.verify_mode = ssl.CERT_REQUIRED
c.minimum_version = ssl.TLSVersion.TLSv1_3
c.options |= ssl.OP_NO_TICKET
c.num_tickets = 0
s.socket = c.wrap_socket(s.socket, server_side=True)
s.serve_forever()
EOF
echo '{"catalogs":[{"allow":"all"}],"queries":[{"allow":["execute","view","kill"]}],"system_information":[{"allow":["read","write"]}]}' >"$D/rules.json"
(cd "$D" && exec python3 -I server.py "$GW" "$PORT") & SRV=$!
sleep 1
API=https://$GW:$PORT/api

# --- The nodes' etc, from the repository --------------------------------------
T=$ROOT/infra/trino/etc
# Each node with a 1 GB heap here: the query memory lowered to fit it, the
# rest of each file as it is.
SMALL='^query\.max-memory'
node_etc() { # DIR ID CONFIG
  mkdir -p "$D/$1/static-catalog" "$D/$1-data/jwks"
  printf 'node.environment=verify\nnode.id=%s\nnode.data-dir=/data/trino\n' "$2" >"$D/$1/node.properties"
  printf -- '-server\n-Xmx1G\n-XX:+ExitOnOutOfMemoryError\n' >"$D/$1/jvm.config"
  { grep -v -E "$SMALL" "$3"; printf 'query.max-memory=512MB\nquery.max-memory-per-node=256MB\n'; } >"$D/$1/config.properties"
  cp "$ROOT/infra/trino/entrypoint.sh" "$D/$1/entrypoint.sh"
  echo connector.name=tpch >"$D/$1/static-catalog/tpch.properties"
  chmod -R a+rX "$D/$1"
  chmod 777 "$D/$1-data" "$D/$1-data/jwks"
}
node_etc coord-etc coordinator-1 "$T/coordinator/config.certificate.properties"
# No OIDC provider here: the Web UI's OAuth 2.0 lines out, clients by JWT.
grep -v -E '^(web-ui\.|http-server\.authentication\.oauth2\.|http-server\.authentication\.type=)' \
  "$D/coord-etc/config.properties" >"$D/coord-etc/config.tmp"
mv "$D/coord-etc/config.tmp" "$D/coord-etc/config.properties"
echo http-server.authentication.type=jwt >>"$D/coord-etc/config.properties"
cp "$T/coordinator/access-control.certificate.properties" "$D/coord-etc/access-control.properties"
cp "$T/coordinator/user-mapping.json" "$T/coordinator/catalog-store.properties" "$D/coord-etc/"
openssl rsa -in "$D/jwt.key" -pubout -out "$D/coord-etc-data/jwks/verify.pem" 2>/dev/null
chmod a+r "$D/coord-etc-data/jwks/verify.pem"
node_etc worker-etc worker-1 "$T/worker/config.certificate.properties"
chmod -R a+rX "$D/coord-etc" "$D/worker-etc"

run() { # NAME ETC AGENT [DOCKER OPTION...]
  local name=$1 etc=$2 agent=$3
  shift 3
  docker rm -f "$name" >/dev/null 2>&1
  docker run -d --name "$name" --network "$NET" --memory 1536m "$@" \
    -e TRINO_DISCOVERY_URI="https://$COORD:8490" -e TRINO_NODE_NAME="$name" \
    -e TRINO_SHARED_SECRET=verify-shared-secret-0123456789abcdef \
    -e TRINO_RULES_URL="$API/internal/trino/rules" -e TRINO_JWT_ISSUER="$ISSUER" \
    -v "$D/$etc:/etc/trino:ro" \
    -v "$D/$etc-data:/data/trino" -v "$D/$agent:/run/qd-node:ro" \
    --entrypoint /bin/bash "$IMAGE" /etc/trino/entrypoint.sh >/dev/null
}
ip() { docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "$1"; }
started() { curl -s -m 2 "http://$(ip "$1"):$2/v1/info" | grep -q '"starting":false'; }
wait_started() { # NAME HTTP-PORT
  for _ in $(seq 90); do
    started "$1" "$2" && return 0
    docker ps -q -f "name=^$1\$" | grep -q . || return 1
    sleep 2
  done
  return 1
}
# sql STATEMENT: the first value of the first row, or the error's name.
sql() {
  local o=(-s -m 20 --cacert "$D/ca.crt" --resolve "$COORD:8490:$(ip "$COORD")" -H "Authorization: Bearer $(jwt)")
  local r next
  r=$(curl "${o[@]}" --data-binary "$1" "https://$COORD:8490/v1/statement") || { echo "curl $?"; return; }
  while :; do
    if echo "$r" | jq -e '.error' >/dev/null 2>&1; then echo "$r" | jq -r '.error.errorName'; return; fi
    if echo "$r" | jq -e '.data' >/dev/null 2>&1; then echo "$r" | jq -r '.data[0][0]'; return; fi
    next=$(echo "$r" | jq -r '.nextUri // empty')
    [ -n "$next" ] || { echo "no rows"; return; }
    r=$(curl "${o[@]}" "$next")
  done
}
served() { # NAME PORT: the serial of the certificate served
  echo | openssl s_client -connect "$(ip "$1"):$2" -servername "$1" -CAfile "$D/ca.crt" 2>/dev/null |
    openssl x509 -noout -serial 2>/dev/null | cut -d= -f2 | tr 'A-F' 'a-f'
}

echo "== (d, first: one JVM at a time) The agent's 0600 machine.pem, read as another uid than Trino's"
cp -a "$D/coord-etc" "$D/other-etc"
cp -a "$D/coord-etc-data" "$D/other-etc-data"
run "$P-other" other-etc coord-agent --user 1001:1001
for _ in $(seq 30); do docker ps -q -f "name=^$P-other\$" | grep -q . || break; sleep 2; done
r=$(docker logs "$P-other" 2>&1 | grep -m1 -E 'qd-node/(machine\.pem|ca\.crt)|AccessDenied|Permission denied' | cut -c1-160)
if [ -n "$r" ] && ! docker ps -q -f "name=^$P-other\$" | grep -q .; then ok "as uid 1001 it does not start: $r"
else ko "uid 1001: $(docker logs "$P-other" 2>&1 | grep -A3 'Configuration is invalid' | head -4)"; fi
docker rm -f "$P-other" >/dev/null 2>&1
note "the agent and Trino run as one uid, 1000 (the image's trino): what (a) to (e) do"

echo "== (a) The coordinator reads its rules with its certificate, no key"
run "$COORD" coord-etc coord-agent
if wait_started "$COORD" 8090; then ok "the coordinator started ($IMAGE)"
else ko "the coordinator did not start"; docker logs "$COORD" 2>&1 | grep -E 'ERROR|Exception' | head -5; exit 1; fi
first=$(grep ' /api/internal/trino/rules' "$D/requests.log" | head -1)
expect "the rules' server saw GET of the path, no query, with the coordinator's certificate" \
  "GET /api/internal/trino/rules $COORD $(serial "$D/coord.crt")" "$first"
expect "requests with a query (a key)" 0 "$(grep -c '?' "$D/requests.log")"
expect "lines of the coordinator's log with 'key='" 0 "$(docker logs "$COORD" 2>&1 | grep -c 'key=')"
docker logs "$COORD" 2>&1 | grep -o 'Refreshing system access control from [^ ]*' | head -1 | sed 's/^/   /'

echo "== (b) The worker joins over HTTPS, and a query runs on it"
run "$WORKER" worker-etc worker-agent
wait_started "$WORKER" 8091 && ok "the worker started" || ko "the worker did not start"
for _ in $(seq 30); do [ "$(sql 'SELECT count(*) FROM system.runtime.nodes')" = 2 ] && break; sleep 2; done
expect "nodes, as the coordinator sees them" 2 "$(sql 'SELECT count(*) FROM system.runtime.nodes')"
expect "the worker's URI" "https://$WORKER:8491" "$(sql "SELECT http_uri FROM system.runtime.nodes WHERE NOT coordinator")"
expect "the coordinator's URI" "https://$COORD:8490" "$(sql "SELECT http_uri FROM system.runtime.nodes WHERE coordinator")"
expect "a query on the worker (the coordinator schedules none)" 60175 "$(sql 'SELECT count(*) FROM tpch.tiny.lineitem')"
expect "the worker serves its machine certificate" "$(serial "$D/worker.crt")" "$(served "$WORKER" 8491)"

echo "== (c) The worker's certificate renewed in its file, no restart"
replace worker-agent worker2
t0=$(date +%s)
for _ in $(seq 50); do [ "$(served "$WORKER" 8491)" = "$(serial "$D/worker2.crt")" ] && break; sleep 2; done
expect "$(($(date +%s) - t0))s later it serves the renewed one" "$(serial "$D/worker2.crt")" "$(served "$WORKER" 8491)"
expect "a query on the worker still runs" 15000 "$(sql 'SELECT count(*) FROM tpch.tiny.orders')"
expect "the worker was not restarted" 0 "$(docker inspect -f '{{.RestartCount}}' "$WORKER")"

echo "== (e) qd-node's restart sequence against it"
if [ ! -x "$QD_NODE" ]; then
  note "no qd-node at $QD_NODE (capped cargo build -p node-agent -j 2): skipped"
else
  export QD_AGENT_DIR=$D/coord-agent QD_INTERNAL_URL=$API
  export QD_TRINO_RESTART="docker restart $COORD" QD_TRINO_INFO_URL="http://$(ip "$COORD"):8090/v1/info"
  chmod 700 "$D/coord-agent"
  "$QD_NODE" trino-ready 2>&1 | tail -1 | sed 's/^/   /'
  expect "trino-ready: exit 0, the hold asked with the old certificate" \
    "POST /api/internal/machines/trino/hold $COORD $(serial "$D/coord.crt")" "$(grep 'trino/hold' "$D/requests.log" | tail -1)"
  replace coord-agent coord2 # what the agent's promotion does
  n0=$(wc -l <"$D/requests.log")
  t0=$(date +%s)
  "$QD_NODE" trino-restart 2>&1 | tail -2 | sed 's/^/   /'
  code=${PIPESTATUS[0]}
  expect "trino-restart exit" 0 "$code"
  ok "restarted, back and released in $(($(date +%s) - t0))s"
  after=$(tail -n +"$((n0 + 1))" "$D/requests.log")
  expect "after it, the rules read with the new certificate" "GET /api/internal/trino/rules $COORD $(serial "$D/coord2.crt")" \
    "$(echo "$after" | grep 'trino/rules' | head -1)"
  expect "and the release made with the new certificate" "POST /api/internal/machines/trino/release $COORD $(serial "$D/coord2.crt")" \
    "$(echo "$after" | grep 'trino/release' | tail -1)"
  expect "any request with the old certificate after the restart" 0 "$(echo "$after" | grep -c "$(serial "$D/coord.crt")")"
  for _ in $(seq 30); do [ "$(sql 'SELECT count(*) FROM system.runtime.nodes')" = 2 ] && break; sleep 2; done
  expect "the worker found the restarted coordinator; a query on it" 25 "$(sql 'SELECT count(*) FROM tpch.tiny.nation')"
fi

[ "$FAILED" = 0 ] && echo "All checks passed." || { echo "Some checks failed."; exit 1; }
