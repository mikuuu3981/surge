#!/usr/bin/env python3
"""Exercise generated routing on loopback only; no system service or firewall writes."""
import json
import os
from pathlib import Path
import socket
import socketserver
import shutil
import subprocess
import sys
import tempfile
import threading
import time

binary, config_path = sys.argv[1:3]
hosts = sys.argv[3:] or ["landing.example"]
seen = []
errors = []


def recv_exact(sock, count):
    data = b""
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise EOFError("connection closed")
        data += chunk
    return data


class Landing(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            sock = self.request
            sock.settimeout(5)
            version, methods = recv_exact(sock, 2)
            assert version == 5
            recv_exact(sock, methods)
            sock.sendall(b"\x05\x00")
            version, command, _, address_type = recv_exact(sock, 4)
            assert (version, command) == (5, 1)
            if address_type == 3:
                destination = recv_exact(sock, recv_exact(sock, 1)[0]).decode()
            elif address_type == 1:
                destination = socket.inet_ntoa(recv_exact(sock, 4))
            else:
                raise AssertionError(address_type)
            recv_exact(sock, 2)
            seen.append(destination)
            sock.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00")
            recv_exact(sock, 4)
            sock.sendall(b"landing-ok")
        except Exception as exc:
            errors.append(repr(exc))


class Direct(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        recv_exact(self.request, 4)
        self.request.sendall(b"direct-ok")


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True


def connect_via_socks(port, host, target_port, payload=b"ping"):
    with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
        sock.sendall(b"\x05\x01\x00")
        assert recv_exact(sock, 2) == b"\x05\x00"
        if host in ("127.0.0.1", "203.0.113.9"):
            addr = b"\x01" + socket.inet_aton(host)
        else:
            name = host.encode()
            addr = b"\x03" + bytes([len(name)]) + name
        sock.sendall(b"\x05\x01\x00" + addr + target_port.to_bytes(2, "big"))
        reply = recv_exact(sock, 4)
        if reply[1] != 0:
            return None
        if reply[3] == 1:
            recv_exact(sock, 6)
        elif reply[3] == 4:
            recv_exact(sock, 18)
        else:
            recv_exact(sock, recv_exact(sock, 1)[0] + 2)
        if payload:
            sock.sendall(payload)
            return sock.recv(64)
        return b""


with Server(("127.0.0.1", 0), Landing) as landing, Server(("127.0.0.1", 0), Direct) as direct:
    for server in (landing, direct):
        threading.Thread(target=server.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory() as tmp:
        cfg = json.loads(Path(config_path).read_text())
        # Keep generated policies and rules; only replace fixture endpoint and ingress ports.
        cfg["listeners"] = []
        with socket.socket() as free:
            free.bind(("127.0.0.1", 0))
            port = free.getsockname()[1]
        cfg["socks-port"] = port
        cfg["bind-address"] = "127.0.0.1"
        cfg["allow-lan"] = False
        for proxy in cfg["proxies"]:
            if proxy["type"] == "socks5":
                proxy["port"] = landing.server_address[1]
                proxy.pop("username", None)
                proxy.pop("password", None)
        # Reuse locally supplied provider fixtures; do not fetch external rules during traffic tests.
        for provider in cfg.get("rule-providers", {}).values():
            relative = Path(provider["path"])
            source = Path(config_path).parent / relative
            destination = Path(tmp) / relative
            if not source.is_file():
                raise FileNotFoundError(f"Missing local rule-provider fixture: {source}")
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
        path = Path(tmp) / "config.json"
        path.write_text(json.dumps(cfg))
        os.chmod(path, 0o600)
        with (Path(tmp) / "kernel.log").open("w+") as log:
            proc = subprocess.Popen([binary, "-d", tmp, "-f", str(path)], stdout=log, stderr=log)
            try:
                for _ in range(100):
                    if proc.poll() is not None:
                        raise RuntimeError("Mihomo exited before ready")
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                            break
                    except OSError:
                        time.sleep(0.05)
                else:
                    raise TimeoutError("Mihomo did not open loopback SOCKS port")
                for host in hosts:
                    assert connect_via_socks(port, host, 80) == b"landing-ok"
                try:
                    rejected = connect_via_socks(port, "blocked.example", 80)
                    assert not rejected, rejected
                except (EOFError, ConnectionResetError):
                    pass
                assert connect_via_socks(port, "127.0.0.1", direct.server_address[1]) == b"direct-ok"
                # 仅提交目标 IP 时，HTTP Host 仍应命中域名分流；保留原始连接目标。
                request = f"GET / HTTP/1.1\r\nHost: {hosts[0]}\r\n\r\n".encode()
                assert connect_via_socks(port, "203.0.113.9", 80, request) == b"landing-ok"
                assert seen == hosts + ["203.0.113.9"], seen
                assert not errors, errors
                print("ok - live domain routing, reject, direct fallback and IP-only HTTP sniffing")
            except BaseException:
                log.flush()
                log.seek(0)
                print(log.read(), file=sys.stderr)
                raise
            finally:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5)
    for server in (landing, direct):
        server.shutdown()
