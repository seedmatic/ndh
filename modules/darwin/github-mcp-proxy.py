#!/usr/bin/env python3
"""
github-mcp-proxy (relocated under modules/darwin)

See accompanying Nix module github-mcp-proxy.nix which wraps this script with pkgs.writeScriptBin.
Original description:
  Local stdio JSON-RPC proxy to forward MCP requests to the GitHub Copilot MCP endpoint
  injecting an Authorization header fetched dynamically via `gh auth token` (macOS Keychain).

Usage (after enabling module): `github-mcp-proxy --dry-run` or reference it in mcp.json as a stdio command.
"""
from __future__ import annotations
import argparse, json, os, queue, subprocess, sys, threading, time, urllib.request, urllib.error
from typing import Any, Dict, Optional

DEFAULT_REMOTE_URL = os.environ.get("GITHUB_MCP_REMOTE_URL", "https://api.githubcopilot.com/mcp")
DEFAULT_TOKEN_CMD = os.environ.get("GITHUB_MCP_TOKEN_COMMAND", "gh auth token")
DEFAULT_TOKEN_TTL = int(os.environ.get("GITHUB_MCP_TOKEN_TTL", "300"))
USER_AGENT = "github-mcp-proxy/0.1"

class TokenCache:
    def __init__(self, cmd: str, ttl: int, verbose: bool=False):
        self.cmd = cmd; self.ttl = ttl; self.verbose = verbose
        self._token: Optional[str] = None; self._expires_at: float = 0.0
        self._lock = threading.Lock()
    def get(self) -> str:
        with self._lock:
            now = time.time()
            if self._token and now < self._expires_at:
                return self._token
            if self.verbose:
                print(f"[token] refreshing via: {self.cmd}", file=sys.stderr)
            try:
                proc = subprocess.run(self.cmd, shell=True, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            except subprocess.CalledProcessError as e:
                raise RuntimeError(f"Token command failed: {e.stderr.strip() or e}") from e
            token = proc.stdout.strip()
            if not token:
                raise RuntimeError("Token command returned empty output")
            self._token = token; self._expires_at = now + self.ttl
            return token

def make_error(id_value: Any, code: int, message: str, data: Any=None) -> Dict[str, Any]:
    err: Dict[str, Any] = {"jsonrpc": "2.0", "error": {"code": code, "message": message}}
    if data is not None: err["error"]["data"] = data
    if id_value is not None: err["id"] = id_value
    return err

class Forwarder:
    def __init__(self, remote_url: str, token_cache: TokenCache, verbose: bool=False, dry_run: bool=False):
        self.remote_url = remote_url.rstrip('/')
        self.token_cache = token_cache; self.verbose = verbose; self.dry_run = dry_run
        self.q: "queue.Queue[tuple[Optional[str], Optional[Dict[str, Any]]]]" = queue.Queue()
        self._thread = threading.Thread(target=self._run, daemon=True); self._running = False
    def start(self): self._running = True; self._thread.start()
    def stop(self): self._running = False; self.q.put((None, None)); self._thread.join(timeout=2)
    def submit(self, raw_line: str, obj: Dict[str, Any]): self.q.put((raw_line, obj))
    def _run(self):
        while True:
            try: raw_line, obj = self.q.get()
            except Exception: break
            if raw_line is None and obj is None: break
            if not obj: continue
            id_value = obj.get("id")
            try: self._process_request(obj)
            except Exception as e:
                if self.verbose:
                    import traceback; traceback.print_exc()
                print(json.dumps(make_error(id_value, -32000, "Internal error", {"detail": str(e)})), flush=True)
    def _process_request(self, obj: Dict[str, Any]):
        id_value = obj.get("id"); method = obj.get("method")
        if not isinstance(method, str):
            print(json.dumps(make_error(id_value, -32600, "Invalid request: missing method")), flush=True); return
        try: token = self.token_cache.get()
        except Exception as e:
            print(json.dumps(make_error(id_value, -32001, "Token acquisition failed", str(e))), flush=True); return
        if self.dry_run:
            if self.verbose: print(f"[dry-run] would forward method={method}", file=sys.stderr)
            print(json.dumps({"jsonrpc": "2.0", "id": id_value, "result": {"dryRun": True, "method": method}}), flush=True); return
        data = json.dumps(obj).encode("utf-8")
        req = urllib.request.Request(self.remote_url, data=data, headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Authorization": f"Bearer {token}",
            "User-Agent": USER_AGENT,
        }, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                body = resp.read().decode("utf-8")
                if not body.endswith('\n'): body += '\n'
                sys.stdout.write(body); sys.stdout.flush()
        except urllib.error.HTTPError as he:
            payload = he.read().decode('utf-8', errors='replace')
            print(json.dumps(make_error(id_value, -32002, f"Upstream HTTP {he.code}", payload)), flush=True)
        except urllib.error.URLError as ue:
            print(json.dumps(make_error(id_value, -32002, "Network error", str(ue))), flush=True)

def parse_line(line: str, verbose: bool=False) -> Optional[Dict[str, Any]]:
    line = line.strip()
    if not line: return None
    try:
        obj = json.loads(line)
        if not isinstance(obj, dict): raise ValueError("JSON-RPC object must be an object")
        return obj
    except json.JSONDecodeError as e:
        if verbose: print(f"[warn] JSON parse error: {e}", file=sys.stderr)
        print(json.dumps(make_error(None, -32600, f"Parse error: {e.msg}")))
        return None
    except Exception as e:
        if verbose: print(f"[warn] Invalid JSON-RPC: {e}", file=sys.stderr)
        print(json.dumps(make_error(None, -32600, f"Invalid request: {e}")))
        return None

def self_test():
    tc = TokenCache(cmd="echo TEST_TOKEN", ttl=1, verbose=True)
    t1 = tc.get(); assert t1 == "TEST_TOKEN"
    t2 = tc.get(); assert t2 == t1
    time.sleep(1.05); t3 = tc.get(); assert t3 == "TEST_TOKEN"
    print("Self-test passed.")

def main():
    ap = argparse.ArgumentParser(description="Local GitHub MCP proxy (stdio JSON-RPC -> HTTPS)")
    ap.add_argument("--remote-url", default=DEFAULT_REMOTE_URL)
    ap.add_argument("--token-command", default=DEFAULT_TOKEN_CMD)
    ap.add_argument("--token-ttl-seconds", type=int, default=DEFAULT_TOKEN_TTL)
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        self_test(); return 0
    token_cache = TokenCache(args.token_command, args.token_ttl_seconds, verbose=args.verbose)
    forwarder = Forwarder(args.remote_url, token_cache, verbose=args.verbose, dry_run=args.dry_run)
    forwarder.start()
    if args.verbose: print(f"[info] github-mcp-proxy started remote_url={args.remote_url}", file=sys.stderr)
    try:
        for line in sys.stdin:
            obj = parse_line(line, verbose=args.verbose)
            if not obj: continue
            forwarder.submit(line, obj)
    except KeyboardInterrupt:
        if args.verbose: print("[info] interrupted", file=sys.stderr)
    finally:
        forwarder.stop()
    return 0

if __name__ == "__main__":
    sys.exit(main())

