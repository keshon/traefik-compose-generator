"""Disposable HTTP/TCP/UDP echo backend for the opt-in live test."""
import http.server
import os
import socketserver
import threading

PORT = int(os.environ.get("TEST_PORT", "51227"))


class HTTP(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"traefik-live-http\n"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


class TCP(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.sendall(self.request.recv(4096))


class UDP(socketserver.BaseRequestHandler):
    def handle(self):
        data, connection = self.request
        connection.sendto(data, self.client_address)


for server in (
    http.server.ThreadingHTTPServer(("0.0.0.0", 8081), HTTP),
    socketserver.ThreadingTCPServer(("0.0.0.0", PORT), TCP),
    socketserver.ThreadingUDPServer(("0.0.0.0", PORT), UDP),
):
    threading.Thread(target=server.serve_forever, daemon=True).start()
threading.Event().wait()
