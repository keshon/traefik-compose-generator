# Development and verification

See [running.md](running.md) for deployment and operation. Run contributor commands from the repository root. Keep hostnames, emails, passwords, private keys, and ACME data out of committed examples.

## Source ownership

| Source | Responsibility |
| --- | --- |
| `lib/common.sh` | Allowed settings, literal environment-file parsing, deployment defaults, Compose invocation |
| `compose.yaml` | Service definitions, mounts, health check, logging, exporter profile |
| `traefik.sh` | Settings validation, generated entrypoints and dashboard labels, deployment lifecycle |
| `traefik-basic-auth.sh` | Bcrypt credentials, password input modes, optional restart |
| `traefik-certs-extract.sh` | Staged certificate/key export and retrying watcher |
| `traefik-logrotate.sh` | Compatibility with legacy file logs |
| `Dockerfile.helper` | Exporter dependencies and copied runtime files |

Edit `.env` for a deployment and `.env.example` for starter settings. Generated Compose output is ignored and replaced by the wrapper. When defaults or accepted settings change, update [the operator reference](running.md#configuration). When image versions change, check all source definitions and test fallbacks that use them.

Shell scripts target POSIX `sh` and use LF endings through `.gitattributes`. Documentation uses `sh script.sh` so invocation does not depend on executable file modes. Keep password input off command-line arguments and avoid printing credentials in test failures.

## Local checks

Run shell syntax and lint checks:

```sh
for file in *.sh lib/*.sh tests/*.sh; do sh -n "$file" || exit; done
shellcheck -x --shell sh ./*.sh lib/*.sh tests/*.sh
sh tests/run.sh
python3 tests/auth.py
```

Install ShellCheck, `jq`, OpenSSL, and Python 3 with bcrypt for the complete set. Credential round trips additionally need a supported hashing backend: `htpasswd`, Python bcrypt, or Docker. On Debian/Ubuntu, the package names used by CI are `shellcheck`, `jq`, `openssl`, `apache2-utils`, and `python3-bcrypt`.

| Check | Coverage and side effects |
| --- | --- |
| `sh tests/run.sh` | Temporary copy with mocked Docker calls; generation, invalid settings, failure propagation, legacy credentials/log rotation, and certificate fixtures. Does not read the checkout's `.env` or deploy containers. |
| `python3 tests/auth.py` | Temporary credentials; special characters, password length limits, bcrypt round trips, output secrecy, and permissions. Needs Python bcrypt for verification and may use Docker for hashing if no host backend is available. |
| `python3 tests/auth.py --docker-fallback` | Same verification, with a restricted tool path forcing the pinned Docker hashing backend; pulls/runs disposable containers. Requires symlink support. |

`tests/run.sh` skips certificate fixtures if `jq` is missing. With `jq` present, OpenSSL is also required. POSIX permission assertions in `tests/auth.py` run on POSIX systems; ACME/export permission assertions in `tests/run.sh` run on Linux. A passing partial run is not evidence that skipped fixtures passed.

Compose validation generates an override and needs Docker Compose, but does not start containers:

```sh
ENV_FILE=/absolute/path/to/test-settings.env sh traefik.sh validate
```

Use a dedicated settings file for example validation. Do not overwrite a developer's `.env` to run checks.

## CI

[The Checks workflow](../.github/workflows/test.yaml) runs on pushes and pull requests. It installs test dependencies, checks shell syntax and ShellCheck, runs the regression fixtures and bcrypt round trips, and validates Compose with the dashboard/exporter disabled and enabled.

CI does not run the live routing, exporter-container, dashboard, or forced Docker hashing tests. Those are opt-in checks below. The live deployment was exercised with Docker Engine 29.9.3 and Docker Compose v5.7.0; this does not establish a tested minimum version.

## Deployment probes

These commands require their stated deployment state and can contact or change Docker services. Tests that use configured deployment files honor the process-level `ENV_FILE`; see [configuration selection](running.md#commands-and-paths).

### Exporter container

Build the helper image on a test host with the selected settings:

```sh
docker build -f Dockerfile.helper -t traefik-compose-helper:local .
sh tests/exporter.sh
```

Use the configured `HELPER_IMAGE` tag if it differs. The test needs host `jq` and OpenSSL. It creates temporary ACME data and a disposable exporter with isolated bind mounts, no network, and reduced capabilities. It checks initial export, corrupt-input recovery, renewed certificate/key data, and permissions. It removes its container and fixture directory and does not read the deployment's ACME storage.

### Dashboard

Run against a configured dashboard with a generated password file available on the probing host:

```sh
python3 tests/dashboard.py dashboard.example.com ./traefik-data/auth
```

This verifies the HTTP redirect, trusted HTTPS, and missing/wrong/correct credentials for `/dashboard/` and `/api/rawdata`. It connects to loopback by default while validating the supplied hostname. Use `--address SERVER_IP` for a remote endpoint and `--http-port` / `--https-port` for nondefault published ports. The credential-directory argument is a local path on the probing host.

`--rotate` replaces the actual dashboard password, restarts Traefik, and checks that the old password stops working. Use it only when credential replacement and a service interruption are intended. `--allow-untrusted` skips certificate trust validation for isolated tests with Traefik's default certificate; omit it for public TLS verification.

### HTTP, TCP, and UDP

Use an isolated deployment with an unused first `CUSTOM_PORTS` entry and loopback-accessible published ports. The test requires host Python 3 and curl and pulls the pinned Python image in [tests/live.sh](../tests/live.sh).

```sh
sh tests/live.sh
# Also restart Traefik and repeat traffic probes:
sh tests/live.sh --restart
```

Both forms run the deployment wrapper's `up` command before creating test backends and again for the idempotence check. They can build images, apply configuration, recreate changed containers, remove orphan project services, and remove a disabled exporter. `--restart` additionally interrupts Traefik and tests recovery.

The test attaches disposable labelled and unlabelled backends to the configured proxy network. It sends 100 HTTP, 100 TCP, and 100 UDP requests, checks that the unlabelled backend is unrouted, and checks that an unchanged redeployment preserves the Traefik container. Restart mode repeats the traffic probes. Cleanup removes test backends.

For a probe from another machine, keep the backend alive briefly:

```sh
LIVE_TEST_HOLD_SECONDS=45 sh tests/live.sh
```

While it is running, use this on the other machine:

```sh
python3 tests/probe.py SERVER_IP HTTP_PORT CUSTOM_PORT
```

`LIVE_TEST_HOLD_SECONDS` belongs in the process environment, not `.env`. A local loopback pass does not establish public firewall, DNS, or TLS behavior; the separate external and dashboard probes cover those paths.
