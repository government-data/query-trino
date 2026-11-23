#!/bin/bash
# Verification of Trino reaching a lake that requires a client certificate
# (decision 0066, point 10), a prototype: the lake's side of
# tools/verify/rustfs_lake_gate.sh without its validator (a Traefik 3.6 in
# front of RustFS, in HTTP mode, that requires a client certificate of the
# CA; what forwardAuth asks is the same for any client), and one Trino 484
# node with the repository's lake catalog (Iceberg over RustFS's REST
# catalog, SigV4, the native S3 file system). It shows:
#   - Trino presents a client certificate by itself once the JVM has a
#     keystore (javax.net.ssl.keyStore): neither the S3 file system nor the
#     REST catalog has a setting of its own, and both use the JVM's. The
#     repository's infra/trino/entrypoint.sh makes it, and the truststore,
#     from the node agent's machine.pem and ca.crt (PemKeystore.java);
#   - Trino also through a TCP proxy on its loopback that presents its
#     machine.pem (tools/verify/rustfs_worker_proxy.sh's, beside Trino): a
#     schema, a table of synthetic rows (tpch), read back, the catalog's
#     calls and the files' both signed for the proxy's address;
#   - the cost: the gate's requests (its access log) for a small and a
#     larger table, and their time against the same RustFS reached straight;
#   - a statement running while the proxy takes a renewed certificate.
#
# Its own Compose project (qd-verify-trino-gate: RustFS, gate), containers
# qd-verify-trino-gate-trino and -proxy, ports 127.0.0.1:59060 (RustFS
# straight, for the comparison only), 59061 (the gate), 59062 (Trino), 59063
# (the proxy). Nothing of the dev stack is touched; Trino is one node with
# 2 GB. RustFS's root credentials are random, never printed, and used only
# in what is thrown away at the end (an installation never uses root).
# Synthetic rows only (Trino's tpch connector). Run from the repository root:
#
#   bash tools/verify/trino_lake_gate.sh
#
# Needs docker with Compose v2, curl 7.75 or later and openssl 3.
set -u
export LC_ALL=C
P=qd-verify-trino-gate
T=$P-trino
PX=$P-proxy
DIRECT=59060
GATE=59061
TRINO=59062
PROXY=59063
PROXY_IMAGE=traefik:v3.6
TRINO_IMAGE=${TRINO_IMAGE:-trinodb/trino:484}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
D=$(mktemp -d)
chmod 755 "$D"
FAILED=0
mkdir -p "$D/infra" "$D/dyn" "$D/pxdyn" "$D/trino/catalog"
cp -r "$ROOT/infra/rustfs" "$D/infra/rustfs"
chmod -R a+rX "$D/infra"
mkdir -m 700 "$D/machine" "$D/node" "$D/gate"
KEY=qd$(openssl rand -hex 8)
SECRET=$(openssl rand -hex 16)
IMAGE=$(sed -n 's/^ *image: \${RUSTFS_IMAGE:-\(.*\)}$/\1/p' "$ROOT/infra/rustfs/docker-compose.yml")
cat >"$D/.env" <<EOF
APP_STACK=$P
RUSTFS_ACCESS_KEY=$KEY
RUSTFS_SECRET_KEY=$SECRET
QD_MACHINE_DIR=$D/machine
RUSTFS_BIND=127.0.0.1
RUSTFS_PORT=$DIRECT
RUSTFS_MTLS=0
QD_UID=$(id -u):$(id -g)
EOF
FILES="-f infra/rustfs/docker-compose.yml -f infra/rustfs/certificate.yml -f gate.yml"
# shellcheck disable=SC2086
compose() { (cd "$D" && docker compose --project-directory . --env-file .env -p $P $FILES "$@"); }
asroot() { docker run --rm --user 0 --entrypoint sh -v "$D:/d" "$IMAGE" -c "$1"; }
cleanup() {
  docker rm -f "$T" "$PX" >/dev/null 2>&1
  compose down -v --remove-orphans >/dev/null 2>&1
  asroot 'rm -rf /d/machine/* /d/trino/*.jks /d/trino/*.p12' >/dev/null 2>&1
  rm -rf "$D"
}
trap cleanup EXIT

