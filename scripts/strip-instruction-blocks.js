#!/usr/bin/env bun
// SPDX-License-Identifier: MPL-2.0
//
// Delete the RSR template's "TEMPLATE INSTRUCTIONS" comment blocks.
//
// The community-health templates open with an HTML comment headed
// "TEMPLATE INSTRUCTIONS (delete this block before publishing)". Nothing in the
// mint ever deleted it. Measured 2026-08-04 across 423 estate checkouts: 211
// repos still carry it — 206 in CODE_OF_CONDUCT.md, 106 in SECURITY.md.
//
// It is self-detonating, which is why substitution cannot save you. The block's
// own first line says to replace all values using a LITERAL doubled-brace token.
// That is metasyntax, not a real token, so the mint's sed pass has nothing to
// match and leaves it intact. Every placeholder gate in the estate then greps a
// doubled-brace SHOUTY_SNAKE pattern and finds it, so a repo whose every genuine
// token was substituted correctly still trips its own gate. That is the mechanism
// behind metadatastician/688-attack-hub#11 and f19-stealth-glider#12.
//
// Worse, the block carries the DONOR's substituted values. squisher-corpus filled
// its own name into the instruction table instead of deleting the block, and its
// root CODE_OF_CONDUCT.md was then copied outward: 58 repos now name "Squisher
// Corpus" as the project they protect and route conduct reports to the wrong repo.
//
// Run AFTER substitution: any real token the operator supplied is already filled
// in, so only the instructions go.
//
// Usage: bun scripts/strip-instruction-blocks.js [root]      (default ".")
// Exit 0 always; prints one line per file changed. Idempotent.
//
// Ported from strip-instruction-blocks.py with the same behaviour: files that
// are not valid UTF-8 are skipped, line endings are normalised to LF in any
// file that is rewritten (as Python's text mode did), symlinks are neither
// followed nor rewritten, and files are visited in sorted path order.

import { readdirSync, readFileSync, writeFileSync } from "node:fs";

const MARKER = "TEMPLATE INSTRUCTIONS";

// `(?:(?!-->).)*?` is load-bearing: it cannot cross a comment terminator.
// Without it the match starts at the file's FIRST `<!--` — which in most of
// these files is a multi-line SPDX and copyright header — skips over that
// header's `-->`, and takes the licence header and the `# Code of Conduct` H1
// with it. Caught on metadatastician/boj-server-mk2 while testing; it looks
// correct on any file whose SPDX header happens to be a single line.
//
// Anchoring on the comment rather than the line also means prose that merely
// MENTIONS the marker survives — documentation about this defect would
// otherwise be deleted by the fix for it.
const BLOCK = new RegExp(
  "<!--(?:(?!-->).)*?" + MARKER + "(?:(?!-->).)*?-->[ \\t]*\\n?",
  "gs",
);

const SKIP_DIRS = new Set([".git", "node_modules", ".venv", "target", "dist"]);

const UTF8 = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });

function strip(path) {
  let text;
  try {
    text = UTF8.decode(readFileSync(path)).replace(/\r\n?/g, "\n");
  } catch {
    return false; // unreadable or not UTF-8
  }
  if (!text.includes(MARKER)) return false;
  let next = text.replace(BLOCK, "");
  if (next === text) return false;
  next = next.replace(/\n{3,}/g, "\n\n"); // collapse the gap the deletion leaves
  writeFileSync(path, next, "utf-8");
  return true;
}

// Code-point order, as Python compares path components.
function cmp(a, b) {
  const x = [...a];
  const y = [...b];
  for (let i = 0; i < Math.min(x.length, y.length); i++) {
    const d = x[i].codePointAt(0) - y[i].codePointAt(0);
    if (d) return d;
  }
  return x.length - y.length;
}

// Depth-first, entries sorted per directory: the same order as sorting every
// path component-wise. Symlinked directories are not descended into.
function join(dir, name) {
  if (dir === ".") return name;
  return dir.endsWith("/") ? dir + name : dir + "/" + name;
}

function* walk(dir) {
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return;
  }
  entries.sort((a, b) => cmp(a.name, b.name));
  for (const e of entries) {
    const path = join(dir, e.name);
    if (e.isDirectory()) {
      yield* walk(path);
    } else if (e.isFile()) {
      yield path;
    }
  }
}

// Render the root the way Python's Path does: drop empty and "." components.
function normalise(root) {
  const abs = root.startsWith("/");
  const parts = root.split("/").filter((p) => p !== "" && p !== ".");
  const s = (abs ? "/" : "") + parts.join("/");
  return s === "" ? "." : s;
}

const root = normalise(process.argv[2] ?? ".");
let changed = 0;
for (const path of walk(root)) {
  // As in the original, any component of the shown path counts, the root's
  // own components and the file name included.
  if (path.split("/").some((p) => SKIP_DIRS.has(p))) continue;
  if (strip(path)) {
    console.log(`  instruction block: stripped from ${path}`);
    changed += 1;
  }
}
console.log(
  changed
    ? `  instruction blocks: ${changed} file(s) cleaned`
    : "  instruction blocks: none found",
);
process.exit(0);
