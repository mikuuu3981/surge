#!/usr/bin/env python3
"""Exercise generated ShadowTLS->Snell detours with local TLS 1.3 and TCP echo.

Usage: test-singbox-shadowtls-runtime.py /path/to/sing-box generated-config.json
No external network, service manager or installed configuration is used.
"""
import copy
import ipaddress
import json
from pathlib import Path
import socket
import socketserver
import ssl
import subprocess
import sys
import tempfile
import threading
import time


def recv_exact(sock, count):
    data = bytearray()
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise EOFError(f"connection closed after {len(data)}/{count} bytes")
        data.extend(chunk)
    return bytes(data)


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True


class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        while True:
            data = self.request.recv(65536)
            if not data:
                return
            self.request.sendall(data)


def start(binary, path, log, ports):
    subprocess.run([binary, "check", "-c", str(path)], check=True, stdout=log, stderr=log)
    proc = subprocess.Popen([binary, "run", "-c", str(path)], stdout=log, stderr=log)
    try:
        for port in ports:
            for _ in range(150):
                if proc.poll() is not None:
                    raise RuntimeError(f"sing-box exited with status {proc.returncode}")
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                        break
                except OSError:
                    time.sleep(0.02)
            else:
                raise TimeoutError(f"loopback listener {port} did not become ready")
        return proc
    except BaseException:
        proc.terminate()
        proc.wait(timeout=5)
        raise


def assert_loopback_listeners(proc, minimum):
    """Inspect only sockets owned by this process, not other namespace users."""
    proc_dir = Path(f"/proc/{proc.pid}")
    inodes = set()
    for fd in (proc_dir / "fd").iterdir():
        try:
            target = str(fd.readlink())
        except FileNotFoundError:
            continue
        if target.startswith("socket:["):
            inodes.add(target[8:-1])
    listeners = []
    for table in ("tcp", "tcp6", "udp", "udp6"):
        for line in (proc_dir / "net" / table).read_text().splitlines()[1:]:
            fields = line.split()
            if fields[9] not in inodes or (table.startswith("tcp") and fields[3] != "0A"):
                continue
            address, port = fields[1].split(":")
            raw = bytes.fromhex(address)
            # Linux exposes each 32-bit address word in host byte order.
            if sys.byteorder == "little":
                raw = b"".join(raw[i:i + 4][::-1] for i in range(0, len(raw), 4))
            address = ipaddress.ip_address(raw)
            assert address.is_loopback, (proc.pid, table, str(address), port)
            listeners.append((table, str(address), int(port, 16)))
    assert len(listeners) >= minimum, (proc.pid, listeners)
    return listeners


def echo_via_socks(port, echo_port, payload):
    with socket.create_connection(("127.0.0.1", port), timeout=8) as sock:
        sock.sendall(b"\x05\x01\x00")
        assert recv_exact(sock, 2) == b"\x05\x00"
        sock.sendall(b"\x05\x01\x00\x01" + socket.inet_aton("127.0.0.1") + echo_port.to_bytes(2, "big"))
        reply = recv_exact(sock, 4)
        assert reply[:2] == b"\x05\x00", reply
        if reply[3] == 1:
            recv_exact(sock, 4)
        elif reply[3] == 4:
            recv_exact(sock, 16)
        elif reply[3] == 3:
            recv_exact(sock, recv_exact(sock, 1)[0])
        else:
            raise AssertionError(reply)
        recv_exact(sock, 2)
        sock.sendall(payload)
        assert recv_exact(sock, len(payload)) == payload


