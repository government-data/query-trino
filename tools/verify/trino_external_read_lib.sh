# shellcheck shell=bash
# The helpers of tools/verify/trino_external_read.sh, which sources this file
# after it set its names and its temporary directory: the throwaway keys, the
# rules and the user mapping proposed, a throwaway Trino and the proxy in
# front of it, the clients and the data. Not run by itself.

# --- Keys: the provider's (ES256), the proxy's CA and certificate ------------
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
# jwt SUB TTL: an ES256 access token as the provider signs one for `trino`.
jwt() {
  local now h c rs s
  now=$(date +%s)
  h=$(printf '{"alg":"ES256","kid":"verify","typ":"at+jwt"}' | b64url)
  c=$(printf '{"iss":"%s","aud":"trino","sub":"%s","iat":%s,"exp":%s}' "$ISS" "$1" "$now" $((now + $2)) | b64url)
  printf '%s.%s' "$h" "$c" >"$D/input"
  openssl dgst -sha256 -sign "$D/idp.pem" -out "$D/sig.der" "$D/input"
  rs=$(openssl asn1parse -inform DER -in "$D/sig.der" | sed -n 's/.*INTEGER *:\([0-9A-F]*\).*/\1/p' | tr '\n' ' ')
  # shellcheck disable=SC2086
  s=$(python3 -I -c 'import sys; sys.stdout.buffer.write(b"".join(bytes.fromhex(v.rjust(64, "0")) for v in sys.argv[1:]))' $rs | b64url)
  printf '%s.%s.%s' "$h" "$c" "$s"
}
make_keys() {
  mkdir -p "$D/etc/catalog" "$D/proxy" "$D/catalogs"
  openssl ecparam -name prime256v1 -genkey -noout -out "$D/idp.pem"
  openssl pkey -in "$D/idp.pem" -pubout -out "$D/etc/jwt.pem" 2>/dev/null
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
    -subj "/CN=qd verify CA" -addext "basicConstraints=critical,CA:TRUE" \
    -keyout "$D/ca.key" -out "$D/ca.crt" 2>/dev/null
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj "/CN=$HOST" \
    -keyout "$D/proxy/proxy.key" -out "$D/proxy.csr" 2>/dev/null
  printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$HOST" >"$D/ext"
  openssl x509 -req -in "$D/proxy.csr" -CA "$D/ca.crt" -CAkey "$D/ca.key" -CAcreateserial \
    -days 1 -extfile "$D/ext" -out "$D/proxy/proxy.crt" 2>/dev/null
  cp "$D/ca.crt" "$D/etc/ca.crt"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
    -subj /CN=localhost -keyout "$D/tls.key" -out "$D/tls.crt" 2>/dev/null
  cat "$D/tls.crt" "$D/tls.key" >"$D/etc/https.pem"
}

# --- The proposal: rules and user mapping for external readers ---------------
EXT='ext-[a-z0-9][a-z0-9-]*'
# The fixture (what quality::trino_rules generates) with the external
# readers' rules before its last catalog rule ({"allow": "none"}).
write_rules() {
  jq --arg ext "$EXT" '
    .catalogs = (.catalogs[:-1] + [{ user: $ext, catalog: "lake", allow: "read-only" }] + .catalogs[-1:])
    | .tables += [{ user: "ext-demo", catalog: "lake", schema: "orders_silver", privileges: ["SELECT"] }]
    | .queries += [{ user: $ext, allow: ["execute"] }]' \
    "$ROOT/tools/verify/fixtures/trino_rules.json" >"$D/etc/rules.json"
}
# The infra's mapping with an external reader's subject kept as its user,
# and any other subject starting with ext- or ext_ refused, before the
# catch-all.
write_mapping() {
  jq '.rules = (.rules[:-1]
    + [{ pattern: "(ext-[a-z0-9][a-z0-9-]{0,59})", user: "$1" }, { pattern: "ext[-_].*", allow: false }]
    + .rules[-1:])' "$ROOT/infra/trino/etc/coordinator/user-mapping.json" >"$D/etc/user-mapping.json"
}

