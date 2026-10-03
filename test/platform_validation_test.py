#!/usr/bin/env python3
"""Unit checks for the host-platform validation and evidence contract."""
from __future__ import annotations

import hashlib
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import platform_validation as validation  # noqa: E402


def main() -> None:
    assert validation.platform_gate_status(
        system="Darwin",
        build_requested=False,
        build_passed=True,
        tests_requested=False,
        tests_passed=True,
        freshness_passed=True,
    ) == "incomplete"
    assert validation.platform_gate_status(
        system="Linux",
        build_requested=True,
        build_passed=True,
        tests_requested=True,
        tests_passed=True,
        freshness_passed=True,
    ) == "validated"
    assert validation.platform_gate_status(
        system="Linux",
        build_requested=True,
        build_passed=False,
        tests_requested=True,
        tests_passed=True,
        freshness_passed=False,
    ) == "failed"
    assert validation.platform_gate_status(
        system="FreeBSD",
        build_requested=True,
        build_passed=True,
        tests_requested=True,
        tests_passed=True,
        freshness_passed=True,
    ) == "unsupported-platform"

    with tempfile.TemporaryDirectory(prefix="elisa-platform-test-") as temporary:
        work = Path(temporary)
        noisy = work / "noisy-command"
        noisy.write_text(
            "#!/bin/sh\n"
            "python3 -c 'print(\"x\" * 6000)'\n",
            encoding="utf-8",
        )
        noisy.chmod(0o755)
        record = validation.command_record([str(noisy)], cwd=work)
        assert record["returncode"] == 0, record
        assert record["timed_out"] is False, record
        assert len(record["output_tail"]) <= validation.OUTPUT_TAIL_CHARS, record
        assert record["output_tail"].endswith("x\n"), record["output_tail"][-10:]
        assert record["failure_markers"] == [], record

        failed_suite = work / "failed-suite"
        failed_suite.write_text(
            "#!/bin/sh\n"
            "printf 'FAILED: test/early.sh\\nFAILED: test/late.sh\\nFAILED: test/early.sh\\n'\n",
            encoding="utf-8",
        )
        failed_suite.chmod(0o755)
        failed_record = validation.command_record([str(failed_suite)], cwd=work)
        assert failed_record["failure_markers"] == [
            "FAILED: test/early.sh",
            "FAILED: test/late.sh",
        ], failed_record

        missing = validation.command_record([str(work / "missing")], cwd=work)
        assert missing["returncode"] == 127, missing
        assert "FileNotFoundError" in missing["output_tail"], missing
        assert missing["failure_markers"] == [], missing

        compiler = work / "elisac-stage0"
        compiler.write_bytes(b"compiler identity")
        compiler.chmod(0o755)
        frontend = work / "Elisa-compiler"
        (frontend / "src" / "semantic").mkdir(parents=True)
        (frontend / "elisacore_std").mkdir()
        (frontend / "src" / "semantic" / "semantic.elisa").write_text("# frontend\n", encoding="utf-8")
        (frontend / "elisacore_std" / "runtime.elisa").write_text("# std\n", encoding="utf-8")
        identity = validation.toolchain_identity(ROOT, compiler, frontend, None)
        assert identity["compiler_sha256"] == hashlib.sha256(b"compiler identity").hexdigest(), identity
        assert identity["compiler_stage1_named"] is False, identity
        assert identity["frontend_sources_sha256"], identity
        assert identity["frontend_dirty"] is False, identity

        valid_manifest = work / "manifest.json"
        valid_manifest.write_text('{"schema_version": 3}\n', encoding="utf-8")
        manifest, error = validation.read_manifest(valid_manifest)
        assert error is None and manifest == {"schema_version": 3}, (manifest, error)
        invalid_manifest = work / "invalid.json"
        invalid_manifest.write_text("[]\n", encoding="utf-8")
        manifest, error = validation.read_manifest(invalid_manifest)
        assert manifest is None and error == "manifest root is not an object", (manifest, error)

    assert validation.resolve_path(None) is None
    assert validation.resolve_path("~/does-not-exist").is_absolute()
    print("platform validation OK: candidate classification, bounded probes, identities, and manifest parsing")


if __name__ == "__main__":
    main()
