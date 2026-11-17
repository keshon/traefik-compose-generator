"""Opt-in: isolated Traefik, host backup fixture, and TLS with PROXY v1/v2."""
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import shutil
import socket
import ssl
import struct
import subprocess
import tempfile
import threading
import time
import uuid


ROOT = Path(__file__).resolve().parents[1]


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()


class Backend(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.respond(b"")

    def do_POST(self):
        data = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.respond(data)

    def respond(self, data):
        allowed = self.headers.get("Authorization") == "Basic Zml4dHVyZTpmaXh0dXJl"
        result = json.dumps({"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}).encode()
        self.send_response(200 if allowed else 401)
        self.send_header("Content-Length", str(len(result)))
        self.end_headers()
        self.wfile.write(result)


def request(port, version=0, authenticated=True, payload=b"", hostname="backup.example.com"):
    with socket.create_connection(("127.0.0.1", port), timeout=10) as raw:
        if version == 1:
            raw.sendall(b"PROXY TCP4 198.51.100.10 203.0.113.10 12345 443\r\n")
        elif version == 2:
            address = socket.inet_aton("198.51.100.10") + socket.inet_aton("203.0.113.10")
            raw.sendall(b"\r\n\r\n\x00\r\nQUIT\n" + bytes([0x21, 0x11]) + struct.pack("!H", 12)
                        + address + struct.pack("!HH", 12345, 443))
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE  # Disposable Traefik default certificate only.
        with context.wrap_socket(raw, server_hostname=hostname) as conn:
            headers = ("POST" if payload else "GET") + " / HTTP/1.1\r\nHost: " + hostname
            headers += "\r\nConnection: close\r\nContent-Length: " + str(len(payload)) + "\r\n"
            if authenticated:
                headers += "Authorization: Basic Zml4dHVyZTpmaXh0dXJl\r\n"
            conn.sendall(headers.encode() + b"\r\n" + payload)
            chunks = []
            while True:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                chunks.append(chunk)
    return b"".join(chunks)


def main():
    name = "traefik-backup-test-" + uuid.uuid4().hex[:10]
    backend = None
    with tempfile.TemporaryDirectory(prefix=name) as temp:
        folder = Path(temp)
        try:
            run("docker", "network", "create", name)
            network = json.loads(run("docker", "network", "inspect", name))[0]
            gateway = network["IPAM"]["Config"][0]["Gateway"]
            backend = ThreadingHTTPServer((gateway, 0), Backend)
            threading.Thread(target=backend.serve_forever, daemon=True).start()
            for file in ("traefik.sh", "compose.yaml"):
                shutil.copy2(ROOT / file, folder / file)
            shutil.copytree(ROOT / "lib", folder / "lib")
            settings = ("LETSENCRYPT_EMAIL=fixture@example.com\nCUSTOM_PORTS=\n"
                        "BACKUP_HOSTNAME=backup.example.com\nBACKUP_BACKEND_URL=http://"
                        + gateway + ":" + str(backend.server_port) + "\n")

            def generate(extra):
                (folder / ".env").write_text(settings + extra)
                run("sh", str(folder / "traefik.sh"), "generate")
                return json.loads(run("sh", "-c",
                                      'cd "$1"; ROOT=$PWD; ENV_FILE=$PWD/.env; '
                                      '. ./lib/common.sh; load_env; defaults; compose config --format json',
                                      "sh", str(folder)))

            direct = generate("XRAY_MODE=false\n")
            assert any(str(p["published"]) == "443" and p["target"] == 443
                       for p in direct["services"]["traefik"]["ports"])
            model = generate("XRAY_MODE=true\nXRAY_TRUSTED_IPS=" + gateway + "/32\n")
            service = model["services"]["traefik"]
            assert any(p["host_ip"] == "127.0.0.1" and str(p["published"]) == "2053"
                       and p["target"] == 8443 for p in service["ports"])
            assert not any(str(p["published"]) == "443" for p in service["ports"])
            assert service["environment"]["TRAEFIK_ENTRYPOINTS_HTTPS_TRANSPORT_RESPONDINGTIMEOUTS_READTIMEOUT"] == "15m"
            print("PASS: Compose models preserve direct HTTPS and private Xray ports")
            route = folder / "dynamic/vps-backup.yml"
            route.write_text(route.read_text().replace("tls:\n        certResolver: letsencrypt", "tls: {}"))
            args = ["docker", "run", "-d", "--name", name, "--network", name,
                    "-p", "127.0.0.1::8443", "-v", str(folder / "dynamic") + ":/dynamic:ro"]
            for key, value in service["environment"].items():
                if key.startswith(("TRAEFIK_PROVIDERS_DOCKER", "TRAEFIK_CERTIFICATESRESOLVERS")) or key.endswith("_TLS_CERTRESOLVER"):
                    continue
                args += ["-e", key + "=" + str(value)]
            run(*args, service["image"])
            port = int(run("docker", "port", name, "8443/tcp").rsplit(":", 1)[1])
            for _ in range(40):
                try:
                    if b" 200 " in request(port).split(b"\r\n", 1)[0]:
                        break
                except (OSError, ssl.SSLError):
                    pass
                time.sleep(0.25)
            else:
                raise AssertionError("Disposable Traefik did not become ready: " + run("docker", "logs", name))
            payload = b"backup-fixture\x00" * 300000
            for version in (0, 1, 2):
                denied = request(port, version, authenticated=False)
                assert b" 401 " in denied.split(b"\r\n", 1)[0]
                response = request(port, version, payload=payload)
                assert b" 200 " in response.split(b"\r\n", 1)[0], response[:200]
                # Force Content-Length responses at the backend; Traefik preserves them.
                body = json.loads(response.split(b"\r\n\r\n", 1)[1])
                assert body == {"bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest()}
                print("PASS: TLS with PROXY version", version, "preserves authentication and upload bytes")
            route.write_text(route.read_text().replace("backup.example.com", "changed.example.com"))
            for _ in range(40):
                if b" 200 " in request(port, 2, hostname="changed.example.com").split(b"\r\n", 1)[0]:
                    break
                time.sleep(0.25)
            else:
                raise AssertionError("File provider did not reload the changed route")
            assert b" 404 " in request(port, 2).split(b"\r\n", 1)[0]
            print("PASS: file-provider route changes reload without a Traefik restart")
        finally:
            subprocess.run(["docker", "rm", "-f", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if backend:
                backend.shutdown()
                backend.server_close()
            subprocess.run(["docker", "network", "rm", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
