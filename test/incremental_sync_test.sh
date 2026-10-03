#!/usr/bin/env bash
# D02: incremental synchronization must match a fresh-open reference model.
# This exercises sequential full and ranged changes (including mixed batches),
# UTF-16 positions around non-ASCII text, CRLF line endings, boundary edits,
# and transaction rollback when a later change in a notification is invalid.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

python3 - "$SRV" "$ROOT" <<'PY'
import json
import os
import random
import sys

sys.path.insert(0, os.path.join(sys.argv[2], "test"))
from lsp_client import LspSession

srv = sys.argv[1]
URI = "file:///incremental-seeded.elisa"

def frame(obj):
    # Keep the deterministic change/request plan as JSON objects. LspSession
    # performs exact UTF-8 byte framing when each item is sent.
    return obj

def utf16_length(text):
    return sum(2 if ord(ch) > 0xFFFF else 1 for ch in text)

def line_spans(text):
    """Return (line start, content end, next line start), excluding CRLF."""
    spans = []
    start = 0
    i = 0
    while i < len(text):
        if text[i] == "\n":
            end = i - 1 if i > start and text[i - 1] == "\r" else i
            spans.append((start, end, i + 1))
            start = i + 1
        elif text[i] == "\r" and (i + 1 == len(text) or text[i + 1] != "\n"):
            # Keep the oracle well-defined if a replacement creates a lone CR.
            spans.append((start, i, i + 1))
            start = i + 1
        i += 1
    spans.append((start, len(text), len(text)))
    return spans

def index_of(text, line, character):
    spans = line_spans(text)
    if line < 0 or line >= len(spans):
        raise AssertionError(f"invalid generated line {line} for {text!r}")
    start, end, _ = spans[line]
    units = 0
    for i in range(start, end):
        if units == character:
            return i
        width = 2 if ord(text[i]) > 0xFFFF else 1
        if units < character < units + width:
            raise AssertionError("generator selected the middle of a UTF-16 surrogate pair")
        units += width
    if units == character:
        return end
    raise AssertionError(f"invalid generated character {character} on line {line}")

def position_at(text, offset):
    """Map a Python code-point boundary to an LSP UTF-16 position."""
    if offset < 0 or offset > len(text):
        raise AssertionError(f"invalid generated offset {offset}")
    for line, (start, end, _) in enumerate(line_spans(text)):
        if start <= offset <= end:
            return {"line": line, "character": utf16_length(text[start:offset])}
    raise AssertionError(f"offset {offset} is inside a CRLF line ending")

def position_tuple(pos):
    return pos["line"], pos["character"]

def apply_edit(text, start, end, new_text):
    a = index_of(text, start["line"], start["character"])
    b = index_of(text, end["line"], end["character"])
    if a > b:
        raise AssertionError("reference model only applies ordered edits")
    return text[:a] + new_text + text[b:]

class Reference:
    def __init__(self, text):
        self.text = text

    def ranged(self, start_offset, end_offset, new_text):
        before = self.text
        start = position_at(before, start_offset)
        end = position_at(before, end_offset)
        a = index_of(before, start["line"], start["character"])
        b = index_of(before, end["line"], end["character"])
        if a != start_offset or b != end_offset or a > b:
            raise AssertionError("generated offsets did not round-trip through LSP coordinates")
        change = {
            "range": {"start": start, "end": end},
            "rangeLength": utf16_length(before[a:b]),
            "text": new_text,
        }
        self.text = before[:a] + new_text + before[b:]
        return change

    def full_after_local_edit(self, start_offset, end_offset, new_text):
        """Model a client-side edit that it then sends as a full snapshot."""
        before = self.text
        start = position_at(before, start_offset)
        end = position_at(before, end_offset)
        a = index_of(before, *position_tuple(start))
        b = index_of(before, *position_tuple(end))
        if a != start_offset or b != end_offset or a > b:
            raise AssertionError("generated full-sync patch has invalid boundaries")
        self.text = before[:a] + new_text + before[b:]
        return {"text": self.text}

    def positions_before_marker(self):
        limit = self.text.index("# STABLE_ANCHOR")
        out = []
        for line, (start, end, _) in enumerate(line_spans(self.text)):
            units = 0
            for offset in range(start, end + 1):
                if offset >= limit:
                    break
                out.append((offset, {"line": line, "character": units}))
                if offset < end:
                    units += 2 if ord(self.text[offset]) > 0xFFFF else 1
        if not out:
            raise AssertionError("stable tail unexpectedly has no editable prefix")
        return out

    def random_offsets(self, rng):
        positions = self.positions_before_marker()
        a = rng.choice(positions)[0]
        b = rng.choice(positions)[0]
        return (a, b) if a <= b else (b, a)

