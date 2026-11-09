#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$ROOT"/*.sh "$ROOT/compose.yaml" "$work/"
cp -R "$ROOT/lib" "$work/"
cd "$work"
mkdir bin
cat > bin/docker <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_LOG"
case "$*" in
    *'version'*) exit 0 ;;
    *'config --quiet'*) exit "${MOCK_CONFIG_STATUS:-0}" ;;
    *'up -d'*) exit "${MOCK_UP_STATUS:-0}" ;;
    *'kill --signal=USR1'*)
        [ "${MOCK_SIGNAL_STATUS:-0}" = 0 ] || exit "$MOCK_SIGNAL_STATUS"
        : > "$MOCK_REOPEN_LOG"
        ;;
esac
MOCK
chmod +x bin/docker
export PATH="$work/bin:$PATH" MOCK_LOG="$work/docker.log"
count=0
pass() { count=$((count + 1)); printf 'ok %s - %s\n' "$count" "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
base_env() {
    cat > .env <<'ENV'
DATA_DIR=./data
LETSENCRYPT_EMAIL=tests@example.com
DASHBOARD_HOSTNAME=
CUSTOM_PORTS="51227,58526"
ENV
}
expect_failure() {
    if sh ./traefik.sh "$1" > output 2>&1; then fail "Unexpected success: $2"; fi
    pass "$2"
}

base_env
sh ./traefik.sh generate > output
grep -q 'TCP-51227_ADDRESS' compose.generated.yaml || fail 'Missing TCP port'
grep -q '58526/udp' compose.generated.yaml || fail 'Missing UDP port'
pass 'Comma-separated ports generate TCP and UDP mappings'
printf 'CUSTOM_PORTS="51227 58526"\n' >> .env
sh ./traefik.sh generate > output
grep -q 'TCP-58526_ADDRESS' compose.generated.yaml || fail 'Space-separated ports'
pass 'Space-separated ports work'

for invalid in '0' '65536' '-1' '0123' 'http' '80' '443' '8080' '51227,51227' '99999999999999'; do
    base_env
    printf 'CUSTOM_PORTS="%s"\n' "$invalid" >> .env
    expect_failure generate "Reject invalid/conflicting ports: $invalid"
done
base_env
printf 'HTTP_PORT=51227\n' >> .env
expect_failure generate 'Reject collision with remapped HTTP port'
base_env
printf 'HTTPS_PORT=80\n' >> .env
expect_failure generate 'Reject identical HTTP/HTTPS host ports'
base_env
printf 'CERTS_EXPORT=yes\n' >> .env
expect_failure generate 'Reject invalid feature toggle'
base_env
printf 'LOG_ROTATE_TRIGGER_SIZE=oops\n' >> .env
expect_failure generate 'Reject invalid log rotation size'
base_env
printf 'DASHBOARD_HOSTNAME=bad/host\n' >> .env
expect_failure generate 'Reject invalid hostname'

base_env
printf 'DASHBOARD_HOSTNAME=dashboard.example.com\n' >> .env
sh ./traefik.sh generate > output
grep -q 'basicauth.usersfile' compose.generated.yaml || fail 'Missing dashboard auth'
printf 'DASHBOARD_HOSTNAME=\nCUSTOM_PORTS=\n' >> .env
sh ./traefik.sh generate > output
if grep -qE 'basicauth|51227|labels:' compose.generated.yaml; then fail 'Stale settings survived'; fi
pass 'Disabling features removes stale dashboard and port configuration'

base_env
# shellcheck disable=SC2016
printf '%s\n' 'TZ=$(touch INJECTED)' "DASHBOARD_PASSWORD_HASH='\$\$2y\$\$12\$\$literal'" >> .env
sh ./traefik.sh generate > output
[ ! -e INJECTED ] || fail 'Executed .env as shell code'
pass '.env command substitution is never executed'
EXPECTED_HASH='$$2y$$12$$literal' ENV_FILE="$work/.env" sh -c '. ./lib/common.sh; load_env; test "$DASHBOARD_PASSWORD_HASH" = "$EXPECTED_HASH"'
pass 'Dollar signs remain literal when reading .env'

base_env
export MOCK_UP_STATUS=42
expect_failure up 'Compose startup failure propagates'
if grep -q 'deployment is healthy' output; then fail 'False success message'; fi
pass 'Failure does not print a success message'
unset MOCK_UP_STATUS
export MOCK_CONFIG_STATUS=19
: > "$MOCK_LOG"
expect_failure up 'Invalid Compose configuration propagates'
if grep -q 'network\|up -d' "$MOCK_LOG"; then fail 'Deployed invalid configuration'; fi
pass 'Configuration is checked before Docker mutations'
unset MOCK_CONFIG_STATUS
base_env
sh ./traefik.sh up > output
grep -q -- '--wait' "$MOCK_LOG" || fail 'Missing health wait'
if grep -q -- '--force-recreate' "$MOCK_LOG"; then fail 'Unnecessary recreation'; fi
pass 'Deployment waits for health without forced recreation'
grep -q -- '--profile certs rm --stop --force certs-exporter' "$MOCK_LOG" || fail 'Disabled exporter is left running'
pass 'Disabling the exporter explicitly removes its old container'
base_env
printf 'DASHBOARD_HOSTNAME=dashboard.example.com\n' >> .env
expect_failure up 'Missing dashboard credentials stop deployment'

base_env
# shellcheck disable=SC2016
hash='$2y$05$usesomesillystringfore7hnbRJHxXVLeakoG8K30oukPsA.ztMG'
escaped=$(printf '%s' "$hash" | sed 's/\$/\$\$/g')
printf 'DASHBOARD_LOGIN=reviewer\nDASHBOARD_PASSWORD_HASH=%s\n' "$escaped" >> .env
sh ./traefik-basic-auth.sh --import-env > output
[ "$(cat data/auth/dashboard.htpasswd)" = "reviewer:$hash" ] || fail 'Legacy hash changed'
pass 'Legacy bcrypt imports preserve exact hash bytes'
printf 'DASHBOARD_PASSWORD_HASH=invalid\n' >> .env
if sh ./traefik-basic-auth.sh --import-env > output 2>&1; then fail 'Invalid hash accepted'; fi
[ "$(cat data/auth/dashboard.htpasswd)" = "reviewer:$hash" ] || fail 'Invalid import overwrote credentials'
pass 'Invalid credential import preserves existing credentials'

base_env
printf 'LOG_ROTATE_TRIGGER_SIZE=1k\nLOG_ROTATE_MAX_BACKUPS=2\n' >> .env
mkdir -p data/logs
export MOCK_REOPEN_LOG="$work/data/logs/access.log"
head -c 2048 /dev/zero > "$MOCK_REOPEN_LOG"
cp "$MOCK_REOPEN_LOG" original-log
sh ./traefik-logrotate.sh > output
cmp original-log data/logs/access.log.1 || fail 'Legacy rotation lost log data'
if [ ! -f "$MOCK_REOPEN_LOG" ] || [ -s "$MOCK_REOPEN_LOG" ]; then
    fail 'Log was not reopened'
fi
pass 'Legacy rotation renames logs before signalling reopen'
cp original-log "$MOCK_REOPEN_LOG"
export MOCK_SIGNAL_STATUS=1
if sh ./traefik-logrotate.sh > output 2>&1; then fail 'Signal failure ignored'; fi
cmp original-log "$MOCK_REOPEN_LOG" || fail 'Signal failure destroyed the active log'
pass 'Legacy rotation restores the active log if reopening fails'
unset MOCK_SIGNAL_STATUS MOCK_REOPEN_LOG

if ! command -v jq >/dev/null 2>&1; then
    printf 'SKIP: certificate fixtures require jq and OpenSSL.\n'
    printf '%s checks passed.\n' "$count"
    exit 0
fi
base_env
mkdir -p data/acme
for domain in one.example.com two.example.com; do
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$domain.key" -out "$domain.pem" -days 2 -subj "/CN=$domain" >/dev/null 2>&1
done
jq -n --rawfile key1 one.example.com.key --rawfile cert1 one.example.com.pem \
    --rawfile key2 two.example.com.key --rawfile cert2 two.example.com.pem \
    '{resolver:{Certificates:[{domain:{main:"one.example.com"},key:($key1|@base64),certificate:($cert1|@base64)}, {domain:{main:"two.example.com"},key:($key2|@base64),certificate:($cert2|@base64)}]}}' > data/acme/acme.json
sh ./traefik-certs-extract.sh > output
cmp one.example.com.key data/certs/one.example.com.key || fail 'First certificate key mismatch'
cmp two.example.com.key data/certs/two.example.com.key || fail 'Second certificate key mismatch'
pass 'Multiple certificate objects retain their own private keys'
jq -c . data/acme/acme.json > compact.json
cp compact.json data/acme/acme.json
sh ./traefik-certs-extract.sh > output
cmp two.example.com.key data/certs/two.example.com.key || fail 'Compact JSON failed'
pass 'Compact JSON is supported'
jq '.resolver.Certificates[0].certificate |= ((@base64d | . + . + .) | @base64)' compact.json > data/acme/acme.json
sh ./traefik-certs-extract.sh > output
[ "$(grep -c 'BEGIN CERTIFICATE' data/certs/one.example.com.chain.pem)" = 2 ] || fail 'Lost intermediate chain certificates'
[ "$(grep -c 'BEGIN CERTIFICATE' data/certs/one.example.com.fullchain.pem)" = 3 ] || fail 'Lost full certificate chain'
pass 'All intermediate certificates are preserved in chain and fullchain outputs'

for failure in malformed empty mismatch invalid-domain invalid-base64 duplicate; do
    case "$failure" in
        malformed) printf '{' > data/acme/acme.json ;;
        empty) printf '{}' > data/acme/acme.json ;;
        mismatch) jq '.resolver.Certificates[1].key = .resolver.Certificates[0].key' compact.json > data/acme/acme.json ;;
        invalid-domain) jq '.resolver.Certificates[0].domain.main = "../../outside"' compact.json > data/acme/acme.json ;;
        invalid-base64) jq '.resolver.Certificates[1].key = "!!!"' compact.json > data/acme/acme.json ;;
        duplicate) jq '.resolver.Certificates[1].domain.main = "one.example.com"' compact.json > data/acme/acme.json ;;
    esac
    if sh ./traefik-certs-extract.sh > output 2>&1; then fail "Accepted $failure input"; fi
    cmp one.example.com.key data/certs/one.example.com.key || fail 'Destroyed existing first key'
    cmp two.example.com.key data/certs/two.example.com.key || fail 'Destroyed existing second key'
    pass "Certificate failure preserves existing exports: $failure"
done
[ ! -e outside.key ] || fail 'Path traversal'
pass 'Domain paths cannot escape the export directory'
if [ "$(uname -s)" = Linux ]; then
    [ "$(stat -c %a data/certs/two.example.com.key)" = 600 ] || fail 'Private key permissions'
    [ "$(stat -c %a data/acme/acme.json)" = 600 ] || fail 'ACME permissions'
    pass 'Private keys and ACME storage have mode 600'
fi
cp compact.json data/acme/acme.json
WATCH_INTERVAL=1 sh ./traefik-certs-extract.sh --watch > watch-output 2>&1 &
watch_pid=$!
sleep 2
kill "$watch_pid"
wait "$watch_pid" || true
grep -q 'Certificates exported' watch-output || fail 'Watch mode did not export'
pass 'Watch mode starts and handles termination'
printf '%s checks passed.\n' "$count"
