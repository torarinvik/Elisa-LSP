#!/usr/bin/env bash
# Smoke test: textDocument/hover surfaces a docs/119 loop-header capture list —
# "Mutates (captured, in place): …" plus "Loop-private accumulators: …" — reports
# "Pure over outer state" for a header with no captures, and returns null on a
# non-header line and on a bitwise `|` that is not a header.
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[ -x "$SRV" ] || { echo "hover test SKIP: $SRV not built" >&2; exit 0; }

python3 - "$SRV" <<'PY'
import subprocess, json, sys, re
srv = sys.argv[1]
def frame(o):
    b = json.dumps(o); return f"Content-Length: {len(b)}\r\n\r\n{b}".encode()
# line 3: capture header; line 6: no-capture header; line 9: bitwise | (not a header)
doc = ("def f(xs: darray[i64], a: i64, b: i64) -> i64:\n"      # 0
       "    total: mutable i64 = 0\n"                          # 1
       "    r: i64 =\n"                                        # 2
       "        for x in xs |acc = 0, total| -> acc:\n"        # 3
       "            total <- total + x\n"                      # 4
       "            acc <- acc + 1\n"                          # 5
       "    s: i64 =\n"                                        # 6
       "        for x in xs |n = 0| -> n:\n"                   # 7
       "            n <- n + 1\n"                              # 8
       "    for y in 0..<(a | b):\n"                           # 9
       "        total <- total + y\n"                          # 10
       "    return total + r + s\n")                           # 11
def hover(line, ch, id):
    return frame({"jsonrpc":"2.0","id":id,"method":"textDocument/hover",
                  "params":{"textDocument":{"uri":"file:///t.elisa"},"position":{"line":line,"character":ch}}})
m  = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///t.elisa","languageId":"Elisa","version":1,"text":doc}}})
m += hover(3, 20, 2)   # capture header
m += hover(7, 20, 3)   # no-capture header
m += hover(9, 20, 4)   # bitwise | — not a header
m += hover(1, 5, 5)    # ordinary decl line
m += frame({"jsonrpc":"2.0","method":"exit"})
out = subprocess.run([srv], input=m, capture_output=True, timeout=30).stdout.decode(errors="replace")
res = {}
for mm in re.finditer(r'\{"jsonrpc":"2\.0","id":(\d+),"result":(.*?)\}(?=Content-Length|\Z)', out, re.S):
    res[int(mm.group(1))] = mm.group(2)
def fail(msg): print("hover test FAIL:", msg, file=sys.stderr); sys.exit(1)
r2 = res.get(2, "")
if "captured, in place): total" not in r2 or "accumulators: acc" not in r2:
    fail(f"capture header hover wrong: {r2}")
r3 = res.get(3, "")
if "Pure over outer state" not in r3:
    fail(f"no-capture header hover wrong: {r3}")
if res.get(4, "").strip() != "null":
    fail(f"bitwise | must not hover: {res.get(4)}")
if res.get(5, "").strip() != "null":
    fail(f"ordinary line must not hover: {res.get(5)}")
print("hover smoke OK: capture list, pure-over-outer, bitwise-| safe, null off-header")
PY