ok() { printf '[OK  ] %s\n' "$*"; }
ko() { printf '[FAIL] %s\n' "$*"; FAILED=1; }
expect() { if [ "$2" = "$3" ]; then ok "$1: $3"; else ko "$1: expected '$2', got '$3'"; fi; }

ca() {
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
    -subj "/O=qd/CN=qd verify $1" -addext "basicConstraints=critical,CA:TRUE" \
    -keyout "$D/$1.key" -out "$D/$1.crt" 2>/dev/null
}
# leaf NAME SUBJECT: NAME.pem, the certificate then the PKCS#8 key, for localhost.
leaf() {
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj "$2" -keyout "$D/$1.key" -out "$D/$1.csr" 2>/dev/null
  printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=clientAuth,serverAuth\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n' >"$D/ext"
  openssl x509 -req -in "$D/$1.csr" -CA "$D/ca.crt" -CAkey "$D/ca.key" -CAcreateserial -extfile "$D/ext" -days 1 -out "$D/$1.crt" 2>/dev/null
  openssl pkey -in "$D/$1.key" -out "$D/$1.p8"
  cat "$D/$1.crt" "$D/$1.p8" >"$D/$1.pem"
}
ca ca
leaf lake "/O=qd/OU=lake/CN=localhost"
leaf trino "/O=qd/OU=trino-coordinator/CN=trino-1"
leaf trino2 "/O=qd/OU=trino-coordinator/CN=trino-1"
asroot "cp /d/ca.crt /d/machine/ca.crt && cp /d/lake.pem /d/machine/machine.pem &&
  chown -R 10001:10001 /d/machine && chmod 644 /d/machine/ca.crt && chmod 600 /d/machine/machine.pem"
cp "$D/ca.crt" "$D/lake.pem" "$D/gate/"

echo "== The lake: RustFS behind a gate that requires a client certificate"
# RustFS stays published on the loopback here, for the comparison only.
cat >"$D/gate.yml" <<EOF
services:
  gate:
    image: $PROXY_IMAGE
    user: \${QD_UID}
    ports: ["127.0.0.1:$GATE:8443"]
    volumes: ["./dyn:/dyn:ro", "./gate:/gate:ro"]
    command: [--providers.file.directory=/dyn, --entrypoints.lake.address=:8443,
              --log.level=ERROR, --accesslog=true]
EOF
cat >"$D/dyn/gate.yml" <<'EOF'
http:
  routers:
    lake:
      entryPoints: [lake]
      rule: "PathPrefix(`/`)"
      tls: {}
      service: rustfs
  services:
    rustfs:
      loadBalancer:
        serversTransport: rustfs
        servers:
          - url: https://rustfs:9000
  serversTransports:
    rustfs:
      serverName: localhost
      rootCAs: [/gate/ca.crt]
tls:
  options:
    default:
      minVersion: VersionTLS12
      clientAuth:
        caFiles: [/gate/ca.crt]
        clientAuthType: RequireAndVerifyClientCert
  stores:
    default:
      defaultCertificate:
        certFile: /gate/lake.pem
        keyFile: /gate/lake.pem
EOF
up=$(compose up -d --wait --wait-timeout 120 rustfs 2>&1) || { echo "RustFS did not become healthy: $up" | tail -5; exit 1; }
compose up -d gate >/dev/null 2>&1
s3() { # CERT|- METHOD PATH [CURL OPTION...]: a signed request to the gate
  local cert=$1 method=$2 path=$3
  shift 3
  [ "$cert" = - ] || set -- --cert "$D/$cert.pem" "$@"
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 --cacert "$D/ca.crt" -X "$method" \
    --aws-sigv4 "aws:amz:us-east-1:s3" --user "$KEY:$SECRET" "$@" "https://localhost:$GATE$path"
}
for _ in $(seq 40); do [ "$(s3 trino GET /)" = 200 ] && break; sleep 1; done
sleep 2
expect "a warehouse's bucket, enabled for tables, with Trino's certificate" "200 200" \
  "$(s3 trino PUT /qd-verify-lake) $(s3 trino PUT /iceberg/v1/buckets/qd-verify-lake --data '')"
