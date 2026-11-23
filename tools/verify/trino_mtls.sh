#!/bin/bash
# Verification of Trino with the installation's certificates (decisions 0023
# and 0030): whether Trino can ask every client for a certificate on top of
# its JWT, whether it presents one of its own when it reads its rules from
# the API (0062), and whether it takes renewed certificates, its server's
# and its client's, without a restart.
#
# It runs its own throwaway Trino, from the same image as infra/trino
# (trinodb/trino:484), single node, on Docker's default bridge, and a rules
# server of its own on this machine (python3, HTTPS that requires a client
# certificate, with a throwaway CA); the shared dev cluster is not touched.
# No rows at all. Run from the repository root:
#
#   bash tools/verify/trino_mtls.sh
#
# Needs docker, openssl, jq and python3.
set -u
export LC_ALL=C
IMAGE=${TRINO_IMAGE:-trinodb/trino:484}
NAME=qd-verify-trino-mtls
HOST=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}')
PORT=${PORT:-18941}
REFRESH=5
D=$(mktemp -d)
chmod 700 "$D"
SRV=""
trap 'kill $SRV 2>/dev/null; docker rm -f "$NAME" >/dev/null 2>&1; rm -rf "$D"' EXIT
FAILED=0

ok() { printf '[OK  ] %s\n' "$*"; }
ko() { printf '[FAIL] %s\n' "$*"; FAILED=1; }
note() { printf '[NOTE] %s\n' "$*"; }
expect() { # NAME EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then ok "$1: $3"; else ko "$1: expected '$2', got '$3'"; fi
}

# --- Certificates ------------------------------------------------------------
ca() { # NAME
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
    -subj "/CN=qd verify $1" -addext "basicConstraints=critical,CA:TRUE" \
    -keyout "$D/$1.key" -out "$D/$1.crt" 2>/dev/null
}
cert() { # FILE CA SUBJECT SAN: FILE.crt, FILE.key and FILE.pem (both)
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj "$3" \
    -keyout "$D/$1.key" -out "$D/$1.csr" 2>/dev/null
  printf 'basicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth,clientAuth\nsubjectAltName=%s\n' "$4" >"$D/ext"
  openssl x509 -req -in "$D/$1.csr" -CA "$D/$2.crt" -CAkey "$D/$2.key" -CAcreateserial \
    -days 1 -extfile "$D/ext" -out "$D/$1.crt" 2>/dev/null
  cat "$D/$1.crt" "$D/$1.key" >"$D/$1.pem"
}
ca ca
ca other
cert rules ca "/CN=$HOST" "IP:$HOST"
cert trino ca "/O=qd/OU=trino/CN=trino-1" "DNS:localhost"
cert trino2 ca "/O=qd/OU=trino/CN=trino-1-renewed" "DNS:localhost"
cert worker ca "/O=qd/OU=worker/CN=worker-7" "DNS:worker-7"
cert stranger other "/O=qd/OU=worker/CN=worker-7" "DNS:worker-7"
# A token's key (RS256: a signature openssl writes as JWT wants it).
openssl genrsa -out "$D/jwt.key" 2048 2>/dev/null
openssl rsa -in "$D/jwt.key" -pubout -out "$D/jwt.pub" 2>/dev/null
b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
jwt() { # SUBJECT
  local h p
  h=$(printf '{"alg":"RS256","typ":"JWT"}' | b64)
  p=$(printf '{"sub":"%s","exp":%s}' "$1" "$(($(date +%s) + 600))" | b64)
  printf '%s.%s.%s' "$h" "$p" "$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -sign "$D/jwt.key" | b64)"
}

# --- The rules server: HTTPS, and a client certificate when ./mtls exists -------
cat >"$D/server.py" <<'EOF'
"""Serves ./rules.json over HTTPS; requires a client certificate of ./ca.crt
when started with `mtls`. Each request's client CN goes to ./requests.log."""
import http.server, ssl, sys
HOST, PORT, MODE = sys.argv[1], int(sys.argv[2]), sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        peer = self.connection.getpeercert() or {}
        cn = [v for rdn in peer.get("subject", ()) for k, v in rdn if k == "commonName"]
        with open("requests.log", "a") as f:
            f.write((cn[0] if cn else "-") + "\n")
        body = open("rules.json", "rb").read()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
