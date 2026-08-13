#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Delete the RSR template's "TEMPLATE INSTRUCTIONS" comment blocks.

The community-health templates open with an HTML comment headed
"TEMPLATE INSTRUCTIONS (delete this block before publishing)". Nothing in the
mint ever deleted it. Measured 2026-08-04 across 423 estate checkouts: 211
repos still carry it — 206 in CODE_OF_CONDUCT.md, 106 in SECURITY.md.

It is self-detonating, which is why substitution cannot save you. The block's
own first line says to replace all values using a LITERAL doubled-brace token.
That is metasyntax, not a real token, so the mint's sed pass has nothing to
match and leaves it intact. Every placeholder gate in the estate then greps a
doubled-brace SHOUTY_SNAKE pattern and finds it, so a repo whose every genuine
token was substituted correctly still trips its own gate. That is the mechanism
behind metadatastician/688-attack-hub#11 and f19-stealth-glider#12.

Worse, the block carries the DONOR's substituted values. squisher-corpus filled
its own name into the instruction table instead of deleting the block, and its
root CODE_OF_CONDUCT.md was then copied outward: 58 repos now name "Squisher
Corpus" as the project they protect and route conduct reports to the wrong repo.

Run AFTER substitution: any real token the operator supplied is already filled
in, so only the instructions go.

Usage: strip-instruction-blocks.py [root]      (default ".")
Exit 0 always; prints one line per file changed. Idempotent.
"""
import re
import sys
from pathlib import Path

MARKER = "TEMPLATE INSTRUCTIONS"

# `(?:(?!-->).)*?` is load-bearing: it cannot cross a comment terminator.
# Without it the match starts at the file's FIRST `<!--` — which in most of
# these files is a multi-line SPDX and copyright header — skips over that
# header's `-->`, and takes the licence header and the `# Code of Conduct` H1
# with it. Caught on metadatastician/boj-server-mk2 while testing; it looks
# correct on any file whose SPDX header happens to be a single line.
#
# Anchoring on the comment rather than the line also means prose that merely
# MENTIONS the marker survives — documentation about this defect would
# otherwise be deleted by the fix for it.
BLOCK = re.compile(
    r"<!--(?:(?!-->).)*?" + re.escape(MARKER) + r"(?:(?!-->).)*?-->[ \t]*\n?",
    re.S,
)

SKIP_DIRS = {".git", "node_modules", ".venv", "target", "dist"}


def strip(path: Path) -> bool:
    try:
        text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        return False
    if MARKER not in text:
        return False
    new = BLOCK.sub("", text)
    if new == text:
        return False
    new = re.sub(r"\n{3,}", "\n\n", new)   # collapse the gap the deletion leaves
    path.write_text(new, encoding="utf-8")
    return True


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    changed = 0
    for p in sorted(root.rglob("*")):
        if not p.is_file() or p.is_symlink():
            continue
        if SKIP_DIRS & set(p.parts):
            continue
        if strip(p):
            print(f"  instruction block: stripped from {p}")
            changed += 1
    print(f"  instruction blocks: {changed} file(s) cleaned" if changed
          else "  instruction blocks: none found")
    return 0


if __name__ == "__main__":
    sys.exit(main())
