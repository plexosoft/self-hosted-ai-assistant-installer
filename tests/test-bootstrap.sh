#!/usr/bin/env bash
set -Eeuo pipefail

# Integration-style tests for bootstrap.sh.
#
# Safety model:
# - Run only as a non-root user on a supported Ubuntu host outside a container.
# - Mock GitHub CLI, Docker, and privileged/system-changing commands.
# - Any unexpected attempt to invoke sudo/APT/account-management commands fails.
# - The bootstrap's real OS/container guards remain enabled and are not patched.

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="$PROJECT_ROOT/bootstrap.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS=0
FAIL=0

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    printf 'ERROR: Run this test as a non-root user.\n' >&2
    exit 1
fi

if [[ ! -f /etc/os-release ]] || ! grep -q '^ID=ubuntu$' /etc/os-release; then
    printf 'ERROR: These integration tests require Ubuntu because bootstrap.sh does.\n' >&2
    exit 1
fi

if [[ -f /.dockerenv ]] ||
   grep -qaE '(docker|containerd|kubepods|podman|lxc)' /proc/1/cgroup 2>/dev/null; then
    printf 'ERROR: bootstrap.sh rejects container environments; run this suite on a supported Ubuntu host or VM.\n' >&2
    exit 1
fi

if ! command -v script >/dev/null 2>&1; then
    printf 'ERROR: The test suite requires the "script" utility.\n' >&2
    exit 1
fi

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
    export MOCK_REQUIRE_TOKEN=yes
    export MOCK_AUTH_LOGIN_STATUS=0
    export MOCK_REPO_ACCESS=yes
    export MOCK_REPO_IDENTITY=plexosoft/self-hosted-ai-assistant
    export MOCK_CLONE_STATUS=0
    export MOCK_DOCKER_COMPOSE_STATUS=0
    export MOCK_DOCKER_GROUP_ACTIVE=yes
    export MOCK_INSTALLER_STATUS=0

    make_mocks
}

make_mocks() {
    cat > "$MOCK_BIN/gh" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
# Never log token values. Record only whether the environment variable exists.
printf 'gh %s GH_TOKEN_%s\n' "$*" "$([[ -n "${GH_TOKEN:-}" ]] && printf PRESENT || printf ABSENT)" >> "$MOCK_LOG"

if [[ "${1:-}" == "--version" ]]; then
    printf 'gh version 2.0.0 (mock)\n'
    exit 0
fi

case "${1:-} ${2:-}" in
    "auth status")
        if [[ "${MOCK_REQUIRE_TOKEN:-yes}" == yes && -z "${GH_TOKEN:-}" ]]; then
            exit 1
        fi
        exit "${MOCK_AUTH_STATUS:-0}"
        ;;
    "auth git-credential")
        # The test's git mock checks the configured helper; no credential is requested.
        exit 0
        ;;
    "repo view")
        if [[ "${MOCK_REPO_ACCESS:-yes}" == yes ]]; then
            printf '%s\n' "${MOCK_REPO_IDENTITY:-plexosoft/self-hosted-ai-assistant}"
            exit 0
        fi
        exit 1
        ;;
    *)
        printf 'Unexpected gh invocation: %s\n' "$*" >&2
        exit 2
        ;;
esac
MOCK

    cat > "$MOCK_BIN/git" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
# Log only command arguments; the token must never appear in them.
printf 'git %s\n' "$*" >> "$MOCK_LOG"
[[ "${1:-}" == -c && "${2:-}" == credential.helper= && "${3:-}" == '-c' && "${4:-}" == 'credential.helper=!gh auth git-credential' && "${5:-}" == clone ]] || {
    printf 'Unexpected git clone configuration.\n' >&2
    exit 93
}
# Correct URL/destination are checked without exposing any environment secrets.
[[ "${6:-}" == 'https://github.com/plexosoft/self-hosted-ai-assistant.git' ]] || exit 94
[[ -n "${7:-}" && "${7:-}" == "$BOOTSTRAP_DEST" ]] || exit 95
if [[ "${MOCK_CLONE_STATUS:-0}" -ne 0 ]]; then
    exit "$MOCK_CLONE_STATUS"
