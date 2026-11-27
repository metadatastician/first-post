#!/usr/bin/env bun
// SPDX-License-Identifier: MPL-2.0
//
// Prune .github/dependabot.yml to the ecosystems this project actually uses.
//
// The template ships every common ecosystem under the header "Covers common
// ecosystems - remove unused ones for your project". Nothing removed them.
// Measured 2026-08-04 across 423 estate checkouts — declared vs. manifest present
// at the repo root:
//
//     pip    206 declared / 206 with no Python manifest   (100%)
//     npm    231 declared / 222 with no package.json      ( 96%)
//     mix    207 declared / 197 with no mix.exs           ( 95%)
//     cargo  251 declared / 166 with no Cargo.toml        ( 66%)
//
// Each of those fails on every scheduled run with "Dependabot encountered an error
// performing the update". Same shape as the instruction block: the template
// documents a manual step and nothing performs it.
//
// Separately and much worse, 209 repos declare `package-ecosystem: "nix"`, which
// is not a valid Dependabot ecosystem value at all. An invalid enum makes GitHub
// reject the WHOLE config, so in those repos the github-actions and cargo entries
// beside it are inert too — Dependabot has been silently doing nothing. The
// template's own dependabot.yml already carries a comment forbidding `nix`; this
// script drops it if a stale copy reintroduces one.
//
// A freshly minted repo has no manifests yet, so pruning on file presence would
// delete everything. Pass the ecosystems to keep explicitly — the operator's
// archetype choice is better evidence than an empty tree.
//
// Usage: bun scripts/prune-dependabot-ecosystems.js <file> <keep...>
//        bun scripts/prune-dependabot-ecosystems.js .github/dependabot.yml github-actions cargo
//
// Exit 1 with usage on missing arguments; otherwise exit 0. The file is
// rewritten only when something is dropped, with LF line endings.
//
// Ported from prune-dependabot-ecosystems.py with the same behaviour. The
// entries are split textually rather than parsed as YAML on purpose: comments
// and layout inside each kept entry survive byte for byte.

import { readFileSync, statSync, writeFileSync } from "node:fs";

const USAGE = `Usage: prune-dependabot-ecosystems.js <file> <keep...>
       prune-dependabot-ecosystems.js .github/dependabot.yml github-actions cargo`;

// Never valid for Dependabot, and rejects the entire file if present.
const ALWAYS_DROP = new Set(["nix"]);

// An entry runs from its `- package-ecosystem:` line to just before the next
// one (or EOF), so trailing comments travel with their own entry. Line starts
// are found after "\n" only, as Python's re.MULTILINE does.
const ENTRY_START = /(?:^|(?<=\n))(?=[ \t]*-[ \t]*package-ecosystem:)/g;
const NAME = /package-ecosystem:[ \t]*["']?([A-Za-z-]+)/;

// Render a path the way Python's Path does: drop empty and "." components.
function normalise(p) {
  const parts = p.split("/").filter((s) => s !== "" && s !== ".");
  const s = (p.startsWith("/") ? "/" : "") + parts.join("/");
  return s === "" ? "." : s;
}

function isFile(p) {
  try {
    return statSync(p).isFile();
  } catch {
    return false;
  }
}

function main(argv) {
  if (argv.length < 2) {
    console.error(USAGE);
    return 1;
  }
  const path = normalise(argv[0]);
  const keep = new Set(argv.slice(1).filter((k) => !ALWAYS_DROP.has(k)));
  if (!isFile(path)) {
    console.log(`  dependabot: ${path} absent, nothing to prune`);
    return 0;
  }

  // Strict UTF-8 (a bad byte is an error, as in the original), BOM kept,
  // CRLF and lone CR read as LF.
  const text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true })
    .decode(readFileSync(path))
    .replace(/\r\n?/g, "\n");

  const cuts = [...text.matchAll(ENTRY_START)].map((m) => m.index);
  const head = text.slice(0, cuts.length ? cuts[0] : text.length);
  const entries = cuts.map((c, i) => text.slice(c, cuts[i + 1]));
  if (!entries.length) {
    console.log("  dependabot: no ecosystem entries found");
    return 0;
  }

  const kept = [];
  const dropped = [];
  for (const entry of entries) {
    const m = NAME.exec(entry);
    const name = m ? m[1] : "?";
    (keep.has(name) ? kept : dropped).push([name, entry]);
  }

  if (!kept.length) {
    // Refuse to write a config with an empty `updates:` list — that is
    // invalid and would reject the file just as surely as a bad enum.
    console.log("  dependabot: refusing to prune every entry; left unchanged");
    return 0;
  }
  if (!dropped.length) {
    console.log("  dependabot: nothing to prune");
    return 0;
  }

  writeFileSync(path, head + kept.map(([, e]) => e).join(""), "utf-8");
  console.log(
    "  dependabot: kept " + kept.map(([n]) => n).join(", ") +
      " / dropped " + dropped.map(([n]) => n).join(", "),
  );
  return 0;
}

process.exit(main(process.argv.slice(2)));
