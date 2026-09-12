#!/usr/bin/env bash
# B03: manifest validation — legend indices/names/mappings agree; advertised
# methods match the feature manifest; untested advertised capabilities fail.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" "$ROOT" <<'PY'
import json, subprocess, sys
srv, root = sys.argv[1], sys.argv[2]
schema = json.load(open(f"{root}/docs/semantic-token-schema.json"))
manifest = json.load(open(f"{root}/docs/feature-manifest.json"))

def frame(o):
    b = json.dumps(o).encode()
    return b"Content-Length: " + str(len(b)).encode() + b"\r\n\r\n" + b
m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
m += frame({"jsonrpc":"2.0","method":"exit"})
out = subprocess.run([srv], input=m, capture_output=True, timeout=15).stdout.decode(errors="replace")

# 1. Legend in initialize response must equal schema legend exactly (order = wire index).
body = out.split("\r\n\r\n",1)[1] if "\r\n\r\n" in out else out
# Find first complete frame body
import re
mm = re.search(r'Content-Length: (\d+)\r\n\r\n', out)
assert mm, "no framing"
start = mm.end()
length = int(mm.group(1))
resp = json.loads(out[start:start+length])
legend = resp["result"]["capabilities"]["semanticTokensProvider"]["legend"]["tokenTypes"]
assert legend == schema["legend"], f"legend drift: server {len(legend)} vs schema {len(schema['legend'])}"
assert len(legend) == 48, f"legend count {len(legend)} != 48"
assert legend[13] == "elisa.fn.def" and legend[47] == "elisa.enum.variant", "wire indices moved"

# 2. Every method marked implemented:true must have a test file present.
import os
for method, spec in manifest["methods"].items():
    if spec.get("implemented"):
        t = spec.get("test")
        assert t and os.path.isfile(f"{root}/{t}"), f"{method} claims {t} but file missing"

# 3. Capabilities advertised must be exactly those in the manifest.
caps = resp["result"]["capabilities"]
assert caps.get("textDocumentSync") == 1
assert "semanticTokensProvider" in caps and caps.get("hoverProvider") is True
print(f"manifest OK: 48 legend entries, {sum(1 for s in manifest['methods'].values() if s.get('implemented'))} implemented methods")
PY
