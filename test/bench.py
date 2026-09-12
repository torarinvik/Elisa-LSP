#!/usr/bin/env python3
"""B04 baseline measurements: startup, clean-open, edit, cached tokens, hover.

Runs against a freshly built executable; records wall time, source bytes,
token count, and toolchain provenance. Single-command rerun:
    python3 test/bench.py [--sizes 100,1000,5000] [--out bench/results.json]

Numbers are baselines to calibrate budgets against, not pass/fail gates.
"""
import json, os, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRV = os.path.join(ROOT, "build", "elisa-lsp")
MANIFEST = os.path.join(ROOT, "build", "manifest.json")

def frame(o):
    b = json.dumps(o, separators=(",", ":")).encode()
    return b"Content-Length: " + str(len(b)).encode() + b"\r\n\r\n" + b

def gen_doc(n_lines):
    lines = ["def f%d(x: i64) -> i64:" % i for i in range(n_lines)]
    # each function: 3 lines to keep parse realistic
    out = []
    for i in range(n_lines):
        out.append(f"def f{i}(x: i64) -> i64:")
        out.append(f"    y: i64 = x + {i}")
        out.append(f"    return y")
    return "\n".join(out) + "\n"

def roundtrip(payload: bytes, timeout=60):
    t0 = time.perf_counter()
    p = subprocess.run([SRV], input=payload, capture_output=True, timeout=timeout)
    dt = time.perf_counter() - t0
    return p.stdout, dt

def parse_frames(buf: bytes):
    msgs = []
    pos = 0
    while True:
        sep = buf.find(b"\r\n\r\n", pos)
        if sep < 0:
            break
        length = int(buf[pos:sep].split(b":", 1)[1].strip())
        start = sep + 4
        msgs.append(json.loads(buf[start:start+length]))
        pos = start + length
    return msgs

def bench_size(n):
    doc = gen_doc(n)
    src_bytes = len(doc.encode())
    uri = f"file:///bench-{n}.elisa"
    # startup+init
    m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
    m += frame({"jsonrpc":"2.0","method":"exit"})
    _, t_init = roundtrip(m)
    # clean open (init + didOpen + tokens + hover + exit)
    m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
    m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
                "params":{"textDocument":{"uri":uri,"languageId":"Elisa","version":1,"text":doc}}})
    m += frame({"jsonrpc":"2.0","id":2,"method":"textDocument/semanticTokens/full",
                "params":{"textDocument":{"uri":uri}}})
    m += frame({"jsonrpc":"2.0","id":3,"method":"textDocument/hover",
                "params":{"textDocument":{"uri":uri},"position":{"line":1,"character":5}}})
    m += frame({"jsonrpc":"2.0","method":"exit"})
    out, t_open = roundtrip(m, timeout=120)
    msgs = parse_frames(out)
    ntoks = 0
    for msg in msgs:
        if msg.get("id") == 2:
            ntoks = len(msg.get("result", {}).get("data", [])) // 5
    # one edit + cached tokens
    edited = doc + "def extra() -> void:\n    pass\n"
    m = frame({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
    m += frame({"jsonrpc":"2.0","method":"textDocument/didOpen",
                "params":{"textDocument":{"uri":uri,"languageId":"Elisa","version":1,"text":doc}}})
    t0 = time.perf_counter()
    m2 = m + frame({"jsonrpc":"2.0","method":"textDocument/didChange",
                "params":{"textDocument":{"uri":uri,"version":2},"contentChanges":[{"text":edited}]}})
    m2 += frame({"jsonrpc":"2.0","id":2,"method":"textDocument/semanticTokens/full",
                "params":{"textDocument":{"uri":uri}}})
    m2 += frame({"jsonrpc":"2.0","method":"exit"})
    out2, t_edit = roundtrip(m2, timeout=120)
    return {"lines": n*3, "src_bytes": src_bytes, "tokens": ntoks,
            "t_init_s": round(t_init,3), "t_open_tokens_hover_s": round(t_open,3),
            "t_edit_retoken_s": round(t_edit,3)}

def main():
    sizes = [100, 1000]
    out_path = None
    for a in sys.argv[1:]:
        if a.startswith("--sizes="):
            sizes = [int(x) for x in a.split("=",1)[1].split(",")]
        elif a.startswith("--out="):
            out_path = a.split("=",1)[1]
    prov = json.load(open(MANIFEST)) if os.path.isfile(MANIFEST) else {}
    results = {"provenance": prov, "cases": []}
    for n in sizes:
        print(f"bench fns={n} ...", flush=True)
        r = bench_size(n)
        print(f"  lines={r['lines']} bytes={r['src_bytes']} tokens={r['tokens']} "
              f"init={r['t_init_s']}s open={r['t_open_tokens_hover_s']}s edit={r['t_edit_retoken_s']}s")
        results["cases"].append(r)
    if out_path:
        os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
        json.dump(results, open(out_path, "w"), indent=2)
        print(f"wrote {out_path}")
    else:
        print(json.dumps(results, indent=2))

if __name__ == "__main__":
    main()
