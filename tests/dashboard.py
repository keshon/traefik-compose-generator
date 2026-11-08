"""Opt-in dashboard authentication probe; credentials stay out of command lines."""
import argparse
import base64
import http.client
from pathlib import Path
import socket
import ssl
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("hostname")
parser.add_argument("credential_directory", type=Path)
parser.add_argument("--address", default="127.0.0.1")
parser.add_argument("--http-port", type=int, default=80)
parser.add_argument("--https-port", type=int, default=443)
parser.add_argument("--allow-untrusted", action="store_true")
parser.add_argument("--rotate", action="store_true")
args = parser.parse_args()
context = ssl._create_unverified_context() if args.allow_untrusted else ssl.create_default_context()


class Connection(http.client.HTTPSConnection):
    def connect(self):
        raw = socket.create_connection((args.address, args.https_port), timeout=10)
        self.sock = context.wrap_socket(raw, server_hostname=args.hostname)


def request(path, password=None):
    connection = Connection(args.hostname, args.https_port, context=context, timeout=10)
    headers = {"Host": args.hostname}
    if password is not None:
        token = base64.b64encode(f"{username}:{password}".encode()).decode()
        headers["Authorization"] = f"Basic {token}"
    connection.request("GET", path, headers=headers)
    response = connection.getresponse()
    status = response.status
    response.read()
    connection.close()
    return status


username = (args.credential_directory / "dashboard.htpasswd").read_text().split(":", 1)[0]
password = (args.credential_directory / "dashboard-password.txt").read_text().strip()
plain = http.client.HTTPConnection(args.address, args.http_port, timeout=10)
plain.request("GET", "/dashboard/", headers={"Host": args.hostname})
response = plain.getresponse()
assert response.status in (301, 302, 307, 308), f"HTTP redirect: {response.status}"
assert response.getheader("Location").startswith(f"https://{args.hostname}"), "Redirect destination"
response.read()
plain.close()
print("PASS: HTTP dashboard redirects to HTTPS")

for path in ("/dashboard/", "/api/rawdata"):
    assert request(path) == 401, f"Unauthenticated access to {path}"
    assert request(path, "intentionally-wrong-password") == 401, f"Invalid credentials accepted for {path}"
    assert request(path, password) == 200, f"Valid credentials rejected for {path}"
print("PASS: dashboard and API reject missing/wrong credentials and accept the generated password")

if args.rotate:
    root = Path(__file__).resolve().parents[1]
    subprocess.run(
        ["sh", str(root / "traefik-basic-auth.sh"), "--username", username, "--generate", "--restart"],
        check=True,
    )
    replacement = (args.credential_directory / "dashboard-password.txt").read_text().strip()
    assert replacement != password
    assert request("/dashboard/", password) == 401, "Old password still authenticates"
    assert request("/dashboard/", replacement) == 200, "New password rejected"
    print("PASS: password rotation rejects the old password and accepts its replacement")

if not args.allow_untrusted:
    print("PASS: HTTPS certificate validates for the dashboard hostname")
