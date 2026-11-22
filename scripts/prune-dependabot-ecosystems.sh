#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Prune .github/dependabot.yml to the ecosystems this project actually uses.
#
# The template ships every common ecosystem. Unused ones fail on every
# scheduled Dependabot run, and an invalid `nix` entry makes GitHub reject the
# whole file. This drops `nix` always and keeps only the ecosystems you name.
#
# A fresh repo has no manifests yet, so pruning on file presence would delete
# everything. Pass the ecosystems to keep explicitly.
#
# Usage: prune-dependabot-ecosystems.sh <file> <keep...>
#        prune-dependabot-ecosystems.sh .github/dependabot.yml github-actions cargo
set -euo pipefail

if [ "$#" -lt 2 ]; then
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 1
fi
file=$1
shift
# `nix` is never valid for Dependabot, so it is never kept.
keep=""
for e in "$@"; do
    [ "$e" = nix ] || keep="$keep $e"
done

if [ ! -f "$file" ]; then
    echo "  dependabot: $file absent, nothing to prune"
    exit 0
fi

tmp=$(mktemp)
trap 'rm -f "$tmp" "$tmp.msg"' EXIT

# An entry runs from its `- package-ecosystem:` line to just before the next
# one (or EOF), so trailing comments travel with their own entry.
# RS is a byte that never occurs, so the whole file is one record and the
# final newline (or its absence) is preserved exactly.
awk -v keep="$keep" -v msg="$tmp.msg" '
BEGIN { RS = "\001"; n = split(keep, k, " "); for (i = 1; i <= n; i++) want[k[i]] = 1 }
{
    text = $0
    # Split at line starts that begin an ecosystem entry.
    head = ""; ne = 0; pos = 1; start = 0
    len = length(text); lineStart = 1
    while (lineStart <= len) {
        nl = index(substr(text, lineStart), "\n")
        lineEnd = nl ? lineStart + nl - 1 : len
        line = substr(text, lineStart, lineEnd - lineStart + 1)
        if (line ~ /^[ \t]*-[ \t]*package-ecosystem:/) {
            if (ne == 0) head = substr(text, 1, lineStart - 1)
            else entry[ne] = substr(text, start, lineStart - start)
            ne++; start = lineStart
        }
        lineStart = lineEnd + 1
    }
    if (ne == 0) { print "  dependabot: no ecosystem entries found" > msg; exit 0 }
    entry[ne] = substr(text, start)

    keptN = 0; dropN = 0; out = head
    for (i = 1; i <= ne; i++) {
        e = entry[i]; name = "?"
        if (match(e, /package-ecosystem:[ \t]*["\047]?[A-Za-z-]+/)) {
            s = substr(e, RSTART, RLENGTH)
            sub(/^package-ecosystem:[ \t]*["\047]?/, "", s)
            name = s
        }
        if (name in want) { kept[++keptN] = name; out = out e }
        else dropped[++dropN] = name
    }
    if (keptN == 0) {
        print "  dependabot: refusing to prune every entry; left unchanged" > msg; exit 0
    }
    if (dropN == 0) { print "  dependabot: nothing to prune" > msg; exit 0 }
    printf "%s", out > OUTFILE
    ks = kept[1]; for (i = 2; i <= keptN; i++) ks = ks ", " kept[i]
    ds = dropped[1]; for (i = 2; i <= dropN; i++) ds = ds ", " dropped[i]
    print "  dependabot: kept " ks " / dropped " ds > msg
}' OUTFILE="$tmp" "$file"

cat "$tmp.msg"
# A non-empty output file means a prune happened.
if [ -s "$tmp" ]; then
    cat "$tmp" > "$file"
fi
