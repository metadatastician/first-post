#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Delete the RSR template's "TEMPLATE INSTRUCTIONS" comment blocks.
#
# The community-health templates open with an HTML comment headed
# "TEMPLATE INSTRUCTIONS (delete this block before publishing)". Nothing in the
# mint deleted it, and its literal doubled-brace token trips every placeholder
# gate. It also carries the donor's values. Run this AFTER substitution.
#
# A block is one whole HTML comment (`<!--` to its first `-->`) that contains
# the marker. The match never crosses a `-->`, so a multi-line SPDX header
# above the block is left alone. Prose that merely mentions the marker outside
# a comment survives.
#
# Usage: strip-instruction-blocks.sh [root]      (default ".")
# Exit 0 always; prints one line per file changed. Idempotent.
set -euo pipefail

marker="TEMPLATE INSTRUCTIONS"
root=${1:-.}

changed=0
while IFS= read -r -d '' f; do
    tmp=$(mktemp)
    # RS is a byte that never occurs, so the whole file is one record.
    awk -v marker="$marker" 'BEGIN { RS = "\001" }
    {
        text = $0; out = ""; changedf = 0
        while ((p = index(text, "<!--")) > 0) {
            rest = substr(text, p + 4)
            e = index(rest, "-->")
            body = e ? substr(rest, 1, e - 1) : rest
            if (e && index(body, marker) > 0) {
                # Drop the comment, trailing blanks and one newline.
                out = out substr(text, 1, p - 1)
                text = substr(rest, e + 3)
                sub(/^[ \t]*\n?/, "", text)
                changedf = 1
            } else {
                # Keep this opener and look at the next one.
                out = out substr(text, 1, p + 3)
                text = rest
            }
        }
        out = out text
        if (!changedf) exit 3
        # Collapse the gap the deletion leaves.
        while (out ~ /\n\n\n/) gsub(/\n\n\n+/, "\n\n", out)
        printf "%s", out
    }' "$f" > "$tmp" && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
        cat "$tmp" > "$f"
        echo "  instruction block: stripped from ${f#./}"
        changed=$((changed + 1))
    fi
    rm -f "$tmp"
done < <(
    # Text files only (-I), no symlinks, skip vendored and build dirs.
    find "$root" \( -name .git -o -name node_modules -o -name .venv \
        -o -name target -o -name dist \) -prune -o -type f -print0 \
        | sort -z \
        | xargs -0 -r grep -IlZ -F -- "$marker" 2>/dev/null || true
)

if [ "$changed" -gt 0 ]; then
    echo "  instruction blocks: $changed file(s) cleaned"
else
    echo "  instruction blocks: none found"
fi