s = http.server.ThreadingHTTPServer((HOST, PORT), H)
c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
c.load_cert_chain("rules.crt", "rules.key")
c.load_verify_locations("ca.crt")
c.verify_mode = ssl.CERT_REQUIRED if MODE == "mtls" else ssl.CERT_OPTIONAL
# TLS 1.3 without tickets: no resumption, every request a full handshake
# that shows the certificate the client holds now.
c.minimum_version = ssl.TLSVersion.TLSv1_3
c.options |= ssl.OP_NO_TICKET
c.num_tickets = 0
s.socket = c.wrap_socket(s.socket, server_side=True)
s.serve_forever()
EOF
echo '{"catalogs":[{"allow":"all"}]}' >"$D/rules.json"
serve() { (cd "$D" && exec python3 -I server.py "$HOST" "$PORT" "$1") & SRV=$!; sleep 1; }
last() { tail -1 "$D/requests.log" 2>/dev/null; }

# --- A throwaway Trino -----------------------------------------------------------
mkdir -p "$D/etc/catalog" "$D/etc/tls"
cp "$D/ca.crt" "$D/etc/ca.crt"
cp "$D/jwt.pub" "$D/etc/jwt.pub"
cp "$D/trino.pem" "$D/etc/tls/server.pem"
cp "$D/trino.pem" "$D/etc/tls/client.pem"
printf 'node.environment=verify\nnode.id=verify\nnode.data-dir=/tmp/trino\n' >"$D/etc/node.properties"
printf -- '-server\n-Xmx1G\n-XX:+ExitOnOutOfMemoryError\n' >"$D/etc/jvm.config"
echo connector.name=memory >"$D/etc/catalog/memory.properties"
config() { # AUTHENTICATION TYPES
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
http-server.https.truststore.path=/etc/trino/ca.crt
http-server.https.ssl-context.refresh-time=${REFRESH}s
http-server.authentication.type=$1
http-server.authentication.allow-insecure-over-http=true
EOF
  case "$1" in *jwt*) echo http-server.authentication.jwt.key-file=/etc/trino/jwt.pub >>"$D/etc/config.properties" ;; esac
}
access() { # [PROPERTY...]
  { printf 'access-control.name=file\nsecurity.config-file=https://%s:%s/rules\nsecurity.refresh-period=%ss\n' "$HOST" "$PORT" "$REFRESH"
    echo system-access-control.http-client.trust-store-path=/etc/trino/ca.crt
    printf '%s\n' "$@"; } >"$D/etc/access-control.properties"
  chmod -R a+rX "$D/etc"
}
start() {
  docker rm -f "$NAME" >/dev/null 2>&1
  docker run -d --name "$NAME" --memory 1536m -v "$D/etc:/etc/trino:ro" "$IMAGE" >/dev/null ||
    { echo "could not start $IMAGE"; exit 1; }
  for _ in $(seq 90); do
    docker exec "$NAME" curl -s http://localhost:8080/v1/info 2>/dev/null | grep -q '"starting":false' && return 0
    docker ps -q -f "name=$NAME" | grep -q . || return 1
    sleep 2
  done
  return 1
}
why() { docker logs "$NAME" 2>&1 | grep -oE "PKIX path building failed|Connection refused|bad_certificate|certificate_required|Received fatal alert: [a-z_]+|Configuration property '[^']+' was not used" | head -1; }
# The clients' files, where curl in the container reads them.
clients() {
  docker exec -u 0 "$NAME" mkdir -p /c
  for f in ca.crt worker.crt worker.key stranger.crt stranger.key; do docker cp -q "$D/$f" "$NAME:/c/$f"; done
  docker exec -u 0 "$NAME" chmod -R a+rX /c
}
# who [CERT|-] [TOKEN]: current_user of a query over HTTPS, or the HTTP
# status, or curl's failure.
who() {
  docker exec -e C="${1:--}" -e T="${2:-}" "$NAME" bash -c '
    o=(-s --cacert /c/ca.crt)
    [ "$C" = - ] || o+=(--cert "/c/$C.crt" --key "/c/$C.key")
    [ -z "$T" ] || o+=(-H "Authorization: Bearer $T")
    r=$(curl "${o[@]}" -w "\n%{http_code}" --data-binary "SELECT current_user" https://localhost:8443/v1/statement) || { echo "curl exit $?"; exit; }
    code=${r##*$'"'"'\n'"'"'}
    [ "$code" = 200 ] || { echo "HTTP $code"; exit; }
    while [[ $r =~ \"nextUri\":\"([^\"]+)\" ]]; do
      next=${BASH_REMATCH[1]}
      [[ $r =~ \"data\":\[\[\"([^\"]+)\" ]] && break
      r=$(curl "${o[@]}" "$next")
    done
    [[ $r =~ \"data\":\[\[\"([^\"]+)\" ]] && echo "${BASH_REMATCH[1]}" || echo "no rows"'
}
# tls: curl's verbose handshake with Trino's HTTPS, no client certificate.
tls() { docker exec "$NAME" bash -c 'curl -sv --cacert /c/ca.crt https://localhost:8443/v1/info 2>&1'; }
served() { tls | grep -oE 'subject: .*CN=[^;,]*' | head -1 | sed 's/.*CN=//'; }
asks() { tls | grep -q 'Request CERT' && echo yes || echo no; }
fetches() { wc -l <"$D/requests.log" | tr -d ' '; }

echo "== Trino reads its rules with a certificate of its own"
serve mtls
config jwt
access
if start; then ko "starts though the rules' server requires a certificate it does not have"
else expect "without a key store, the rules' server refuses it and Trino does not start" certificate_required "$(why)"; fi
access system-access-control.http-client.key-store-path=/etc/trino/tls/client.pem
if start; then ok "with system-access-control.http-client.key-store-path (a PEM file, certificate and key), it starts"
else ko "does not start with the key store: $(why)"; docker logs "$NAME" 2>&1 | tail -5; exit 1; fi
VERSION=$(docker exec "$NAME" curl -s http://localhost:8080/v1/info | jq -r '.nodeVersion.version')
expect "Trino $VERSION: the rules' server saw the certificate of" trino-1 "$(last)"

echo "== That certificate, renewed while Trino runs (refresh ${REFRESH}s)"
clients
cp "$D/trino2.pem" "$D/etc/tls/client.pem"
n0=$(fetches)
t0=$(date +%s)
# A query after each refresh period makes Trino read its rules again.
while [ $(($(date +%s) - t0)) -lt 130 ]; do
  sleep $((REFRESH + 1))
  [ "$(who - "$(jwt renewal)")" = renewal ] || { ko "a query during the renewal failed"; break; }
done
n=$(($(fetches) - n0))
if [ "$n" -ge 15 ]; then ok "in $(($(date +%s) - t0))s after the renewal, Trino read its rules $n times"
else ko "only $n rule fetches in $(($(date +%s) - t0))s"; fi
expect "of those, how many presented the renewed certificate (its client reads the key store once)" 0 \
  "$(tail -n "$n" "$D/requests.log" | grep -c trino-1-renewed)"
start >/dev/null && sleep 1
expect "after a restart" trino-1-renewed "$(last)"

echo "== Clients of Trino: a certificate on top of the token?"
# Trino binds airlift's client-certificate mode to REQUESTED when `certificate`
# is among the types (ServerSecurityModule), never to REQUIRED, and airlift's
# HttpsConfig has no property for it: a certificate is one more authenticator,
# and the first that succeeds names the user.
kill "$SRV"; serve optional
cp "$D/trino.pem" "$D/etc/tls/client.pem"
DN="CN=worker-7, OU=worker, O=qd"
for spec in "jwt|no|HTTP 401|worker-7|HTTP 401|job-1|worker-7" \
  "certificate,jwt|yes|HTTP 401|worker-7|$DN|$DN|curl exit 56" \
  "certificate|yes|HTTP 401|HTTP 401|$DN|$DN|curl exit 56"; do
  IFS='|' read -r types e0 e1 e2 e3 e4 e5 <<<"$spec"
  config "$types"
  access system-access-control.http-client.key-store-path=/etc/trino/tls/client.pem
  start || { ko "does not start with authentication.type=$types: $(why)"; continue; }
  clients
  echo "   http-server.authentication.type=$types, a trust store with the CA:"
  expect "  its handshake asks for a client certificate" "$e0" "$(asks)"
  expect "  no certificate, no token" "$e1" "$(who -)"
  expect "  no certificate, a token for worker-7" "$e2" "$(who - "$(jwt worker-7)")"
  expect "  worker-7's certificate, no token" "$e3" "$(who worker)"
  expect "  worker-7's certificate and a token for job-1" "$e4" "$(who worker "$(jwt job-1)")"
  expect "  another CA's certificate, a token for worker-7" "$e5" "$(who stranger "$(jwt worker-7)")"
done
note "no combination demands both: with jwt any certificate (or none) passes with a token; with certificate a token is not needed"

echo "== Trino's server certificate, renewed while it runs (ssl-context.refresh-time ${REFRESH}s)"
expect "it serves" trino-1 "$(served)"
cp "$D/trino2.pem" "$D/etc/tls/server.pem"
t0=$(date +%s)
for _ in $(seq 15); do sleep 2; [ "$(served)" = trino-1-renewed ] && break; done
expect "$(($(date +%s) - t0))s after the PEM is replaced, with no restart, it serves" trino-1-renewed "$(served)"

[ "$FAILED" = 0 ] && echo "All checks passed." || { echo "Some checks failed."; exit 1; }
