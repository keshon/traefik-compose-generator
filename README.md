# Traefik Compose helper

Deploy Traefik with Docker discovery, custom TCP/UDP entrypoints, an optional dashboard protected by BasicAuth, and an optional certificate exporter. Configure `.env` and use the shell wrapper to generate and deploy the Compose configuration.

## Requirements

- Linux server with Docker Engine and the Docker Compose plugin supporting `up --wait --wait-timeout`.
- POSIX shell and standard utilities. See [dependencies](docs/running.md#requirements) for credential and host-export tools.
- For public HTTPS: DNS pointing to the server and public TCP ports 80 and 443 reaching Traefik.

## Quick start

```sh
cp .env.example .env
# Set LETSENCRYPT_EMAIL, CUSTOM_PORTS, and optionally DASHBOARD_HOSTNAME.
sh build-n-run.sh generate
sh build-n-run.sh validate

# Only needed when DASHBOARD_HOSTNAME is set:
sh traefik-basic-auth.sh --username admin --generate

sh build-n-run.sh up
sh build-n-run.sh status
```

When enabled, open `https://YOUR_HOST/dashboard/`. Log in with the username chosen above and the complete generated password from `${DATA_DIR}/auth/dashboard-password.txt`. This is a random hexadecimal password, not the bcrypt hash stored in `dashboard.htpasswd`. See [dashboard credentials](docs/running.md#dashboard-credentials) for retrieval, custom passwords, and rotation.

The tracked [compose.yaml](compose.yaml) defines the services. The wrapper replaces the ignored `compose.generated.yaml` with the configured entrypoints and dashboard labels. Application routing labels belong in each application's Compose file.

## Guides

- [Running and operating Traefik](docs/running.md): configuration, commands, HTTP/HTTPS and TCP/UDP routing, credentials, certificate export, backup, migration, and troubleshooting.
- [Development and verification](docs/conventions.md): source ownership, local checks, CI coverage, and tests that create or restart containers.
- [.env.example](.env.example): copyable starter settings. Runtime defaults are defined in [lib/common.sh](lib/common.sh).

## License

[MIT](LICENSE)
