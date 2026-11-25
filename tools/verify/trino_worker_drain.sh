#!/usr/bin/env bash
# T16 of core decision 0090 and V3 of quality-sdk decision 0011, against
# this module's worker files and engine-trino's coordinator files: a
# coordinator that schedules no work on itself and two workers, Trino 484
# by digest, HTTPS between the nodes with a test CA, RustFS 1.0.5.
#   - both workers join the coordinator (system.runtime.nodes);
#   - a worker stopped (SIGTERM, as `docker stop` and the node agent do)
#     during a long INSERT shuts down gracefully: the INSERT finishes and
#     commits once, the worker leaves, and how long it took is said.
# Not here: V2 (a worker one release newer), which needs a second image.
#
# Run alone, never during a build, from this repository's root, with a
# checkout of government-data/orchestrator for engine-trino's files and
# its verification helpers:
#   ORCH=<orchestrator checkout> tools/verify/trino_worker_drain.sh
# Containers and the network are `qo-verify-drain-*`, removed in a trap.
set -uo pipefail
: "${ORCH:?set ORCH to a checkout of the orchestrator repository}"
WORKERS=$PWD
P=qo-verify-drain
# shellcheck source=/dev/null
. "$ORCH/tools/verify/engine_trino_lib.sh"
MODULE=$ORCH/modules/engine-trino

worker_cert() { # NAME: a node directory with the worker's own certificate
  local n=$1 d=$D/$1
  mkdir -p "$d"
  cp "$D/node/ca.crt" "$d/"
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/O=qd/OU=trino-worker/CN=$n" \
    -keyout "$d/k" -out "$d/csr" 2>/dev/null
  printf 'subjectAltName=DNS:%s\n' "$n" >"$d/ext"
  openssl x509 -req -in "$d/csr" -CA "$D/node/ca.crt" -CAkey "$D/ca.key" -CAcreateserial \
    -days 1 -extfile "$d/ext" -out "$d/crt" 2>/dev/null
  openssl pkcs8 -topk8 -nocrypt -in "$d/k" -out "$d/p8"
  cat "$d/crt" "$d/p8" >"$d/machine.pem"
  rm -f "$d/k" "$d/csr" "$d/ext" "$d/crt" "$d/p8"
  chmod 755 "$d"; chmod 644 "$d/ca.crt"; chmod 600 "$d/machine.pem"
}
worker() { # NAME
  worker_cert "$1"
  docker run -d --name "$1" --hostname "$1" --network "$P" --memory 2g \
    --entrypoint /etc/trino-module/entrypoint.sh \
    -e TRINO_TIER=s -e TRINO_HEAP=1G -e TRINO_HEADROOM=300MB -e TRINO_NODE_CAP=700MB \
    -e TRINO_NODE_ID="$1" -e TRINO_NODE_NAME="$1" \
    -e TRINO_DISCOVERY_URI="https://$P-coordinator:8490" \
    -e TRINO_LAKE_S3_URL="http://$P-lake:9000" -e TRINO_LAKE_WAREHOUSE="$WAREHOUSE" \
    -v "$WORKERS/trino:/etc/trino-module:ro" -v "$D/$1:/run/qd-node:ro" \
    -v "$D/secrets/trino-shared-secret:/run/secrets/trino-shared-secret:ro" \
    -v "$D/secrets/lake-access-key:/run/secrets/lake-access-key:ro" \
    -v "$D/secrets/lake-secret-key:/run/secrets/lake-secret-key:ro" \
    --tmpfs /spill:uid=1000,gid=1000 "$TRINO_IMAGE" >/dev/null
}

et_pki
et_rustfs || exit 1
et_core
et_coordinator TRINO_INCLUDE_COORDINATOR=false TRINO_TIER=l TRINO_QUERY_CAP=1GB || exit 1
worker "$P-w1"
worker "$P-w2"
admin=$(et_token qd-admin)
nodes() { tq "$admin" "SELECT count(*) FROM system.runtime.nodes WHERE coordinator = false AND state = 'active'"; }
for _ in $(seq 1 60); do [ "$(nodes)" = '[[2]]' ] && break; sleep 2; done
expect "both workers active" '[[2]]' "$(nodes)"

tq_ok "setup: schema" "$admin" "CREATE SCHEMA lake.qo_verify"
tq_ok "setup: table" "$admin" "CREATE TABLE lake.qo_verify.t (x bigint, y varchar)"
# A long INSERT, in the background, its answer in a file.
docker exec -d -e T="$admin" "$P-coordinator" bash -c '/verify/tq.sh "INSERT INTO lake.qo_verify.t
  SELECT a * 10000 + b, to_hex(sha256(to_utf8(CAST(a * b AS varchar))))
  FROM UNNEST(sequence(1, 3000)) AS s(a) CROSS JOIN UNNEST(sequence(1, 3000)) AS u(b)" \
  >/data/trino/insert.out 2>&1'
for _ in $(seq 1 40); do
  r=$(tq "$admin" "SELECT count(*) FROM system.runtime.tasks WHERE node_id = '$P-w1' AND state = 'RUNNING'")
  [ "$r" != '[[0]]' ] && break; sleep 0.5
done
info "tasks on w1 when it is stopped: $r"
start=$(date +%s)
docker stop -t 600 "$P-w1" >/dev/null
info "w1 left $(( $(date +%s) - start )) s after SIGTERM, exit $(docker inspect -f '{{.State.ExitCode}}' "$P-w1")"
expect_match "w1 was told SHUTTING_DOWN by its entrypoint" "state change: HTTP 200" \
  "$(docker logs "$P-w1" 2>&1 | grep -m1 'state change')"
for _ in $(seq 1 300); do
  out=$(docker exec "$P-coordinator" cat /data/trino/insert.out 2>/dev/null)
  [ -n "$out" ] && break; sleep 1
done
for _ in $(seq 1 60); do [ "$(nodes)" = '[[1]]' ] && break; sleep 2; done
expect "one worker left active" '[[1]]' "$(nodes)"
info "the INSERT answered: $out"
rows=$(tq "$admin" "SELECT count(*) FROM lake.qo_verify.t")
case "$out" in
  '[[9000000]]') expect "committed once" '[[9000000]]' "$rows" ;;
  *) expect "the failed INSERT committed nothing" '[[0]]' "$rows" ;;
esac
expect_match "the INSERT finished (T16)" '^\[\[9000000\]\]$' "$out"

[ "$FAILED" = 0 ] && echo "ALL OK" || { echo "SOME CHECKS FAILED"; exit 1; }
