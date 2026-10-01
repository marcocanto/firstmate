#!/usr/bin/env bash
# fm-evidence-review.sh - print what a no-mistakes run's PR body will publish from its Test step, for review at the evidence-review gate.
#
# Usage:
#   bin/fm-evidence-review.sh [--nm-home <dir>] [--evidence-root <dir>] [--term <text>]... <run-id>
#
# This repository's trusted .no-mistakes.yaml parks every run at the
# gate.test.evidence-review step, before Push and PR, because the PR step
# renders the Test step's recorded text and inlines the run's text evidence
# files into the public PR body. docs/configuration.md "Gate defaults" owns that
# policy; the validation-supervision skill owns the review procedure.
#
# The helper is read-only. It prints three sections:
#   1. Every Test record no-mistakes can render for the run: the step result's
#      findings and each round's findings, as JSON.
#   2. Every file under <evidence-root>/<run-id>, with the full content of
#      UTF-8 text files and a size line for anything else.
#   3. Identity markers: lines in sections 1 and 2 that still contain the
#      operator's username, a hostname, or a --term value after the home
#      directory redaction no-mistakes applies to the PR body.
#
# Inputs:
#   --nm-home        no-mistakes home; default $NM_HOME, else ~/.no-mistakes.
#   --evidence-root  run evidence root; default <nm-home>/evidence. Pass it when
#                    the global test.evidence.local_root moves evidence.
#   --term           extra private text to flag, repeatable (for example a
#                    private project, repository, or second mate name).
#
# The Test records come from <nm-home>/state.sqlite, opened read-only, using the
# step_results and step_rounds tables of no-mistakes v1.79.0. A missing table,
# column, or run stops with exit 2 rather than printing a partial review.
#
# Exit status:
#   0  no identity marker found. This does not certify the evidence: private
#      project, issue, PR, and feature names need a human read of sections 1-2.
#   1  at least one identity marker found; section 3 lists each one.
#   2  usage error, unreadable state database, or no Test step for the run.
set -eu

exec python3 - "$@" <<'PY'
from __future__ import annotations

import argparse
import getpass
import json
import os
import re
import socket
import sqlite3
import subprocess
import sys
from pathlib import Path


class ReviewError(Exception):
    """A condition that prevents a complete review."""


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="fm-evidence-review.sh",
        description="Print what a no-mistakes run's PR body will publish from its Test step.",
    )
    parser.add_argument("--nm-home", default=None)
    parser.add_argument("--evidence-root", default=None)
    parser.add_argument("--term", action="append", default=[])
    parser.add_argument("run_id")
    return parser.parse_args(argv)


def resolve_nm_home(value: str | None) -> Path:
    if value:
        return Path(value).expanduser()
    env = os.environ.get("NM_HOME", "").strip()
    if env:
        return Path(env).expanduser()
    return Path.home() / ".no-mistakes"


def test_records(db_path: Path, run_id: str) -> list[tuple[str, str]]:
    if not db_path.is_file():
        raise ReviewError(f"no-mistakes state database not found: {db_path}")
    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    except sqlite3.Error as exc:
        raise ReviewError(f"cannot open {db_path} read-only: {exc}") from exc
    try:
        step = conn.execute(
            "SELECT id, findings_json FROM step_results WHERE run_id = ? AND step_name = 'test'",
            (run_id,),
        ).fetchone()
        if step is None:
            raise ReviewError(f"run {run_id} has no test step in {db_path}")
        records: list[tuple[str, str]] = []
        if step[1] and step[1].strip():
            records.append(("test step result", step[1]))
        for number, findings in conn.execute(
            "SELECT round, findings_json FROM step_rounds WHERE step_result_id = ? ORDER BY round",
            (step[0],),
        ):
            if findings and findings.strip():
                records.append((f"test round {number}", findings))
        return records
    except sqlite3.Error as exc:
        raise ReviewError(f"cannot read Test records from {db_path}: {exc}") from exc
    finally:
        conn.close()


def pretty(raw: str) -> str:
    try:
        return json.dumps(json.loads(raw), indent=2, ensure_ascii=False)
    except ValueError:
        return raw


