#!/usr/bin/env python3
"""
unlock-context.py — remove the 64K context floor from an installed hermes-agent.

Hermes Agent ships a hard floor:

    agent/model_metadata.py:  MINIMUM_CONTEXT_LENGTH = 64_000

and two `raise ValueError(...)` guards that refuse to start a session when the
selected model (or the auxiliary compression model) reports a smaller window.
On a local Ollama box that means perfectly usable models — qwen2.5:32b at 32K,
anything you ran with a modest num_ctx — get rejected outright, and the gateway
churns restarting on the same error.

This script patches the floor out of *your own* installed copy so you can pick
whatever model you want:

  1. model_metadata.py       MINIMUM_CONTEXT_LENGTH = 64_000 -> 4096
  2. agent_init.py           delete the main-model `raise ValueError` block
  3. conversation_compression.py
                             delete the auxiliary-model `raise ValueError` block
  4. run_agent.py            keep the LM Studio preload target sane (it used the
                             floor as its fallback size)

Why 4096 and not 0: two call sites use the constant as a *positive* fallback
(LM Studio preload target, auxiliary compression floor). Zero would ask for a
zero-token load. 4096 is below every real model's window, so it gates nothing.

Every edit is backed up to <file>.hermes-local.orig and marked, so re-running is
a no-op and `--restore` puts the tree back byte-for-byte.

Run it with the interpreter of the venv Hermes is installed in:

    ./venv/bin/python scripts/unlock-context.py
    ./venv/bin/python scripts/unlock-context.py --check
    ./venv/bin/python scripts/unlock-context.py --restore

Re-run it after every `pip install --upgrade hermes-agent` / `hermes update` —
an upgrade overwrites site-packages and puts the floor back.
"""

from __future__ import annotations

import argparse
import filecmp
import shutil
import sys
from pathlib import Path

MARKER = "# hermes-local: 64K context floor removed"
BACKUP_SUFFIX = ".hermes-local.orig"
NEW_FLOOR = 4096
LMSTUDIO_FALLBACK_CTX = 32768


# --------------------------------------------------------------------------- #
# locating the installed package
# --------------------------------------------------------------------------- #

def find_site_packages(explicit: str | None) -> Path:
    """Return the directory that holds the installed hermes-agent package."""
    if explicit:
        root = Path(explicit).expanduser().resolve()
        if not (root / "agent" / "model_metadata.py").is_file():
            die(f"no agent/model_metadata.py under {root}")
        return root

    # Preferred: ask the interpreter we are running under.
    try:
        import agent.model_metadata as mm  # type: ignore

        return Path(mm.__file__).resolve().parent.parent
    except Exception:
        pass

    # Fallback: scan this interpreter's own site-packages dirs.
    import sysconfig

    candidates = []
    for key in ("purelib", "platlib"):
        path = sysconfig.get_paths().get(key)
        if path:
            candidates.append(Path(path))
    for path in sys.path:
        if path:
            candidates.append(Path(path))
    for cand in candidates:
        if (cand / "agent" / "model_metadata.py").is_file():
            return cand.resolve()

    die(
        "could not find an installed hermes-agent.\n"
        "Run this with the venv's interpreter, e.g. ./venv/bin/python "
        "scripts/unlock-context.py — or pass --site-packages /path/to/site-packages"
    )
    raise SystemExit(2)  # unreachable, keeps type checkers quiet


def die(msg: str) -> None:
    print(f"unlock-context: error: {msg}", file=sys.stderr)
    raise SystemExit(2)


# --------------------------------------------------------------------------- #
# edit primitives
# --------------------------------------------------------------------------- #

def replace_once(lines: list[str], needle: str, new_line: str, what: str) -> list[str]:
    """Replace the single line containing `needle`. Fails loudly if 0 or >1 match."""
    hits = [i for i, line in enumerate(lines) if needle in line]
    if len(hits) != 1:
        die(
            f"{what}: expected exactly one line containing {needle!r}, "
            f"found {len(hits)}. hermes-agent has changed shape — "
            f"this script needs updating rather than forcing."
        )
    idx = hits[0]
    lines[idx] = new_line
    return lines


def drop_if_block(lines: list[str], needle: str, what: str) -> list[str]:
    """
    Delete a whole `if ...:` statement whose header line contains `needle`.

    Walks forward from the header consuming every line that is blank or indented
    deeper than the header. That handles multi-line f-strings inside the body,
    which a regex cannot do safely.
    """
    hits = [
        i
        for i, line in enumerate(lines)
        if needle in line and line.lstrip().startswith("if ")
    ]
    if len(hits) != 1:
        die(
            f"{what}: expected exactly one `if` header containing {needle!r}, "
            f"found {len(hits)}. hermes-agent has changed shape — "
            f"this script needs updating rather than forcing."
        )
    start = hits[0]
    header_indent = len(lines[start]) - len(lines[start].lstrip())

    end = start + 1
    while end < len(lines):
        line = lines[end]
        if not line.strip():
            end += 1
            continue
        indent = len(line) - len(line.lstrip())
        if indent <= header_indent:
            break
        end += 1

    pad = " " * header_indent
    replacement = [
        f"{pad}{MARKER}: the guard that lived here refused any model whose\n",
        f"{pad}# window was under 64K. Deleted so every model is selectable.\n",
    ]
    return lines[:start] + replacement + lines[end:]


