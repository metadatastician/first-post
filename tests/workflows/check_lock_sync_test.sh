#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Unit tests for scripts/check-lock-sync.sh. Each case uses an isolated workflow
# directory so the checker is exercised through its public command-line interface.

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="$SCRIPT_DIR/../../scripts/check-lock-sync.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/check-lock-sync-test.XXXXXX")"

PASS=0
FAIL=0
CHECK_STATUS=0
CHECK_OUTPUT=""
CASE_DIR=""

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

pass() {
    printf 'PASS: %s\n' "$1"
    PASS=$((PASS + 1))
}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    FAIL=$((FAIL + 1))
}

new_case() {
    CASE_DIR="$TEST_ROOT/$1"
    mkdir -p "$CASE_DIR/.github/workflows"
}

write_file() {
    local path="$1"
    shift
    mkdir -p "$(dirname "$CASE_DIR/$path")"
    printf '%s\n' "$@" > "$CASE_DIR/$path"
}

write_workflow() {
    local filename="$1"
    shift
    write_file ".github/workflows/$filename" "$@"
}

write_lock() {
    write_file .github/workflows/actions.lock "$@"
}

run_checker() {
    local name="$1"
    CHECK_OUTPUT="$TEST_ROOT/$name.output"
    if "$CHECKER" "$TEST_ROOT/$name/.github/workflows" > "$CHECK_OUTPUT" 2>&1; then
        CHECK_STATUS=0
    else
        CHECK_STATUS=$?
    fi
}

expect_success() {
    local name="$1"
    shift
    run_checker "$name"
    if [ "$CHECK_STATUS" -ne 0 ]; then
        fail "$name should succeed (exit $CHECK_STATUS)"
        sed -n '1,160p' "$CHECK_OUTPUT" >&2
        return 0
    fi
    local expected
    for expected in "$@"; do
        if ! grep -Fq -- "$expected" "$CHECK_OUTPUT"; then
            fail "$name should report: $expected"
            sed -n '1,160p' "$CHECK_OUTPUT" >&2
            return 0
        fi
    done
    pass "$name"
}

expect_failure() {
    local name="$1"
    shift
    run_checker "$name"
    if [ "$CHECK_STATUS" -eq 0 ]; then
        fail "$name should fail"
        sed -n '1,160p' "$CHECK_OUTPUT" >&2
        return 0
    fi
    local expected
    for expected in "$@"; do
        if ! grep -Fq -- "$expected" "$CHECK_OUTPUT"; then
            fail "$name should mention: $expected"
            sed -n '1,160p' "$CHECK_OUTPUT" >&2
            return 0
        fi
    done
    pass "$name"
}

test_accepts_normalized_external_refs_and_local_actions() {
    new_case normalized-refs
    write_workflow ci.yml \
        'name: CI' \
        'jobs:' \
        '  call-shared:' \
        '    uses: Acme/Shared/.github/workflows/reusable.yml@Release-1 # inline comment' \
        '  build:' \
        '    runs-on: ubuntu-latest' \
        '    steps:' \
        '      - uses: "Vendor/Action/subpath@v2"' \
        '      - uses: ./local-action'
    write_lock \
        'workflows:' \
        "    '.github/workflows/ci.yml':" \
        "        - 'acme/shared@Release-1'" \
        "        - 'vendor/action@v2'" \
        'dependencies:' \
        "    'acme/shared@Release-1':" \
        "        ref: 'Release-1'" \
        "    'vendor/action@v2':" \
        "        ref: 'v2'"
    expect_success normalized-refs 'actions.lock is in sync and transitively closed'
}

test_reports_missing_workflow_lock_entry() {
    new_case missing-lock-entry
    write_workflow ci.yml \
        'jobs:' \
        '  build:' \
        '    steps:' \
        '      - uses: vendor/action@v1'
    write_lock \
        'workflows:' \
        "    '.github/workflows/ci.yml': []" \
        'dependencies:'
    expect_failure missing-lock-entry 'refs missing from the lockfile: vendor/action@v1'
}

test_reports_orphaned_lock_entry() {
    new_case orphaned-entry
    write_workflow ci.yml \
        'jobs:' \
        '  build:' \
        '    steps:' \
        '      - uses: vendor/action@v1'
    write_lock \
        'workflows:' \
        "    '.github/workflows/ci.yml':" \
        "        - 'vendor/action@v1'" \
        "        - 'vendor/stale@v2'" \
        'dependencies:' \
        "    'vendor/action@v1':" \
        "        ref: 'v1'" \
        "    'vendor/stale@v2':" \
        "        ref: 'v2'"
    expect_failure orphaned-entry 'stale lockfile entries, no uses: references them: vendor/stale@v2'
}

test_reports_transitive_dangling_dependency() {
    new_case dangling-dependency
    write_workflow ci.yml \
        'jobs:' \
        '  build:' \
        '    steps:' \
        '      - uses: owner/root@v1'
    write_lock \
        'workflows:' \
        "    '.github/workflows/ci.yml':" \
        "        - 'owner/root@v1'" \
        'dependencies:' \
        "    'owner/root@v1':" \
        "        ref: 'v1'" \
        '        uses:' \
        "            - 'actions/cache@v1'"
    expect_failure dangling-dependency 'FAIL actions.lock: DANGLING EDGES'
}