def main(binary, config_path):
    generated = json.loads(Path(config_path).read_text())
    originals = {ib["tag"]: ib for ib in generated["inbounds"]}
    frontends = [ib for ib in originals.values() if ib["type"] == "shadowtls"]
    assert frontends, "generated configuration has no ShadowTLS inbounds"
    # Validate the installer topology before substituting any runtime fixture.
    for front in frontends:
        assert front["version"] == 3 and front["users"]
        backend = originals[front["detour"]]
        assert backend["type"] == "snell" and backend["version"] == 5
        assert backend["listen"] == "127.0.0.1" and backend["listen_port"] == 0
        assert isinstance(backend["psk"], str) and backend["psk"]

    with tempfile.TemporaryDirectory(prefix="singbox-shadowtls-") as tmp:
        tmp = Path(tmp)
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
            "-nodes", "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
            "-keyout", str(tmp / "server.key"), "-out", str(tmp / "server.crt"),
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = context.maximum_version = ssl.TLSVersion.TLSv1_3
        context.load_cert_chain(tmp / "server.crt", tmp / "server.key")
        handshakes = []

        class Handshake(socketserver.BaseRequestHandler):
            def handle(self):
                self.request.settimeout(5)
                try:
                    with context.wrap_socket(self.request, server_side=True) as tls:
                        handshakes.append(tls.version())
                        # Keep the upstream session alive until ShadowTLS closes
                        # it or a fallback client sends a local HTTP request.
                        if tls.recv(4096):
                            tls.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
                except (ssl.SSLError, OSError):
                    # Port readiness probes and detached camouflage connections
                    # can close before the TLS handler finishes.
                    pass

        with Server(("127.0.0.1", 0), Handshake) as handshake, Server(("127.0.0.1", 0), Echo) as echo:
            for server in (handshake, echo):
                threading.Thread(target=server.serve_forever, daemon=True).start()
            server_cfg = {"log": {"level": "debug"}, "inbounds": [],
                          "outbounds": [{"type": "direct", "tag": "direct"}], "route": {"final": "direct"}}
            client_cfg = {"log": {"level": "debug"}, "inbounds": [], "outbounds": [], "route": {"rules": []}}
            public_ports, socks_ports = [], []
            for index, original in enumerate(frontends):
                front = copy.deepcopy(original)
                backend = copy.deepcopy(originals[front["detour"]])
                public_port, socks_port = free_port(), free_port()
                front.update(listen="127.0.0.1", listen_port=public_port,
                             handshake={"server": "127.0.0.1", "server_port": handshake.server_address[1]})
                server_cfg["inbounds"].extend([front, backend])
                public_ports.append(public_port)
                socks_ports.append(socks_port)
                tag = f"client-{index}"
                client_cfg["inbounds"].append({"type": "socks", "tag": tag, "listen": "127.0.0.1", "listen_port": socks_port})
                client_cfg["outbounds"].extend([
                    {"type": "snell", "tag": tag, "server": "127.0.0.1", "server_port": public_port,
                     "version": 4, "psk": backend["psk"], "reuse": True, "detour": tag + "-tls"},
                    {"type": "shadowtls", "tag": tag + "-tls", "server": "127.0.0.1", "server_port": public_port,
                     "version": 3, "password": front["users"][0]["password"],
                     "tls": {"enabled": True, "insecure": True, "server_name": "localhost"}},
                ])
                client_cfg["route"]["rules"].append({"inbound": [tag], "outbound": tag})
            processes = []
            with (tmp / "runtime.log").open("w+") as log:
                try:
                    for name, cfg, ports in (("server", server_cfg, public_ports), ("client", client_cfg, socks_ports)):
                        path = tmp / f"{name}.json"
                        path.write_text(json.dumps(cfg))
                        processes.append(start(binary, path, log, ports))
                    for port in socks_ports:
                        # Multiple TCP requests catch reuse/handshake regressions.
                        for attempt in range(2):
                            payload = (f"shadowtls-echo-{port}-{attempt}:".encode() + bytes(range(256))) * 64
                            echo_via_socks(port, echo.server_address[1], payload)
                    assert handshakes and all(v == "TLSv1.3" for v in handshakes), handshakes
                    assert_loopback_listeners(processes[0], len(frontends) * 2)
                    assert_loopback_listeners(processes[1], len(frontends))
                    print(f"ok - live generated ShadowTLS v3 -> Snell v5 ({len(frontends)} detours), TLS 1.3, v4 clients, TCP echo and all listeners loopback")
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
                    for server in (handshake, echo):
                        server.shutdown()


if __name__ == "__main__":
    main(*sys.argv[1:3])