# --------------------------------------------------------------------------- #
# the patches
# --------------------------------------------------------------------------- #

def patch_model_metadata(lines: list[str]) -> list[str]:
    return replace_once(
        lines,
        "MINIMUM_CONTEXT_LENGTH = 64_000",
        f"MINIMUM_CONTEXT_LENGTH = {NEW_FLOOR}  {MARKER}\n",
        "model_metadata.py",
    )


def patch_agent_init(lines: list[str]) -> list[str]:
    return drop_if_block(
        lines,
        "_ctx < MINIMUM_CONTEXT_LENGTH",
        "agent_init.py",
    )


def patch_conversation_compression(lines: list[str]) -> list[str]:
    return drop_if_block(
        lines,
        "aux_context < MINIMUM_CONTEXT_LENGTH",
        "conversation_compression.py",
    )


def patch_run_agent(lines: list[str]) -> list[str]:
    return replace_once(
        lines,
        "target_ctx = max(config_context_length or 0, MINIMUM_CONTEXT_LENGTH)",
        f"            target_ctx = max(config_context_length or 0, {LMSTUDIO_FALLBACK_CTX})"
        f"  {MARKER}\n",
        "run_agent.py",
    )


PATCHES: list[tuple[str, object]] = [
    ("agent/model_metadata.py", patch_model_metadata),
    ("agent/agent_init.py", patch_agent_init),
    ("agent/conversation_compression.py", patch_conversation_compression),
    ("run_agent.py", patch_run_agent),
]


# --------------------------------------------------------------------------- #
# apply / restore / check
# --------------------------------------------------------------------------- #

def apply(site: Path) -> int:
    changed = 0
    for rel, fn in PATCHES:
        target = site / rel
        if not target.is_file():
            die(f"missing {target} — is this really a hermes-agent install?")
        text = target.read_text(encoding="utf-8")
        if MARKER in text:
            print(f"  ok       {rel} (already patched)")
            continue

        backup = Path(str(target) + BACKUP_SUFFIX)
        if not backup.exists():
            shutil.copy2(target, backup)

        lines = text.splitlines(keepends=True)
        lines = fn(lines)  # type: ignore[operator]
        target.write_text("".join(lines), encoding="utf-8")
        print(f"  patched  {rel}")
        changed += 1

    drop_pycache(site)
    if changed:
        print(f"\n64K floor removed. MINIMUM_CONTEXT_LENGTH is now {NEW_FLOOR}.")
        print("Any model is selectable — Hermes will no longer refuse a small window.")
        print(
            "Trade-off: a 32K window still has to hold the system prompt + tool\n"
            "schemas, so long sessions compress earlier and more often."
        )
    else:
        print("\nNothing to do — already unlocked.")
    return 0


def restore(site: Path) -> int:
    restored = 0
    for rel, _ in PATCHES:
        target = site / rel
        backup = Path(str(target) + BACKUP_SUFFIX)
        if not backup.exists():
            print(f"  skip     {rel} (no backup)")
            continue
        shutil.copy2(backup, target)
        backup.unlink()
        print(f"  restored {rel}")
        restored += 1
    drop_pycache(site)
    print(f"\n{restored} file(s) restored. The 64K floor is back in force.")
    return 0


def check(site: Path) -> int:
    patched = 0
    for rel, _ in PATCHES:
        target = site / rel
        if not target.is_file():
            print(f"  missing  {rel}")
            continue
        state = "patched" if MARKER in target.read_text(encoding="utf-8") else "stock"
        backup = Path(str(target) + BACKUP_SUFFIX)
        note = ""
        if backup.exists():
            note = " (backup intact)" if not filecmp.cmp(target, backup, shallow=False) else " (backup identical)"
        print(f"  {state:8} {rel}{note}")
        patched += state == "patched"
    try:
        import agent.model_metadata as mm  # type: ignore

        print(f"\nlive MINIMUM_CONTEXT_LENGTH = {mm.MINIMUM_CONTEXT_LENGTH}")
    except Exception:
        pass
    return 0 if patched == len(PATCHES) else 1


def drop_pycache(site: Path) -> None:
    """Nuke stale bytecode for the files we touched."""
    for rel, _ in PATCHES:
        pkg = (site / rel).parent
        cache = pkg / "__pycache__"
        if not cache.is_dir():
            continue
        stem = Path(rel).stem
        for pyc in cache.glob(f"{stem}.*.pyc"):
            try:
                pyc.unlink()
            except OSError:
                pass


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Remove hermes-agent's 64K minimum-context floor.",
    )
    ap.add_argument("--restore", action="store_true", help="undo the patch from backups")
    ap.add_argument("--check", action="store_true", help="report patch state and exit")
    ap.add_argument(
        "--site-packages",
        default=None,
        help="path to the site-packages holding hermes-agent (auto-detected otherwise)",
    )
    args = ap.parse_args()

    site = find_site_packages(args.site_packages)
    print(f"hermes-agent at: {site}\n")

    if args.check:
        return check(site)
    if args.restore:
        return restore(site)
    return apply(site)


if __name__ == "__main__":
    raise SystemExit(main())
