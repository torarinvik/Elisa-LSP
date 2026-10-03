#!/usr/bin/env bash
# D03: measure the host filesystem's case and symlink behavior in a private
# temporary directory.  The result is evidence for the resolver contract; the
# shipped open-buffer server remains lexical and never aliases on this basis.
set -euo pipefail

python3 - <<'PY'
import os
import pathlib
import tempfile


def case_policy(root: pathlib.Path) -> str:
    canonical = root / "CaseProbe.elisa"
    alias = root / "caseprobe.elisa"
    canonical.write_bytes(b"def probe() -> int:\n    return 0\n")

    # An existing differently-cased name that is the same file is the direct
    # observation on a case-insensitive volume.  Do not overwrite it while
    # probing: this directory is private, but the test should never depend on
    # destructive behavior even if the host has unusual directory semantics.
    if os.path.lexists(alias):
        try:
            return "insensitive" if os.path.samefile(canonical, alias) else "unknown"
        except OSError:
            return "unknown"

    try:
        fd = os.open(alias, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        return "insensitive"
    except OSError:
        return "unknown"
    else:
        os.close(fd)
        alias.unlink()
        return "sensitive"


def symlink_policy(root: pathlib.Path) -> str:
    target = root / "target.elisa"
    alias = root / "link.elisa"
    target.write_bytes(b"def target() -> int:\n    return 0\n")
    try:
        os.symlink(target, alias)
    except (NotImplementedError, OSError):
        # A platform without usable symlinks must keep the resolver in its
        # lexical/unknown policy; it must not guess from the OS name.
        return "unavailable"
    try:
        same_file = os.path.samefile(target, alias)
        same_path = os.path.realpath(target) == os.path.realpath(alias)
        return "physical" if same_file and same_path else "unknown"
    except OSError:
        return "unknown"


with tempfile.TemporaryDirectory(prefix="elisa-lsp-identity-") as temp:
    root = pathlib.Path(temp)
    case = case_policy(root)
    symlink = symlink_policy(root)

assert case in {"sensitive", "insensitive", "unknown"}, case
assert symlink in {"physical", "unavailable", "unknown"}, symlink

# These are the resolver decisions, independent of the measured host result:
# lexical identity is always safe; physical aliasing is allowed only after a
# successful, host-specific filesystem query.  The test intentionally prints
# the observation so platform validation records can compare hosts without
# baking a Darwin/Linux assumption into the LSP.
print(f"filesystem identity OK: case={case} symlink={symlink}; lexical overlay aliases disabled")
PY
