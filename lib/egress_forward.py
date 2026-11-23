#!/usr/bin/env python3
"""orchestra egress forwarder: runs INSIDE the sandbox, which has no network but loopback.

Listens on 127.0.0.1:<port> and relays each connection to the egress proxy's unix socket (bound into the sandbox).
It enforces nothing: the policy is in egress_proxy.py, outside the sandbox. HTTPS_PROXY points here.

  egress_forward.py <unix-socket> <port>
Standard library only.
"""
import asyncio
import sys


async def pipe(reader, writer):
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


def handler(sock):
    async def handle(reader, writer):
        try:
            up_r, up_w = await asyncio.open_unix_connection(sock)
        except OSError:
            writer.close()
            return
        await asyncio.gather(pipe(reader, up_w), pipe(up_r, writer))
    return handle


async def serve(sock, port):
    server = await asyncio.start_server(handler(sock), "127.0.0.1", port)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(serve(sys.argv[1], int(sys.argv[2])))