def first_span(text, needle):
    start = text.find(needle)
    if start < 0:
        raise AssertionError(f"expected reference text to contain {needle!r}")
    return start, start + len(needle)

BASE = (
    'def f(name: i64) -> i64:\r\n'
    '    msg: dstr = "héllo 🌍"\r\n'
    '    value: i64 = 1\r\n'
    '    return value\r\n'
    '\r\n'
    '# STABLE_ANCHOR\r\n'
    'def stable_anchor() -> i64:\r\n'
    '    return 9\r\n'
)

messages = []
reference = Reference(BASE)
version = 1
messages.append(frame({"jsonrpc": "2.0", "method": "textDocument/didOpen",
                       "params": {"textDocument": {"uri": URI, "languageId": "Elisa",
                                                       "version": version, "text": reference.text}}}))

# One deliberately mixed notification: boundary insert, a UTF-16 edit after
# an astral scalar, line-end/CRLF edits, boundary deletion, and two full
# snapshots interleaved with ranged changes. The reference advances in the
# same order as contentChanges must be applied.
mixed = []
mixed.append(reference.ranged(0, 0, "# seeded header\r\n"))
emoji = reference.text.index("🌍")
mixed.append(reference.ranged(emoji, emoji + 1, "🪐"))
value_line = reference.text.index("    value: i64 = 1")
line_end = value_line + len("    value: i64 = 1")
mixed.append(reference.ranged(line_end, line_end, "\r\n    # CRLF boundary"))
# Delete the inserted first line by selecting from file start through its CRLF.
mixed.append(reference.ranged(0, len("# seeded header\r\n"), ""))
# Insert at the true EOF (after the final CRLF), then send a full snapshot
# after a separate local edit.
mixed.append(reference.ranged(len(reference.text), len(reference.text), "# EOF boundary\r\n"))
lo, _ = first_span(reference.text, "value: i64 = 1")
digit = lo + len("value: i64 = ")
mixed.append(reference.full_after_local_edit(digit, digit + 1, "2"))
# A ranged insertion after source text, followed by a second full snapshot
# containing a distinct client-side edit.
ret = reference.text.index("return value") + len("return value")
mixed.append(reference.ranged(ret, ret, " + 1"))
lo, hi = first_span(reference.text, "héllo")
mixed.append(reference.full_after_local_edit(lo, hi, "halló"))
# Boundary deletion at EOF leaves the preceding source and stable tail intact.
lo, hi = first_span(reference.text, "# EOF boundary\r\n")
mixed.append(reference.ranged(lo, hi, ""))
version += 1
messages.append(frame({"jsonrpc": "2.0", "method": "textDocument/didChange",
                       "params": {"textDocument": {"uri": URI, "version": version},
                                  "contentChanges": mixed}}))

# Deterministic property-style sequence. Edits are generated only before an
# immutable valid anchor function, so token output remains observable even if
# random prefix edits temporarily make the first function malformed. All
# offsets are code-point boundaries represented as UTF-16 LSP positions.
rng = random.Random(0xD02_2026)
replacement_pool = ("", "x", "é", "🧪", "42", " + 1", "# seeded\r\n", "\n", "\r\n", '"ø"')
range_count = full_count = 0
for batch_no in range(9):
    changes = []
    # Each notification is a multi-change batch. Even-numbered batches include
    # multiple full snapshots interleaved with ranged edits.
    for step in range(5):
        start, end = reference.random_offsets(rng)
        replacement = rng.choice(replacement_pool)
        if batch_no % 2 == 0 and step in (1, 3):
            changes.append(reference.full_after_local_edit(start, end, replacement))
            full_count += 1
        else:
            changes.append(reference.ranged(start, end, replacement))
            range_count += 1
    version += 1
    messages.append(frame({"jsonrpc": "2.0", "method": "textDocument/didChange",
                           "params": {"textDocument": {"uri": URI, "version": version},
                                      "contentChanges": changes}}))

# Snapshot before invalid changes. The first rejected notification has a valid
# mutation followed by an inverted range; the second has a valid mutation
# followed by a malformed content change. Both must roll back the whole batch.
messages.append(frame({"jsonrpc": "2.0", "id": 2, "method": "textDocument/semanticTokens/full",
                       "params": {"textDocument": {"uri": URI}}}))
trial_insert = {"range": {"start": {"line": 0, "character": 0},
                           "end": {"line": 0, "character": 0}},
                "rangeLength": 0, "text": "MUTATION\r\n"}
inverted = {"range": {"start": {"line": 0, "character": 1},
                       "end": {"line": 0, "character": 0}}, "text": "bad"}
version += 1
messages.append(frame({"jsonrpc": "2.0", "method": "textDocument/didChange",
                       "params": {"textDocument": {"uri": URI, "version": version},
                                  "contentChanges": [trial_insert, inverted]}}))
