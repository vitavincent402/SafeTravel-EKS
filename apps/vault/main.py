"""임시 vault: /healthz. 실제 구현(서류 업로드·열람, KMS 봉투 암호화)으로 교체하세요."""
import json, os
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        code, body = (200, {"status": "ok"}) if self.path == "/healthz" else (404, {"error": "not found"})
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


HTTPServer(("0.0.0.0", int(os.environ.get("PORT", "8080"))), Handler).serve_forever()
