#!/usr/bin/env bash
# D02: incremental synchronization matches a reference model. Ranged edits
# (insert/delete/replace, multi-change notifications, multi-line ranges, EOF,
# supplementary characters) applied via didChange must converge to exactly the
# same analysis as opening the final text fresh. An inverted range rejects the
# whole notification and leaves the document unchanged.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" <<'PY'
import json, subprocess, sys
srv = sys.argv[1]
def frame(o):
    b = json.dumps(o, separators=(",", ":")).encode()
    return b"Content-Length: " + str(len(b)).encode() + b"\r\n\r\n" + b

# --- reference model: LSP UTF-16 positions -> Python string splice ----------
def index_of(text, line, char):
    lines = text.split("\n")
    line = min(max(line, 0), len(lines) - 1)
    base = 0
    for k in range(line):
        base += len(lines[k]) + 1
    col = 0; i = 0
    while i < len(lines[line]) and col < char:
        col += 2 if ord(lines[line][i]) > 0xFFFF else 1
        i += 1
    return base + i

def apply_edit(text, sline, schar, eline, echar, new):
    s = index_of(text, sline, schar)
    e = index_of(text, eline, echar)
    return text[:s] + new + text[e:]

BASE = ('def f(name: i64) -> i64:\n'
        '    msg: dstr = "héllo 🌍"\n'
        '    x: i64 = 1\n'
        '    return name\n')

EDITS = [
    # (startLine, startChar, endLine, endChar, newText)
    (0, 8, 0, 12, "value"),                    # rename param
    (1, 4, 1, 7, "txt"),                       # rename local
    (2, 11, 2, 12, "42"),                      # replace literal
    (3, 0, 3, 10, "    return value + x\n"),   # replace whole line
    (1, 16, 1, 21, "wörld"),                   # replace inside string, after astral char
    (4, 0, 4, 0, "    pass\n"),                # insert at EOF (line 4 empty)
    (2, 4, 2, 4, "# c\n"),                     # insert with newline mid-line
    (0, 25, 1, 4, ""),                         # delete across a line boundary
]

msgs = [frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})]
msgs.append(frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
                   "params":{"textDocument":{"uri":"file:///inc.elisa","languageId":"Elisa","version":1,"text":BASE}}}))

expected = BASE
version = 1
for (sl, sc, el, ec, new) in EDITS:
    expected = apply_edit(expected, sl, sc, el, ec, new)
    version += 1
    msgs.append(frame({"jsonrpc":"2.0","method":"textDocument/didChange",
                       "params":{"textDocument":{"uri":"file:///inc.elisa","version":version},
                                 "contentChanges":[{"range":{"start":{"line":sl,"character":sc},
                                                             "end":{"line":el,"character":ec}},
                                                    "rangeLength":0,"text":new}]}}))
# Multi-change notification: three sequential edits in one message.
multi = [((0, 4), (0, 8), "renamed"), ((0, 12), (0, 12), " /*a*/"), ((1, 0), (1, 0), "    # lead\n")]
for (s, e, new) in multi:
    expected = apply_edit(expected, s[0], s[1], e[0], e[1], new)
version += 1
msgs.append(frame({"jsonrpc":"2.0","method":"textDocument/didChange",
                   "params":{"textDocument":{"uri":"file:///inc.elisa","version":version},
                             "contentChanges":[{"range":{"start":{"line":s[0],"character":s[1]},
                                                         "end":{"line":e[0],"character":e[1]}}, "text":new} for (s,e,new) in multi]}}))

# Tokens for the edited document.
msgs.append(frame({"jsonrpc":"2.0","id":2,"method":"textDocument/semanticTokens/full",
                   "params":{"textDocument":{"uri":"file:///inc.elisa"}}}))
# Inverted range: rejected, document unchanged.
msgs.append(frame({"jsonrpc":"2.0","method":"textDocument/didChange",
                   "params":{"textDocument":{"uri":"file:///inc.elisa","version":version+1},
                             "contentChanges":[{"range":{"start":{"line":2,"character":5},
                                                         "end":{"line":2,"character":1}}, "text":"XX"}]}}))
msgs.append(frame({"jsonrpc":"2.0","id":3,"method":"textDocument/semanticTokens/full",
                   "params":{"textDocument":{"uri":"file:///inc.elisa"}}}))
# Fresh open of the expected final text as the independent oracle.
msgs.append(frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
                   "params":{"textDocument":{"uri":"file:///oracle.elisa","languageId":"Elisa","version":1,"text":expected}}}))
msgs.append(frame({"jsonrpc":"2.0","id":4,"method":"textDocument/semanticTokens/full",
                   "params":{"textDocument":{"uri":"file:///oracle.elisa"}}}))
msgs.append(frame({"jsonrpc":"2.0","id":9,"method":"shutdown"}))
msgs.append(frame({"jsonrpc":"2.0","method":"exit"}))

p = subprocess.run([srv], input=b"".join(msgs), capture_output=True, timeout=60)
assert p.returncode == 0, f"exit {p.returncode}"
out, pos, res = p.stdout, 0, {}
while pos < len(out):
    sep = out.find(b"\r\n\r\n", pos)
    ln = int(out[pos:sep].split(b":",1)[1].strip())
    start = sep+4
    msg = json.loads(out[start:start+ln])  # every frame valid JSON
    if msg.get("id") in (2,3,4): res[msg["id"]] = msg["result"]["data"]
    pos = start+ln

assert res.get(2), "edited document produced no tokens"
assert res.get(4), "oracle document produced no tokens"
assert res[2] == res[4], (
    "incremental edits diverged from the reference model\n"
    f"  edited={res[2][:40]}\n  oracle={res[4][:40]}\n  expected text={expected!r}"
)
assert res[3] == res[2], "an inverted-range change must not mutate the document"

print("incremental sync OK: ranged edits converge to the fresh-open oracle; inverted rejected")
PY
