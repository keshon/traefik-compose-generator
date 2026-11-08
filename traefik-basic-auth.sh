#!/bin/sh
set -eu
umask 077
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"
. "$ROOT/lib/common.sh"
ENV_FILE=${ENV_FILE:-$ROOT/.env}
load_env
defaults
username=${DASHBOARD_LOGIN:-admin}
mode=interactive
restart=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --username) [ "$#" -ge 2 ] || die 'Missing username'; username=$2; shift ;;
        --generate) mode=generate ;;
        --password-stdin) mode=stdin ;;
        --import-env) mode=import ;;
        --restart) restart=true ;;
        --skip-restart) restart=false ;;
        --help|-h) printf 'Usage: sh traefik-basic-auth.sh [--username USER] [--generate|--password-stdin|--import-env] [--restart]\n'; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
    shift
done
printf '%s\n' "$username" | grep -Eq '^[a-zA-Z0-9_.@-]+$' || die 'Invalid username'
mkdir -p "$DATA_DIR/auth"
chmod 700 "$DATA_DIR/auth"
tmp=$(mktemp "$DATA_DIR/auth/.htpasswd.XXXXXX")
trap 'rm -f "$tmp"; if [ "${terminal_hidden:-false}" = true ]; then stty echo; fi' EXIT
if [ "$mode" = import ]; then
    # Old versions stored Compose-escaped hashes. Never source them as shell code.
    hash=$(printf '%s' "${DASHBOARD_PASSWORD_HASH:-}" | sed 's/\$\$/\$/g')
    printf '%s\n' "$hash" | grep -Eq '^[$]2[aby][$][0-9]{2}[$][./A-Za-z0-9]{53}$' || die 'Legacy value is not a bcrypt hash; generate fresh credentials'
    printf '%s:%s\n' "$username" "$hash" > "$tmp"
else
    case "$mode" in
        generate)
            command -v openssl >/dev/null 2>&1 || die 'OpenSSL is required to generate a password'
            password=$(openssl rand -hex 24)
            ;;
        stdin) IFS= read -r password || [ -n "${password:-}" ] || die 'No password on stdin' ;;
        interactive)
            [ -t 0 ] || die 'Use --generate or --password-stdin without a terminal'
            printf 'Dashboard password: ' >&2
            terminal_hidden=true
            stty -echo
            IFS= read -r password
            stty echo
            terminal_hidden=false
            printf '\n' >&2
            ;;
    esac
    [ -n "$password" ] || die 'Password must not be empty'
    password_bytes=$(printf '%s' "$password" | wc -c | tr -d ' ')
    [ "$password_bytes" -le 72 ] || die 'Bcrypt passwords must not exceed 72 bytes'
    if command -v htpasswd >/dev/null 2>&1; then
        printf '%s\n' "$password" | htpasswd -niBC 12 "$username" > "$tmp"
    elif command -v python3 >/dev/null 2>&1 && python3 -c 'import bcrypt' 2>/dev/null; then
        hash=$(printf '%s\n' "$password" | python3 -c 'import sys,bcrypt; print(bcrypt.hashpw(sys.stdin.buffer.readline().rstrip(b"\n"), bcrypt.gensalt(rounds=12)).decode())')
        printf '%s:%s\n' "$username" "$hash" > "$tmp"
    elif command -v docker >/dev/null 2>&1; then
        printf '%s\n' "$password" | docker run --rm -i --entrypoint htpasswd httpd:2.4.69-alpine3.24 -niBC 12 "$username" > "$tmp"
    else
        die 'Install htpasswd (apache2-utils), Python bcrypt, or Docker; bcrypt is required'
    fi
    # htpasswd emits an extra blank line on some platforms.
    sed '/^$/d' "$tmp" > "$tmp.clean"
    mv "$tmp.clean" "$tmp"
    grep -Eq '^[^:]+:[$]2[aby][$][0-9]{2}[$][./A-Za-z0-9]{53}$' "$tmp" || die 'Hash generation failed'
    if [ "$mode" = generate ]; then
        password_tmp=$(mktemp "$DATA_DIR/auth/.password.XXXXXX")
        printf '%s\n' "$password" > "$password_tmp"
        chmod 600 "$password_tmp"
        mv "$password_tmp" "$DATA_DIR/auth/dashboard-password.txt"
        printf 'Generated password saved to %s/auth/dashboard-password.txt (mode 600).\n' "$DATA_DIR"
    else
        rm -f "$DATA_DIR/auth/dashboard-password.txt"
    fi
    unset password
fi
chmod 600 "$tmp"
mv "$tmp" "$DATA_DIR/auth/dashboard.htpasswd"
printf 'Dashboard credentials saved for %s.\n' "$username"
if [ "$restart" = true ]; then
    compose restart traefik
    compose up -d --wait --wait-timeout 120 traefik
else
    printf 'For an existing deployment, rerun with --restart to reload credentials.\n'
fi
