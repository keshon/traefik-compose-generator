# VPS Backup with Xray

Use this on the backup server. Other VPS only need their backup clients.
Xray keeps public port 443 and forwards web TLS to Traefik, which sends the
backup hostname to the host's gateway on port 8787.

## With Xray

Add these settings to `.env`, using your hostname and network addresses:

```dotenv
XRAY_MODE=true
HTTPS_PORT=2053
XRAY_TRUSTED_IPS=172.19.0.10/32
XRAY_CERTS_DIR=/opt/dockers/xray-stack/shared/certs
BACKUP_HOSTNAME=backup.example.com
BACKUP_BACKEND_URL=http://172.19.0.1:8787
```

Check the Xray container address and Docker bridge gateway on your host:

```sh
docker inspect 3x-ui --format '{{range .NetworkSettings.Networks}}{{println .IPAddress}}{{end}}'
docker network inspect proxy --format '{{json .IPAM.Config}}'
```

Use the Xray peer address seen by Traefik. An exact address trusts only that
peer; a private subnet also permits peers whose addresses change on recreation.
Keep `XRAY_CERTS_DIR` if an existing dynamic TLS file uses `/certs/...`.

The generator publishes `127.0.0.1:2053` to Traefik's internal `8443` and keeps
redirects pointed at public 443. An Xray container on the proxy network can
reach Traefik directly on port 8443. Container loopback is not host loopback.
Keep the existing working Xray destination; the script does not edit Xray.

Xray must forward the original TLS stream, optionally preceded by PROXY
protocol v1 or v2. A TLS-terminating fallback that sends plain HTTP needs a
different listener. See the official [Traefik entrypoint settings](https://doc.traefik.io/traefik/reference/install-configuration/entrypoints/)
and [Xray fallback options](https://xtls.github.io/en/config/features/fallback.html).

## Existing deployment

The wrapper mounts `./dynamic` read-only at `/dynamic` and enables file watching.
Keep existing TLS files and unrelated routes there.

If `dynamic/vps-backup.yml` was created by hand, the script refuses to replace
it. During a maintenance window, move it outside the watched directory, then
generate the replacement:

```sh
mv dynamic/vps-backup.yml vps-backup.previous.yml
sh traefik.sh validate
```

Moving an active route briefly removes it until generation restores it.
Clearing `BACKUP_HOSTNAME` removes only a route created by this script.

Before replacing a legacy deployment, save `.env`, `dynamic/`, the existing
Compose files, and persistent data. Preserve the data mounts and project name.
If an older deployment has a separate certificate dumper absent from this
repository, preserve its service in `compose.local.yaml` and set
`EXTRA_COMPOSE_FILE` to that file's absolute path. The wrapper loads it after
the generated configuration, so the service remains managed during orphan
cleanup. Keep its existing script, image, and certificate mounts.

For an installation already managed by this generator:

```sh
sh traefik.sh validate
sh traefik.sh up
curl -sS -o /dev/null -w '%{http_code}\n' https://backup.example.com/
```

Expect `401`: the gateway requires a login. Also check another website and
your Xray client. The backup gateway must already listen on the configured
private address; see [VPS Backup setup](https://github.com/keshon/vps-backup/blob/main/docs/traefik.md).

## Without Xray

Let Traefik own public HTTPS and enable the same backup route:

```dotenv
XRAY_MODE=false
HTTPS_PORT=443
BACKUP_HOSTNAME=backup.example.com
BACKUP_BACKEND_URL=http://172.19.0.1:8787
```

With a backup route enabled, the HTTPS request-read timeout defaults to `15m`.
Override it with `HTTPS_READ_TIMEOUT`. This applies to the shared HTTPS
entrypoint. The route has no buffering middleware and preserves Authorization.
