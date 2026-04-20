#!/usr/bin/env python3
"""Summer — Miette's local conception organ.

Runs as an HTTP server on the laptop. Miette calls her for drafts.
Post-processes output to deduplicate policies and ensure clean termination.

Usage:
  python3 summer/serve.py                  # start on port 8787
  python3 summer/serve.py --port 9000      # custom port
  curl localhost:8787/conceive -d '{"vision": "a veterinary clinic"}'
"""

import json
import sys
import os
from http.server import HTTPServer, BaseHTTPRequestHandler

# Will be set after model loads
MODEL = None
TOKENIZER = None
ADAPTER_PATH = os.environ.get(
    "SUMMER_ADAPTER",
    "/tmp/summer_adapter_v3"
)
BASE_MODEL = os.environ.get(
    "SUMMER_MODEL",
    "mlx-community/Qwen2.5-3B-Instruct-4bit"
)

def load_model():
    global MODEL, TOKENIZER
    from mlx_lm import load
    print(f"Loading {BASE_MODEL} + {ADAPTER_PATH}...")
    MODEL, TOKENIZER = load(BASE_MODEL, adapter_path=ADAPTER_PATH)
    print("Summer is ready.")

def conceive(vision: str) -> dict:
    """Generate a domain from a vision, post-process, validate."""
    from mlx_lm import generate

    messages = [{"role": "user", "content": f"Conceive a domain for: {vision}"}]
    prompt = TOKENIZER.apply_chat_template(
        messages, tokenize=False, add_generation_prompt=True
    )

    raw = generate(MODEL, TOKENIZER, prompt=prompt, max_tokens=1500, verbose=False)
    clean = postprocess(raw)

    # Try to validate
    valid = validate(clean)

    return {
        "bluebook": clean,
        "valid": valid,
        "raw_tokens": len(raw),
    }

def postprocess(raw: str) -> str:
    """Deduplicate policy lines, ensure clean end."""
    lines = raw.split("\n")
    seen_policies = set()
    clean = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("policy"):
            if stripped in seen_policies:
                continue
            seen_policies.add(stripped)
        clean.append(line)

    output = "\n".join(clean).rstrip()
    if not output.endswith("end"):
        output += "\nend"
    return output

def validate(bluebook: str) -> bool:
    """Run hecks-life validate on the output."""
    import subprocess
    import tempfile

    with tempfile.NamedTemporaryFile(mode="w", suffix=".bluebook", delete=False) as f:
        f.write(bluebook)
        path = f.name

    try:
        result = subprocess.run(
            ["hecks_life/target/debug/hecks-life", "validate", path],
            capture_output=True, text=True,
            cwd="/Users/christopheryoung/Projects/hecks",
        )
        return "VALID" in result.stdout
    finally:
        os.unlink(path)

def critique(bluebook: str) -> dict:
    """Ask Summer to review a domain."""
    from mlx_lm import generate

    messages = [{"role": "user", "content": f"What's wrong with this domain?\n\n{bluebook}"}]
    prompt = TOKENIZER.apply_chat_template(
        messages, tokenize=False, add_generation_prompt=True
    )
    response = generate(MODEL, TOKENIZER, prompt=prompt, max_tokens=500, verbose=False)
    return {"critique": response}


class SummerHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length)) if length else {}

        if self.path == "/conceive":
            vision = body.get("vision", "")
            if not vision:
                self.send_json(400, {"error": "vision required"})
                return
            result = conceive(vision)
            self.send_json(200, result)

        elif self.path == "/critique":
            bluebook = body.get("bluebook", "")
            if not bluebook:
                self.send_json(400, {"error": "bluebook required"})
                return
            result = critique(bluebook)
            self.send_json(200, result)

        else:
            self.send_json(404, {"error": "not found"})

    def do_GET(self):
        if self.path == "/health":
            self.send_json(200, {"status": "ready", "model": BASE_MODEL, "adapter": ADAPTER_PATH})
        else:
            self.send_json(200, {
                "name": "Summer",
                "role": "Miette's local conception organ",
                "endpoints": ["/conceive", "/critique", "/health"],
            })

    def send_json(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print(f"  ⚡ {args[0]}")


if __name__ == "__main__":
    port = 8787
    for i, arg in enumerate(sys.argv):
        if arg == "--port" and i + 1 < len(sys.argv):
            port = int(sys.argv[i + 1])

    load_model()
    print(f"Summer listening on http://localhost:{port}")
    HTTPServer(("0.0.0.0", port), SummerHandler).serve_forever()
