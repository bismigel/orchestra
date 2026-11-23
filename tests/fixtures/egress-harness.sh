# shellcheck shell=bash
# Test harness for the egress allowlist: from inside the sandbox, try the allowed host through the proxy, a denied
# host, plain HTTP, a direct connection that bypasses the proxy, and DNS. Prints one verdict per probe on stderr,
# then a pi-style event and a valid report. Ports come from FAKE_OK_PORT / FAKE_NO_PORT, baked into the command.
harness_argv() {
  local -n _argv=$1; local task=$2
  _argv=(python3 -I -c '
import os, socket, sys
task, ok_port, no_port = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
def say(s): print("probe: " + s, file=sys.stderr, flush=True)
proxy = os.environ.get("HTTPS_PROXY", "")
say("proxy-env " + ("set" if proxy == "http://127.0.0.1:3128" and os.environ.get("NODE_USE_ENV_PROXY") == "1" else "MISSING"))
if not proxy:   # the default sandbox: no proxy, only the direct probe means anything
    try: socket.create_connection(("127.0.0.1", ok_port), 2); say("direct LEAK")
    except OSError: say("direct blocked")
    print("{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"provider\":\"fake\",\"model\":\"worker-1\",\"usage\":{\"cost\":{\"total\":0.001}}}}")
    open(".orchestra/report.json", "w").write("{\"task\":\"%s\",\"status\":\"done\",\"summary\":\"ok\",\"files_changed\":[],\"checks\":[],\"open_questions\":[]}" % task)
    raise SystemExit(0)
def connect(host, port):
    s = socket.create_connection(("127.0.0.1", 3128), 5)
    s.sendall(f"CONNECT {host}:{port} HTTP/1.1\r\nHost: {host}:{port}\r\n\r\n".encode())
    head = b""
    while b"\r\n\r\n" not in head:
        b = s.recv(1)
        if not b: break
        head += b
    return s, head.split(b"\r\n")[0].decode()
s, status = connect("localhost", ok_port)
if " 200 " in status:
    s.sendall(b"ping\n"); say("allowed " + ("echo-ok" if s.recv(16) == b"ping\n" else "NO-ECHO"))
else: say("allowed REFUSED " + status)
s, status = connect("localhost", no_port); say("denied " + ("403" if " 403 " in status else "LEAK " + status))
s = socket.create_connection(("127.0.0.1", 3128), 5); s.sendall(b"GET http://localhost/ HTTP/1.1\r\nHost: localhost\r\n\r\n")
say("plain-http " + ("403" if b" 403 " in s.recv(64) else "LEAK"))
try: socket.create_connection(("127.0.0.1", ok_port), 2); say("direct LEAK")
except OSError: say("direct blocked")
try: socket.getaddrinfo("example.com", 443); say("dns LEAK")
except OSError: say("dns blocked")
print("{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"provider\":\"fake\",\"model\":\"worker-1\",\"usage\":{\"cost\":{\"total\":0.001}}}}")
open(".orchestra/report.json", "w").write("{\"task\":\"%s\",\"status\":\"done\",\"summary\":\"ok\",\"files_changed\":[],\"checks\":[],\"open_questions\":[]}" % task)
' "$task" "${FAKE_OK_PORT:?}" "${FAKE_NO_PORT:?}")
}
harness_models_used() { echo fake/worker-1; }
harness_usage() { echo '{"responses":1,"cost":0.001}'; }