# --- A throwaway Trino, as infra/trino's coordinator --------------------------
write_trino_config() {
  cat >"$D/etc/config.properties" <<EOF
coordinator=true
node-scheduler.include-coordinator=true
http-server.http.port=8080
discovery.uri=http://localhost:8080
query.max-memory=1GB
query.max-memory-per-node=1GB
catalog.management=dynamic
catalog.store=file
http-server.https.enabled=true
http-server.https.port=8443
http-server.https.keystore.path=/etc/trino/https.pem
internal-communication.shared-secret=verify-only
http-server.authentication.type=oauth2,jwt
http-server.authentication.jwt.key-file=/etc/trino/jwt.pem
http-server.authentication.jwt.required-issuer=$ISS
http-server.authentication.jwt.required-audience=trino
http-server.authentication.jwt.user-mapping.file=/etc/trino/user-mapping.json
http-server.authentication.allow-insecure-over-http=false
http-server.process-forwarded=true
http-server.authentication.oauth2.issuer=$ISS
http-server.authentication.oauth2.oidc.discovery=false
http-server.authentication.oauth2.auth-url=$ISS/oauth/authorize
http-server.authentication.oauth2.token-url=$ISS/oauth/token
http-server.authentication.oauth2.jwks-url=$ISS/oauth/jwks
http-server.authentication.oauth2.client-id=trino
http-server.authentication.oauth2.client-secret=verify-only
http-server.authentication.oauth2.scopes=openid,email,profile
http-server.authentication.oauth2.principal-field=email
EOF
  printf 'node.environment=verify\nnode.id=verify\nnode.data-dir=/tmp/trino\n' >"$D/etc/node.properties"
  printf -- '-server\n-Xmx2G\n-XX:+ExitOnOutOfMemoryError\n-Djdk.attach.allowAttachSelf=true\n' >"$D/etc/jvm.config"
  printf 'access-control.name=file\nsecurity.config-file=/etc/trino/rules.json\n' >"$D/etc/access-control.properties"
  echo catalog.config-dir=/data/catalogs >"$D/etc/catalog-store.properties"
  printf 'connector.name=memory\nmemory.max-data-per-node=1GB\n' >"$D/catalogs/lake.properties"
  echo connector.name=tpch >"$D/catalogs/src_demo.properties"
}
start_trino() {
  chmod -R a+rX "$D/etc" "$D/catalogs"
  docker run -d --name "$COORD" --network "$NET" --memory 3g \
    -v "$D/etc:/etc/trino:ro" -v "$D/catalogs:/data/catalogs" "$IMAGE" >/dev/null ||
    { echo "could not start $IMAGE"; exit 1; }
}

# --- The proxy, as infra/traefik's websecure entry point ----------------------
write_proxy_config() {
  cat >"$D/proxy/traefik.yml" <<'EOF'
global: { checkNewVersion: false, sendAnonymousUsage: false }
entryPoints:
  websecure:
    address: ":443"
    transport:
      respondingTimeouts: { readTimeout: 120s, writeTimeout: 0s, idleTimeout: 90s }
providers:
  file: { filename: /etc/traefik/dynamic.yml }
log: { level: ERROR }
accessLog: {}
EOF
  cat >"$D/proxy/dynamic.yml" <<EOF
http:
  routers:
    trino:
      # infra/traefik/dynamic/apps-trino.yml's trino-ui, with /v1/ added.
      rule: "Host(\`$HOST\`) && (PathPrefix(\`/v1/\`) || Path(\`/ui\`) || PathPrefix(\`/ui/\`) || PathPrefix(\`/oauth2/\`))"
      entryPoints: [websecure]
      tls: {}
      service: trino
  services:
    trino:
      loadBalancer:
        servers:
          - url: "http://$COORD:8080"
tls:
  stores:
    default:
      defaultCertificate: { certFile: /etc/traefik/proxy.crt, keyFile: /etc/traefik/proxy.key }
EOF
}
start_proxy() {
  docker run -d --name "$PROXY" --network "$NET" --network-alias "$HOST" \
    -v "$D/proxy:/etc/traefik:ro" "$PROXY_IMAGE" >/dev/null ||
    { echo "could not start $PROXY_IMAGE"; exit 1; }
}
wait_ready() {
  for _ in $(seq 120); do
    docker exec "$COORD" curl -s http://localhost:8080/v1/info 2>/dev/null | grep -q '"starting":false' && return 0
    [ "$(docker inspect -f '{{.State.Running}}' "$COORD")" = true ] || break
    sleep 2
  done
  echo "Trino did not start"; docker logs --tail 30 "$COORD"; exit 1
}

