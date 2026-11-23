#!/bin/bash
# Verification of a Trino worker reaching the lake through a proxy on its
# loopback (decision 0066, point 10). A Trino worker's JVM reads its
# keystore once and nothing restarts a worker when its agent renews
# machine.pem, so by itself it would go on presenting the certificate it
# started with. The proxy of the DuckDB workers
# (infra/worker/lake/entrypoint.sh) presents the machine's certificate for
# it and takes the renewed one by itself. It shows, with a coordinator and
# one worker of Trino 484 and the repository's lake catalog
# (infra/trino/etc/catalog/lake.properties, sent by the coordinator with
# each task, `catalog.management=dynamic`):
#   - `${ENV:TRINO_LAKE_S3_URL}` in the catalog is read on each node from
#     its own environment: the coordinator reaches the gate by itself
#     (its JVM's keystore, infra/trino/entrypoint.sh), the worker its own
#     proxy, under its own name, trusting the installation's CA;
#   - the worker, whose JVM has no keystore here, writes and reads a table
#     of synthetic rows through the proxy, and with the proxy stopped it
#     cannot;
#   - the proxy serves and presents a renewed machine.pem with neither it
#     nor the worker restarted, and the worker goes on.
#
# The lake's side is tools/verify/trino_lake_gate.sh's: a Traefik 3.6 in
# front of RustFS that requires a client certificate of the CA (what
# forwardAuth asks is the same for any client; rustfs_lake_gate_api.sh).
# Its own Compose project (qd-verify-trino-wproxy: RustFS, gate), containers
# qd-verify-trino-wproxy-coord, -worker and -proxy, ports 127.0.0.1:59070
# (RustFS, unused), 59071 (the gate), 59072 (the coordinator), 59073 (the
# proxy), 59074 (the worker). Nothing of the dev stack is touched; each
# node has 1.5 GB. RustFS's root credentials are random, never printed, and
# used only in what is thrown away at the end. Synthetic rows only (Trino's
# tpch connector). Run from the repository root:
#
#   bash tools/verify/trino_worker_lake_proxy.sh
#
# Needs docker with Compose v2, curl 7.75 or later and openssl 3.
set -u
export LC_ALL=C
P=qd-verify-trino-wproxy
C=$P-coord
W=$P-worker
PX=$P-proxy
DIRECT=59070
GATE=59071
COORD=59072
PROXY=59073
WORKER=59074
NAME=trino-w1 # the worker's machine name, its loopback's inside its container
PROXY_IMAGE=traefik:v3.6
TRINO_IMAGE=${TRINO_IMAGE:-trinodb/trino:484}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
D=$(mktemp -d)
chmod 755 "$D"
FAILED=0
mkdir -p "$D/infra/worker" "$D/dyn" "$D/coord/catalog" "$D/worker"
cp -r "$ROOT/infra/rustfs" "$D/infra/rustfs"
cp -r "$ROOT/infra/worker/lake" "$D/infra/worker/lake"
chmod -R a+rX "$D/infra"
mkdir -m 700 "$D/machine" "$D/cnode" "$D/wnode" "$D/gate"
KEY=qd$(openssl rand -hex 8)
SECRET=$(openssl rand -hex 16)
SHARED=$(openssl rand -hex 16)
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
  docker rm -f "$C" "$W" "$PX" >/dev/null 2>&1
  compose down -v --remove-orphans >/dev/null 2>&1
  asroot 'rm -rf /d/machine/*' >/dev/null 2>&1
  rm -rf "$D"
}
trap cleanup EXIT

ok() { printf '[OK  ] %s\n' "$*"; }
ko() { printf '[FAIL] %s\n' "$*"; FAILED=1; }
expect() { if [ "$2" = "$3" ]; then ok "$1: $3"; else ko "$1: expected '$2', got '$3'"; fi; }

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
  -subj "/O=qd/CN=qd verify ca" -addext "basicConstraints=critical,CA:TRUE" \
  -keyout "$D/ca.key" -out "$D/ca.crt" 2>/dev/null
# leaf NAME SUBJECT DNS: NAME.pem, the certificate then the PKCS#8 key.
leaf() {
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj "$2" -keyout "$D/$1.key" -out "$D/$1.csr" 2>/dev/null
  printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=clientAuth,serverAuth\nsubjectAltName=DNS:%s\n' "$3" >"$D/ext"
  openssl x509 -req -in "$D/$1.csr" -CA "$D/ca.crt" -CAkey "$D/ca.key" -CAcreateserial -extfile "$D/ext" -days 1 -out "$D/$1.crt" 2>/dev/null
  openssl pkey -in "$D/$1.key" -out "$D/$1.p8"
  cat "$D/$1.crt" "$D/$1.p8" >"$D/$1.pem"
}
leaf lake "/O=qd/OU=lake/CN=localhost" localhost
leaf coord "/O=qd/OU=trino-coordinator/CN=trino-1" trino-1
leaf worker "/O=qd/OU=trino-worker/CN=$NAME" "$NAME"
leaf worker2 "/O=qd/OU=trino-worker/CN=$NAME" "$NAME"
asroot "cp /d/ca.crt /d/machine/ca.crt && cp /d/lake.pem /d/machine/machine.pem &&
  chown -R 10001:10001 /d/machine && chmod 644 /d/machine/ca.crt && chmod 600 /d/machine/machine.pem"
