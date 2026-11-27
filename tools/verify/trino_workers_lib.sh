# shellcheck shell=bash
# Workers for the verification scripts of this module: sourced after
# engine-trino's engine_trino_lib.sh (from an orchestrator checkout, ORCH),
# with WORKERS set to this repository's root. A worker gets its own machine
# certificate of the scripts' CA and starts from trino/ as compose.yml
# starts it, sized down for this machine.

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
worker() { # NAME [IMAGE]
  worker_cert "$1"
  docker run -d --name "$1" --hostname "$1" --network "$P" --memory 2g \
    --sysctl net.ipv4.ip_unprivileged_port_start=443 \
    --entrypoint /etc/trino-module/entrypoint.sh \
    -e TRINO_TIER=s -e TRINO_HEAP=1G -e TRINO_HEADROOM=300MB -e TRINO_NODE_CAP=700MB \
    -e TRINO_NODE_ID="$1" -e TRINO_NODE_NAME="$1" \
    -e TRINO_DISCOVERY_URI="https://$P-coordinator" \
    -e TRINO_LAKE_S3_URL="http://$P-lake:9000" -e TRINO_LAKE_WAREHOUSE="$WAREHOUSE" \
    -v "$WORKERS/trino:/etc/trino-module:ro" -v "$D/$1:/run/qd-node:ro" \
    -v "$D/secrets/trino-shared-secret:/run/secrets/trino-shared-secret:ro" \
    -v "$D/secrets/lake-query-engine-access-key:/run/secrets/lake-query-engine-access-key:ro" \
    -v "$D/secrets/lake-query-engine-secret-key:/run/secrets/lake-query-engine-secret-key:ro" \
    --tmpfs /spill:uid=1000,gid=1000 "${2:-$TRINO_IMAGE}" >/dev/null
}