messages.append(frame({"jsonrpc": "2.0", "id": 3, "method": "textDocument/semanticTokens/full",
                       "params": {"textDocument": {"uri": URI}}}))
version += 1
messages.append(frame({"jsonrpc": "2.0", "method": "textDocument/didChange",
                       "params": {"textDocument": {"uri": URI, "version": version},
                                  "contentChanges": [trial_insert, {"text": 17}]}}))
messages.append(frame({"jsonrpc": "2.0", "id": 4, "method": "textDocument/semanticTokens/full",
                       "params": {"textDocument": {"uri": URI}}}))

# A later valid edit must still apply after the two rejected versions. It is
# included in the final reference text used by the fresh-open oracle.
lo, hi = first_span(reference.text, "return 9")
final_pos = position_at(reference.text, hi)
reference.ranged(hi, hi, " + 1")
version += 1
messages.append(frame({"jsonrpc": "2.0", "method": "textDocument/didChange",
                       "params": {"textDocument": {"uri": URI, "version": version},
                                  "contentChanges": [{"range": {"start": final_pos, "end": final_pos},
                                                       "rangeLength": 0, "text": " + 1"}]}}))
messages.append(frame({"jsonrpc": "2.0", "id": 5, "method": "textDocument/semanticTokens/full",
                       "params": {"textDocument": {"uri": URI}}}))

# Close and re-open the same URI with exactly the reference-model text. This
# removes all incremental state and serves as a strict fresh-open oracle for
# both semantic tokens and diagnostics.
messages.append(frame({"jsonrpc": "2.0", "method": "textDocument/didClose",
                       "params": {"textDocument": {"uri": URI}}}))
messages.append(frame({"jsonrpc": "2.0", "method": "textDocument/didOpen",
                       "params": {"textDocument": {"uri": URI, "languageId": "Elisa",
                                                       "version": 1, "text": reference.text}}}))
messages.append(frame({"jsonrpc": "2.0", "id": 6, "method": "textDocument/semanticTokens/full",
                       "params": {"textDocument": {"uri": URI}}}))

assert range_count >= 20 and full_count >= 8, (range_count, full_count)
responses = {}
with LspSession(srv, startup_timeout=15, request_timeout=90, teardown_timeout=10) as client:
    initialized = client.initialize({"capabilities": {}}, timeout=30)
    assert "result" in initialized, initialized
    for message in messages:
        if "id" in message:
            response = client.request(message["method"], message.get("params"), timeout=90)
            assert response.get("id") == message["id"], (message, response)
            responses[message["id"]] = response.get("result")
        else:
            client.notify(message["method"], message.get("params"), timeout=90)
    client.finish(timeout=90)
    wire = list(client.all_messages)

for rid in (2, 3, 4, 5, 6):
    assert rid in responses, f"missing semantic token response {rid}: {wire}"
    assert isinstance(responses[rid], dict) and "data" in responses[rid], responses[rid]

assert responses[2] == responses[3] == responses[4], (
    "an invalid range/change after a valid staged edit must roll back the entire notification"
)
assert responses[5] == responses[6], (
    "incremental semantic tokens diverged from a fresh open of the reference-model text\n"
    f"  incremental={responses[5]}\n  fresh={responses[6]}\n"
    f"  final text={reference.text!r}"
)

def diagnostics_before_response(request_id):
    response_index = next(i for i, msg in enumerate(wire) if msg.get("id") == request_id)
    result = []
    for msg in wire[:response_index]:
        if msg.get("method") == "textDocument/publishDiagnostics" and msg.get("params", {}).get("uri") == URI:
            result.append(msg["params"].get("diagnostics"))
    return result

before_invalid = diagnostics_before_response(2)
after_inverted = diagnostics_before_response(3)
after_bad_change = diagnostics_before_response(4)
incremental_diags = diagnostics_before_response(5)
fresh_diags = diagnostics_before_response(6)
assert before_invalid, "opening/changing the incremental document should publish diagnostics"
assert before_invalid == after_inverted == after_bad_change, (
    "rejected notifications must not publish diagnostics or alter diagnostic state"
)
assert incremental_diags and fresh_diags, "incremental and fresh-open documents need diagnostics"
assert incremental_diags[-1] == fresh_diags[-1], (
    "incremental diagnostics diverged from the fresh-open oracle\n"
    f"  incremental={incremental_diags[-1]}\n  fresh={fresh_diags[-1]}\n"
    f"  final text={reference.text!r}"
)

print(f"incremental sync OK: {range_count} ranged and {full_count} full changes; "
      "mixed batches, UTF-16/CRLF, rollback, tokens, and diagnostics match fresh open")
PY