fi
mkdir -p "$7/.git" "$7/scripts"
cat > "$7/scripts/install.sh" <<'INSTALL'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'installer ran\n' >> "$MOCK_LOG"
if [[ -n "${GH_TOKEN:-}" ]]; then
    printf 'GH_TOKEN_PRESENT in installer\n' >> "$MOCK_LOG"
else
    printf 'GH_TOKEN_ABSENT in installer\n' >> "$MOCK_LOG"
fi
exit "${MOCK_INSTALLER_STATUS:-0}"
INSTALL
chmod +x "$7/scripts/install.sh"
printf 'mock clone completed\n' >> "$MOCK_LOG"
MOCK

    cat > "$MOCK_BIN/docker" <<'MOCK'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$MOCK_LOG"
if [[ "${1:-}" == compose && "${2:-}" == version ]]; then
    exit "${MOCK_DOCKER_COMPOSE_STATUS:-0}"
fi
exit 0
MOCK

    cat > "$MOCK_BIN/id" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    -un)
        /usr/bin/id -un
        ;;
    -nG)
        if [[ "${MOCK_DOCKER_GROUP_ACTIVE:-yes}" == yes ]]; then
            printf 'users docker\n'
        else
            printf 'users\n'
        fi
        ;;
    *)
        exec /usr/bin/id "$@"
        ;;
esac
MOCK

    cat > "$MOCK_BIN/dpkg-query" <<'MOCK'
#!/usr/bin/env bash
printf 'dpkg-query %s\n' "$*" >> "$MOCK_LOG"
package="${@: -1}"
case "$package" in
    ca-certificates|curl|git)
        printf 'install ok installed\n'
        exit 0
        ;;
    *)
        # Treat Docker conflict packages as absent in the default test fixture.
        exit 1
        ;;
esac
MOCK

    cat > "$MOCK_BIN/getent" <<'MOCK'
#!/usr/bin/env bash
printf 'getent %s\n' "$*" >> "$MOCK_LOG"
if [[ "${1:-}" == group && "${2:-}" == docker ]]; then
    printf 'docker:x:999:\n'
    exit 0
fi
exec /usr/bin/getent "$@"
MOCK

    cat > "$MOCK_BIN/sudo" <<'MOCK'
#!/usr/bin/env bash
printf 'BLOCKED privileged command: sudo %s\n' "$*" >> "$MOCK_LOG"
printf 'ERROR: test attempted a privileged operation: sudo %s\n' "$*" >&2
exit 97
MOCK

    # Defensive blockers: these must never perform real host changes in tests.
    for command_name in apt-get apt-cache systemctl groupadd usermod install; do
        cat > "$MOCK_BIN/$command_name" <<'MOCK'
#!/usr/bin/env bash
printf 'BLOCKED system command: %s %s\n' "${0##*/}" "$*" >> "$MOCK_LOG"
printf 'ERROR: test attempted a system-changing command: %s\n' "${0##*/}" >&2
exit 98
MOCK
    done

    cat > "$MOCK_BIN/sg" <<'MOCK'
#!/usr/bin/env bash
printf 'sg %s\n' "$*" >> "$MOCK_LOG"
# Execute only the command the bootstrap constructed. Its checkout is a test fixture.
[[ "${1:-}" == docker && "${2:-}" == -c && -n "${3:-}" ]] || exit 99
exec /bin/bash -c "$3"
MOCK

    cat > "$MOCK_BIN/curl" <<'MOCK'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$MOCK_LOG"