expect "without a certificate the gate refuses at the handshake" 000 "$(s3 - GET /qd-verify-lake)"
requests() { docker logs "$P-gate-1" 2>/dev/null | grep -c ' "[A-Z]* /'; }

echo "== One Trino node: its lake three ways"
# The node agent's files: the repository's entrypoint makes the JVM's truststore and keystore of them.
install -m 600 "$D/trino.pem" "$D/node/machine.pem" && cp "$D/ca.crt" "$D/node/ca.crt"
cat >"$D/trino/config.properties" <<EOF
coordinator=true
node-scheduler.include-coordinator=true
http-server.http.port=$TRINO
discovery.uri=http://localhost:$TRINO
query.max-memory=512MB
query.max-memory-per-node=512MB
EOF
# catalog NAME ENDPOINT: the repository's lake catalog, at ENDPOINT.
catalog() {
  cat >"$D/trino/catalog/$1.properties" <<EOF
connector.name=iceberg
iceberg.catalog.type=rest
iceberg.rest-catalog.uri=$2/iceberg
iceberg.rest-catalog.warehouse=qd-verify-lake
iceberg.rest-catalog.security=SIGV4
iceberg.rest-catalog.signing-name=s3
fs.s3.enabled=true
s3.endpoint=$2
s3.region=us-east-1
s3.path-style-access=true
s3.aws-access-key=\${ENV:LAKE_KEY}
s3.aws-secret-key=\${ENV:LAKE_SECRET}
EOF
}
catalog straight "https://localhost:$DIRECT" # RustFS itself, no certificate asked: the comparison
catalog native "https://localhost:$GATE"     # the gate, Trino presenting what the JVM's keystore holds
catalog proxied "http://127.0.0.1:$PROXY"    # the gate, through the proxy on Trino's loopback
printf 'connector.name=tpch\n' >"$D/trino/catalog/tpch.properties"
cat >"$D/pxdyn/lake.yml" <<EOF
tcp:
  routers:
    gate: {entryPoints: [gate], rule: "HostSNI(\`*\`)", service: gate}
  services:
    gate:
      loadBalancer:
        serversTransport: node
        servers: [{address: "127.0.0.1:$GATE", tls: true}]
  serversTransports:
    node:
      tls:
        serverName: localhost
        rootCAs: [/node/ca.crt]
        certificates:
          - {certFile: /node/machine.pem, keyFile: /node/machine.pem}
EOF
docker rm -f "$PX" "$T" >/dev/null 2>&1
docker run -d --name "$PX" --network host --user "$(id -u):$(id -g)" -v "$D/pxdyn:/dyn:ro" -v "$D/node:/node:ro" \
  "$PROXY_IMAGE" --providers.file.directory=/dyn --providers.file.watch=true \
  --entrypoints.gate.address=127.0.0.1:$PROXY --log.level=ERROR >/dev/null
docker run -d --name "$T" --network host --memory 2g -e LAKE_KEY="$KEY" -e LAKE_SECRET="$SECRET" \
  --entrypoint /bin/bash -v "$ROOT/infra/trino/entrypoint.sh:/etc/trino/entrypoint.sh:ro" \
  -v "$ROOT/infra/trino/PemKeystore.java:/etc/trino/PemKeystore.java:ro" -v "$D/node:/run/qd-node:ro" \
  -v "$D/trino/config.properties:/etc/trino/config.properties:ro" -v "$D/trino/catalog:/etc/trino/catalog:ro" \
  "$TRINO_IMAGE" /etc/trino/entrypoint.sh >/dev/null
for _ in $(seq 120); do docker logs "$T" 2>&1 | grep -q "SERVER STARTED" && break; sleep 2; done
docker logs "$T" 2>&1 | grep -q "SERVER STARTED" || { echo "Trino did not start"; docker logs "$T" 2>&1 | tail -5 | cut -c1-200; exit 1; }
# q SQL: its rows, or the first line of the error.
q() { docker exec "$T" trino --server "http://localhost:$TRINO" --output-format TSV --execute "$1" 2>&1 | grep -v -e '^WARNING' -e '^Picked up' | head -3 | tr '\n' ' ' | sed 's/ $//' | cut -c1-200; }
timed() { local t0; t0=$(date +%s.%N); OUT=$(q "$1"); SECS=$(python3 -c 'import sys,time;print(f"{time.time()-float(sys.argv[1]):.1f}")' "$t0"); }