test_accepts_self_repository_reference() {
    new_case self-repository-reference
    write_workflow ci.yml \
        'jobs:' \
        '  build:' \
        '    steps:' \
        '      - uses: $/local-action'
    write_lock \
        'workflows:' \
        "    '.github/workflows/ci.yml': []" \
        'dependencies:'
    expect_success self-repository-reference 'actions.lock is in sync and transitively closed'
}

test_reports_lock_entry_for_deleted_workflow() {
    new_case deleted-workflow
    write_workflow ci.yml \
        'jobs:' \
        '  build:' \
        '    runs-on: ubuntu-latest' \
        '    steps:' \
        '      - run: true'
    write_lock \
        'workflows:' \
        "    '.github/workflows/ci.yml': []" \
        "    '.github/workflows/deleted.yml': []" \
        'dependencies:'
    expect_failure deleted-workflow 'lockfile entry for a workflow file that does not exist'
}

test_accepts_empty_lock_entry_for_zero_uses_workflow() {
    new_case covered-zero-uses
    write_workflow maintenance.yaml \
        'name: Maintenance' \
        'jobs:' \
        '  clean:' \
        '    runs-on: ubuntu-latest' \
        '    steps:' \
        '      - run: true'
    write_lock \
        'workflows:' \
        "    '.github/workflows/maintenance.yaml': []" \
        'dependencies:'
    expect_success covered-zero-uses \
        'actions.lock is in sync and transitively closed' \
        'every workflow file has a lockfile key (zero-uses: workflows included)'
}

test_reports_unlisted_zero_uses_workflow() {
    new_case unlisted-zero-uses
    write_workflow covered.yml \
        'name: Covered' \
        'jobs:' \
        '  build:' \
        '    runs-on: ubuntu-latest'
    write_workflow unlisted.yml \
        'name: Unlisted' \
        'jobs:' \
        '  build:' \
        '    runs-on: ubuntu-latest'
    write_lock \
        'workflows:' \
        "    '.github/workflows/covered.yml': []" \
        'dependencies:'
    expect_failure unlisted-zero-uses \
        'FAIL actions.lock: UNLISTED WORKFLOWS' \
        '1 workflow file(s) have no key in the lockfile' \
        '.github/workflows/unlisted.yml' \
        "with no uses: takes an empty list:  '.github/workflows/x.yml': []" \
        're-running the tool may not add it'
}

test_reports_every_unlisted_workflow() {
    new_case multiple-unlisted
    write_workflow covered.yml \
        'name: Covered' \
        'jobs:' \
        '  build:' \
        '    runs-on: ubuntu-latest'
    write_workflow alpha.yml \
        'name: Alpha' \
        'jobs:' \
        '  build:' \
        '    runs-on: ubuntu-latest'
    write_workflow omega.yaml \
        'name: Omega' \
        'jobs:' \
        '  build:' \
        '    runs-on: ubuntu-latest'
    write_lock \
        'workflows:' \
        "    '.github/workflows/covered.yml': []" \
        'dependencies:'
    expect_failure multiple-unlisted \
        '2 workflow file(s) have no key in the lockfile' \
        '.github/workflows/alpha.yml' \
        '.github/workflows/omega.yaml'
}

test_fails_without_a_lockfile() {
    new_case no-lockfile
    write_workflow ci.yml \
        'jobs:' \
        '  build:' \
        '    runs-on: ubuntu-latest'
    expect_failure no-lockfile 'FATAL: no lockfile'
}

test_fails_without_workflow_files() {
    new_case no-workflows
    write_lock \
        'workflows:' \
        'dependencies:'
    expect_failure no-workflows 'FATAL: no workflow files'
}

test_compares_refs_case_sensitively() {
    new_case ref-case
    write_workflow ci.yml \
        'jobs:' \
        '  build:' \
        '    steps:' \
        '      - uses: Vendor/Action@V1'
    write_lock \
        'workflows:' \
        "    '.github/workflows/ci.yml':" \
        "        - 'vendor/action@v1'" \
        'dependencies:' \
        "    'vendor/action@v1':" \
        "        ref: 'v1'"
    expect_failure ref-case 'refs missing from the lockfile: Vendor/Action@V1'
}

if [ ! -x "$CHECKER" ]; then
    printf 'check-lock-sync test target is missing or not executable: %s\n' "$CHECKER" >&2
    exit 1
fi

test_accepts_normalized_external_refs_and_local_actions
test_reports_missing_workflow_lock_entry
test_reports_orphaned_lock_entry
test_reports_transitive_dangling_dependency
test_accepts_self_repository_reference
test_reports_lock_entry_for_deleted_workflow
test_accepts_empty_lock_entry_for_zero_uses_workflow
test_reports_unlisted_zero_uses_workflow
test_reports_every_unlisted_workflow
test_fails_without_a_lockfile
test_fails_without_workflow_files
test_compares_refs_case_sensitively

printf '\n%d passed; %d failed\n' "$PASS" "$FAIL"
exit "$FAIL"
