#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Prune .github/dependabot.yml to the ecosystems this project actually uses.

The template ships every common ecosystem under the header "Covers common
ecosystems - remove unused ones for your project". Nothing removed them.
Measured 2026-08-04 across 423 estate checkouts — declared vs. manifest present
at the repo root:

    pip    206 declared / 206 with no Python manifest   (100%)
    npm    231 declared / 222 with no package.json      ( 96%)
    mix    207 declared / 197 with no mix.exs           ( 95%)
    cargo  251 declared / 166 with no Cargo.toml        ( 66%)

Each of those fails on every scheduled run with "Dependabot encountered an error
performing the update". Same shape as the instruction block: the template
documents a manual step and nothing performs it.

Separately and much worse, 209 repos declare `package-ecosystem: "nix"`, which
is not a valid Dependabot ecosystem value at all. An invalid enum makes GitHub
reject the WHOLE config, so in those repos the github-actions and cargo entries
beside it are inert too — Dependabot has been silently doing nothing. The
template's own dependabot.yml already carries a comment forbidding `nix`; this
script drops it if a stale copy reintroduces one.

A freshly minted repo has no manifests yet, so pruning on file presence would
delete everything. Pass the ecosystems to keep explicitly — the operator's
archetype choice is better evidence than an empty tree.

Usage: prune-dependabot-ecosystems.py <file> <keep...>
       prune-dependabot-ecosystems.py .github/dependabot.yml github-actions cargo
"""
import re
import sys
from pathlib import Path

# Never valid for Dependabot, and rejects the entire file if present.
ALWAYS_DROP = {"nix"}


def main() -> int:
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    path = Path(sys.argv[1])
    keep = set(sys.argv[2:]) - ALWAYS_DROP
    if not path.is_file():
        print(f"  dependabot: {path} absent, nothing to prune")
        return 0

    text = path.read_text(encoding="utf-8")
    # An entry runs from its `- package-ecosystem:` line to just before the
    # next one (or EOF), so trailing comments travel with their own entry.
    parts = re.split(r"(?m)^(?=[ \t]*-[ \t]*package-ecosystem:)", text)
    head, entries = parts[0], parts[1:]
    if not entries:
        print("  dependabot: no ecosystem entries found")
        return 0

    kept, dropped = [], []
    for entry in entries:
        m = re.search(r"package-ecosystem:[ \t]*[\"']?([A-Za-z-]+)", entry)
        name = m.group(1) if m else "?"
        (kept if name in keep else dropped).append((name, entry))

    if not kept:
        # Refuse to write a config with an empty `updates:` list — that is
        # invalid and would reject the file just as surely as a bad enum.
        print("  dependabot: refusing to prune every entry; left unchanged")
        return 0
    if not dropped:
        print("  dependabot: nothing to prune")
        return 0

    path.write_text(head + "".join(e for _, e in kept), encoding="utf-8")
    print("  dependabot: kept " + ", ".join(n for n, _ in kept)
          + " / dropped " + ", ".join(n for n, _ in dropped))
    return 0


if __name__ == "__main__":
    sys.exit(main())
