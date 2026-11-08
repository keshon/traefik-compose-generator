#!/bin/sh
# Opt-in: creates a disposable backend on the configured proxy network.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
. "$ROOT/lib/common.sh"
ENV_FILE=${ENV_FILE:-$ROOT/.env}
load_env
defaults
command -v python3 >/dev/null 2>&1 || die 'Python 3 is required for live probes'
test_port=$(printf '%s' "$CUSTOM_PORTS" | tr ',' ' ' | awk '{print $1}')
[ -n "$test_port" ] || die 'Configure at least one unused CUSTOM_PORTS entry'
valid_port CUSTOM_PORTS "$test_port"
sh "$ROOT/build-n-run.sh" up
backend="$PROJECT_NAME-live-test-$$"
unlabelled="$backend-unlabelled"
cleanup() { docker rm -f "$backend" "$unlabelled" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker run -d --name "$backend" --network "$PROXY_NETWORK" \
    --env "TEST_PORT=$test_port" -v "$ROOT/tests/backend.py:/backend.py:ro" \
    --label traefik.enable=true \
    --label "traefik.http.routers.$backend.rule=Host(\`traefik-live-test.invalid\`)" \
    --label "traefik.http.routers.$backend.entrypoints=http" \
    --label "traefik.http.routers.$backend.service=$backend" \
    --label "traefik.http.services.$backend.loadbalancer.server.port=8081" \
    --label "traefik.tcp.routers.$backend.rule=HostSNI(\`*\`)" \
    --label "traefik.tcp.routers.$backend.entrypoints=tcp-$test_port" \
    --label "traefik.tcp.routers.$backend.service=$backend" \
    --label "traefik.tcp.services.$backend.loadbalancer.server.port=$test_port" \
    --label "traefik.udp.routers.$backend.entrypoints=udp-$test_port" \
    --label "traefik.udp.routers.$backend.service=$backend" \
    --label "traefik.udp.services.$backend.loadbalancer.server.port=$test_port" \
    python:3.12.16-alpine3.24 python /backend.py >/dev/null
attempt=0
until curl --silent --fail -H 'Host: traefik-live-test.invalid' "http://127.0.0.1:$HTTP_PORT/" >/dev/null; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 30 ] || die 'Test backend failed to become routable'
    sleep 1
done
python3 "$ROOT/tests/probe.py" 127.0.0.1 "$HTTP_PORT" "$test_port"
# No enable label: an otherwise discoverable HTTP backend must stay unrouted.
docker run -d --name "$unlabelled" --network "$PROXY_NETWORK" \
    -v "$ROOT/tests/backend.py:/backend.py:ro" --expose 8081 \
    python:3.12.16-alpine3.24 python /backend.py >/dev/null
sleep 3
status=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $unlabelled" "http://127.0.0.1:$HTTP_PORT/")
[ "$status" = 404 ] || die "Unlabelled backend became exposed: $status"
printf 'PASS: unlabelled backend is not exposed\n'
before=$(compose ps -q traefik)
sh "$ROOT/build-n-run.sh" up
after=$(compose ps -q traefik)
[ "$before" = "$after" ] || die 'Unchanged deployment recreated Traefik'
printf 'PASS: repeated deployment preserves the Traefik container\n'
if [ "${1:-}" = --restart ]; then
    docker restart "$after" >/dev/null
    compose up -d --wait --wait-timeout 120 traefik
    sleep 3
    python3 "$ROOT/tests/probe.py" 127.0.0.1 "$HTTP_PORT" "$test_port"
    printf 'PASS: routing recovers after container restart\n'
fi
if [ -n "${LIVE_TEST_HOLD_SECONDS:-}" ]; then
    positive_integer LIVE_TEST_HOLD_SECONDS "$LIVE_TEST_HOLD_SECONDS"
    printf 'Holding disposable backend for %s seconds for external probes.\n' "$LIVE_TEST_HOLD_SECONDS"
    sleep "$LIVE_TEST_HOLD_SECONDS"
fi
printf 'Live tests passed; disposable backends will be removed.\n'
