#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="$PROJECT_ROOT/bootstrap.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS=0
FAIL=0

setup() {
    local name="$1"

    CASE_DIR="$TEST_ROOT/$name"
    MOCK_BIN="$CASE_DIR/bin"
    MOCK_LOG="$CASE_DIR/commands.log"
    MOCK_HOME="$CASE_DIR/home"
    BOOTSTRAP_DEST="$CASE_DIR/checkout"

    mkdir -p "$MOCK_BIN" "$MOCK_HOME"
    : > "$MOCK_LOG"

    export MOCK_BIN MOCK_LOG MOCK_HOME BOOTSTRAP_DEST
    export HOME="$MOCK_HOME"
    export PATH="$MOCK_BIN:/usr/bin:/bin"

    export MOCK_AUTH_STATUS=0
    export MOCK_AUTH_LOGIN_STATUS=0
    export MOCK_REPO_ACCESS=yes
    export MOCK_CLONE_STATUS=0

    make_mocks
}

make_mocks() {
    cat > "$MOCK_BIN/gh" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail

printf 'gh %s\n' "$*" >> "$MOCK_LOG"

case "${1:-} ${2:-}" in
    "auth status")
        exit "${MOCK_AUTH_STATUS:-0}"
        ;;

    "auth login")
        exit "${MOCK_AUTH_LOGIN_STATUS:-0}"
        ;;

    "repo view")
        if [[ "${MOCK_REPO_ACCESS:-yes}" == "yes" ]]; then
            printf 'plexosoft/self-hosted-ai-assistant\n'
            exit 0
        fi

        exit 1
        ;;

    "repo clone")
        if [[ "${MOCK_CLONE_STATUS:-0}" -ne 0 ]]; then
            exit "$MOCK_CLONE_STATUS"
        fi

        # gh repo clone OWNER/REPO DESTINATION:
        # $1=repo, $2=clone, $3=OWNER/REPO, $4=DESTINATION.
        if [[ "${4:-}" != "$BOOTSTRAP_DEST" ]]; then
            printf 'Unexpected clone destination: %s\n' "${4:-<missing>}" >&2
            exit 90
        fi

        mkdir -p "$4/.git" "$4/scripts"

        cat > "$4/scripts/install.sh" <<'INSTALL'
#!/usr/bin/env bash
printf 'installer ran\n' >> "$MOCK_LOG"
INSTALL

        chmod +x "$4/scripts/install.sh"
        printf 'mock clone completed\n' >> "$MOCK_LOG"
        ;;

    *)
        printf 'Unexpected gh invocation: %s\n' "$*" >&2
        exit 2
        ;;
esac
MOCK

    cat > "$MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "$MOCK_LOG"
exit 0
MOCK

    cat > "$MOCK_BIN/curl" <<'MOCK'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$MOCK_LOG"
exit 0
MOCK

    chmod +x "$MOCK_BIN/gh" "$MOCK_BIN/git" "$MOCK_BIN/curl"

    # These utilities must resolve correctly while gh remains mocked.
    for utility in dirname mkdir; do
        ln -sf "$(command -v "$utility")" "$MOCK_BIN/$utility"
    done
}

assert_contains() {
    local file="$1"
    local expected="$2"

    if grep -Fq -- "$expected" "$file"; then
        printf '  PASS: %s\n' "$expected"
        PASS=$((PASS + 1))
    else
        printf '  FAIL: expected to find: %s\n' "$expected"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local file="$1"
    local unexpected="$2"

    if grep -Fq -- "$unexpected" "$file"; then
        printf '  FAIL: unexpectedly found: %s\n' "$unexpected"
        FAIL=$((FAIL + 1))
    else
        printf '  PASS: absent as expected: %s\n' "$unexpected"
        PASS=$((PASS + 1))
    fi
}

assert_success() {
    local description="$1"
    local status="$2"

    if [[ "$status" -eq 0 ]]; then
        printf '  PASS: %s\n' "$description"
        PASS=$((PASS + 1))
    else
        printf '  FAIL: %s (exit status %s)\n' "$description" "$status"
        FAIL=$((FAIL + 1))
    fi
}

run_bootstrap() {
    local input="$1"
    local output="$CASE_DIR/output.log"
    local status=0

    # A pseudo-terminal makes stdin a TTY, as required by confirm().
    # The input is supplied to the terminal rather than piped directly
    # into bootstrap.sh.
    if ! command -v script >/dev/null 2>&1; then
        printf 'ERROR: The test suite requires the "script" utility.\n' >&2
        return 127
    fi

    printf '%s' "$input" |
        script -qec "bash '$BOOTSTRAP'" /dev/null > "$output" 2>&1 ||
        status=$?

    return "$status"
}

