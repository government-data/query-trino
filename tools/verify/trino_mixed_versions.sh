#!/usr/bin/env bash
# V2 of quality-sdk decision 0011 (mixed versions): engine-trino's
# coordinator on Trino 484 and one worker of this module on another release
# (483, the one before: no newer release than 484 is published as of
# 2026-11-25). Does the coordinator refuse it, list it inactive, or use it?
# Expected refused; the answer decides whether `trino-cluster`'s exact
# version is all lockstep needs.
#
# Run alone, never during a build, from this repository's root:
#   ORCH=<orchestrator checkout> tools/verify/trino_mixed_versions.sh
# Containers and the network are `qo-verify-mixed-*`, removed in a trap.
set -uo pipefail
: "${ORCH:?set ORCH to a checkout of the orchestrator repository}"
OTHER_IMAGE=${OTHER_IMAGE:-trinodb/trino:483}
WORKERS=$PWD
P=qo-verify-mixed
# shellcheck source=/dev/null
. "$ORCH/tools/verify/engine_trino_lib.sh"
MODULE=$ORCH/modules/engine-trino
# shellcheck source=trino_workers_lib.sh
. "$(dirname "$0")/trino_workers_lib.sh"

et_pki
et_rustfs || exit 1
et_core
et_coordinator TRINO_INCLUDE_COORDINATOR=false TRINO_TIER=l TRINO_QUERY_CAP=1GB || exit 1
worker "$P-old" "$OTHER_IMAGE"
admin=$(et_token qd-admin)
for _ in $(seq 1 60); do
  docker logs "$P-coordinator" 2>&1 | grep -q 'Node version mismatch' && break; sleep 2
done
expect_match "the coordinator refuses the worker's version" "Node version mismatch: expected 484, got 4[0-9]+" \
  "$(docker logs "$P-coordinator" 2>&1 | grep -o -m1 'Node version mismatch: expected [0-9]*, got [0-9]*')"
# A query that needs a worker gets none: it fails, or waits, within 20 s.
out=$(timeout 20 docker exec -e T="$admin" "$P-coordinator" /verify/tq.sh "SELECT count(*) FROM UNNEST(sequence(1, 1000)) t(x)" 2>&1 || echo "no answer in 20 s")
expect_match "no work goes to the worker of another release" 'failed|no answer' "$out"

[ "$FAILED" = 0 ] && echo "ALL OK" || { echo "SOME CHECKS FAILED"; exit 1; }
