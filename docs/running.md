# Running and operating Traefik

Start with the [quick start](../README.md#quick-start). Run the commands below from the repository directory on the Docker host. Storage examples use the starter `DATA_DIR=./traefik-data`; substitute your configured path when it differs.

## Requirements

Use Linux, a POSIX shell with standard utilities, Docker Engine, and the Docker Compose plugin. The wrapper requires `docker compose up --wait --wait-timeout`; check `docker compose up --help` before deployment. The legacy `docker-compose` executable is not used.

Credential creation needs one of: `htpasswd` from `apache2-utils`, Python 3 with bcrypt, or Docker. The helper tries them in that order. Its Docker fallback uses the pinned httpd image in [traefik-basic-auth.sh](../traefik-basic-auth.sh). Generating a random password also requires OpenSSL. Password input is passed through stdin, not command-line arguments.

For export directly on the host, install `jq` and OpenSSL. The optional exporter container installs these through [Dockerfile.helper](../Dockerfile.helper).

For public HTTPS, set dashboard or application DNS to the server. Check both A and AAAA records: every published address must reach the intended server. HTTP-01 validation needs public TCP port 80 to reach the internal `http` entrypoint. HTTPS clients need port 443 to reach `https`. Publishing a different host port alone does not change these public requirements.

## Commands and paths

| Command | Effect |
| --- | --- |
| `sh traefik.sh generate` | Validate settings and replace `compose.generated.yaml`; no Docker calls |
| `sh traefik.sh validate` | Generate the override and run `docker compose config --quiet` |
| `sh traefik.sh up` | Validate, prepare storage and the external network, build the enabled exporter, and deploy with a health wait |
| `sh traefik.sh status` | Show project containers |
| `sh traefik.sh logs` | Show the last 100 log lines |
| `sh traefik.sh down` | Remove project containers and their networks; retain the configured external network and bind-mounted data |

With no argument, the wrapper runs `up`. Use the wrapper instead of bare `docker compose up`: it supplies both Compose files, the selected environment file, project name, and exporter profile. `down`, `status`, and `logs` require an existing generated override and still validate settings.

Script paths resolve from the repository. Relative `DATA_DIR` paths are relative to that directory. Select another settings file through the process environment:

```sh
ENV_FILE=/absolute/path/to/settings.env sh traefik.sh validate
```

`ENV_FILE` is not a setting inside `.env`. Values read from the selected file override environment variables with the same names; absent values use the existing environment or script defaults.

`up` replaces stale generated ports and dashboard labels, removes an exporter disabled since the previous deployment, and removes orphan project containers. It does not force Traefik recreation when its configuration and image are unchanged. Its health check verifies Traefik's internal ping endpoint. The exporter has no separate health check, and successful deployment does not establish public routing or certificate issuance.

## Configuration

[.env.example](../.env.example) contains starter values, including example custom ports. It is not the complete default configuration. The tables below describe runtime defaults from [lib/common.sh](../lib/common.sh), the helper scripts, and [compose.yaml](../compose.yaml).

Use one `KEY=value` per line. Values are literal and do not expand other variables or shell commands. Matching single or double quotes may enclose a value; quoted values should have comments on separate lines. Blank lines and lines beginning with `#` are ignored. For an unquoted value, a whitespace-prefixed `#` starts a comment. Unknown setting names are rejected.

| Setting | Runtime default | Meaning |
| --- | --- | --- |
| `DATA_DIR` | `./traefik-data` | Persistent ACME, credentials, and exports; use a path without dollar signs, backticks, quotes, or backslashes |
| `TZ` | `UTC` | Traefik container timezone environment |
| `LETSENCRYPT_EMAIL` | Empty; required by deployment wrapper | ACME account registration email |
| `TRAEFIK_IMAGE` | Pinned tag in `lib/common.sh` and `compose.yaml` | Traefik image; upgrade deliberately |
| `HELPER_IMAGE` | `traefik-compose-helper:local` | Tag assigned to the locally built exporter image |
| `PROJECT_NAME` | `traefik` | Compose project name; lowercase letters, digits, `_`, and `-`, starting with a letter or digit |
| `PROXY_NETWORK` | `proxy` | External Docker network name; letters, digits, `_`, `.`, and `-`, starting with a letter or digit |
| `CUSTOM_PORTS` | Empty | Space or comma separated ports; every port creates both TCP and UDP mappings |
| `DASHBOARD_HOSTNAME` | Empty | Empty disables the dashboard; otherwise use a DNS hostname |
| `DASHBOARD_LOGIN` | `admin` in the credential helper | Username used when `--username` is omitted |
| `CERTS_EXPORT` | `false` | Accepts `true` or `false`; enables or removes the exporter on `up` |
| `HTTP_PORT` | `80` | Host port mapped to internal HTTP port 80 |
| `HTTPS_PORT` | `443` | Host port mapped to internal HTTPS port 443 and dashboard redirect destination |
| `BIND_ADDRESS` | `0.0.0.0` | IPv4 address on which host ports are published |
| `ACME_CA_SERVER` | Production URL in `.env.example` | HTTPS ACME directory URL |
| `LOG_LEVEL` | `WARN` | `TRACE`, `DEBUG`, `INFO`, `WARN`, `ERROR`, `FATAL`, or `PANIC` |
| `LOG_ROTATE_TRIGGER_SIZE` | `10m` | Positive integer plus `k`, `m`, or `g`; suffix is case-insensitive |
| `LOG_ROTATE_MAX_BACKUPS` | `5` | Maximum Docker log files, including the active file |

Ports must be integers from 1 through 65535 without leading zeroes. HTTP and HTTPS host ports must differ. Custom ports cannot repeat, equal either HTTP/HTTPS host port, or use the internal reserved ports 80, 443, or 8080. Port 8080 is used internally for ping and is not published by the base configuration.

The following settings apply to host helpers. The Compose exporter supplies fixed container paths and a 10-second watch interval, so changing these in `.env` does not change that container's paths or interval.

| Setting | Host-helper default | Scope |
| --- | --- | --- |
| `ACME_FILE` | `${DATA_DIR}/acme/acme.json` | Certificate input |
| `CERTS_DIR` | `${DATA_DIR}/certs` | Export directory |
| `WATCH_INTERVAL` | `10` seconds | Host certificate watcher; positive integer |
| `LOGS_DIR` | `${DATA_DIR}/logs` | Legacy file-log directory |
| `LOGROTATE_INTERVAL` | `60` seconds | Legacy log watcher; positive integer |
| `TRAEFIK_CONTAINER` | `traefik` | Legacy container to signal with USR1 |
| `DASHBOARD_PASSWORD_HASH` | Empty | Legacy bcrypt import through `--import-env` only |

The host exporter and legacy log helper can run without `.env`; their default data root is `traefik-data` under the repository. Deployment and credential creation require the selected environment file.

For issuance tests, use the staging ACME URL shown in `.env.example` and a separate `DATA_DIR`. Staging certificates are not publicly trusted. Keep production and staging account/certificate storage separate.

## Dashboard credentials

The dashboard is optional. When enabled, both `/dashboard/` and `/api` require BasicAuth over HTTPS; its HTTP router redirects to HTTPS. The trailing slash in `/dashboard/` is part of the URL.

```sh
sh traefik-basic-auth.sh --username admin --generate
cat traefik-data/auth/dashboard-password.txt
```

The generated password is a random 48-character hexadecimal string. Use the complete string to log in. `dashboard-password.txt` contains that plaintext password; `dashboard.htpasswd` contains `username:bcrypt-hash` and cannot be used as the login password. Both files have mode 600 inside a mode 700 `auth` directory.

Save the password in your password manager. The plaintext file can then be removed if no longer needed; the dashboard uses only `dashboard.htpasswd`.

To enter your own password, run the helper without `--generate`. It prompts without displaying input. Automation can use `--password-stdin` with a password delivered on stdin. Passwords must be nonempty and at most 72 bytes. Interactive and stdin modes remove an existing generated plaintext password file; the helper does not save a supplied password.

For an existing deployment, explicitly preserve the intended username during rotation:

```sh
sh traefik-basic-auth.sh --username admin --generate --restart
```

Replace `admin` with your existing login. `--username` affects that invocation; it does not update `DASHBOARD_LOGIN` in `.env`. Keep the setting aligned if you later omit the option. The helper replaces the single-user credentials file. Failed hash generation leaves the existing credentials file intact.

`--restart` restarts Traefik to reload the mounted users file and waits for health. Omit it before the first deployment. Rotation replaces the password; rerunning a generated-password command creates another password.

## Application routing

Attach backends to the external network named by `PROXY_NETWORK` and set `traefik.enable=true`. No backend host-port publication is required. Give routers, services, and middlewares names unique to each application.

### HTTP and HTTPS

This example assumes an application listening on container port 8080. Replace the image and hostname, and set the network's `name` to your configured `PROXY_NETWORK` if it differs from `proxy`.

```yaml
services:
  app:
    image: your-application:version
    networks: [proxy]
    labels:
      traefik.enable: "true"
      traefik.http.routers.app-http.rule: Host(`app.example.com`)
      traefik.http.routers.app-http.entrypoints: http
      traefik.http.routers.app-http.service: app-web
      traefik.http.routers.app-http.middlewares: app-redirect
      traefik.http.middlewares.app-redirect.redirectscheme.scheme: https
      traefik.http.routers.app-https.rule: Host(`app.example.com`)
      traefik.http.routers.app-https.entrypoints: https
      traefik.http.routers.app-https.service: app-web
      traefik.http.routers.app-https.tls: "true"
      traefik.http.routers.app-https.tls.certresolver: letsencrypt
      traefik.http.services.app-web.loadbalancer.server.port: "8080"
networks:
  proxy:
    external: true
    name: proxy
```

This redirects to public HTTPS port 443. Set the redirect middleware's `redirectscheme.port` when clients use a different public HTTPS port. The dashboard's authentication and redirect do not apply to application routers; add application-specific middleware as needed.

### TCP and UDP

Include `51227` in `CUSTOM_PORTS` and deploy Traefik before using this example. The backend must listen on TCP and UDP port 51227 inside its container.

```yaml
services:
  app:
    image: your-application:version
    networks: [proxy]
    labels:
      traefik.enable: "true"
      traefik.tcp.routers.app-51227.rule: HostSNI(`*`)
      traefik.tcp.routers.app-51227.entrypoints: tcp-51227
      traefik.tcp.routers.app-51227.service: app-51227
      traefik.tcp.services.app-51227.loadbalancer.server.port: "51227"
      traefik.udp.routers.app-51227.entrypoints: udp-51227
      traefik.udp.routers.app-51227.service: app-51227
      traefik.udp.services.app-51227.loadbalancer.server.port: "51227"
networks:
  proxy:
    external: true
    name: proxy
```

For a different network, change `name`. EntryPoint names follow `tcp-PORT` and `udp-PORT`. The TCP example forwards raw TCP without TLS termination; UDP routing uses its dedicated entrypoint.

## Certificates and persistent data

Traefik persists its ACME account and certificates in `${DATA_DIR}/acme/acme.json` with mode 600. Setting `CERTS_EXPORT=true` enables a locally built exporter with a read-only ACME mount, a writable export directory, no Docker socket, and no network access.

For a host export:

```sh
sh traefik-certs-extract.sh --once
sh traefik-certs-extract.sh --watch
```

The watcher checks for changed ACME content and retries failed exports. Before the first certificate is available, an empty input is not exported. A one-shot export fails for missing, empty, malformed, or certificate-free input.

Each primary domain produces `.key`, `.crt` (leaf certificate), `.chain.pem` (remaining chain), and `.fullchain.pem`. Wildcard filenames contain a literal `*`; quote them in shell commands. SAN names remain in the certificate and do not get separate filename aliases. Duplicate primary domains across resolvers are rejected.

The exporter parses JSON objects with `jq`, validates certificate/key correspondence with OpenSSL, and stages the whole input before replacing exports. Each file is renamed atomically; the set of files is not an atomic transaction for concurrent readers. Invalid input leaves existing exports intact. Removed domains remain until explicitly deleted. Exports have mode 600 inside a mode 700 directory; configure consumer access for the required user or group.

### Backup and restore

Back up the selected `.env` and the complete `DATA_DIR`; they identify the deployment and include ACME account credentials, private keys, and dashboard credentials. Store backups with restricted access.

For a consistent offline copy using the starter data path:

```sh
sh traefik.sh down
cp -p .env .env.backup
cp -a traefik-data traefik-data.backup
sh traefik.sh up
```

Use new backup destinations. To restore, stop the project, copy the saved environment file and data directory back to their configured paths, retain their ownership and permissions, and run `validate`, then `up`. Container removal also removes Docker-managed container logs; retain required logs separately before `down`.

## Logging and Docker access

Traefik writes JSON logs to stdout/stderr. Docker rotates them according to the log size and file-count settings. Use `sh traefik.sh logs` to inspect them. No log-rotation sidecar is used.

The API's insecure access is disabled, Docker discovery is opt-in, and Traefik runs with reduced Linux capabilities. The internal ping entrypoint is not a public API endpoint. Traefik still mounts the Docker socket for discovery: a read-only bind mount does not restrict Docker API operations. Treat this as privileged access and use trusted images and host accounts.

The legacy `traefik-logrotate.sh` operates only on existing file logs. It renames logs and signals the configured legacy container with USR1. It requires Docker access and supports `--once` or `--watch`; new deployments use Docker-managed logs instead.

## Migrating an older checkout

1. Back up `.env` and the complete data directory.
2. Keep the existing data path, custom ports, registration email, and hostname settings. Keep `DASHBOARD_LOGIN` aligned with the login you want to retain.
3. Import an existing bcrypt hash with `sh traefik-basic-auth.sh --import-env`. This reads `DASHBOARD_PASSWORD_HASH` and normalizes Compose-escaped dollar signs. Invalid hashes, including output from the old homemade APR1 fallback, require fresh credentials. Importing a hash cannot recover its plaintext password or create a matching plaintext file; remove any previous `dashboard-password.txt` that belongs to different credentials.
4. Stop the old stack with its original Compose files before starting the replacement. Older fixed container names differ from the new Compose-managed names. Retain the ACME data directory.
5. Run `generate`, `validate`, and `up`. Old ignored `docker-compose*.yml` files are no longer used. Logging moves from `${DATA_DIR}/logs` to Docker-managed logs.

## Troubleshooting

| Symptom | Checks and recovery |
| --- | --- |
| Dashboard rejects a password | Use the plaintext password, not `username:hash`. Check the username used when credentials were created. After changing credentials for an existing deployment, use `--restart` to reload them. |
| Healthy container, untrusted or default certificate | Check DNS A/AAAA records, public port 80 reachability, registration email, and Traefik logs. Confirm production rather than staging ACME configuration. Ping health does not verify issuance. |
| Application returns 404 | Check `traefik.enable`, router hostname and entrypoint, and unique router names. For custom ports, regenerate and deploy the matching entrypoint. |
| Application returns 502 | Check that Traefik and the backend share the configured external network and that the service label names the backend's internal listening port. |
| Export is missing or stale | Check exporter logs, whether ACME contains an issued certificate, and access to the data directory. Invalid input is retried while previous exports remain available. |
| Package downloads or outbound TLS stall inside containers | Compare the host interface and Docker bridge MTUs using `ip link` and `docker network inspect`. A cloud-link MTU mismatch is one possible cause; confirm it before changing Docker's network configuration. |

Use [verification tools](conventions.md#deployment-probes) for dashboard checks and isolated end-to-end routing tests.