def evidence_files(run_dir: Path) -> list[tuple[str, str | None, int]]:
    if not run_dir.is_dir():
        return []
    files: list[tuple[str, str | None, int]] = []
    for path in sorted(p for p in run_dir.rglob("*") if p.is_file()):
        data = path.read_bytes()
        text: str | None = None
        if data and b"\x00" not in data:
            try:
                text = data.decode("utf-8")
            except UnicodeDecodeError:
                text = None
        files.append((path.relative_to(run_dir).as_posix(), text, len(data)))
    return files


# Mirrors the shape of no-mistakes' safepath.RedactText closely enough to keep
# redacted home paths from tripping the username marker: the account's own
# home spellings first, then any /home/<user> or /Users/<user> root.
GENERIC_HOME_RE = re.compile(r"(?<![A-Za-z0-9_./\\-])(?:file://)?/(?:home|users)/[^/\\\s\"'`<>()\[\]{},;:&|*?]+", re.IGNORECASE)


def home_candidates() -> list[str]:
    raw = [str(Path.home()), os.environ.get("HOME", "")]
    out: set[str] = set()
    for home in raw:
        home = home.strip().rstrip("/")
        if len(home) < 4 or not home.startswith("/"):
            continue
        out.add(home)
        out.add(os.path.realpath(home))
    return sorted(out, key=len, reverse=True)


def redact_home(text: str, homes: list[str]) -> str:
    for home in homes:
        text = re.sub(re.escape(home) + r"(?=$|[/\\]|[^A-Za-z0-9_.-])", "~", text)
    return GENERIC_HOME_RE.sub("~", text)


def scutil_name(key: str) -> str:
    try:
        result = subprocess.run(["scutil", "--get", key], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return ""
    return result.stdout.strip() if result.returncode == 0 else ""


def identity_markers(extra_terms: list[str]) -> list[tuple[str, str]]:
    markers: list[tuple[str, str]] = []
    try:
        markers.append(("username", getpass.getuser()))
    except (KeyError, OSError):
        pass
    host = socket.gethostname()
    for name in (host, host.split(".")[0], scutil_name("ComputerName"), scutil_name("LocalHostName")):
        markers.append(("hostname", name))
    for term in extra_terms:
        markers.append(("term", term))
    seen: set[str] = set()
    usable: list[tuple[str, str]] = []
    for kind, value in markers:
        value = value.strip()
        key = value.lower()
        if len(value) < 3 or key in seen:
            continue
        seen.add(key)
        usable.append((kind, value))
    return usable


def scan(label: str, text: str, homes: list[str], markers: list[tuple[str, str]]) -> list[str]:
    hits: list[str] = []
    for number, line in enumerate(redact_home(text, homes).splitlines(), start=1):
        lowered = line.lower()
        for kind, value in markers:
            if value.lower() in lowered:
                hits.append(f"{kind} {value!r}: {label} line {number}")
    return hits


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    nm_home = resolve_nm_home(args.nm_home)
    evidence_root = Path(args.evidence_root).expanduser() if args.evidence_root else nm_home / "evidence"
    try:
        records = test_records(nm_home / "state.sqlite", args.run_id)
    except ReviewError as exc:
        print(f"fm-evidence-review: {exc}", file=sys.stderr)
        return 2

    homes = home_candidates()
    markers = identity_markers(args.term)
    hits: list[str] = []

    print(f"===== Test records for run {args.run_id}")
    if not records:
        print("(none recorded)")
    for label, raw in records:
        body = pretty(raw)
        print(f"\n--- {label}\n{body}")
        hits += scan(label, body, homes, markers)

    run_dir = evidence_root / args.run_id
    print(f"\n===== Evidence files under {run_dir}")
    files = evidence_files(run_dir)
    if not files:
        print("(none)")
    for rel, text, size in files:
        if text is None:
            print(f"\n--- {rel} (not UTF-8 text, {size} bytes)")
            continue
        print(f"\n--- {rel} (text, {size} bytes)\n{text}")
        hits += scan(rel, text, homes, markers)

    print("\n===== Identity markers")
    if not hits:
        print("none found; read the sections above for private names before approving")
        return 0
    for hit in hits:
        print(hit)
    return 1


try:
    sys.exit(main(sys.argv[1:]))
except BrokenPipeError:
    sys.exit(1)
PY
