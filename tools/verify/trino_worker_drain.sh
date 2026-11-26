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

# shellcheck source=trino_workers_lib.sh
. "$(dirname "$0")/trino_workers_lib.sh"

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
