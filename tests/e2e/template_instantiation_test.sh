#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# E2E Test: Template Instantiation
# Verifies that the template can be cloned and instantiated into a working project
#
# This test:
# 1. Clones the template to a temp directory
# 2. Replaces all placeholder tokens with test values
# 3. Validates the resulting repository structure
# 4. Verifies builds work after instantiation
# 5. Cleans up

set -euo pipefail

# Test configuration
TEMPLATE_ROOT="${1:-.}"
TEST_DIR="${TMPDIR:-/tmp}/rsr-template-test-$$"
TEST_REPO_NAME="test-instantiated-repo"
TEST_OWNER="test-owner"
TEST_FORGE="github"
TEST_AUTHOR="Test Author"
TEST_AUTHOR_EMAIL="test@example.com"
TEST_PROJECT_NAME="Test Project"
TEST_DESCRIPTION="A test project instantiated from the RSR template"
TEST_PRIMARY_LANGUAGE="Rust"

# ANSI colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
log_step() {
    echo ""
    echo -e "${BLUE}→${NC} $*"
}

log_pass() {
    echo -e "${GREEN}✓${NC} $*"
}

log_error() {
    echo -e "${RED}✗${NC} $*" >&2
}

cleanup() {
    if [ -d "$TEST_DIR" ]; then
        log_step "Cleaning up test directory: $TEST_DIR"
        rm -rf "$TEST_DIR"
        log_pass "Cleanup complete"
    fi
}

trap cleanup EXIT

#==============================================================================
# PHASE 1: SETUP
#==============================================================================

echo ""
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "E2E TEST: Template Instantiation"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""

log_step "Creating test directory: $TEST_DIR"
mkdir -p "$TEST_DIR"
log_pass "Test directory created"

#==============================================================================
# PHASE 2: CLONE TEMPLATE
#==============================================================================

log_step "Cloning template from $TEMPLATE_ROOT"

# Copy template to test location (simulating git clone)
TEST_REPO_PATH="$TEST_DIR/$TEST_REPO_NAME"
cp -r "$TEMPLATE_ROOT" "$TEST_REPO_PATH"
log_pass "Template cloned to $TEST_REPO_PATH"

# Remove .git directory for clean state, then re-init as the INSTANTIATED repo.
#
# The re-init is not cosmetic. check-no-placeholders.sh identifies the repo from
# `git config --get remote.origin.url`, so that a worktree whose basename is not
# `*-template-repo` still gets the template exemption. With no git repo at all
# that lookup fails and the script exits 1 having printed NOTHING — so this test
# reported "left unfilled placeholder tokens (see above)" with nothing above,
# and had been failing for a reason that has nothing to do with placeholders.
#
# That is worth stating plainly: the one gate whose whole job is "no placeholder
# may survive instantiation" was inoperative, which is exactly consistent with
# 211 estate repos shipping an un-deleted template instruction block.
#
# The origin is set to the INSTANTIATED name deliberately, for the same reason
# the check below clears GITHUB_REPOSITORY: we want the checker to judge this as
# a real minted repo, not to exempt itself as a template.
if [ -d "$TEST_REPO_PATH/.git" ]; then
    rm -rf "$TEST_REPO_PATH/.git"
    log_pass ".git directory removed (fresh clone)"
fi
if git -C "$TEST_REPO_PATH" init -q 2>/dev/null \
   && git -C "$TEST_REPO_PATH" remote add origin \
        "git@github.com:${TEST_OWNER}/${TEST_REPO_NAME}.git" 2>/dev/null; then
    log_pass "re-initialised as ${TEST_OWNER}/${TEST_REPO_NAME} (checker needs a remote)"
else
    log_error "could not re-init the test repo — check-no-placeholders.sh will exit 1 silently"
    exit 1
fi

#==============================================================================
# PHASE 3: PLACEHOLDER REPLACEMENT
#==============================================================================

log_step "Replacing placeholder tokens"

# Substitution is `just repo-init`'s job. This test MUST drive the real recipe:
# a second, hand-rolled replacement list here would be a mock that silently
# diverges from init.just (it did — it carried {{REPO_DESCRIPTION}} and
# {{PRIMARY_LANGUAGE}}, tokens init has never defined), so the test passed
# while real instantiation leaked placeholders into every new repo.
if ! command -v just >/dev/null 2>&1; then
    log_error "just is not installed — cannot exercise the real init recipe"
    exit 1
fi

# Answers, in the exact order init.just prompts for them.
INIT_ANSWERS=(
    "$TEST_PROJECT_NAME"        # Project name
    "$TEST_REPO_NAME"           # Repository slug
    "$TEST_OWNER"               # Owner
    "$TEST_AUTHOR"              # Author full name
    "$TEST_AUTHOR_EMAIL"        # Author email
    ""                          # Author organization
    ""                          # Previous/alt email
    "$TEST_DESCRIPTION"         # Project description
    ""                          # Forge domain      -> default
    ""                          # Security email    -> default
    ""                          # Conduct email     -> default
    "library"                   # Project type
    ""                          # Website URL       -> default
    ""                          # OpenSSF BP ID
)
# init only asks the container questions when container/ exists.
if [ -d "$TEST_REPO_PATH/container" ]; then
    INIT_ANSWERS+=("" "" "")    # service name, port, registry -> defaults
fi
INIT_ANSWERS+=("Y")             # Proceed?

if ! (cd "$TEST_REPO_PATH" && printf '%s\n' "${INIT_ANSWERS[@]}" | just repo-init) > "$TEST_DIR/init.log" 2>&1; then
    log_error "just repo-init failed:"
    cat "$TEST_DIR/init.log" >&2
    exit 1