cp "$D/ca.crt" "$D/lake.pem" "$D/gate/"
# given DIR PEM: a node agent's directory, written aside and renamed.
given() {
  cp "$D/ca.crt" "$D/$1/ca.crt"
  install -m 600 "$D/$2.pem" "$D/$1/.machine.pem.new" && mv "$D/$1/.machine.pem.new" "$D/$1/machine.pem"
}
given cnode coord
given wnode worker

echo "== The lake: RustFS behind a gate that requires a client certificate"
cat >"$D/gate.yml" <<EOF
services:
  gate:
    image: $PROXY_IMAGE
    user: \${QD_UID}
    ports: ["127.0.0.1:$GATE:8443"]
    volumes: ["./dyn:/dyn:ro", "./gate:/gate:ro"]
    command: [--providers.file.directory=/dyn, --entrypoints.lake.address=:8443, --log.level=ERROR]
EOF
cat >"$D/dyn/gate.yml" <<'EOF'
http:
  routers:
    lake: {entryPoints: [lake], rule: "PathPrefix(`/`)", tls: {}, service: rustfs}
  services:
    rustfs:
      loadBalancer:
        serversTransport: rustfs
        servers: [{url: "https://rustfs:9000"}]
  serversTransports:
    rustfs: {serverName: localhost, rootCAs: [/gate/ca.crt]}
tls:
  options:
    default:
      minVersion: VersionTLS12
      clientAuth: {caFiles: [/gate/ca.crt], clientAuthType: RequireAndVerifyClientCert}
  stores:
    default:
      defaultCertificate: {certFile: /gate/lake.pem, keyFile: /gate/lake.pem}
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
for _ in $(seq 40); do [ "$(s3 coord GET /)" = 200 ] && break; sleep 1; done
sleep 2
expect "a warehouse's bucket, enabled for tables" "200 200" \
  "$(s3 coord PUT /qd-verify-lake) $(s3 coord PUT /iceberg/v1/buckets/qd-verify-lake --data '')"
expect "without a certificate the gate refuses at the handshake" 000 "$(s3 - GET /qd-verify-lake)"

echo "== A coordinator and a worker, the worker's lake its proxy"
cp "$ROOT/infra/trino/etc/catalog/lake.properties" "$D/coord/catalog/"
printf 'connector.name=tpch\n' >"$D/coord/catalog/tpch.properties"
cat >"$D/coord/config.properties" <<EOF
coordinator=true
node-scheduler.include-coordinator=false
http-server.http.port=$COORD
discovery.uri=http://localhost:$COORD
internal-communication.shared-secret=$SHARED
catalog.management=dynamic
catalog.store=file
query.max-memory=512MB
query.max-memory-per-node=512MB
EOF
cat >"$D/worker/config.properties" <<EOF
coordinator=false
http-server.http.port=$WORKER
discovery.uri=http://localhost:$COORD
internal-communication.shared-secret=$SHARED
catalog.management=dynamic
query.max-memory-per-node=512MB
EOF
printf 'node.environment=verify\nnode.id=coordinator-1\nnode.data-dir=/data/trino\n' >"$D/coord/node.properties"
printf 'node.environment=verify\nnode.id=worker-1\nnode.data-dir=/data/trino\n' >"$D/worker/node.properties"
chmod -R a+rX "$D/coord" "$D/worker"
# node NAME DIR NODE-DIR LAKE-URL [DOCKER OPTION...]: a Trino node by the repository's entrypoint.
node() {
  local name=$1 dir=$2 agent=$3 url=$4
  shift 4
  docker run -d --name "$name" --network host --memory 1500m \
    -e TRINO_LAKE_S3_URL="$url" -e TRINO_LAKE_WAREHOUSE=qd-verify-lake \
    -e TRINO_LAKE_ACCESS_KEY="$KEY" -e TRINO_LAKE_SECRET_KEY="$SECRET" \
    --entrypoint /bin/bash -v "$ROOT/infra/trino/entrypoint.sh:/etc/trino/entrypoint.sh:ro" \
    -v "$D/$agent:/run/qd-node:ro" -v "$D/$dir/config.properties:/etc/trino/config.properties:ro" \
    -v "$D/$dir/node.properties:/etc/trino/node.properties:ro" "$@" "$TRINO_IMAGE" /etc/trino/entrypoint.sh >/dev/null
}
docker rm -f "$C" "$W" "$PX" >/dev/null 2>&1
# The coordinator by itself: its JVM's keystore, the static catalogs its own.
node "$C" coord cnode "https://localhost:$GATE" -v "$ROOT/infra/trino/PemKeystore.java:/etc/trino/PemKeystore.java:ro" \
  -v "$D/coord/catalog:/etc/trino/static-catalog:ro" -v "$ROOT/infra/trino/etc/coordinator/catalog-store.properties:/etc/trino/catalog-store.properties:ro"
