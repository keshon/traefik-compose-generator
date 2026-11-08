#!/bin/sh
set -eu
umask 077
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"
. "$ROOT/lib/common.sh"
ENV_FILE=${ENV_FILE:-$ROOT/.env}
if [ -f "$ENV_FILE" ]; then load_env; fi
: "${ACME_FILE:=${DATA_DIR:-$ROOT/traefik-data}/acme/acme.json}"
: "${CERTS_DIR:=${DATA_DIR:-$ROOT/traefik-data}/certs}"
: "${WATCH_INTERVAL:=10}"
export ACME_FILE CERTS_DIR WATCH_INTERVAL
positive_integer WATCH_INTERVAL "$WATCH_INTERVAL"
for dependency in jq openssl; do
    command -v "$dependency" >/dev/null 2>&1 || die "Install $dependency to export certificates"
done
case "${1:---once}" in
    --watch)
        last_checksum=''
        trap 'exit 0' TERM INT
        while :; do
            checksum=''
            if [ -s "$ACME_FILE" ]; then checksum=$(cksum "$ACME_FILE" 2>/dev/null || true); fi
            if [ -n "$checksum" ] && [ "$checksum" != "$last_checksum" ]; then
                # A child process keeps strict error handling active, including on decode failure.
                if sh "$ROOT/traefik-certs-extract.sh" --once; then
                    last_checksum=$checksum
                else
                    printf 'Certificate export failed; retaining existing files and retrying.\n' >&2
                fi
            fi
            sleep "$WATCH_INTERVAL" & wait "$!" || true
        done
        ;;
    --once) ;;
    --help|-h) printf 'Usage: sh traefik-certs-extract.sh [--once|--watch]\n'; exit 0 ;;
    *) die "Unknown argument: $1" ;;
esac
[ -s "$ACME_FILE" ] || die "ACME file is missing or empty: $ACME_FILE"
mkdir -p "$CERTS_DIR"
chmod 700 "$CERTS_DIR"
stage=$(mktemp -d "$CERTS_DIR/.staging.XXXXXX")
trap 'rm -rf "$stage"' EXIT
cp "$ACME_FILE" "$stage/acme.json"
# Read complete certificate objects, independent of indentation, key order, or resolver.
jq -e 'type == "object"' "$stage/acme.json" >/dev/null
jq -r '[.[] | .Certificates[]?] | .[] | @base64' "$stage/acme.json" > "$stage/objects"
[ -s "$stage/objects" ] || die 'No certificates found; retaining existing exports'
while IFS= read -r object; do
    printf '%s' "$object" | base64 -d > "$stage/object.json"
    domain=$(jq -er '.domain.main | strings' "$stage/object.json")
    printf '%s\n' "$domain" | grep -Eq '^(\*\.)?([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$' || die 'Invalid domain in ACME file'
    [ ! -f "$stage/$domain.key" ] || die "Duplicate certificate for $domain across resolvers"
    jq -er '.key | strings | select(length > 0)' "$stage/object.json" > "$stage/base64"
    base64 -d < "$stage/base64" > "$stage/$domain.key"
    jq -er '.certificate | strings | select(length > 0)' "$stage/object.json" > "$stage/base64"
    base64 -d < "$stage/base64" > "$stage/$domain.fullchain.pem"
    openssl pkey -in "$stage/$domain.key" -pubout > "$stage/key.pub" 2>/dev/null
    openssl x509 -in "$stage/$domain.fullchain.pem" -pubkey -noout > "$stage/cert.pub" 2>/dev/null
    cmp -s "$stage/key.pub" "$stage/cert.pub" || die "Certificate/key mismatch for $domain"
    openssl crl2pkcs7 -nocrl -certfile "$stage/$domain.fullchain.pem" -out "$stage/chain.p7b" 2>/dev/null
    openssl pkcs7 -in "$stage/chain.p7b" -print_certs -noout >/dev/null 2>&1
    openssl x509 -in "$stage/$domain.fullchain.pem" -out "$stage/$domain.crt" 2>/dev/null
    awk '/-----BEGIN CERTIFICATE-----/ {count++} count > 1 {print}' "$stage/$domain.fullchain.pem" > "$stage/$domain.chain.pem"
done < "$stage/objects"
# Decode and check the whole input before touching an existing export. Each rename is atomic.
# Keep removed domains until an administrator explicitly deletes their exports.
for file in "$stage"/*.key "$stage"/*.crt "$stage"/*.pem; do
    [ -f "$file" ] || continue
    chmod 600 "$file"
    mv "$file" "$CERTS_DIR/$(basename "$file")"
done
printf 'Certificates exported to %s\n' "$CERTS_DIR"
