#!/usr/bin/env python3
"""Snell v4/v5 compatibility and v6 TCP/UDP/routing, all on loopback."""
import copy
import json
import os
from pathlib import Path
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time

binary, config_path = sys.argv[1:3]
seen = []
http_seen = []
errors = []
HTTP_REQUEST = b"GET /sniff-routing HTTP/1.1\r\nHost: landing.example\r\nConnection: close\r\n\r\n"
HTTP_LANDING = b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\nConnection: close\r\n\r\nlanding-ok"
HTTP_DIRECT = b"HTTP/1.1 200 OK\r\nContent-Length: 9\r\nConnection: close\r\n\r\ndirect-ok"


def read_http(sock, prefix):
    data = prefix
    while b"\r\n\r\n" not in data:
        assert len(data) < 8192, "HTTP fixture header too large"
        data += recv_exact(sock, 1)
    assert data == HTTP_REQUEST, data
    return data


def recv_exact(sock, count):
    data = b""
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise EOFError("connection closed")
        data += chunk
    return data


def read_address(sock, family):
    if family == 1:
        return socket.inet_ntoa(recv_exact(sock, 4))
    if family == 4:
        return socket.inet_ntop(socket.AF_INET6, recv_exact(sock, 16))
    if family == 3:
        return recv_exact(sock, recv_exact(sock, 1)[0]).decode()
    raise ValueError(family)


