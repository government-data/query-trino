#!/bin/sh
# Trino's RustFS user (infra/trino): reads and writes the lake's warehouses
# (the buckets `qd-tenant-*`, lake-policy.json), nothing else, no admin API.
# Until the application manages it (decisions 0028, 0030), run it by hand
# from the repository, with RustFS up:
#   sh infra/trino/lake-user.sh
# The first time it generates the user's keys and appends them to .env
# (TRINO_LAKE_ACCESS_KEY, TRINO_LAKE_SECRET_KEY); it never prints them. It
# also creates the development warehouse (TRINO_LAKE_WAREHOUSE, a bucket and
# its Iceberg table bucket) if missing. The admin API is called from
# RustFS's own network (port 9000 is not published), signed with the root
# credentials of .env; the bodies go on stdin.
set -eu
cd "$(dirname "$0")/../.."
set -a; . ./.env; set +a
if [ -z "${TRINO_LAKE_ACCESS_KEY:-}" ]; then
  TRINO_LAKE_ACCESS_KEY="trino-$(openssl rand -hex 6)"
  TRINO_LAKE_SECRET_KEY=$(openssl rand -hex 24)
  printf '\n# Trino'"'"'s RustFS user (infra/trino/lake-user.sh)\nTRINO_LAKE_ACCESS_KEY=%s\nTRINO_LAKE_SECRET_KEY=%s\n' \
    "$TRINO_LAKE_ACCESS_KEY" "$TRINO_LAKE_SECRET_KEY" >>.env
fi
container=${RUSTFS_CONTAINER:-data-quality-lake-rustfs-1}
warehouse=${TRINO_LAKE_WAREHOUSE:-qd-tenant-00000000000000000000000000000001}

# admin METHOD PATH: a request signed with the root credentials (body on stdin).
admin() {
  docker run --rm -i --network "container:$container" curlimages/curl:8.11.1 \
    -s -o /dev/null -w '%{http_code}' -X "$1" \
    --aws-sigv4 "aws:amz:us-east-1:s3" --user "$RUSTFS_ACCESS_KEY:$RUSTFS_SECRET_KEY" \
    -H 'content-type: application/json' --data-binary @- "http://127.0.0.1:9000$2"
}
check() {
  echo "$1: $2"
  case "$2" in 200 | 204) ;; *) exit 1 ;; esac
}

check "policy qd-trino-lake" "$(admin PUT '/rustfs/admin/v3/add-canned-policy?name=qd-trino-lake' <infra/trino/lake-policy.json)"
check "user" "$(printf '{"secretKey":"%s","status":"enabled"}' "$TRINO_LAKE_SECRET_KEY" |
  admin PUT "/rustfs/admin/v3/add-user?accessKey=$TRINO_LAKE_ACCESS_KEY")"
check "user's policy" "$(admin PUT "/rustfs/admin/v3/set-user-or-group-policy?policyName=qd-trino-lake&userOrGroup=$TRINO_LAKE_ACCESS_KEY&isGroup=false" </dev/null)"
if [ "$(admin GET "/$warehouse?list-type=2&max-keys=1" </dev/null)" != 200 ]; then
  check "bucket $warehouse" "$(admin PUT "/$warehouse" </dev/null)"
fi
check "table bucket $warehouse" "$(admin PUT "/iceberg/v1/buckets/$warehouse" </dev/null)"
