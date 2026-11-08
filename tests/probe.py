"""Exercise a running live-test backend through Traefik, from any client host."""
import concurrent.futures
import http.client
import socket
import sys

host, http_port, custom_port = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])


def probe(index):
    payload = f"traefik-live-{index}".encode()
    connection = http.client.HTTPConnection(host, http_port, timeout=5)
    connection.request("GET", "/", headers={"Host": "traefik-live-test.invalid"})
    response = connection.getresponse()
    assert response.status == 200, f"HTTP status {response.status}"
    assert response.read() == b"traefik-live-http\n", "HTTP body"
    connection.close()
    with socket.create_connection((host, custom_port), timeout=5) as client:
        client.sendall(payload)
        reply = b""
        while len(reply) < len(payload):
            chunk = client.recv(4096)
            assert chunk, "TCP closed before receiving payload"
            reply += chunk
        assert reply == payload, "TCP payload mismatch"
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
        client.settimeout(5)
        client.sendto(payload, (host, custom_port))
        reply, _ = client.recvfrom(4096)
        assert reply == payload, "UDP payload mismatch"


with concurrent.futures.ThreadPoolExecutor(max_workers=10) as pool:
    list(pool.map(probe, range(100)))
print(f"PASS: 100 HTTP, 100 TCP, and 100 UDP requests via {host}")