expect "the keystore the entrypoint made is Trino's alone, and neither file's content is in its log" "600 0" \
  "$(docker exec "$T" stat -c %a /data/trino/machine.p12) $(docker logs "$T" 2>&1 | grep -c -e 'BEGIN ' -e 'PRIVATE KEY')"
expect "straight to RustFS (no certificate asked): a schema" "CREATE SCHEMA" "$(q "CREATE SCHEMA straight.plain")"
n0=$(requests)
expect "by itself, the JVM's keystore its only setting: a schema (the catalog's client)" "CREATE SCHEMA" "$(q "CREATE SCHEMA native.own")"
expect "by itself: a table (the S3 file system's client)" "CREATE TABLE: 15000 rows" \
  "$(q "CREATE TABLE native.own.small AS SELECT orderkey, totalprice FROM tpch.tiny.orders")"
expect "by itself: read back" 15000 "$(q "SELECT count(*) FROM native.own.small")"
n1=$(requests)
if [ $((n1 - n0)) -gt 0 ]; then ok "by itself: its requests went through the gate: $((n1 - n0))"; else ko "nothing went through the gate"; fi
r0=$(requests)
expect "through the proxy on its loopback: a schema" "CREATE SCHEMA" "$(q "CREATE SCHEMA proxied.gated")"
timed "CREATE TABLE proxied.gated.small AS SELECT orderkey, totalprice FROM tpch.tiny.orders"
expect "a small table of synthetic rows written" "CREATE TABLE: 15000 rows" "$OUT"
expect "and read back" 15000 "$(q "SELECT count(*) FROM proxied.gated.small")"
r1=$(requests)
echo "[INFO] the gate's requests for the schema, the small table and its read: $((r1 - r0)) (written in ${SECS}s)"

echo "== Cost: 1.5 million synthetic rows, through the gate and straight"
timed "CREATE TABLE proxied.gated.large AS SELECT * FROM tpch.sf1.orders"
gated_out=$OUT gated_write=$SECS
timed "SELECT count(*), count(DISTINCT custkey) FROM proxied.gated.large"
gated_read=$SECS gated_rows=$OUT
r2=$(requests)
expect "written through the gate" "CREATE TABLE: 1500000 rows" "$gated_out"
timed "CREATE TABLE straight.plain.large AS SELECT * FROM tpch.sf1.orders"
straight_out=$OUT straight_write=$SECS
timed "SELECT count(*), count(DISTINCT custkey) FROM straight.plain.large"
straight_read=$SECS
expect "written straight" "CREATE TABLE: 1500000 rows" "$straight_out"
expect "both read the same" "$OUT" "$gated_rows"
timed "CREATE TABLE native.own.large AS SELECT * FROM tpch.sf1.orders"
native_out=$OUT native_write=$SECS
timed "SELECT count(*), count(DISTINCT custkey) FROM native.own.large"
expect "written by itself through the gate" "CREATE TABLE: 1500000 rows" "$native_out"
echo "[INFO] by itself through the gate: write ${native_write}s read ${SECS}s"
echo "[INFO] through proxy and gate: write ${gated_write}s read ${gated_read}s, $((r2 - r1)) requests at the gate"
echo "[INFO] straight to RustFS:     write ${straight_write}s read ${straight_read}s"

echo "== The proxy takes a renewed certificate under a running statement"
(q "CREATE TABLE proxied.gated.during AS SELECT * FROM tpch.sf1.orders" >"$D/during" 2>&1) &
sleep 2
install -m 600 "$D/trino2.pem" "$D/node/.machine.pem.new" && mv "$D/node/.machine.pem.new" "$D/node/machine.pem"
touch "$D/pxdyn/lake.yml"
wait
expect "the statement that was running ends well" "CREATE TABLE: 1500000 rows" "$(cat "$D/during")"
expect "and the next one, with the renewed certificate" 1500000 "$(q "SELECT count(*) FROM proxied.gated.during")"

[ $FAILED = 0 ] && echo "ALL OK" || echo "SOME FAILED"
exit $FAILED
