#!/bin/sh

private_ipv4() {
    printf '%s\n' "$1" | awk -F. '
        NF != 4 {exit 1}
        {for (i=1;i<=4;i++) if ($i !~ /^[0-9]+$/ || $i > 255) exit 1}
        !($1 == 10 || ($1 == 172 && $2 >= 16 && $2 <= 31) || ($1 == 192 && $2 == 168) || $1 == 127) {exit 1}'
}

validate_routes() {
    case "$XRAY_MODE" in true|false) ;; *) die 'XRAY_MODE must be true or false' ;; esac
    printf '%s\n' "$HTTPS_READ_TIMEOUT" | grep -Eq '^[0-9]+(ms|s|m|h)$' || die 'HTTPS_READ_TIMEOUT must be a duration such as 15m'
    if [ "$XRAY_MODE" = true ]; then
        [ "$HTTPS_PORT" != 443 ] || die 'Xray owns port 443; use HTTPS_PORT=2053 for its private Traefik listener'
        [ -n "$XRAY_TRUSTED_IPS" ] || die 'Set XRAY_TRUSTED_IPS to the Xray peer address or private Docker subnet'
        # Only explicit private IPv4 peers/subnets are accepted; never trust all clients.
        printf '%s\n' "$XRAY_TRUSTED_IPS" | grep -Eq '^[0-9./]+(,[0-9./]+)*$' || die 'XRAY_TRUSTED_IPS must be comma-separated IPv4 addresses or CIDRs'
        for peer in $(printf '%s' "$XRAY_TRUSTED_IPS" | tr ',' ' '); do
            private_ipv4 "${peer%/*}" || die 'Xray peers must be private IPv4 addresses'
            case "$peer" in */*)
                mask=${peer#*/}
                printf '%s\n' "$mask" | grep -Eq '^(8|9|[12][0-9]|3[0-2])$' || die 'Xray CIDR prefix must be between 8 and 32'
                case "$peer" in
                    172.*) [ "$mask" -ge 12 ] || die 'Xray CIDR includes public addresses' ;;
                    192.*) [ "$mask" -ge 16 ] || die 'Xray CIDR includes public addresses' ;;
                esac
            ;; esac
        done
    fi
    if [ -n "$XRAY_CERTS_DIR" ]; then
        case "$XRAY_CERTS_DIR" in /*) ;; *) die 'XRAY_CERTS_DIR must be absolute' ;; esac
        printf '%s\n' "$XRAY_CERTS_DIR" | grep -Eq '^/[A-Za-z0-9_./-]+$' || die 'XRAY_CERTS_DIR contains unsupported characters'
        case "/$XRAY_CERTS_DIR/" in */../*) die 'XRAY_CERTS_DIR must not contain parent traversal' ;; esac
    fi
    if [ -n "$BACKUP_HOSTNAME" ]; then
        [ "$BACKUP_HOSTNAME" != "$DASHBOARD_HOSTNAME" ] || die 'Use separate hostnames for the backup gateway and dashboard'
        printf '%s\n' "$BACKUP_HOSTNAME" | grep -Eq '^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$' || die 'Invalid BACKUP_HOSTNAME'
        printf '%s\n' "$BACKUP_BACKEND_URL" | grep -Eq '^http://[0-9.]+:[0-9]+$' || die 'BACKUP_BACKEND_URL must be http://PRIVATE_IPV4:PORT'
        backend=${BACKUP_BACKEND_URL#http://}
        private_ipv4 "${backend%:*}" || die 'Backup backend must use a private IPv4 address'
        case "${backend%:*}" in 127.*) die 'Use the Docker bridge gateway, not container loopback, for the backup backend' ;; esac
        valid_port BACKUP_BACKEND_URL "${backend##*:}"
    fi
}

generate_backup_route() {
    route="$ROOT/dynamic/vps-backup.yml"
    marker='# Managed by traefik.sh: VPS backup route'
    [ ! -L "$ROOT/dynamic" ] && [ ! -L "$route" ] || die 'Backup route paths must not be symlinks'
    if [ -e "$route" ] && [ "$(head -n 1 "$route")" != "$marker" ]; then
        [ -z "$BACKUP_HOSTNAME" ] || die 'dynamic/vps-backup.yml is hand-maintained; move it outside dynamic/ before enabling the generated backup route'
        return
    fi
    mkdir -p "$ROOT/dynamic"
    if [ -z "$BACKUP_HOSTNAME" ]; then
        rm -f "$route"
        return
    fi
    route_tmp=$(mktemp "$ROOT/dynamic/.vps-backup.XXXXXX")
    cat > "$route_tmp" <<YAML
$marker
http:
  routers:
    vps-backup:
      rule: Host(\`$BACKUP_HOSTNAME\`)
      entryPoints: [https]
      service: vps-backup
      tls:
        certResolver: letsencrypt
  services:
    vps-backup:
      loadBalancer:
        serversTransport: vps-backup
        servers:
          - url: "$BACKUP_BACKEND_URL"
  serversTransports:
    vps-backup:
      forwardingTimeouts:
        dialTimeout: 10s
        responseHeaderTimeout: 15m
        idleConnTimeout: 90s
YAML
    chmod 644 "$route_tmp"
    mv "$route_tmp" "$route"
}
