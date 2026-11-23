#!/usr/bin/env python3
"""orchestra egress proxy: the sandbox's only way out, when ORCHESTRA_EGRESS_ALLOW is set.

Runs OUTSIDE the sandbox and listens on a unix socket that is bound into it. It speaks just enough HTTP to accept
`CONNECT host:port`, and opens the tunnel only when the host is on the allowlist. Everything else is refused:
plain-HTTP requests, hosts not listed, ports not listed. The policy lives here, outside the sandbox, so nothing a
worker does inside can change it.

Allowlist entries (space or comma separated):
  api.deepseek.com          that host, port 443
  registry.example.com:8443 that host and port
  *.example.com             any subdomain of example.com (not example.com itself), port 443
  *.example.com:8443        the same, on that port
Hosts are compared case-insensitively. An IP address is allowed only when listed literally.

The log (one line per connection attempt) holds the time, allow/deny and host:port: never request content.

  egress_proxy.py --socket PATH --allow "LIST" --log FILE
  egress_proxy.py --check --allow "LIST"     validate only (exit 2 on a bad entry)
Standard library only.
"""
import argparse
import asyncio
import os
import re
import sys
import time

HEAD_LIMIT = 8192
CONNECT_TIMEOUT = 15
HOST_RE = re.compile(r"^[a-z0-9.-]+$|^\[[0-9a-f:]+\]$")


def parse_rules(text):
    """[(pattern, port)] from the allowlist text. Raises ValueError on a malformed entry."""
    rules = []
    for entry in re.split(r"[\s,]+", text.strip().lower()):
        if not entry:
            continue
        host, port = entry, 443
        m = re.match(r"^(.*):(\d+)$", entry)
        if m and not entry.startswith("["):
            host, port = m.group(1), int(m.group(2))
        wild = host.startswith("*.")
        name = host[2:] if wild else host
        if not name or not HOST_RE.match(name) or not 0 < port < 65536:
            raise ValueError(f"bad egress allowlist entry: {entry!r}")
        rules.append((host, port))
    return rules


def allowed(host, port, rules):
    host = host.lower().rstrip(".")
    for pattern, p in rules:
        if p != port:
            continue
        if pattern.startswith("*."):
            if host.endswith(pattern[1:]) and host != pattern[2:]:
                return True
        elif host == pattern:
            return True
    return False


def parse_connect(head):
    """(host, port) from a CONNECT request head, or None for anything else."""
    try:
        line = head.split(b"\r\n", 1)[0].decode("ascii")
    except UnicodeDecodeError:
        return None
    m = re.match(r"^CONNECT (\[[0-9A-Fa-f:]+\]|[A-Za-z0-9.-]+):(\d{1,5}) HTTP/1\.[01]$", line)
    if not m:
        return None
    return m.group(1).lower(), int(m.group(2))


class Proxy:
    def __init__(self, rules, log_path):
        self.rules = rules
        self.log_path = log_path

    def log(self, verdict, target):
        stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        try:
            with open(self.log_path, "a", encoding="utf-8") as f:
                f.write(f"{stamp} {verdict} {target}\n")
        except OSError:
            pass

    async def pipe(self, reader, writer):
        try:
            while True:
                data = await reader.read(65536)
                if not data:
                    break
                writer.write(data)
                await writer.drain()
        except (ConnectionError, OSError):
            pass
        finally:
            try:
                writer.close()
            except OSError:
                pass

    async def handle(self, reader, writer):
        try:
            head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), timeout=30)
        except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, asyncio.TimeoutError, ConnectionError):
            writer.close()
            return
        target = parse_connect(head)
        if target is None:
            self.log("deny", "non-CONNECT request")
            writer.write(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            await writer.drain()
            writer.close()
            return
        host, port = target
        name = f"{host}:{port}"
        if not allowed(host.strip("[]"), port, self.rules) and not allowed(host, port, self.rules):
            self.log("deny", name)
            writer.write(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            await writer.drain()
            writer.close()
            return
        try:
            up_r, up_w = await asyncio.wait_for(asyncio.open_connection(host.strip("[]"), port),
                                                timeout=CONNECT_TIMEOUT)
        except (OSError, asyncio.TimeoutError):
            self.log("fail", name)
            writer.write(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            await writer.drain()
            writer.close()
            return
        self.log("allow", name)
        writer.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
        await writer.drain()
        await asyncio.gather(self.pipe(reader, up_w), self.pipe(up_r, writer))


async def serve(sock, proxy):
    server = await asyncio.start_unix_server(proxy.handle, path=sock, limit=HEAD_LIMIT)
    os.chmod(sock, 0o600)
    async with server:
        await server.serve_forever()


def main(argv):
    ap = argparse.ArgumentParser(prog="egress_proxy.py")
    ap.add_argument("--socket")
    ap.add_argument("--check", action="store_true", help="only validate the allowlist")
    ap.add_argument("--allow", required=True)
    ap.add_argument("--log")
    a = ap.parse_args(argv)
    try:
        rules = parse_rules(a.allow)
    except ValueError as e:
        sys.stderr.write(f"orchestra egress: {e}\n")
        return 2
    if not rules:
        sys.stderr.write("orchestra egress: empty allowlist\n")
        return 2
    if a.check:
        return 0
    if not a.socket or not a.log:
        sys.stderr.write("orchestra egress: --socket and --log are required\n")
        return 2
    try:
        asyncio.run(serve(a.socket, Proxy(rules, a.log)))
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
