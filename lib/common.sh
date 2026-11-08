#!/bin/sh
# Values in .env are data, never evaluated as shell code.
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

load_env() {
    [ -f "$ENV_FILE" ] || die "Missing $ENV_FILE; copy .env.example first."
    while IFS= read -r env_line || [ -n "$env_line" ]; do
        env_line=$(printf '%s' "$env_line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        case "$env_line" in ''|'#'*) continue ;; esac
        case "$env_line" in *=*) ;; *) die "Expected KEY=value in $ENV_FILE" ;; esac
        env_name=${env_line%%=*}
        env_value=${env_line#*=}
        case "$env_name" in
            DATA_DIR|TZ|LETSENCRYPT_EMAIL|ACME_CA_SERVER|CUSTOM_PORTS|DASHBOARD_HOSTNAME|DASHBOARD_LOGIN|DASHBOARD_PASSWORD_HASH|TRAEFIK_IMAGE|HELPER_IMAGE|PROJECT_NAME|PROXY_NETWORK|CERTS_EXPORT|LOG_LEVEL|LOG_ROTATE_MAX_BACKUPS|LOG_ROTATE_TRIGGER_SIZE|HTTP_PORT|HTTPS_PORT|BIND_ADDRESS|WATCH_INTERVAL|ACME_FILE|CERTS_DIR|LOGS_DIR|LOGROTATE_INTERVAL|TRAEFIK_CONTAINER) ;;
            *) die "Unsupported setting: $env_name" ;;
        esac
        case "$env_value" in
            \"*\") env_value=${env_value#\"}; env_value=${env_value%\"} ;;
            \'*\') env_value=${env_value#\'}; env_value=${env_value%\'} ;;
            *) env_value=$(printf '%s' "$env_value" | sed 's/[[:space:]]#.*$//;s/[[:space:]]*$//') ;;
        esac
        export "$env_name=$env_value"
    done < "$ENV_FILE"
}

positive_integer() {
    case "$2" in ''|*[!0-9]*|0|0*) die "$1 must be a positive integer without leading zeroes" ;; esac
    [ "${#2}" -le 9 ] || die "$1 is too large"
}

valid_port() {
    positive_integer "$1" "$2"
    [ "$2" -le 65535 ] || die "$1 must be between 1 and 65535"
}

defaults() {
    : "${DATA_DIR:=./traefik-data}" "${TZ:=UTC}" "${TRAEFIK_IMAGE:=traefik:v3.7.17}"
    : "${HELPER_IMAGE:=traefik-compose-helper:local}" "${PROJECT_NAME:=traefik}" "${PROXY_NETWORK:=proxy}"
    : "${CERTS_EXPORT:=false}" "${LOG_LEVEL:=WARN}" "${LOG_ROTATE_MAX_BACKUPS:=5}" "${LOG_ROTATE_TRIGGER_SIZE:=10m}"
    : "${HTTP_PORT:=80}" "${HTTPS_PORT:=443}" "${BIND_ADDRESS:=0.0.0.0}"
    : "${ACME_CA_SERVER:=https://acme-v02.api.letsencrypt.org/directory}"
    : "${LETSENCRYPT_EMAIL:=}" "${CUSTOM_PORTS:=}" "${DASHBOARD_HOSTNAME:=}"
    export DATA_DIR TZ TRAEFIK_IMAGE HELPER_IMAGE PROJECT_NAME PROXY_NETWORK CERTS_EXPORT LOG_LEVEL
    export LOG_ROTATE_MAX_BACKUPS LOG_ROTATE_TRIGGER_SIZE HTTP_PORT HTTPS_PORT BIND_ADDRESS ACME_CA_SERVER LETSENCRYPT_EMAIL
}

compose() {
    if [ "$CERTS_EXPORT" = true ]; then
        docker compose --project-directory "$ROOT" --env-file "$ENV_FILE" -p "$PROJECT_NAME" \
            -f "$ROOT/compose.yaml" -f "$ROOT/compose.generated.yaml" --profile certs "$@"
    else
        docker compose --project-directory "$ROOT" --env-file "$ENV_FILE" -p "$PROJECT_NAME" \
            -f "$ROOT/compose.yaml" -f "$ROOT/compose.generated.yaml" "$@"
    fi
}
