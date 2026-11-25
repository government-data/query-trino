#!/bin/bash
# Starts a query-trino worker (quality-sdk decision 0011): bash, coreutils,
# curl and the JDK only (the image has no sed or grep).
#
#   - the tier's settings render Trino's etc directory under /data/trino/etc;
#   - the coordinator's shared secret and the lake user's keys are read
#     from their files into the environment Trino reads, never printed
#     (the catalogs the coordinator sends resolve `${ENV:…}` here);
#   - on SIGTERM the worker shuts down gracefully: it is told
#     `SHUTTING_DOWN`, takes no new task, finishes the running ones and
#     leaves, so a rolling restart cuts no query (V3, T16).
set -euo pipefail
MODULE=/etc/trino-module
# shellcheck source=tiers.sh
. "$MODULE/tiers.sh"
tier

ETC=/data/trino/etc
mkdir -p "$ETC"
cp "$MODULE"/etc/*.properties "$ETC/"
jvm=$(<"$MODULE/etc/jvm.config.in")
printf '%s\n' "${jvm//@HEAP@/$TRINO_HEAP}" >"$ETC/jvm.config"
cat >>"$ETC/config.properties" <<PROPS

# Tier ${TRINO_TIER:-l} (tiers.sh): the pool is the heap less the headroom.
memory.heap-headroom-per-node=${TRINO_HEADROOM}
query.max-memory-per-node=${TRINO_NODE_CAP}
spill-enabled=true
spiller-spill-path=/spill
spill-compression-codec=LZ4
shutdown.grace-period=${TRINO_SHUTDOWN_GRACE:-10s}
PROPS

secret() { # the first line of a secret file
  local line
  IFS= read -r line <"$1" || [ -n "$line" ]
  printf '%s' "$line"
}
TRINO_SHARED_SECRET=$(secret /run/secrets/trino-shared-secret)
TRINO_LAKE_ACCESS_KEY=$(secret /run/secrets/lake-access-key)
TRINO_LAKE_SECRET_KEY=$(secret /run/secrets/lake-secret-key)
export TRINO_SHARED_SECRET TRINO_LAKE_ACCESS_KEY TRINO_LAKE_SECRET_KEY

/usr/lib/trino/bin/launcher run --etc-dir "$ETC" &
trino=$!
leave() {
  echo "graceful shutdown asked" >&2
  curl -sS -o /dev/stderr -w 'state change: HTTP %{http_code}\n' -X PUT -H 'X-Trino-User: qd-admin' \
    -H 'Content-Type: application/json' --data '"SHUTTING_DOWN"' \
    http://127.0.0.1:8091/v1/info/state >&2 || kill -TERM "$trino"
}
trap leave TERM INT
# `wait` returns when a trapped signal arrives: wait again for Trino itself.
while kill -0 "$trino" 2>/dev/null; do
  wait "$trino" || true
done
