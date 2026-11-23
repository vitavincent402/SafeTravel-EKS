"""임시 api: /healthz, /api/healthz (vault까지 연결 확인). 실제 구현으로 교체하세요."""
import json, os, urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

VAULT_URL = os.environ.get("VAULT_URL", "http://keeper-vault:8080")


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/healthz":
            return self._send(200, {"status": "ok"})
        if self.path == "/api/healthz":
            try:
                with urllib.request.urlopen(f"{VAULT_URL}/healthz", timeout=3) as r:
                    vault = json.load(r)
            except Exception as e:  # noqa: BLE001
                vault = {"error": str(e)}
            return self._send(200, {"api": "ok", "vault": vault})
        return self._send(404, {"error": "not found"})

    def log_message(self, *args):
        pass


HTTPServer(("0.0.0.0", int(os.environ.get("PORT", "8080"))), Handler).serve_forever()