printf 'mock curl must not be used in this test\n' >&2
exit 96
MOCK

    chmod +x "$MOCK_BIN"/*
}

assert_contains() {
    local file="$1" expected="$2"
    if grep -Fq -- "$expected" "$file"; then
        printf '  PASS: found: %s\n' "$expected"
        PASS=$((PASS + 1))
    else
        printf '  FAIL: expected to find: %s\n' "$expected"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local file="$1" unexpected="$2"
    if grep -Fq -- "$unexpected" "$file"; then
        printf '  FAIL: unexpectedly found: %s\n' "$unexpected"
        FAIL=$((FAIL + 1))
    else
        printf '  PASS: absent as expected: %s\n' "$unexpected"
        PASS=$((PASS + 1))
    fi
}

assert_success() {
    local description="$1" status="$2"
    if [[ "$status" -eq 0 ]]; then
        printf '  PASS: %s\n' "$description"
        PASS=$((PASS + 1))
    else
        printf '  FAIL: %s (exit status %s)\n' "$description" "$status"
        FAIL=$((FAIL + 1))
    fi
}

assert_failure() {
    local description="$1" status="$2"
    if [[ "$status" -ne 0 ]]; then
        printf '  PASS: %s\n' "$description"
        PASS=$((PASS + 1))
    else
        printf '  FAIL: %s\n' "$description"
        FAIL=$((FAIL + 1))
    fi
}

run_bootstrap() {
    local input="$1"
    local output="$CASE_DIR/output.log"
    local status=0

    # A pseudo-terminal is needed because confirm() requires terminal stdin.
    printf '%s' "$input" |
        script -qec "bash '$BOOTSTRAP'" /dev/null > "$output" 2>&1 ||
        status=$?
    return "$status"
}

test_prompted_token_and_https_clone() {
    echo "== Prompts for a token and clones over HTTPS even when gh has a saved session =="
    setup prompted-token
    export MOCK_AUTH_STATUS=0
    local token='test-token-do-not-print'
    local status=0
    run_bootstrap "$token"$'\nn\n' || status=$?

    assert_success "bootstrap succeeds after declining application installation" "$status"
    assert_contains "$CASE_DIR/output.log" "GitHub fine-grained token:"
    assert_contains "$MOCK_LOG" "gh auth status --hostname github.com GH_TOKEN_PRESENT"
    assert_contains "$MOCK_LOG" "gh repo view plexosoft/self-hosted-ai-assistant --json nameWithOwner --jq .nameWithOwner GH_TOKEN_PRESENT"
    assert_contains "$MOCK_LOG" "git -c credential.helper= -c credential.helper=!gh auth git-credential clone https://github.com/plexosoft/self-hosted-ai-assistant.git $BOOTSTRAP_DEST"
    assert_contains "$MOCK_LOG" "mock clone completed"
    assert_contains "$CASE_DIR/output.log" "Installation skipped"
    assert_not_contains "$MOCK_LOG" "$token"
    assert_not_contains "$CASE_DIR/output.log" "$token"
    assert_not_contains "$MOCK_LOG" "gh auth logout"

    if [[ -d "$BOOTSTRAP_DEST/.git" && -x "$BOOTSTRAP_DEST/scripts/install.sh" ]]; then
        printf '  PASS: checkout exists and installer is executable\n'
        PASS=$((PASS + 1))
    else
        printf '  FAIL: checkout is missing or incomplete\n'
        FAIL=$((FAIL + 1))
    fi
}

test_invalid_token_stops_early() {
    echo "== Invalid token prevents repository access, Docker setup, and cloning =="
    setup invalid-token
    export MOCK_AUTH_STATUS=1
    local status=0
    run_bootstrap $'bad-token\n' || status=$?

    assert_failure "bootstrap fails when token validation fails" "$status"
    assert_contains "$CASE_DIR/output.log" "GitHub token validation failed"
    assert_not_contains "$MOCK_LOG" "gh repo view"
    assert_not_contains "$MOCK_LOG" "docker compose version"
    assert_not_contains "$MOCK_LOG" "git -c"
    assert_not_contains "$MOCK_LOG" "bad-token"
    assert_not_contains "$CASE_DIR/output.log" "bad-token"
}

test_repository_access_failure() {
    echo "== Repository access failure stops before Docker setup and clone =="
    setup repository-access-failure
    export MOCK_REPO_ACCESS=no
    local status=0
    run_bootstrap $'valid-token\n' || status=$?

    assert_failure "bootstrap fails when repository access is denied" "$status"
    assert_contains "$CASE_DIR/output.log" "cannot access"
    assert_not_contains "$MOCK_LOG" "docker compose version"
    assert_not_contains "$MOCK_LOG" "git -c"
    assert_not_contains "$MOCK_LOG" "BLOCKED"
}

test_unexpected_repository_identity() {
    echo "== Unexpected repository identity stops installation =="
    setup unexpected-repository
    export MOCK_REPO_IDENTITY="someone-else/different-repository"
    local status=0
    run_bootstrap $'valid-token\n' || status=$?

    assert_failure "bootstrap rejects an unexpected repository identity" "$status"
    assert_contains "$CASE_DIR/output.log" "unexpected repository identity"
    assert_not_contains "$MOCK_LOG" "docker compose version"
    assert_not_contains "$MOCK_LOG" "git -c"
}

test_existing_destination() {
    echo "== Existing destination is not overwritten =="
    setup existing-destination
    mkdir -p "$BOOTSTRAP_DEST"
    printf 'keep this file\n' > "$BOOTSTRAP_DEST/keep.txt"
    local status=0
    run_bootstrap $'valid-token\n' || status=$?

    assert_failure "bootstrap rejects the existing destination" "$status"
    assert_contains "$CASE_DIR/output.log" "Destination already exists"
    assert_not_contains "$MOCK_LOG" "git -c"
    if [[ -f "$BOOTSTRAP_DEST/keep.txt" ]] && [[ "$(cat "$BOOTSTRAP_DEST/keep.txt")" == "keep this file" ]]; then
        printf '  PASS: existing destination contents were preserved\n'
        PASS=$((PASS + 1))
    else
        printf '  FAIL: existing destination contents were changed\n'
        FAIL=$((FAIL + 1))
    fi
}

test_clone_failure() {
    echo "== HTTPS clone failure is reported =="
    setup clone-failure
    export MOCK_CLONE_STATUS=1
    local status=0
    run_bootstrap $'valid-token\n' || status=$?

    assert_failure "bootstrap fails when cloning fails" "$status"
    assert_contains "$MOCK_LOG" "git -c credential.helper= -c credential.helper=!gh auth git-credential clone https://github.com/plexosoft/self-hosted-ai-assistant.git $BOOTSTRAP_DEST"
    assert_not_contains "$MOCK_LOG" "installer ran"
    assert_not_contains "$CASE_DIR/output.log" "Repository cloned to:"
    if [[ ! -e "$BOOTSTRAP_DEST" ]]; then
        printf '  PASS: failed clone did not create a checkout\n'
        PASS=$((PASS + 1))
    else
        printf '  FAIL: failed clone unexpectedly created a checkout\n'
        FAIL=$((FAIL + 1))
    fi
}

test_token_not_passed_to_installer() {
    echo "== Token is cleared before application installer runs =="
    setup token-cleanup
    local status=0
    run_bootstrap $'test-token-do-not-print\ny\n' || status=$?

    assert_success "bootstrap and mock installer complete successfully" "$status"
    assert_contains "$MOCK_LOG" "installer ran"
    assert_contains "$MOCK_LOG" "GH_TOKEN_ABSENT in installer"
    assert_not_contains "$MOCK_LOG" "GH_TOKEN_PRESENT in installer"
    assert_not_contains "$MOCK_LOG" "test-token-do-not-print"
    assert_not_contains "$CASE_DIR/output.log" "test-token-do-not-print"
}

test_environment_token() {
    echo "== GH_TOKEN environment path works and is cleared before installer =="
    setup environment-token
    export GH_TOKEN='environment-token-do-not-print'
    local status=0
    run_bootstrap $'n\n' || status=$?
    unset GH_TOKEN

    assert_success "bootstrap accepts GH_TOKEN and skips installation" "$status"
    assert_contains "$CASE_DIR/output.log" "Using the GitHub token supplied through GH_TOKEN"
    assert_contains "$MOCK_LOG" "GH_TOKEN_PRESENT"
    assert_not_contains "$MOCK_LOG" "environment-token-do-not-print"
    assert_not_contains "$CASE_DIR/output.log" "environment-token-do-not-print"
}

test_installer_failure_propagates() {
    echo "== Application installer failure is propagated =="
    setup installer-failure
    export MOCK_INSTALLER_STATUS=7
    local status=0
    run_bootstrap $'valid-token\ny\n' || status=$?

    assert_failure "bootstrap reports an application installer failure" "$status"
    assert_contains "$MOCK_LOG" "installer ran"
    assert_contains "$MOCK_LOG" "GH_TOKEN_ABSENT in installer"
    assert_not_contains "$MOCK_LOG" "BLOCKED"
}

test_prompted_token_and_https_clone
test_invalid_token_stops_early
test_repository_access_failure
test_unexpected_repository_identity
test_existing_destination
test_clone_failure
test_token_not_passed_to_installer
test_environment_token
test_installer_failure_propagates

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
