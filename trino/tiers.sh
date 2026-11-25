# A worker's sizing (core decision 0090, point 6.1, tier L: workers of 8–16
# vCPU and 32–64 GB): estimates until T11 to T13 measure them. Any value
# can be set in the environment instead. No heap dump, no -Xms.
# shellcheck shell=bash
tier() {
  local heap headroom cap
  case "${TRINO_TIER:-l}" in
    # A smaller worker, for tests and pilots only.
    s) heap=10G headroom=3GB cap=5GB ;;
    l) heap=26G headroom=6GB cap=7GB ;;
    *) echo "TRINO_TIER: s or l, not ${TRINO_TIER}" >&2; return 1 ;;
  esac
  TRINO_HEAP=${TRINO_HEAP:-$heap}
  TRINO_HEADROOM=${TRINO_HEADROOM:-$headroom}
  TRINO_NODE_CAP=${TRINO_NODE_CAP:-$cap}
}
