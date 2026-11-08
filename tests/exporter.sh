#!/bin/sh
# Opt-in container test. Build the configured helper image before running.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/lib/common.sh"
ENV_FILE=${ENV_FILE:-$ROOT/.env}
load_env
defaults
work=$(mktemp -d)
container="$PROJECT_NAME-exporter-test-$$"
cleanup() {
    docker rm -f "$container" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT
mkdir "$work/acme" "$work/certs"
fixture() {
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$work/key.pem" -out "$work/cert.pem" -days 2 -subj /CN=renew.example.com >/dev/null 2>&1
    jq -n --rawfile key "$work/key.pem" --rawfile cert "$work/cert.pem" \
        '{resolver:{Certificates:[{domain:{main:"renew.example.com"},key:($key|@base64),certificate:($cert|@base64)}]}}' > "$work/acme/next.json"
    mv "$work/acme/next.json" "$work/acme/acme.json"
}
await_key() {
    attempt=0
    until cmp -s "$work/key.pem" "$work/certs/renew.example.com.key"; do
        attempt=$((attempt + 1))
        [ "$attempt" -lt 15 ] || die 'Container exporter did not publish the expected key'
        sleep 1
    done
}
fixture
docker run -d --name "$container" --network none --cap-drop ALL \
    --security-opt no-new-privileges:true \
    -v "$work/acme:/acme:ro" -v "$work/certs:/certs" \
    -e ACME_FILE=/acme/acme.json -e CERTS_DIR=/certs -e WATCH_INTERVAL=1 \
    "$HELPER_IMAGE" sh /app/traefik-certs-extract.sh --watch >/dev/null
await_key
printf 'PASS: Alpine exporter reads its read-only ACME mount and publishes certificates\n'
printf '{' > "$work/acme/acme.json"
sleep 3
cmp -s "$work/key.pem" "$work/certs/renew.example.com.key" || die 'Malformed ACME input destroyed the exported key'
printf 'PASS: corrupt input preserves the mounted export\n'
fixture
await_key
printf 'PASS: watcher retries after failure and exports renewed certificate/key data\n'
[ "$(stat -c %a "$work/certs/renew.example.com.key")" = 600 ] || die 'Exported key has incorrect permissions'
[ "$(docker inspect "$container" --format '{{.RestartCount}}')" = 0 ] || die 'Exporter crashed during renewal'
printf 'PASS: private key permissions and container stability\n'
