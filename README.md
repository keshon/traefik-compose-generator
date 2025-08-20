# Traefik docker-compose generator

Generator for Traefik Proxy `docker-compose.yml` file with **custom TCP/UDP ports** mapping.  

In other words no manual editing of docker-compose is needed. Just define your custom ports in the .env file, and the script will automatically generate all the necessary port mappings, entrypoints, and labels for you Traefik instance.


## The problem

Traefik is amazing, but its default behavior can be a bit tricky for custom ports. By default, Traefik only listens on HTTP/HTTPS (ports 80 and 443). Unlike nginx, which will start listening on any configured port immediately, Traefik requires explicit configuration of entrypoints, routers, and services for each TCP or UDP port.

This means that if you want Traefik to handle traffic on custom TCP/UDP ports, you have to declare them. For Docker users, that also means adding the proper labels to each service so Traefik knows how to route the traffic.

These scripts make this process easier: just define your custom ports in .env, run the generator, and it will automatically generate the necessary Docker-compose port mappings, Traefik entrypoints, routers, and service labels. No manual editing of docker-compose.yml is required.


## Commands

Rebuild `docker-compose.yml`:

```bash
./generate-compose.sh
````

Generate auth and write it into `.env`:

```bash
./generate-auth.sh
```

## Usage

1. Copy `.env.example` to `.env` and set values:

   ```ini
   TZ=Europe/Amsterdam
   LOG_LEVEL=WARN
   LETSENCRYPT_EMAIL=you@example.com

   CUSTOM_PORTS=51227,58526,31223

   # Alternative format:
   # CUSTOM_PORTS=51227,58526,31223

   # Basic auth (leave empty to auto-generate)
   DASHBOARD_HOSTNAME=traefik.domain.tld
   DASHBOARD_LOGIN=
   DASHBOARD_PASSWORD_HASH=
   ```

2. Run the generator:

   ```bash
   ./generate-compose.sh
   ```

3. The script will:

    * generate `docker-compose.yml`
    * check that the `proxy` network exists (create it if not)
    * call `./generate-auth.sh` if `LOGIN` or `PASSWORD_HASH` is missing
    * restart Traefik

## Example: using new ports in services

Add `labels:` to the service section in your `docker-compose.yml`.
Example (`CUSTOM_PORTS=51227,58526`):

```yaml
labels:
  - "traefik.enable=true"

  # TCP 51227
  - "traefik.tcp.routers.app-51227.rule=HostSNI(`*`)"
  - "traefik.tcp.routers.app-51227.entrypoints=tcp-51227"
  - "traefik.tcp.routers.app-51227.service=app-51227"
  - "traefik.tcp.services.app-51227.loadbalancer.server.port=51227"

  # UDP 51227
  - "traefik.udp.routers.app-51227.entrypoints=udp-51227"
  - "traefik.udp.routers.app-51227.service=app-51227"
  - "traefik.udp.services.app-51227.loadbalancer.server.port=51227"

  # TCP 58526
  - "traefik.tcp.routers.app-58526.rule=HostSNI(`*`)"
  - "traefik.tcp.routers.app-58526.entrypoints=tcp-58526"
  - "traefik.tcp.routers.app-58526.service=app-58526"
  - "traefik.tcp.services.app-58526.loadbalancer.server.port=58526"

  # UDP 58526
  - "traefik.udp.routers.app-58526.entrypoints=udp-58526"
  - "traefik.udp.routers.app-58526.service=app-58526"
  - "traefik.udp.services.app-58526.loadbalancer.server.port=58526"
```

## FAQ

**Traefik doesn’t listen on my custom ports**
– Check `.env` and make sure `CUSTOM_PORTS` are set, then rerun the generator.
– Verify that the ports aren’t taken by other containers or processes.

**UDP doesn’t work but TCP does**
– Check that `docker-compose.yml` has `- "$port:$port/udp"`.
– Make sure your service actually listens on UDP.

**ACME (Let’s Encrypt) fails**
– Check `LETSENCRYPT_EMAIL` in `.env`.
– Ports `80` and `443` must be open from outside (no firewall blocking).

**Basic Auth doesn’t work**
– Remove `DASHBOARD_LOGIN` and `DASHBOARD_PASSWORD_HASH` from `.env` and rerun the script (it’ll call `./generate-auth.sh`).
– Check that `generate-auth.sh` exists and is executable (`chmod +x generate-auth.sh`).

**`proxy` network missing**
– The script creates it automatically. Or just do it manually:

```bash
docker network create proxy
```

## Support
For any questions, get support in ["The Megabyte Order"](https://discord.gg/NVtdTka8ZT) Discord server.