test_clone_and_skip_install() {
    echo "== Clone succeeds; installer is declined =="
    setup clone-success

    local status=0
    run_bootstrap $'n\n' || status=$?
    assert_success "bootstrap exits successfully after declining installation" "$status"

    assert_contains "$MOCK_LOG" \
        "gh repo view plexosoft/self-hosted-ai-assistant --json nameWithOwner --jq .nameWithOwner"

    assert_contains "$MOCK_LOG" \
        "gh repo clone plexosoft/self-hosted-ai-assistant $BOOTSTRAP_DEST"

    assert_contains "$MOCK_LOG" "mock clone completed"
    assert_not_contains "$MOCK_LOG" "installer ran"

    if [[ -d "$BOOTSTRAP_DEST/.git" && -x "$BOOTSTRAP_DEST/scripts/install.sh" ]]; then
        printf '  PASS: mock checkout exists and installer is executable\n'
        PASS=$((PASS + 1))
    else
        printf '  FAIL: mock checkout is missing or incomplete\n'
        FAIL=$((FAIL + 1))
    fi

    assert_contains "$CASE_DIR/output.log" "Repository cloned to:"
    assert_contains "$CASE_DIR/output.log" "Installation skipped"
}

test_existing_destination() {
    echo "== Existing destination is not overwritten =="
    setup existing-destination

    mkdir -p "$BOOTSTRAP_DEST"
    printf 'keep this file\n' > "$BOOTSTRAP_DEST/keep.txt"

    local status=0
    run_bootstrap "" || status=$?

    if [[ "$status" -ne 0 ]]; then
        printf '  PASS: bootstrap rejects the existing destination\n'
        PASS=$((PASS + 1))
    else
        printf '  FAIL: bootstrap unexpectedly accepted the existing destination\n'
        FAIL=$((FAIL + 1))
    fi

    assert_contains "$CASE_DIR/output.log" "Destination already exists"
    assert_not_contains "$MOCK_LOG" "gh repo clone"

    if [[ -f "$BOOTSTRAP_DEST/keep.txt" ]] &&
       [[ "$(cat "$BOOTSTRAP_DEST/keep.txt")" == "keep this file" ]]; then
        printf '  PASS: existing destination contents were preserved\n'
        PASS=$((PASS + 1))
    else
        printf '  FAIL: existing destination contents were changed\n'
        FAIL=$((FAIL + 1))
    fi
}

test_authentication_failure() {
    echo "== Authentication failure prevents cloning =="
    setup authentication-failure

    export MOCK_AUTH_STATUS=1
    export MOCK_AUTH_LOGIN_STATUS=1

    local status=0
    run_bootstrap "" || status=$?

    if [[ "$status" -ne 0 ]]; then
        printf '  PASS: bootstrap exits unsuccessfully when authentication fails\n'
        PASS=$((PASS + 1))
    else
        printf '  FAIL: bootstrap unexpectedly succeeded without authentication\n'
        FAIL=$((FAIL + 1))
    fi

    assert_contains "$MOCK_LOG" \
        "gh auth login --hostname github.com --git-protocol https --web"

    assert_not_contains "$MOCK_LOG" "gh repo clone"
}

test_repository_access_failure() {
    echo "== Repository access failure prevents cloning =="
    setup repository-access-failure

    export MOCK_REPO_ACCESS=no

    local status=0
    run_bootstrap "" || status=$?

    if [[ "$status" -ne 0 ]]; then
        printf '  PASS: bootstrap exits unsuccessfully when repository access fails\n'
        PASS=$((PASS + 1))
    else
        printf '  FAIL: bootstrap unexpectedly succeeded without repository access\n'
        FAIL=$((FAIL + 1))
    fi

    assert_contains "$CASE_DIR/output.log" "cannot access"
    assert_not_contains "$MOCK_LOG" "gh repo clone"
}

test_clone_failure() {
    echo "== Clone failure is reported =="
    setup clone-failure

    export MOCK_CLONE_STATUS=1

    local status=0
    run_bootstrap $'y\n' || status=$?

    if [[ "$status" -ne 0 ]]; then
        printf '  PASS: bootstrap exits unsuccessfully when cloning fails\n'
        PASS=$((PASS + 1))
    else
        printf '  FAIL: bootstrap unexpectedly succeeded after clone failure\n'
        FAIL=$((FAIL + 1))
    fi

    assert_contains "$MOCK_LOG" \
        "gh repo clone plexosoft/self-hosted-ai-assistant $BOOTSTRAP_DEST"

    assert_not_contains "$MOCK_LOG" "installer ran"
    assert_not_contains "$CASE_DIR/output.log" "Repository cloned to:"

    if [[ ! -e "$BOOTSTRAP_DEST" ]]; then
        printf '  PASS: failed clone did not create the mock checkout\n'
        PASS=$((PASS + 1))
    else
        printf '  FAIL: failed clone unexpectedly created the mock checkout\n'
        FAIL=$((FAIL + 1))
    fi
}

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    echo "ERROR: Run this test as a non-root user." >&2
    exit 1
fi

test_clone_and_skip_install
test_existing_destination
test_authentication_failure
test_repository_access_failure
test_clone_failure

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"

[[ "$FAIL" -eq 0 ]]