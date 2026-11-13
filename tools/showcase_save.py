"""Serves the showcase page and saves the images it renders into docs/screens.

    node tools/test.js --showcase /tmp/show/index.html
    python3 tools/showcase_save.py /tmp/show
    open http://localhost:8767/index.html?save

The page draws each presentation image on a canvas and POSTs it here as /save?name=<file>.
"""
import os
import re
import shutil
import subprocess
import sys
from http.server import HTTPServer, SimpleHTTPRequestHandler
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "docs", "screens")
PAGE_DIR = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=PAGE_DIR, **kwargs)

    def do_POST(self):
        url = urlparse(self.path)
        name = parse_qs(url.query).get("name", [""])[0]
        if url.path != "/save" or not re.fullmatch(r"[a-z0-9-]{1,40}", name):
            self.send_error(400, "bad name")
            return
        size = int(self.headers.get("Content-Length", "0"))
        data = self.rfile.read(size)
        if not data.startswith(b"\x89PNG"):
            self.send_error(400, "not a PNG")
            return
        os.makedirs(OUT, exist_ok=True)
        png = os.path.join(OUT, name + ".png")
        with open(png, "wb") as f:
            f.write(data)
        # the PNGs are large (soft gradients); keep a high-quality JPEG instead where we can
        jpg = os.path.join(OUT, name + ".jpg")
        if shutil.which("sips") and subprocess.run(
                ["sips", "-s", "format", "jpeg", "-s", "formatOptions", "88", png, "--out", jpg],
                capture_output=True).returncode == 0:
            os.remove(png)
            print("saved", name + ".jpg", os.path.getsize(jpg), "bytes", flush=True)
        else:
            print("saved", name + ".png", len(data), "bytes", flush=True)
        self.send_response(204)
        self.end_headers()


if __name__ == "__main__":
    print("serving", PAGE_DIR, "on http://localhost:8767, saving to", os.path.abspath(OUT), flush=True)
    HTTPServer(("127.0.0.1", 8767), Handler).serve_forever()