class Landing(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            sock = self.request
            sock.settimeout(5)
            version, methods = recv_exact(sock, 2)
            assert version == 5
            recv_exact(sock, methods)
            sock.sendall(b"\x05\x00")
            version, command, _, family = recv_exact(sock, 4)
            assert (version, command) == (5, 1)
            host = read_address(sock, family)
            target_port = int.from_bytes(recv_exact(sock, 2), "big")
            sock.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00")
            prefix = recv_exact(sock, 4)
            if prefix == b"GET ":
                http_seen.append((host, target_port, read_http(sock, prefix)))
                sock.sendall(HTTP_LANDING)
            else:
                assert prefix == b"ping", prefix
                seen.append(host)
                sock.sendall(b"landing-ok")
        except Exception as exc:
            errors.append(repr(exc))


class Direct(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        prefix = recv_exact(self.request, 4)
        if prefix == b"GET ":
            read_http(self.request, prefix)
            self.request.sendall(HTTP_DIRECT)
        elif prefix == b"ping":
            self.request.sendall(b"direct-ok")


class UDP(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        sock.sendto(b"udp-" + data, self.client_address)


class TCPServer(socketserver.ThreadingTCPServer):
    daemon_threads = True


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def socks_connect(port, host, target_port, payload=b"ping", response_size=None):
    sock = socket.create_connection(("127.0.0.1", port), timeout=5)
    try:
        sock.sendall(b"\x05\x01\x00")
        assert recv_exact(sock, 2) == b"\x05\x00"
        if host == "127.0.0.1":
            address = b"\x01" + socket.inet_aton(host)
        else:
            name = host.encode()
            address = b"\x03" + bytes([len(name)]) + name
        sock.sendall(b"\x05\x01\x00" + address + target_port.to_bytes(2, "big"))
        reply = recv_exact(sock, 4)
        if reply[1] != 0:
            return None
        read_address(sock, reply[3])
        recv_exact(sock, 2)
        sock.sendall(payload)
        if response_size is not None:
            return recv_exact(sock, response_size)
        return sock.recv(64)
    finally:
        sock.close()


def socks_udp(port, target_port):
    with socket.create_connection(("127.0.0.1", port), timeout=5) as control:
        control.sendall(b"\x05\x01\x00")
        assert recv_exact(control, 2) == b"\x05\x00"
        control.sendall(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
        reply = recv_exact(control, 4)
        assert reply[1] == 0
        host = read_address(control, reply[3])
        relay_port = int.from_bytes(recv_exact(control, 2), "big")
        if host == "0.0.0.0":
            host = "127.0.0.1"
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.settimeout(5)
            header = b"\x00\x00\x00\x01" + socket.inet_aton("127.0.0.1") + target_port.to_bytes(2, "big")
            sock.sendto(header + b"ping", (host, relay_port))
            data, _ = sock.recvfrom(2048)
            assert data[0:4] == b"\x00\x00\x00\x01", data
            assert data[10:] == b"udp-ping", data


def start(binary, path, log, ports):
    proc = subprocess.Popen([binary, "run", "-c", str(path)], stdout=log, stderr=log)
    try:
        for port in ports:
            for _ in range(100):
                if proc.poll() is not None:
                    raise RuntimeError("sing-box exited before ready")
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                        break
                except OSError:
                    time.sleep(0.03)
            else:
                raise TimeoutError("sing-box did not open loopback port")
        return proc
    except BaseException:
        proc.terminate()
        proc.wait(timeout=5)
        raise


with TCPServer(("127.0.0.1", 0), Landing) as landing, \
        TCPServer(("127.0.0.1", 0), Direct) as direct, \
        socketserver.ThreadingUDPServer(("127.0.0.1", 0), UDP) as udp:
    for server in (landing, direct, udp):
        threading.Thread(target=server.serve_forever, daemon=True).start()
    temp_base = os.environ.get("TMPDIR")
    if temp_base is None and Path("/tmp/opencode").is_dir() and os.access("/tmp/opencode", os.W_OK):
        temp_base = "/tmp/opencode"
    with tempfile.TemporaryDirectory(prefix="singbox-snell-", dir=temp_base) as tmp:
        processes = []
        log_path = Path(tmp) / "kernel.log"
        with log_path.open("w+") as log:
            try:
                cfg = json.loads(Path(config_path).read_text())
                # Keep generated inbound fields and routing. Only change fixture ports.
                cfg.pop("experimental", None)
                cfg["log"] = {"level": "debug"}
                listeners = []
                for inbound in cfg["inbounds"]:
                    if inbound["type"] == "snell" and "listen_port" in inbound:
                        inbound["listen"] = "127.0.0.1"
                        inbound["listen_port"] = free_port()
                        listeners.append(inbound)
                assert len(listeners) >= 2
                for outbound in cfg["outbounds"]:
                    if outbound["type"] == "socks":
                        outbound["server_port"] = landing.server_address[1]
                # Exercise all modes even if the active fixture has only two listeners.
                v6 = next(ib for ib in listeners if ib.get("version") == 6)
                extra = copy.deepcopy(v6)
                extra.update(tag="runtime-unshaped", mode="unshaped", listen_port=free_port())
                cfg["inbounds"].append(extra)
                listeners.append(extra)
                # v4/v5 inbounds and sniff rules come from the actual installer.
                legacy_tags = {ib["tag"] for ib in listeners if ib["version"] == 5}
                assert len(legacy_tags) >= 2, "pass generated v4 and v5 listeners"
                sniff = [rule for rule in cfg["route"]["rules"] if rule.get("action") == "sniff"]
                assert {tag for rule in sniff for tag in rule["inbound"]} == legacy_tags, sniff
                assert all(sorted(rule["sniffer"]) == ["http", "tls"] for rule in sniff), sniff
                path = Path(tmp) / "server.json"
                path.write_text(json.dumps(cfg))
                processes.append(start(binary, path, log, [ib["listen_port"] for ib in listeners]))

                client = {"log": {"level": "debug"}, "inbounds": [], "outbounds": [], "route": {"rules": []}}
                for index, inbound in enumerate(listeners):
                    tag = f"client-{index}"
                    port = free_port()
                    client["inbounds"].append({"type": "socks", "tag": tag, "listen": "127.0.0.1", "listen_port": port})
                    outbound = {
                        "type": "snell", "tag": tag, "server": "127.0.0.1",
                        "server_port": inbound["listen_port"],
                        "version": 6 if inbound["version"] == 6 else 4,
                        "psk": inbound["psk"], "reuse": True,
                    }
                    if inbound["version"] == 6:
                        outbound["mode"] = inbound.get("mode", "default")
                    client["outbounds"].append(outbound)
                    client["route"]["rules"].append({"inbound": [tag], "outbound": tag})
                path = Path(tmp) / "client.json"
                path.write_text(json.dumps(client))
                ports = [ib["listen_port"] for ib in client["inbounds"]]
                processes.append(start(binary, path, log, ports))
                for port, inbound in zip(ports, listeners):
                    assert socks_connect(port, "landing.example", 80) == b"landing-ok"
                    assert socks_connect(port, "127.0.0.1", direct.server_address[1]) == b"direct-ok"
                    try:
                        assert not socks_connect(port, "blocked.example", 80)
                    except (EOFError, ConnectionResetError):
                        pass
                    socks_udp(port, udp.server_address[1])
                    # Sniff HTTP Host for the routing decision while preserving
                    # the requested IP and port delivered to the SOCKS landing.
                    expected = HTTP_LANDING if inbound["version"] == 5 else HTTP_DIRECT
                    assert socks_connect(port, "127.0.0.1", direct.server_address[1],
                                         HTTP_REQUEST, len(expected)) == expected
                assert seen == ["landing.example"] * len(ports), seen
                assert http_seen == [("127.0.0.1", direct.server_address[1], HTTP_REQUEST)] * len(legacy_tags), http_seen
                assert not errors, errors
                print("ok - live Snell v4/v5 via version-5 servers and v6 modes: TCP/UDP, direct, reject, chain")
                print("ok - v4/v5 HTTP Host sniff routes IP targets through chain without destination override; v6 remains direct")
            except BaseException:
                log.flush()
                log.seek(0)
                print(log.read(), file=sys.stderr)
                raise
            finally:
                for proc in reversed(processes):
                    proc.terminate()
                    try:
                        proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait(timeout=5)
    for server in (landing, direct, udp):
        server.shutdown()
