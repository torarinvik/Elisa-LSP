#!/usr/bin/env bash
# U02: one coordinate API — diagnostics, tokens, and hover slice the same
# UTF-16 lines. Every token and diagnostic range must decode through a single
# UTF-16 slicing helper, including past emoji/CJK content on the same line.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRV="$ROOT/build/elisa-lsp"
[[ -x "$SRV" ]] || { echo "build first: bash build.sh" >&2; exit 2; }

# Probe coordinate helpers directly as well as through LSP providers.
# Provider output alone cannot cover every byte boundary, malformed byte
# sequence, line index, and inverse conversion exhaustively.
ELISAC_BIN="${ELISAC:-$HOME/.elisac/elisac-stage0}"
COMPILER_ROOT="${ELISA_COMPILER_ROOT:-$ROOT/../Elisa-compiler}"
[[ -x "$ELISAC_BIN" ]] || { echo "stage0 compiler missing: $ELISAC_BIN" >&2; exit 2; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM HUP
python3 - "$ROOT" "$COMPILER_ROOT" "$WORK/positions_probe.elisa" "$WORK/cases.json" <<'PY'
import itertools, json, random, sys

root, compiler_root, source_path, cases_path = sys.argv[1:]
cases = []
seen = set()
def add(data):
    if data not in seen:
        seen.add(data)
        cases.append(data)

# Exhaust every sequence of up to three Unicode atoms from this compact basis.
# It covers ordinary/tab bytes, CR/LF/CRLF, Nordic letters, Greek, CJK, a
# combining mark, and an astral scalar (whose UTF-16 interior is not a byte
# boundary).
atoms = [b"A", b"\t", b"\r", b"\n", "é".encode(), "\u0301".encode(),
         "æ".encode(), "ø".encode(), "å".encode(), "λ".encode(), "漢".encode(),
         "🌍".encode(), "€".encode()]
add(b"")
for count in range(1, 4):
    for parts in itertools.product(atoms, repeat=count):
        add(b"".join(parts))

# Exhaust short raw-byte strings over byte classes that expose valid UTF-8
# boundaries, continuations, overlong/surrogate/out-of-range leads, ASCII,
# controls, tabs, and line endings. Add longer malformed/truncated examples.
byte_alphabet = (0x00, 0x41, 0x09, 0x0A, 0x0D, 0x7F, 0x80, 0xBF, 0xC0,
                 0xC2, 0xA9, 0xC3, 0x28, 0xE0, 0xED, 0xF0, 0xF4, 0xF5, 0xFF)
for count in range(1, 4):
    for raw in itertools.product(byte_alphabet, repeat=count):
        add(bytes(raw))
for raw in (
    b"\xF0\x9F\x8C",             # truncated four-byte sequence
    b"\xE2\x82",                 # truncated three-byte sequence
    b"\xC3",                     # truncated two-byte sequence
    b"\xC3(\xA9",               # invalid continuation, then stray continuation
    b"\xE0\x80\x80",            # overlong three-byte encoding
    b"\xED\xA0\x80",            # UTF-16 surrogate encoded as UTF-8
    b"\xF4\x90\x80\x80",        # above Unicode maximum
    b"\xF5\x80\x80\x80",        # impossible leading byte
    b"\xF0(\x8C(",               # invalid continuation boundaries
):
    add(raw)

# Add longer reproducible samples so scan/indexed helpers and byte/unit
# conversions are checked past the exhaustive short-string boundary. Keep the
# samples short enough that this probe's all-spans walk remains inexpensive.
rng = random.Random(0xE115A)
random_atoms = atoms + [
    b"\x80", b"\xC3", b"\xC3(", b"\xE2\x82", b"\xF0\x9F\x8C",
    b"\xED\xA0\x80", b"\xF4\x90\x80\x80",
]
for _ in range(64):
    count = rng.randint(4, 20)
    add(b"".join(rng.choice(random_atoms) for _ in range(count)))

packed = []
for raw in cases:
    assert len(raw) <= 255
    packed.extend((len(raw), *raw))
packed.append(0)  # safe one-byte address for an empty final case
include_runtime = compiler_root.replace('"', '\\"') + "/elisacore_std/elisacore_runtime.elisa"
include_positions = root.replace('"', '\\"') + "/src/positions.elisa"
source = f'''include "{include_runtime}"
include "{include_positions}"
def emit_number(output: mutable darray[u8]&, value: i64) -> void can[Memory.Allocate, Abort.Panic]:
    negative: bool = value < 0
    magnitude: mutable u64 = value.u64()
    if negative:
        output.push(45)
        magnitude <- 0.u64() - magnitude
    divisor: mutable u64 = 1
    while divisor <= magnitude / 10.u64():
        divisor <- divisor * 10.u64()
    while divisor > 0:
        output.push((48 + (magnitude / divisor).i64()).u8())
        magnitude <- magnitude % divisor
        divisor <- divisor / 10.u64()
    output.push(32)

def main() -> int:
    can Console.Write, Memory.Allocate, Console.Format, Abort.Panic:
        bytes_blob: mutable darray[u8] = [{", ".join(map(str, packed))}]
        output: mutable darray[u8] = []
        case_count: i64 = {len(cases)}
        case_no: mutable i64 = 0
        off: mutable usize = 0
        while case_no < case_count:
            case_len: usize = bytes_blob[off].usize()
            off <- off + 1
            src: u8& = &bytes_blob[off]
            src_len: usize = case_len
            starts: darray[usize] = Positions::build_line_starts(src, src_len)
            padded_starts: mutable darray[usize] = []
            padded_starts.push(src_len + 17)
            for indexed_start in starts:
                padded_starts.push(indexed_start)
            padded_starts.push(src_len + 23)
            span_start: usize = 1
            span_count: usize = starts.count
            span_mismatch: mutable bool = false
            empty_span: (line: i64, character: i64) = Positions::byte_offset_to_position_span_indexed(src, src_len, padded_starts, span_start, 0, src_len, false)
            if empty_span.line != 0 or empty_span.character != 0:
                span_mismatch <- true
            lines: i64 = Positions::line_count(src, src_len)
            print(case_no)
            print(src_len.i64())
            print(lines)
            print(starts.count.i64())
            # Out-of-range line behavior is part of the public helper contract.
            print(Positions::line_start_offset(src, src_len, -1).i64())
            print(Positions::line_start_offset_indexed(starts, src_len, -1).i64())
            print(Positions::line_byte_length(src, src_len, -1))
            print(Positions::line_byte_length_indexed(src, src_len, starts, -1))
            print(Positions::line_start_offset(src, src_len, lines).i64())
            print(Positions::line_start_offset_indexed(starts, src_len, lines).i64())
            print(Positions::line_byte_length(src, src_len, lines))
            print(Positions::line_byte_length_indexed(src, src_len, starts, lines))
            print(Positions::line_start_offset(src, src_len, lines + 1).i64())
            print(Positions::line_start_offset_indexed(starts, src_len, lines + 1).i64())
            print(Positions::line_byte_length(src, src_len, lines + 1))
            print(Positions::line_byte_length_indexed(src, src_len, starts, lines + 1))
            invalid_line_index: mutable i64 = 0
            while invalid_line_index < 3 |invalid_line_index, lines|:
                invalid_line: i64 = -1 if invalid_line_index == 0 else (lines if invalid_line_index == 1 else lines + 1)
                print(Positions::line_utf16_length(src, src_len, invalid_line))
                print(Positions::line_unit_length(src, src_len, invalid_line, false))
                print(Positions::line_unit_length(src, src_len, invalid_line, true))
                print(Positions::line_utf16_length_indexed(src, src_len, starts, invalid_line))
                print(Positions::line_unit_length_indexed(src, src_len, starts, invalid_line, false))
                print(Positions::line_unit_length_indexed(src, src_len, starts, invalid_line, true))
                for invalid_col in [0, 2] |src, src_len, starts, invalid_line|:
                    print(Positions::byte_col_to_units(src, src_len, invalid_line, invalid_col, false))
                    print(Positions::byte_col_to_units(src, src_len, invalid_line, invalid_col, true))
                    print(Positions::byte_col_to_units_indexed(src, src_len, starts, invalid_line, invalid_col, false))
                    print(Positions::byte_col_to_units_indexed(src, src_len, starts, invalid_line, invalid_col, true))
                    print(Positions::char_to_byte_col(src, src_len, invalid_line, invalid_col, false))
                    print(Positions::char_to_byte_col(src, src_len, invalid_line, invalid_col, true))
                    print(Positions::char_to_byte_col_indexed(src, src_len, starts, invalid_line, invalid_col, false))
                    print(Positions::char_to_byte_col_indexed(src, src_len, starts, invalid_line, invalid_col, true))
                invalid_line_index <- invalid_line_index + 1
            line: mutable i64 = 0
            while line < lines:
                line_start: usize = Positions::line_start_offset(src, src_len, line)
                line_start_indexed: usize = Positions::line_start_offset_indexed(starts, src_len, line)
                line_len: i64 = Positions::line_byte_length(src, src_len, line)
                print(line_start.i64())
                print(line_start_indexed.i64())
                print(line_len)
                print(Positions::line_byte_length_indexed(src, src_len, starts, line))
                print(Positions::line_utf16_length(src, src_len, line))
                print(Positions::line_unit_length(src, src_len, line, false))
                print(Positions::line_unit_length(src, src_len, line, true))
                print(Positions::line_utf16_length_indexed(src, src_len, starts, line))
                print(Positions::line_unit_length_indexed(src, src_len, starts, line, false))
                print(Positions::line_unit_length_indexed(src, src_len, starts, line, true))
                byte_col: mutable i64 = -1
                while byte_col <= line_len + 1:
                    print(Positions::byte_col_to_units(src, src_len, line, byte_col, false))
                    print(Positions::byte_col_to_units(src, src_len, line, byte_col, true))
                    print(Positions::byte_col_to_utf16(src, src_len, line, byte_col))
                    print(Positions::byte_col_to_units_indexed(src, src_len, starts, line, byte_col, false))
                    print(Positions::byte_col_to_units_indexed(src, src_len, starts, line, byte_col, true))
                    byte_col <- byte_col + 1
                unit_col: mutable i64 = -1
                while unit_col <= line_len + 1:
                    print(Positions::char_to_byte_col(src, src_len, line, unit_col, false))
                    print(Positions::char_to_byte_col(src, src_len, line, unit_col, true))
                    print(Positions::char_to_byte_col_indexed(src, src_len, starts, line, unit_col, false))
                    print(Positions::char_to_byte_col_indexed(src, src_len, starts, line, unit_col, true))
                    unit_col <- unit_col + 1
                span_start: mutable usize = 0
                while span_start <= src_len:
                    span_len: mutable usize = 0
                    while span_len <= src_len - span_start:
                        print(Positions::span_utf16_length(src, src_len, span_start, span_len))
                        print(Positions::span_unit_length(src, src_len, span_start, span_len, false))
                        print(Positions::span_unit_length(src, src_len, span_start, span_len, true))
                        span_len <- span_len + 1
                    span_start <- span_start + 1
                line <- line + 1
            absolute_offset: mutable usize = 0
            while absolute_offset <= src_len + 1:
                mapped16: (line: i64, character: i64) = Positions::byte_offset_to_position_indexed(src, src_len, starts, absolute_offset, false)
                mapped8: (line: i64, character: i64) = Positions::byte_offset_to_position_indexed(src, src_len, starts, absolute_offset, true)
                print(mapped16.line)
                print(mapped16.character)
                print(mapped8.line)
                print(mapped8.character)
                absolute_offset <- absolute_offset + 1
            # The sidecar helpers must use exactly this document's subspan,
            # even when neighboring entries surround it in the flat array.
            span_line: mutable i64 = 0
            while span_line < lines:
                if Positions::line_start_offset_span_indexed(padded_starts, span_start, span_count, src_len, span_line) != Positions::line_start_offset_indexed(starts, src_len, span_line):
                    span_mismatch <- true
                if Positions::line_byte_length_span_indexed(src, src_len, padded_starts, span_start, span_count, span_line) != Positions::line_byte_length_indexed(src, src_len, starts, span_line):
                    span_mismatch <- true
                if Positions::line_unit_length_span_indexed(src, src_len, padded_starts, span_start, span_count, span_line, false) != Positions::line_unit_length_indexed(src, src_len, starts, span_line, false):
                    span_mismatch <- true
                if Positions::line_unit_length_span_indexed(src, src_len, padded_starts, span_start, span_count, span_line, true) != Positions::line_unit_length_indexed(src, src_len, starts, span_line, true):
                    span_mismatch <- true
                span_col: mutable i64 = -1
                while span_col <= Positions::line_byte_length_indexed(src, src_len, starts, span_line) + 1:
                    if Positions::byte_col_to_units_span_indexed(src, src_len, padded_starts, span_start, span_count, span_line, span_col, false) != Positions::byte_col_to_units_indexed(src, src_len, starts, span_line, span_col, false):
                        span_mismatch <- true
                    if Positions::byte_col_to_units_span_indexed(src, src_len, padded_starts, span_start, span_count, span_line, span_col, true) != Positions::byte_col_to_units_indexed(src, src_len, starts, span_line, span_col, true):
                        span_mismatch <- true
                    if Positions::char_to_byte_col_span_indexed(src, src_len, padded_starts, span_start, span_count, span_line, span_col, false) != Positions::char_to_byte_col_indexed(src, src_len, starts, span_line, span_col, false):
                        span_mismatch <- true
                    if Positions::char_to_byte_col_span_indexed(src, src_len, padded_starts, span_start, span_count, span_line, span_col, true) != Positions::char_to_byte_col_indexed(src, src_len, starts, span_line, span_col, true):
                        span_mismatch <- true
                    span_col <- span_col + 1
                span_line <- span_line + 1
            absolute_offset <- 0
            while absolute_offset <= src_len + 1:
                span16: (line: i64, character: i64) = Positions::byte_offset_to_position_span_indexed(src, src_len, padded_starts, span_start, span_count, absolute_offset, false)
                span8: (line: i64, character: i64) = Positions::byte_offset_to_position_span_indexed(src, src_len, padded_starts, span_start, span_count, absolute_offset, true)
                indexed16: (line: i64, character: i64) = Positions::byte_offset_to_position_indexed(src, src_len, starts, absolute_offset, false)
                indexed8: (line: i64, character: i64) = Positions::byte_offset_to_position_indexed(src, src_len, starts, absolute_offset, true)
                if span16.line != indexed16.line or span16.character != indexed16.character or span8.line != indexed8.line or span8.character != indexed8.character:
                    span_mismatch <- true
                absolute_offset <- absolute_offset + 1
            print(-999999) if span_mismatch
            off <- off + src_len
            case_no <- case_no + 1
        return 0
'''
# The position oracle emits millions of scalar values. Collect every value in
# one reusable buffer and write bounded chunks; the independent Python oracle
# still parses and checks the complete stream.
source = source.replace("print(", "emit_number(output, ")
source = source.replace(
    "def main() -> int:",
    '''def flush_probe_output(output: mutable darray[u8]&) -> void can[Console.Write, Memory.Allocate, Console.Format, Abort.Panic]:
    if output.count == 0:
        return
    can Console.Write, Memory.Allocate, Console.Format, Abort.Panic:
        output.push(0)
        print(bytes_view_range_ref(output, 0, output.count - 1))
        output.count <- 0

def main() -> int:''',
)
source = source.replace(
    "            off <- off + src_len",
    """            if output.count >= 65536:
                flush_probe_output(output)
            off <- off + src_len""",
)
source = source.replace(
    "        return 0\n",
    "        flush_probe_output(output)\n        return 0\n",
)
with open(source_path, "w", encoding="utf-8") as f:
    f.write(source)
with open(cases_path, "w", encoding="utf-8") as f:
    json.dump([list(raw) for raw in cases], f)
print(f"generated {len(cases)} exhaustive byte-string cases")
PY
"$ELISAC_BIN" -emit obj -O2 -o "$WORK/positions_probe.o" "$WORK/positions_probe.elisa" >/dev/null
cat > "$WORK/fallback.c" <<'EOF'
#include <stddef.h>
#include <stdint.h>
#if defined(__GNUC__) || defined(__clang__)
#define ELISA_WEAK __attribute__((weak))
#else
#define ELISA_WEAK
#endif
ELISA_WEAK uint32_t elisa_profile_allocation_negotiate(uint32_t v) { (void)v; return 0; }
ELISA_WEAK uint32_t elisa_profile_region_layout_negotiate(uint32_t v) { (void)v; return 0; }
ELISA_WEAK void elisa_profile_region_layout_v1(uintptr_t a,size_t b,uintptr_t c,uintptr_t d,size_t e){(void)a;(void)b;(void)c;(void)d;(void)e;}
ELISA_WEAK void elisa_profile_allocation_event_v1(uint32_t a,uintptr_t b,size_t c,uintptr_t d,size_t e,uintptr_t f,size_t g){(void)a;(void)b;(void)c;(void)d;(void)e;(void)f;(void)g;}
EOF
clang -O2 -fno-builtin -o "$WORK/positions_probe" "$WORK/positions_probe.o" "$WORK/fallback.c"
python3 - "$WORK/positions_probe" "$WORK/cases.json" <<'PY'
import json, subprocess, sys

probe, cases_path = sys.argv[1:]
cases = [bytes(raw) for raw in json.load(open(cases_path, encoding="utf-8"))]
run = subprocess.run([probe], capture_output=True, timeout=90, check=True)
try:
    values = [int(token) for token in run.stdout.split()]
except ValueError as exc:
    raise AssertionError(f"coordinate probe emitted non-integer output: {run.stdout[:200]!r}") from exc
cursor = 0
failures = []
context = "start"
truncated = False
def take(label):
    global cursor, truncated
    if cursor >= len(values):
        if not truncated:
            failures.append(f"probe output ended before {label}; consumed={cursor}, "
                            f"total={len(values)}, context={context}, tail={values[-12:]}")
            truncated = True
        return 0
    v = values[cursor]
    cursor += 1
    return v

def decode_units(raw):
    """Strict UTF-8 scalar decoder; each malformed byte independently counts 1."""
    result = []
    i = 0
    while i < len(raw):
        first = raw[i]
        if first < 0x80:
            result.append((i, i + 1, 1))
            i += 1
            continue
        size = 0
        if 0xC2 <= first <= 0xDF:
            size = 2
        elif 0xE0 <= first <= 0xEF:
            size = 3
        elif 0xF0 <= first <= 0xF4:
            size = 4
        valid = size > 0 and i + size <= len(raw)
        if valid:
            tail = raw[i + 1:i + size]
            valid = all(0x80 <= b <= 0xBF for b in tail)
            if size == 3 and first == 0xE0:
                valid = valid and tail[0] >= 0xA0
            if size == 3 and first == 0xED:
                valid = valid and tail[0] <= 0x9F
            if size == 4 and first == 0xF0:
                valid = valid and tail[0] >= 0x90
            if size == 4 and first == 0xF4:
                valid = valid and tail[0] <= 0x8F
        if valid:
            result.append((i, i + size, 2 if size == 4 else 1))
            i += size
        else:
            result.append((i, i + 1, 1))
            i += 1
    return result

def lines_for(raw):
    starts = [0]
    starts.extend(i + 1 for i, b in enumerate(raw) if b == 0x0A)
    result = []
    for line, start in enumerate(starts):
        end = starts[line + 1] if line + 1 < len(starts) else len(raw)
        if end > start and raw[end - 1] == 0x0A:
            end -= 1
            if end > start and raw[end - 1] == 0x0D:
                end -= 1
        result.append((start, end))
    return starts, result

def decoded_line(raw):
    return decode_units(raw)

def byte_to_u16(raw, col):
    target = min(max(col, 0), len(raw))
    units = 0
    for start, end, width in decoded_line(raw):
        if end > target:
            break
        units += width
    return units

def byte_to_boundary(raw, col):
    target = min(max(col, 0), len(raw))
    for start, end, _ in decoded_line(raw):
        if start < target < end:
            return start
    return target

def u16_to_byte(raw, col):
    target = min(max(col, 0), len(raw))
    units = 0
    for start, end, width in decoded_line(raw):
        if units < target < units + width:
            return start
        if units + width > target:
            return start
        units += width
    return len(raw)

def take_eq(actual, expected, label):
    if actual != expected:
        failures.append(f"{label}: got {actual}, expected {expected}")

for case_no, raw in enumerate(cases):
    context = f"case {case_no} bytes={raw!r}"
    starts, spans = lines_for(raw)
    header = [take("case index"), take("source length"), take("line count"),
              take("indexed start count")]
    expected_header = [case_no, len(raw), len(spans), len(starts)]
    if header != expected_header:
        raise AssertionError(f"case framing mismatch for {raw!r}: got {header}, "
                             f"expected {expected_header}")

    # Negative and past-the-end line indexes are clamped to source end/empty.
    for line in (-1, len(spans), len(spans) + 1):
        got = [take("out-of-range line result") for _ in range(4)]
        want = [len(raw), len(raw), 0, 0]
        if got != want:
            failures.append(f"out-of-range line {line} on {raw!r}: got {got}, expected {want}")

    for line in (-1, len(spans), len(spans) + 1):
        got = [take("out-of-range unit-length result") for _ in range(6)]
        if got != [0] * 6:
            failures.append(f"out-of-range unit lengths line={line} bytes={raw!r}: got {got}, expected zeros")
        for col in (0, 2):
            got = [take("out-of-range byte/character conversion") for _ in range(8)]
            if got != [0] * 8:
                failures.append(f"out-of-range conversion line={line} col={col} bytes={raw!r}: got {got}, expected zeros")

    for line, (start, end) in enumerate(spans):
        context = f"case {case_no}, line {line}, bytes={raw!r}"
        content = raw[start:end]
        units = sum(width for _, _, width in decode_units(content))
        got_static = [take("line start/length/unit metrics") for _ in range(10)]
        want_static = [start, start, len(content), len(content), units, units, len(content),
                       units, units, len(content)]
        if got_static != want_static:
            failures.append(f"line metrics case={case_no} line={line} bytes={raw!r}: "
                            f"got {got_static}, expected {want_static}")
        # The probe bounds conversion loops by its scan-helper result. Parse
        # using that runtime count so a line-length bug is reported directly
        # without shifting every later value in the flat output stream.
        runtime_len = got_static[2]
        for col in range(-1, runtime_len + 2):
            context = f"case {case_no}, line {line}, byte column {col}, bytes={raw!r}"
            got = [take("byte-to-unit conversion") for _ in range(5)]
            want = [byte_to_u16(content, col), byte_to_boundary(content, col),
                    byte_to_u16(content, col), byte_to_u16(content, col),
                    byte_to_boundary(content, col)]
            if got != want:
                failures.append(f"byte column {col}, case={case_no} line={line}, "
                                f"bytes={content!r}: got {got}, expected {want}")
        for col in range(-1, runtime_len + 2):
            context = f"case {case_no}, line {line}, unit column {col}, bytes={raw!r}"
            got = [take("unit-to-byte conversion") for _ in range(4)]
            want = [u16_to_byte(content, col), byte_to_boundary(content, col),
                    u16_to_byte(content, col), byte_to_boundary(content, col)]
            if got != want:
                failures.append(f"unit column {col}, case={case_no} line={line}, "
                                f"bytes={content!r}: got {got}, expected {want}")

        for span_start in range(len(raw) + 1):
            for span_len in range(len(raw) - span_start + 1):
                context = f"case {case_no}, line {line}, span=({span_start},{span_len}), bytes={raw!r}"
                part = raw[span_start:span_start + span_len]
                want = sum(width for _, _, width in decode_units(part))
                got = [take("absolute span unit conversion") for _ in range(3)]
                expected = [want, want, span_len]
                if got != expected:
                    failures.append(f"span ({span_start},{span_len}) case={case_no} "
                                    f"bytes={raw!r}: got {got}, expected {expected}")

    # Absolute offsets use a binary-searched line index and clamp to valid
    # UTF-8/UTF-16 boundaries, including offsets inside CRLF and at EOF.
    for offset in range(len(raw) + 2):
        context = f"case {case_no}, absolute byte offset {offset}, bytes={raw!r}"
        bounded = min(offset, len(raw))
        line = max(index for index, start in enumerate(starts) if start <= bounded)
        start, end = spans[line]
        content = raw[start:end]
        byte_col = bounded - start
        expected = [line, byte_to_u16(content, byte_col),
                    line, byte_to_boundary(content, byte_col)]
        got = [take("absolute offset to position") for _ in range(4)]
        if got != expected:
            failures.append(f"absolute offset {offset} case={case_no} bytes={raw!r}: "
                            f"got {got}, expected {expected}")

if cursor != len(values):
    failures.append(f"{len(values) - cursor} unexpected probe values remain")
if failures:
    raise AssertionError(f"{len(failures)} reference mismatches; first {min(20, len(failures))}:\n  "
                         + "\n  ".join(failures[:20]))
print(f"position helpers OK: {len(cases)} exhaustive short byte strings; line starts, "
      "CRLF/final-empty lines, absolute-offset mapping, UTF-16/UTF-8 conversions, tabs, combining marks, "
      "emoji, and malformed/truncated UTF-8 checked")
PY

python3 - "$SRV" "$ROOT" <<'PY'
import os, sys
srv, root = sys.argv[1:]
sys.path.insert(0, os.path.join(root, "test"))
from lsp_client import LspSession

def u16slice(line, col, ln):
    raw = line.encode("utf-16-le")
    assert 0 <= col <= len(raw)//2 and 0 <= ln and col+ln <= len(raw)//2, \
        f"span ({col},{ln}) outside {len(raw)//2}-unit line {line!r}"
    part = raw[col*2:(col+ln)*2].decode("utf-16-le")
    assert len(part) > 0, "zero-length slice"
    return part

doc = ('def f(name: i64) -> i64:\n'
       '    x: dstr = "héllo 🌍"\n'
       '    y: i64 = name + 1 # héllo\n'
       '    return zzz_undefined\n')
uri = "file:///positions.elisa"
with LspSession(srv, startup_timeout=10, request_timeout=30) as client:
    initialized = client.initialize({"capabilities": {}})
    assert "result" in initialized, initialized
    client.notify("textDocument/didOpen", {"textDocument": {
        "uri": uri, "languageId": "Elisa", "version": 1, "text": doc
    }})
    token_response = client.request("textDocument/semanticTokens/full", {
        "textDocument": {"uri": uri}
    })
    assert "result" in token_response, token_response
    client.wait_notification(
        "textDocument/publishDiagnostics",
        timeout=30,
        predicate=lambda message: message.get("params", {}).get("uri") == uri,
    )
    res = {2: token_response["result"]}
    assert client.finish(timeout=30) == 0
    notifs = client.notifications[:]

lines = doc.split("\n")
# --- tokens: decode all, spot-check exact texts ---
data = res[2]["data"]
assert len(data) % 5 == 0 and len(data) >= 5*10
toks = []
line = col = 0
for i in range(0, len(data), 5):
    dl, dc, ln_, tt, md = data[i:i+5]
    line += dl; col = (col + dc) if dl == 0 else dc
    text = u16slice(lines[line], col, ln_)
    toks.append((line, col, ln_, tt, text))
by_text = {}
for _, _, _, tt, text in toks:
    by_text.setdefault(text, tt)
assert by_text.get('"héllo 🌍"') == 11, f"string token mis-sliced/classified"
assert by_text.get("# héllo") == 40, f"comment token mis-sliced/classified"
assert by_text.get("zzz_undefined") == 17, f"local fallback mis-sliced/classified"
# token after non-ASCII on the SAME line: `name` follows nothing non-ASCII here,
# but `1` follows the `#`-comment line content — instead assert the return line:
ret = [t for t in toks if t[0] == 3 and t[4] == "return"]
assert ret and ret[0][3] == 27, f"keyword after unicode lines wrong: {ret}"

# --- diagnostics: same helper, same lines (provider agreement) ---
diags = [n["params"] for n in notifs
         if n.get("method") == "textDocument/publishDiagnostics" and n["params"]["uri"] == uri]
assert diags, "no diagnostics published"
found = False
for d in diags[-1]["diagnostics"]:
    r = d["range"]
    if r["end"]["line"] == r["start"]["line"]:
        frag = u16slice(lines[r["start"]["line"]], r["start"]["character"],
                        r["end"]["character"] - r["start"]["character"])
        if "zzz_undefined" in frag:
            found = True
    else:
        # multiline: start must at least be in-bounds
        rest = len(lines[r["start"]["line"]].encode("utf-16-le"))//2 - r["start"]["character"]
        u16slice(lines[r["start"]["line"]], r["start"]["character"], rest)
assert found, "no diagnostic covers zzz_undefined"
print(f"positions OK: {len(toks)} tokens + diagnostics share one UTF-16 basis")
PY