# The worker: no keystore, its own name its loopback, its lake the proxy there.
node "$W" worker wnode "https://$NAME:$PROXY" --add-host "$NAME:127.0.0.1"
proxy() {
  docker rm -f "$PX" >/dev/null 2>&1
  docker run -d --name "$PX" --init --network host --user "$(id -u):$(id -g)" --tmpfs "/run/qd-lake:uid=$(id -u),mode=0700" \
    -v "$D/infra/worker/lake/entrypoint.sh:/etc/qd/lake/entrypoint.sh:ro" -v "$D/wnode:/run/qd-node:ro" \
    -e QD_LAKE_GATE="localhost:$GATE" -e QD_LAKE_LISTEN="127.0.0.1:$PROXY" -e QD_LAKE_CHECK_EVERY=2 \
    --entrypoint /etc/qd/lake/entrypoint.sh "$PROXY_IMAGE" >/dev/null
  for _ in $(seq 30); do (exec 3<>"/dev/tcp/127.0.0.1/$PROXY") 2>/dev/null && { sleep 2; return 0; }; sleep 1; done
}
proxy
for n in "$C" "$W"; do
  for _ in $(seq 120); do docker logs "$n" 2>&1 | grep -q "SERVER STARTED" && break; sleep 2; done
  docker logs "$n" 2>&1 | grep -q "SERVER STARTED" || { echo "$n did not start"; docker logs "$n" 2>&1 | tail -5 | cut -c1-200; exit 1; }
done
# q SQL: its rows, or the first line of the error.
q() { docker exec "$C" trino --server "http://localhost:$COORD" --output-format TSV --execute "$1" 2>&1 | grep -v -e '^WARNING' -e '^Picked up' | head -3 | tr '\n' ' ' | sed 's/ $//' | cut -c1-200; }
for _ in $(seq 30); do [ "$(q "SELECT count(*) FROM system.runtime.nodes WHERE state = 'active'")" = 2 ] && break; sleep 2; done
expect "two active nodes; the coordinator runs no task" 2 "$(q "SELECT count(*) FROM system.runtime.nodes WHERE state = 'active'")"
expect "the worker's JVM has no keystore" 0 "$(docker exec "$W" sh -c 'ls /data/trino/machine.p12 2>/dev/null | wc -l')"
expect "the coordinator, by itself at the gate: a schema" "CREATE SCHEMA" "$(q "CREATE SCHEMA lake.w")"
expect "the worker writes a table of synthetic rows, through its proxy" "CREATE TABLE: 15000 rows" \
  "$(q "CREATE TABLE lake.w.small AS SELECT orderkey, totalprice FROM tpch.tiny.orders")"
expect "and reads it back" "15000 15000" "$(q "SELECT count(*), count(DISTINCT orderkey) FROM lake.w.small" | tr '\t' ' ')"

echo "== The worker's certificate renewed"
started=$(docker inspect -f '{{.State.StartedAt}}' "$W" "$PX" | tr '\n' ' ')
served() { openssl s_client -connect "127.0.0.1:$PROXY" -servername "$NAME" </dev/null 2>/dev/null | openssl x509 -noout -serial 2>/dev/null; }
expect "the proxy serves the worker's certificate" "$(openssl x509 -in "$D/worker.crt" -noout -serial)" "$(served)"
given wnode worker2
want=$(openssl x509 -in "$D/worker2.crt" -noout -serial)
for _ in $(seq 20); do [ "$(served)" = "$want" ] && break; sleep 1; done
expect "renewed in its file, the proxy serves the new one" "$want" "$(served)"
expect "the worker writes again" "CREATE TABLE: 15000 rows" \
  "$(q "CREATE TABLE lake.w.after AS SELECT orderkey, totalprice FROM tpch.tiny.orders")"
expect "and reads both tables" "30000" "$(q "SELECT (SELECT count(*) FROM lake.w.small) + (SELECT count(*) FROM lake.w.after)")"
expect "neither the worker nor its proxy was restarted" "$started" "$(docker inspect -f '{{.State.StartedAt}}' "$W" "$PX" | tr '\n' ' ')"

echo "== Without its proxy"
docker rm -f "$PX" >/dev/null 2>&1
without=$(q "CREATE TABLE lake.w.none AS SELECT orderkey FROM tpch.tiny.orders")
case "$without" in CREATE\ TABLE*) ko "the worker wrote without its proxy: $without" ;; *) ok "the worker cannot write: $(echo "$without" | cut -c1-110)" ;; esac
proxy
expect "its proxy back, it writes" "CREATE TABLE: 15000 rows" \
  "$(q "CREATE TABLE lake.w.back AS SELECT orderkey, totalprice FROM tpch.tiny.orders")"

[ $FAILED = 0 ] && echo "ALL OK" || echo "SOME FAILED"
exit $FAILED
