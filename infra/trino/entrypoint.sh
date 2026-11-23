#!/bin/bash
# Start a Trino node (coordinator or worker) of infra/trino. Bash, coreutils,
# curl and the JDK only: the image ships no grep or sed.
#
#   - an extra CA (/etc/trino/extra-ca.crt, the development one) joins the
#     JVM's default truststore, for https://localhost; with the machines'
#     certificates, the installation's CA does, and the node's machine.pem
#     becomes the JVM's keystore, for the lake's gate;
#   - the coordinator's HTTPS certificate becomes Trino's PEM keystore;
#   - the static catalogs (/etc/trino/static-catalog) are copied into the
#     catalog directory, where `CREATE CATALOG` writes the dynamic ones
#     (catalog.store=file); the static ones always match the repository.
set -euo pipefail

# The JVM's own TLS, which the lake's clients use (the S3 file system and
# the REST catalog have no setting of their own). Its truststore: the
# default one with the extra CA and, with the machines' certificates
# (certificate.yml), the installation's. Its keystore: the node's machine
# certificate, made from the agent's machine.pem at each start
# (PemKeystore.java), which Trino presents at the lake's gate (decision
# 0066, point 10). The JVM reads it once: a renewed certificate takes a
# restart. The keystore's word protects nothing and is no secret: the file
# is this user's alone, as machine.pem is.
jvm_tls=()
store=/data/trino/truststore.jks
cas=()
[ -f /etc/trino/extra-ca.crt ] && cas+=(/etc/trino/extra-ca.crt)
[ -f /run/qd-node/ca.crt ] && cas+=(/run/qd-node/ca.crt)
if [ ${#cas[@]} -gt 0 ]; then
  cp "$JAVA_HOME/lib/security/cacerts" "$store.tmp"
  chmod u+w "$store.tmp"
  for i in "${!cas[@]}"; do
    keytool -importcert -noprompt -alias "extra-ca-$i" -file "${cas[$i]}" \
      -keystore "$store.tmp" -storepass changeit >/dev/null
  done
  mv "$store.tmp" "$store"
  jvm_tls+=("-Djavax.net.ssl.trustStore=$store" -Djavax.net.ssl.trustStorePassword=changeit)
fi
if [ -f /run/qd-node/machine.pem ] && [ -f /etc/trino/PemKeystore.java ]; then
  keys=/data/trino/machine.p12
  (umask 077 && java /etc/trino/PemKeystore.java /run/qd-node/machine.pem "$keys.tmp" changeit)
  mv "$keys.tmp" "$keys"
  jvm_tls+=("-Djavax.net.ssl.keyStore=$keys" -Djavax.net.ssl.keyStorePassword=changeit -Djavax.net.ssl.keyStoreType=PKCS12)
fi
[ ${#jvm_tls[@]} -gt 0 ] && export JAVA_TOOL_OPTIONS="${jvm_tls[*]}"

# The coordinator's HTTPS certificate and key (/etc/trino/tls; in
# production the machine's certificate, decision 0030), in the single PEM
# file Trino reads.
if [ -f /etc/trino/tls/tls.crt ] && [ -f /etc/trino/tls/tls.key ]; then
  (umask 077 && cat /etc/trino/tls/tls.crt /etc/trino/tls/tls.key >/data/trino/https.pem)
fi

if [ -d /etc/trino/static-catalog ]; then
  mkdir -p /data/trino/catalog
  chmod 700 /data/trino/catalog
  cp /etc/trino/static-catalog/*.properties /data/trino/catalog/
fi

# The coordinator (TRINO_JWKS_URL set): Quality Data's public keys, one PEM
# file per key id (http-server.authentication.jwt.key-file), read again every
# few minutes so a rotated key is known before its first token.
#
# Trino 484 verifies RSA and EC keys only, from a JWKS or from files: the
# provider's Ed25519 keys (EdDSA, `kty: OKP`) cannot be used until it also
# publishes an EC P-256 key (ES256) for Trino; they are skipped and logged.
# A P-256 public key in X.509 form is a fixed 27-byte header (with the 0x04
# of an uncompressed point) followed by x and y.
P256_HEADER='\x30\x59\x30\x13\x06\x07\x2a\x86\x48\xce\x3d\x02\x01\x06\x08\x2a\x86\x48\xce\x3d\x03\x01\x07\x03\x42\x00\x04'
b64std() { # base64url without padding -> base64
  local s=${1//-/+}
  s=${s//_//}
  while ((${#s} % 4)); do s+='='; done
  printf '%s' "$s"
}
sync_jwks() {
  local jwks key kid x y dir=/data/trino/jwks ca=() log=${1:-}
  [ -f /etc/trino/extra-ca.crt ] && ca=(--cacert /etc/trino/extra-ca.crt)
  jwks=$(curl --fail --silent --show-error --max-time 10 "${ca[@]}" "$TRINO_JWKS_URL") || return 0
  mkdir -p "$dir"
  while [[ $jwks =~ \{([^{}]*)\} ]]; do
    key=${BASH_REMATCH[1]}
    jwks=${jwks#*"${BASH_REMATCH[0]}"}
    [[ $key =~ \"kid\":\"([A-Za-z0-9_-]+)\" ]] || continue
    kid=${BASH_REMATCH[1]}
    if [[ $key =~ \"kty\":\"EC\" && $key =~ \"crv\":\"P-256\" &&
      $key =~ \"x\":\"([A-Za-z0-9_-]{43})\".*\"y\":\"([A-Za-z0-9_-]{43})\" ]]; then
      x=${BASH_REMATCH[1]} y=${BASH_REMATCH[2]}
      {
        echo '-----BEGIN PUBLIC KEY-----'
        { printf "$P256_HEADER"; b64std "$x" | base64 -d; b64std "$y" | base64 -d; } | base64 -w 64
        echo '-----END PUBLIC KEY-----'
      } >"$dir/$kid.pem.tmp"
      mv "$dir/$kid.pem.tmp" "$dir/$kid.pem"
    elif [ -n "$log" ]; then
      echo "jwks: key $kid skipped: Trino verifies EC (P-256) keys from this JWKS, not this one" >&2
    fi
  done
}
if [ -n "${TRINO_JWKS_URL:-}" ]; then
  sync_jwks log
  (while sleep "${TRINO_JWKS_REFRESH_SECONDS:-300}"; do sync_jwks; done) &
fi

exec /usr/lib/trino/bin/launcher run --etc-dir /etc/trino