fi

log_pass "just repo-init completed"

#==============================================================================
# PHASE 3b: NO PLACEHOLDER MAY SURVIVE INSTANTIATION
#==============================================================================

log_step "Checking for placeholders that survived instantiation"

# Same script the openssf-compliance workflow runs, deliberately: a second
# copy of this logic here is what let the two drift last time. GITHUB_REPOSITORY
# is cleared so the check does not mistake the instantiated repo for a template
# repo and skip itself — the instantiated name is what we want it to judge.
if ! env -u GITHUB_REPOSITORY bash "$TEMPLATE_ROOT/scripts/check-no-placeholders.sh" "$TEST_REPO_PATH"; then
    log_error "just repo-init left unfilled placeholder tokens (see above)"
    exit 1
fi

log_pass "No placeholders survived instantiation"

#==============================================================================
# PHASE 3c: NO TEMPLATE INSTRUCTION BLOCK MAY SURVIVE INSTANTIATION
#==============================================================================

log_step "Checking for un-deleted template instruction blocks"

# This is a SEPARATE assertion from 3b on purpose, and the two cannot be merged.
#
# check-no-placeholders.sh exempts metasyntactic tokens (PLACEHOLDER, TOKEN,
# ANYTHING, UPPER_SNAKE) so that prose ABOUT tokens does not fail the build. It
# has to: without that exemption README.adoc, EXPLAINME.adoc and both
# descriptiles fail on every mint, and a gate that always fires gets switched
# off. But the instruction block's ONLY doubled-brace text is the metasyntactic
# PLACEHOLDER token, so 3b is structurally incapable of seeing it.
#
# That gap is why 211 estate repos shipped the block, 206 of them in
# CODE_OF_CONDUCT.md, each one naming "Squisher Corpus" as the project it
# protects and routing conduct reports to the wrong repository. Measured
# 2026-08-04. Catch it by name instead.
LEFTOVER=$(grep -rl 'TEMPLATE INSTRUCTIONS' "$TEST_REPO_PATH" \
    --exclude-dir=.git 2>/dev/null \
    | grep -vE '/(scripts/strip-instruction-blocks\.py|build/just/repo-init\.just|tests/e2e/template_instantiation_test\.sh)$' || true)
if [ -n "$LEFTOVER" ]; then
    log_error "just repo-init left a TEMPLATE INSTRUCTIONS block in:"
    echo "$LEFTOVER" | sed 's/^/    /' >&2
    exit 1
fi

log_pass "No template instruction blocks survived instantiation"

#==============================================================================
# PHASE 4: VALIDATE STRUCTURE
#==============================================================================

log_step "Validating instantiated repository structure"

# Run validation script on the instantiated repo
if [ -f "$TEMPLATE_ROOT/scripts/validate-template.sh" ]; then
    bash "$TEMPLATE_ROOT/scripts/validate-template.sh" "$TEST_REPO_PATH" 0
    log_pass "Repository structure validation passed"
else
    log_error "Validation script not found"
    exit 1
fi

#==============================================================================
# PHASE 5: VERIFY BUILD
#==============================================================================

log_step "Verifying build system works after instantiation"

if [ -f "$TEST_REPO_PATH/src/interface/ffi/build.zig" ]; then
    if command -v zig &> /dev/null; then
        cd "$TEST_REPO_PATH/src/interface/ffi"
        if zig build 2>&1; then
            log_pass "Zig build successful"
        else
            log_error "Zig build failed"
            exit 1
        fi
        cd - > /dev/null
    else
        log_error "Zig compiler not found - cannot verify build"
        exit 1
    fi
fi

#==============================================================================
# PHASE 7: VERIFY CRITICAL FILES ARE NOT TEMPLATES
#==============================================================================

log_step "Verifying critical files have been instantiated"

CRITICAL_FILES=(
    "README.adoc"
    "EXPLAINME.adoc"
    "Justfile"
)

for file in "${CRITICAL_FILES[@]}"; do
    if [ -f "$TEST_REPO_PATH/$file" ]; then
        # Check that it's not just a template (contains some actual content)
        if grep -q "$TEST_PROJECT_NAME\|$TEST_AUTHOR\|$TEST_REPO_NAME" "$TEST_REPO_PATH/$file" 2>/dev/null || \
           [ $(wc -l < "$TEST_REPO_PATH/$file") -gt 10 ]; then
            log_pass "File instantiated: $file"
        else
            log_error "File appears to be a template: $file"
            exit 1
        fi
    else
        log_error "Critical file missing: $file"
        exit 1
    fi
done

#==============================================================================
# PHASE 8: VERIFY METADATA
#==============================================================================

log_step "Verifying machine-readable metadata"

METADATA_FILES=(
    ".machine_readable/descriptiles/STATE.a2ml"
    ".machine_readable/descriptiles/META.a2ml"
)

for file in "${METADATA_FILES[@]}"; do
    if [ -f "$TEST_REPO_PATH/$file" ]; then
        log_pass "Metadata file exists: $file"
    else
        log_error "Metadata file missing: $file"
        exit 1
    fi
done

#==============================================================================
# SUMMARY
#==============================================================================

echo ""
echo "═══════════════════════════════════════════════════════════════════════════════"
echo -e "${GREEN}✓ E2E TEMPLATE INSTANTIATION TEST PASSED${NC}"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""
echo "Summary:"
echo "  - Template cloned successfully"
echo "  - All placeholders replaced"
echo "  - Repository structure valid"
echo "  - Build system works"
echo "  - No remaining placeholders"
echo "  - Metadata intact"
echo ""
echo "Test repository: $TEST_REPO_PATH (will be cleaned up)"
echo ""
