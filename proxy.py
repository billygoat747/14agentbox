#!/usr/bin/env python3
"""
14agentbox Zero-Trust Host Credential Proxy
Listens locally on 127.0.0.1:8040 (host.docker.internal:8040).
Intercepts outbound requests from the sandbox container and injects real API keys
from the host .env file, ensuring secrets never enter the Docker container.
"""

import argparse
import http.server
import os
import socketserver
import sys
import urllib.error
import urllib.parse
import urllib.request

# Default listen configuration
DEFAULT_HOST = "0.0.0.0"
DEFAULT_PORT = 8040


def load_env(env_path):
    """Load key-value pairs from an env file without overriding existing env vars."""
    env = {}
    if os.path.isfile(env_path):
        with open(env_path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" in line:
                    key, val = line.split("=", 1)
                    key = key.strip()
                    val = val.strip().strip("\"'")
                    env[key] = val
    return env


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        # Silence verbose request logs to keep terminal output clean
        pass

    def do_GET(self):
        self._handle_proxy()

    def do_POST(self):
        self._handle_proxy()

    def do_PUT(self):
        self._handle_proxy()

    def do_DELETE(self):
        self._handle_proxy()

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _resolve_target(self, path):
        """
        Map incoming request path to upstream target URL and inject appropriate secret headers.
        """
        print(f"[DEBUG proxy] Request path: {path}", flush=True)
        env = self.server.secrets
        headers = {}

        if path.startswith("/health"):
            return None, None, True

        # OpenRouter routing: /openrouter/* -> https://openrouter.ai/*
        if path.startswith("/openrouter/"):
            target_path = path[len("/openrouter"):]
            target_url = "https://openrouter.ai" + target_path
            api_key = env.get("OPENROUTER_API_KEY") or os.environ.get("OPENROUTER_API_KEY", "")
            if api_key:
                headers["Authorization"] = f"Bearer {api_key}"
            headers["HTTP-Referer"] = "https://14agentbox.local"
            headers["X-Title"] = "14agentbox"
            return target_url, headers, False

        # OpenAI routing: /openai/* -> https://api.openai.com/*
        if path.startswith("/openai/"):
            target_path = path[len("/openai"):]
            target_url = "https://api.openai.com" + target_path
            api_key = env.get("OPENAI_API_KEY") or os.environ.get("OPENAI_API_KEY", "")
            if api_key:
                headers["Authorization"] = f"Bearer {api_key}"
            return target_url, headers, False

        # Google Gemini routing: /google/* -> https://generativelanguage.googleapis.com/*
        if path.startswith("/google/"):
            target_path = path[len("/google"):]
            if not (target_path.startswith("/v1/") or target_path.startswith("/v1beta/")):
                target_path = "/v1beta" + target_path
            target_url = "https://generativelanguage.googleapis.com" + target_path
            api_key = env.get("GOOGLEAI_API_KEY") or env.get("GEMINI_API_KEY") or os.environ.get("GOOGLEAI_API_KEY", "")
            if api_key:
                headers["x-goog-api-key"] = api_key
            return target_url, headers, False

        # Exa MCP routing: /mcp/exa* -> https://mcp.exa.ai/mcp*
        if path.startswith("/mcp/exa"):
            target_path = path[len("/mcp/exa"):]
            target_url = "https://mcp.exa.ai/mcp" + target_path
            api_key = env.get("EXA_API_KEY") or os.environ.get("EXA_API_KEY", "")
            if api_key:
                headers["x-api-key"] = api_key
            return target_url, headers, False

        # Unknown prefix: return 404
        return None, None, False

    def _handle_proxy(self):
        target_url, injected_headers, is_health = self._resolve_target(self.path)

        if is_health:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            response = b'{"status":"ok","proxy":"14agentbox-zero-trust"}'
            self.send_header("Content-Length", str(len(response)))
            self.end_headers()
            self.wfile.write(response)
            return

        if not target_url:
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            msg = b'{"error":"Unknown route in 14agentbox proxy"}'
            self.send_header("Content-Length", str(len(msg)))
            self.end_headers()
            self.wfile.write(msg)
            return

        # Read request body
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length) if content_length > 0 else None

        # Build outbound headers
        out_headers = {}
        for k, v in self.headers.items():
            if k.lower() not in ("host", "authorization", "x-api-key", "x-goog-api-key", "accept-encoding"):
                out_headers[k] = v

        # Inject real secrets
        out_headers.update(injected_headers)

        req = urllib.request.Request(
            target_url,
            data=body,
            headers=out_headers,
            method=self.command
        )

        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                self.send_response(resp.status)
                has_content_length = False
                for header, value in resp.getheaders():
                    # Strip hop-by-hop headers
                    if header.lower() not in ("transfer-encoding", "connection", "content-encoding"):
                        if header.lower() == "content-length":
                            has_content_length = True
                        self.send_header(header, value)

                if not has_content_length:
                    self.send_header("Connection", "close")
                    self.close_connection = True

                self.end_headers()

                # Stream response chunks (supports SSE with low latency)
                while True:
                    chunk = resp.read1(4096) if hasattr(resp, "read1") else resp.read(1024)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()


        except urllib.error.HTTPError as e:
            err_body = e.read()
            print(f"[DEBUG proxy] Upstream HTTP error {e.code}: {err_body.decode('utf-8', 'ignore')}", flush=True)
            self.send_response(e.code)
            for header, value in e.headers.items():
                if header.lower() not in ("transfer-encoding", "connection"):
                    self.send_header(header, value)
            self.end_headers()
            if err_body:
                self.wfile.write(err_body)
                self.wfile.flush()


        except Exception as e:
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            err_msg = f'{{"error": "14agentbox proxy gateway error", "details": "{str(e)}"}}\n'.encode("utf-8")
            self.send_header("Content-Length", str(len(err_msg)))
            self.end_headers()
            self.wfile.write(err_msg)


class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    parser = argparse.ArgumentParser(description="14agentbox Zero-Trust Host Credential Proxy")
    parser.add_argument("--host", default=DEFAULT_HOST, help="Host to bind (default 0.0.0.0)")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="Port to bind (default 8040)")
    parser.add_argument("--env-file", default=None, help="Path to .env file containing host secrets")
    args = parser.parse_args()

    env_file = args.env_file
    if not env_file:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        env_file = os.path.join(script_dir, ".env")

    secrets = load_env(env_file)

    server = ThreadedHTTPServer((args.host, args.port), ProxyHandler)
    server.secrets = secrets

    print(f"[14agentbox proxy] Listening on http://{args.host}:{args.port} (loaded secrets from {env_file})", flush=True)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[14agentbox proxy] Shutting down cleanly.", flush=True)
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
