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
# The helper is read-only and prints a conservative complete review rather than
# an exact rendered preview. It prints three sections:
#   1. Every Test record no-mistakes can render for the run: the step result's
#      findings and each round's findings, as JSON. The Testing section uses the
#      final payload; the Pipeline section renders each round's findings.
#   2. Every file under <evidence-root>/<run-id>, with the full content of
#      UTF-8 text files and a size line for anything else. Symlinks and other
#      non-regular entries are never followed or read.
#   3. Hits: lines in sections 1 and 2 that still contain a home path (the
#      "~" no-mistakes leaves after redacting the home directory), the
#      operator's username, a hostname as a whole word, a worktree path (a
#      .treehouse/ path or a no-mistakes worktrees/ path), or a --term value
#      after the home directory redaction no-mistakes applies to the PR body,
#      plus each refused entry from section 2. The username and --term values
#      also match inside longer words.
#
# Inputs:
#   --nm-home        no-mistakes home; default $NM_HOME, else ~/.no-mistakes.
#   --evidence-root  run evidence root; default <nm-home>/evidence. Required
#                    when <nm-home>/config.yaml sets test.evidence.local_root,
#                    because the default would then name the wrong directory.
#   --term           extra private text to flag, repeatable (for example a
#                    private project, repository, or second mate name).
#   <run-id>         one path segment of letters, digits, '-' or '_'.
#
# The Test records come from <nm-home>/state.sqlite, opened read-only, using the
# step_results and step_rounds tables of no-mistakes v1.79.0. A missing table,
# column, or run stops with exit 2 rather than printing a partial review.
#
# Exit status:
#   0  no hit found. This does not certify the evidence: private project,
#      issue, PR, and feature names need a human read of sections 1-2.
#   1  at least one hit found; section 3 lists each one.
#   2  usage error, unproved evidence root, unreadable state database, a run
#      evidence path that is a symlink, or no Test step for the run.
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


RUN_ID_RE = re.compile(r"^[A-Za-z0-9_-]+$")
LOCAL_ROOT_RE = re.compile(r"^\s*local_root\s*:")


def configured_local_root(nm_home: Path) -> bool:
    """Report whether the global config sets test.evidence.local_root."""
    config = nm_home / "config.yaml"
    if not config.is_file():
        return False
    return any(LOCAL_ROOT_RE.match(line) for line in config.read_text(encoding="utf-8", errors="replace").splitlines())


def evidence_files(run_dir: Path) -> tuple[list[tuple[str, str | None, int]], list[str]]:
    if run_dir.is_symlink():
        raise ReviewError(f"run evidence path is a symlink: {run_dir}")
    if not run_dir.is_dir():
        return [], []
    files: list[tuple[str, str | None, int]] = []
    refused: list[str] = []
    for parent, dirs, names in os.walk(run_dir, followlinks=False):
        base = Path(parent)
        for name in list(dirs):
            if (base / name).is_symlink():
                refused.append((base / name).relative_to(run_dir).as_posix())
                dirs.remove(name)
        for name in names:
            path = base / name
            rel = path.relative_to(run_dir).as_posix()
            if path.is_symlink() or not path.is_file():
                refused.append(rel)
                continue
            data = path.read_bytes()
            text: str | None = None
            if data and b"\x00" not in data:
                try:
                    text = data.decode("utf-8")
                except UnicodeDecodeError:
                    text = None
            files.append((rel, text, len(data)))
    return sorted(files), sorted(refused)


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


# Host names are short machine labels that can occur inside ordinary words, so
# a host marker matches only as a whole word. Username and --term markers keep
# substring matching, because those private names often appear joined into a
# longer handle, slug, or branch name.
def marker_pattern(kind: str, value: str) -> re.Pattern[str]:
    escaped = re.escape(value)
    if kind == "hostname":
        escaped = r"(?<!\w)" + escaped + r"(?!\w)"
    return re.compile(escaped, re.IGNORECASE)


def identity_markers(extra_terms: list[str]) -> list[tuple[str, str, re.Pattern[str]]]:
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
    usable: list[tuple[str, str, re.Pattern[str]]] = []
    for kind, value in markers:
        value = value.strip()
        key = value.lower()
        if len(value) < 3 or key in seen:
            continue
        seen.add(key)
        usable.append((kind, value, marker_pattern(kind, value)))
    return usable


def worktree_markers(nm_home: Path, homes: list[str]) -> list[str]:
    """Worktree path spellings that survive home redaction."""
    markers = [".treehouse/", ".no-mistakes/worktrees/"]
    configured = redact_home(str(nm_home / "worktrees"), homes) + "/"
    if not any(m.lower() in configured.lower() for m in markers):
        markers.append(configured)
    return markers


# The "~" that home redaction leaves behind, standing alone or starting a path.
REDACTED_HOME_RE = re.compile(r"(?:^|(?<=[\s\"'`(=:]))~(?=/|[\s\"'`),;:]|$)")


def scan(label: str, text: str, homes: list[str], markers: list[tuple[str, str, re.Pattern[str]]], worktrees: list[str]) -> list[str]:
    hits: list[str] = []
    for number, line in enumerate(redact_home(text, homes).splitlines(), start=1):
        lowered = line.lower()
        if REDACTED_HOME_RE.search(line):
            hits.append(f"home path: {label} line {number}")
        for kind, value, pattern in markers:
            if pattern.search(line):
                hits.append(f"{kind} {value!r}: {label} line {number}")
        for value in worktrees:
            if value.lower() in lowered:
                hits.append(f"worktree path {value!r}: {label} line {number}")
    return hits


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        if not RUN_ID_RE.match(args.run_id):
            raise ReviewError(f"run id must be one path segment of letters, digits, '-' or '_': {args.run_id!r}")
        nm_home = resolve_nm_home(args.nm_home)
        if args.evidence_root:
            evidence_root = Path(args.evidence_root).expanduser()
        elif configured_local_root(nm_home):
            raise ReviewError(f"{nm_home / 'config.yaml'} sets test.evidence.local_root; pass --evidence-root with that directory")
        else:
            evidence_root = nm_home / "evidence"
        records = test_records(nm_home / "state.sqlite", args.run_id)
        run_dir = evidence_root / args.run_id
        files, refused = evidence_files(run_dir)
    except ReviewError as exc:
        print(f"fm-evidence-review: {exc}", file=sys.stderr)
        return 2

    homes = home_candidates()
    markers = identity_markers(args.term)
    worktrees = worktree_markers(nm_home, homes)
    hits: list[str] = []

    print(f"===== Test records for run {args.run_id}")
    if not records:
        print("(none recorded)")
    for label, raw in records:
        body = pretty(raw)
        print(f"\n--- {label}\n{body}")
        hits += scan(label, body, homes, markers, worktrees)

    print(f"\n===== Evidence files under {run_dir}")
    if not files and not refused:
        print("(none)")
    for rel, text, size in files:
        if text is None:
            print(f"\n--- {rel} (not UTF-8 text, {size} bytes)")
            continue
        print(f"\n--- {rel} (text, {size} bytes)\n{text}")
        hits += scan(rel, text, homes, markers, worktrees)
    for rel in refused:
        print(f"\n--- {rel} (symlink or non-regular entry, not read)")
        hits.append(f"refused entry: {rel}")

    print("\n===== Hits")
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
