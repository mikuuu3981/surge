#!/usr/bin/env python3
"""Real Mieru TCP/UDP transport, payload and server AI routing checks on loopback."""
import http.server
import json
import pathlib
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time


def free_port(kind=socket.SOCK_STREAM):
    with socket.socket(socket.AF_INET, kind) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def receive(sock, size):
    data = b""
    while len(data) < size:
        block = sock.recv(size - len(data))
        if not block:
            raise ConnectionError("SOCKS connection closed")
        data += block
    return data


def socks_request(port, host, target_port, command=1):
    sock = socket.create_connection(("127.0.0.1", port), 8)
    sock.settimeout(8)
    try:
        sock.sendall(b"\x05\x01\x00")
        assert receive(sock, 2) == b"\x05\x00"
        address = host.encode()
        sock.sendall(bytes([5, command, 0, 3, len(address)]) + address + struct.pack("!H", target_port))
        header = receive(sock, 4)
        if header[1] != 0:
            raise ConnectionError(f"SOCKS error {header[1]}")
        if header[3] == 1:
            bound = socket.inet_ntoa(receive(sock, 4))
        elif header[3] == 4:
            bound = socket.inet_ntop(socket.AF_INET6, receive(sock, 16))
        else:
            bound = receive(sock, receive(sock, 1)[0]).decode()
        bound_port = struct.unpack("!H", receive(sock, 2))[0]
        return sock, (bound, bound_port)
    except BaseException:
        sock.close()
        raise


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"mieru-loopback-ok"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


binary, config_path, temp_path = sys.argv[1:]
temp = pathlib.Path(temp_path)
server = json.loads(pathlib.Path(config_path).read_text())
http = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=http.serve_forever, daemon=True).start()
udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
udp.bind(("127.0.0.1", 0))


def udp_echo():
    while True:
        try:
            payload, address = udp.recvfrom(65535)
            udp.sendto(payload, address)
        except OSError:
            return


threading.Thread(target=udp_echo, daemon=True).start()
server["listeners"] = []
server["sniffer"]["sniff"]["HTTP"]["ports"] = [http.server_port]
client = {"mode": "rule", "listeners": [], "proxies": [], "rules": [], "log-level": "debug"}
ports = {}
for transport in ("TCP", "UDP"):
    port = free_port(socket.SOCK_STREAM if transport == "TCP" else socket.SOCK_DGRAM)
    socks_port = free_port()
    ports[transport] = socks_port
    server["listeners"].append({"name": transport, "type": "mieru", "listen": "127.0.0.1",
                                "port": port, "transport": transport, "users": {"00123": "00123456789"}})
    client["listeners"].append({"name": transport, "type": "socks", "listen": "127.0.0.1", "port": socks_port, "udp": True})
    client["proxies"].append({"name": transport, "type": "mieru", "server": "127.0.0.1", "port": port,
                              "transport": transport, "username": "00123", "password": "00123456789",
                              "multiplexing": "MULTIPLEXING_LOW", "udp": True})
    client["rules"].append(f"IN-PORT,{socks_port},{transport}")
client["rules"].append("MATCH,REJECT")
processes = []
logs = []
try:
    for name, config in (("server", server), ("client", client)):
        directory = temp / name
        directory.mkdir()
        if name == "server":
            for tag, provider in config["rule-providers"].items():
                target = directory / f"{tag}.txt"
                shutil.copyfile(provider["path"], target)
                provider["path"] = str(target)
        path = directory / "config.json"
        path.write_text(json.dumps(config))
        log = (directory / "core.log").open("w")
        logs.append(log)
        processes.append(subprocess.Popen([binary, "-d", str(directory), "-f", str(path)], stdout=log, stderr=log))
    deadline = time.monotonic() + 10
    for port in ports.values():
        while True:
            assert all(proc.poll() is None for proc in processes), "Mihomo exited"
            try:
                with socket.create_connection(("127.0.0.1", port), 0.2):
                    break
            except OSError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("SOCKS listener not ready")
                time.sleep(0.1)

    def http_request(port, address, host):
        sock, _ = socks_request(port, address, http.server_port)
        with sock:
            sock.sendall(f"GET / HTTP/1.0\r\nHost: {host}\r\n\r\n".encode())
            response = b""
            while block := sock.recv(65535):
                response += block
            return response

    for transport, port in ports.items():
        assert b"mieru-loopback-ok" in http_request(port, "127.0.0.1", "ordinary.fixture")
        for address, host in (("ai.fixture", "ai.fixture"), ("127.0.0.2", "ordinary.fixture"), ("127.0.0.1", "ai.fixture")):
            try:
                result = http_request(port, address, host)
            except (OSError, ConnectionError):
                result = b""
            assert b"mieru-loopback-ok" not in result, f"{transport}: AI traffic bypassed routing: {address}, {host}"
        control, relay = socks_request(port, "0.0.0.0", 0, command=3)
        with control, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as packet:
            packet.settimeout(8)
            payload = b"mieru-udp-echo"
            header = b"\x00\x00\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack("!H", udp.getsockname()[1])
            packet.sendto(header + payload, ("127.0.0.1", relay[1]))
            result, _ = packet.recvfrom(65535)
            assert result[10:] == payload, (transport, result)
        print(f"ok - real Mieru {transport} transport: HTTP, UDP relay, AI domain/IP routing and sniffing")
finally:
    for proc in reversed(processes):
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
    for log in logs:
        log.close()
    if sys.exc_info()[0] is not None:
        for name in ("server", "client"):
            path = temp / name / "core.log"
            if path.exists():
                print(path.read_text(), file=sys.stderr)
    http.shutdown()
    udp.close()
