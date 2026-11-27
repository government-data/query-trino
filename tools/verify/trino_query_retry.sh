#!/usr/bin/env bash
# T17 of core decision 0090 (query retry on tier L), against engine-trino's
# coordinator (tier L: `retry-policy=QUERY`, BI's session `NONE`) and two
# workers of this module:
#   - a worker killed (SIGKILL) during an INSERT: the query is repeated on
#     the worker left and commits once;
#   - a person's query runs with `retry_policy` NONE (the session property
#     manager), and fails when a worker running one of its tasks dies;
#   - which error a repeated and a non-repeated query end with is said.
# Not here: a 100 MB BI result under NONE and QUERY.
#
# Run alone, never during a build, from this repository's root:
#   ORCH=<orchestrator checkout> tools/verify/trino_query_retry.sh
# Containers and the network are `qo-verify-retry-*`, removed in a trap.
set -uo pipefail
: "${ORCH:?set ORCH to a checkout of the orchestrator repository}"
WORKERS=$PWD
P=qo-verify-retry
# shellcheck source=/dev/null
. "$ORCH/tools/verify/engine_trino_lib.sh"
MODULE=$ORCH/modules/engine-trino
# shellcheck source=trino_workers_lib.sh
. "$(dirname "$0")/trino_workers_lib.sh"

ANA=person-00000000-0000-4000-8000-00000000000a
cat >"$D/rules.json" <<JSON
{"catalogs": [{"user": "qd-admin", "allow": "owner"}, {"user": "$ANA", "catalog": "gold", "allow": "read-only"}, {"allow": "none"}],
 "tables": [{"user": "qd-admin", "privileges": ["SELECT", "INSERT", "DELETE", "OWNERSHIP"]},
            {"user": "$ANA", "catalog": "gold", "privileges": ["SELECT"]}],
 "queries": [{"allow": ["execute", "view", "kill"]}],
 "system_information": [{"user": "qd-admin", "allow": ["read", "write"]}]}
JSON
et_pki
et_rustfs || exit 1
et_rules "$D/rules.json"
et_core
et_coordinator TRINO_TIER=l TRINO_QUERY_CAP=1GB || exit 1
worker "$P-w1"
worker "$P-w2"
admin=$(et_token qd-admin)
ana=$(et_token "$ANA")
nodes() { tq "$admin" "SELECT count(*) FROM system.runtime.nodes WHERE coordinator = false AND state = 'active'"; }
for _ in $(seq 1 60); do [ "$(nodes)" = '[[2]]' ] && break; sleep 2; done
expect "two workers active" '[[2]]' "$(nodes)"
expect "the cluster's retry policy" "retry-policy=QUERY" \
  "$(docker exec "$P-coordinator" cat /data/trino/etc/config.properties | grep -o 'retry-policy=QUERY')"

T=lake.qo_verify.t
tq_ok "setup" "$admin" "CREATE SCHEMA lake.qo_verify"
tq_ok "setup" "$admin" "CREATE TABLE $T (x bigint)"
long="INSERT INTO $T SELECT a * 1000000 + b * 1000 + c FROM UNNEST(sequence(1, 9)) x(a)
  CROSS JOIN UNNEST(sequence(1, 1000)) y(b) CROSS JOIN UNNEST(sequence(1, 1000)) z(c)
  WHERE length(to_hex(sha256(to_utf8(CAST(a * b * c AS varchar))))) = 64"
docker exec -d -e T="$admin" "$P-coordinator" bash -c "/verify/tq.sh \"$long\" >/data/trino/insert.out 2>&1"
for _ in $(seq 1 40); do
  r=$(tq "$admin" "SELECT count(*) FROM system.runtime.tasks WHERE node_id = '$P-w1' AND state = 'RUNNING'")
  [ "$r" != '[[0]]' ] && break; sleep 0.5
done
docker kill -s KILL "$P-w1" >/dev/null
info "w1 killed with $r of its tasks running"
for _ in $(seq 1 300); do
  out=$(docker exec "$P-coordinator" cat /data/trino/insert.out 2>/dev/null); [ -n "$out" ] && break; sleep 1
done
expect "the INSERT repeated and finished" '[[9000000]]' "$out"
expect "committed once" '[[9000000]]' "$(tq "$admin" "SELECT count(*) FROM $T")"

docker start "$P-w1" >/dev/null
for _ in $(seq 1 60); do [ "$(nodes)" = '[[2]]' ] && break; sleep 2; done
slow="SELECT count(*) FROM gold.qo_verify.t a CROSS JOIN UNNEST(sequence(1, 8)) s(i)
  WHERE length(to_hex(sha256(to_utf8(CAST(a.x * i AS varchar))))) = 64"
docker exec -d -e T="$ana" "$P-coordinator" bash -c "/verify/tq.sh \"$slow\" >/data/trino/bi.out 2>&1"
pid=
for _ in $(seq 1 40); do
  pid=$(tq "$admin" "SELECT query_id FROM system.runtime.queries WHERE user = '$ANA' AND state = 'RUNNING' LIMIT 1" | tr -d '[]"')
  [ -n "$pid" ] && break; sleep 0.5
done
expect_match "a person's query runs with retry_policy NONE" "'retry_policy': 'NONE'" \
  "$(docker exec "$P-coordinator" curl -sS --cacert /run/qd-node/ca.crt -H "Authorization: Bearer $admin" \
    "https://localhost/v1/query/$pid" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session"]["systemProperties"])' 2>/dev/null)"
for _ in $(seq 1 40); do
  r=$(tq "$admin" "SELECT count(*) FROM system.runtime.tasks WHERE node_id = '$P-w2' AND state = 'RUNNING'
    AND query_id = '$pid'")
  [ "$r" != '[[0]]' ] && break; sleep 0.25
done
docker kill -s KILL "$P-w2" >/dev/null
info "w2 killed with $r of the person's tasks running"
for _ in $(seq 1 120); do
  out=$(docker exec "$P-coordinator" cat /data/trino/bi.out 2>/dev/null); [ -n "$out" ] && break; sleep 1
done
if [ "$r" = '[[0]]' ]; then
  info "not shown: the person's query had no task on w2 when it died (its answer: $out)"
else
  expect_match "the person's query fails when a worker dies (not repeated)" "failed" "$out"
  info "its error: $out"
fi

[ "$FAILED" = 0 ] && echo "ALL OK" || { echo "SOME CHECKS FAILED"; exit 1; }