# --- Clients, all inside the coordinator's container, through the proxy ------
# raw TOKEN SQL [HEADER]: the first answer of a statement: code, headers, body.
raw() {
  docker exec -e T="$1" -e Q="$2" -e H="${3:-X-Verify: 1}" "$COORD" bash -c \
    'curl -s --cacert /etc/trino/ca.crt -D /tmp/h -o /tmp/r -w "%{http_code}\n" ${T:+-H "Authorization: Bearer $T"} -H "$H" --data-binary "$Q" '"$BASE"'/v1/statement; cat /tmp/h; echo; cat /tmp/r'
}
# pages TOKEN SQL [HEADER]: every answer of a statement, one JSON per line.
pages() {
  docker exec -e T="$1" -e Q="$2" -e H="${3:-X-Verify: 1}" "$COORD" bash -c '
    c="curl -s --cacert /etc/trino/ca.crt"
    code=$($c -o /tmp/r -w "%{http_code}" -H "Authorization: Bearer $T" -H "$H" --data-binary "$Q" '"$BASE"'/v1/statement)
    [ "$code" = 200 ] || { echo "{\"error\":{\"message\":\"HTTP $code\"}}"; exit 0; }
    r=$(</tmp/r)
    while :; do
      printf "%s\n" "$r"
      [[ $r =~ \"nextUri\":\"([^\"]+)\" ]] || break
      r=$($c -H "Authorization: Bearer $T" "${BASH_REMATCH[1]}")
    done'
}
# tq TOKEN SQL [HEADER]: the rows as TSV, or "ERROR: …".
tq() {
  pages "$@" | jq -rR '(fromjson? // {"error": {"message": .}}) |
    (.data // [] | .[] | map(tostring) | join("\t")), (.error.message // empty | "ERROR: " + .)'
}
# get TOKEN PATH: a GET through the proxy.
get() {
  docker exec -e T="$1" "$COORD" bash -c \
    'curl -s --cacert /etc/trino/ca.crt ${T:+-H "Authorization: Bearer $T"} '"$BASE$2"
}
# cli TOKEN ARGS...: the Trino CLI against the proxy, verifying its CA.
cli() {
  local t=$1; shift
  docker exec -e T="$t" "$COORD" trino --server "$BASE" --truststore-path /etc/trino/ca.crt \
    --access-token "$t" "$@" 2>&1
}

TENANT=00000000-0000-0000-0000-000000000001
JOB=7f0c2a52-1c1e-4c43-9a55-0d2f1e0b6a10

setup_data() {
  echo "== The API's client (qd-api) sets up the stand-ins"
  local s
  for s in "CREATE SCHEMA lake.orders_silver" "CREATE SCHEMA lake.loans_silver"; do
    expect "qd-api: $s" "" "$(tq "$API" "$s")"
  done
  expect "qd-api: synthetic rows" 3 "$(tq "$API" "CREATE TABLE lake.orders_silver.t AS SELECT * FROM (VALUES (1, 'a'), (2, 'b'), (3, 'c')) v(id, code)")"
  expect "qd-api: another schema's table" 1 "$(tq "$API" "CREATE TABLE lake.loans_silver.t AS SELECT 1 AS id")"
  expect "qd-api: $LONG_ROWS generated rows in the lake" "$LONG_ROWS" \
    "$(tq "$API" "CREATE TABLE lake.orders_silver.lineitem AS SELECT * FROM src_demo.sf1.lineitem LIMIT $LONG_ROWS")"
}
