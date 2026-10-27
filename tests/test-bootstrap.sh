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
    export MOCK_AUTH_LOGIN_STATUS=0
    export MOCK_REPO_ACCESS=yes
    export MOCK_REPO_IDENTITY=plexosoft/self-hosted-ai-assistant
    export MOCK_CLONE_STATUS=0
    export MOCK_LOGOUT_STATUS=0
    export MOCK_STORED_USER=test-user
    export MOCK_DOCKER_COMPOSE_STATUS=0
    export MOCK_DOCKER_GROUP_ACTIVE=yes
    export MOCK_INSTALLER_STATUS=0

    make_mocks
}

make_mocks() {
    cat > "$MOCK_BIN/gh" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'gh %s\n' "$*" >> "$MOCK_LOG"

if [[ "${1:-}" == "--version" ]]; then
    printf 'gh version 2.0.0 (mock)\n'
    exit 0
fi

case "${1:-} ${2:-}" in
    "auth status")
        exit "${MOCK_AUTH_STATUS:-0}"
        ;;
    "auth login")
        exit "${MOCK_AUTH_LOGIN_STATUS:-0}"
        ;;
    "auth logout")
        exit "${MOCK_LOGOUT_STATUS:-0}"
        ;;
    "api user")
        if [[ -n "${MOCK_STORED_USER:-}" ]]; then
            printf '%s\n' "$MOCK_STORED_USER"
            exit 0
        fi
        exit 1
        ;;
    "repo view")
        if [[ "${MOCK_REPO_ACCESS:-yes}" == yes ]]; then
            printf '%s\n' "${MOCK_REPO_IDENTITY:-plexosoft/self-hosted-ai-assistant}"
            exit 0
        fi
        exit 1
        ;;
    "repo clone")
        if [[ "${MOCK_CLONE_STATUS:-0}" -ne 0 ]]; then
            exit "$MOCK_CLONE_STATUS"
        fi
        if [[ "${3:-}" != "plexosoft/self-hosted-ai-assistant" ]]; then
            printf 'Unexpected repository: %s\n' "${3:-<missing>}" >&2
            exit 91
        fi
        if [[ "${4:-}" != "$BOOTSTRAP_DEST" ]]; then
            printf 'Unexpected clone destination: %s\n' "${4:-<missing>}" >&2
            exit 92
        fi

        mkdir -p "$4/.git" "$4/scripts"
        cat > "$4/scripts/install.sh" <<'INSTALL'
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
        chmod +x "$4/scripts/install.sh"
        printf 'mock clone completed\n' >> "$MOCK_LOG"
        ;;
    *)
        printf 'Unexpected gh invocation: %s\n' "$*" >&2
        exit 2
        ;;
esac
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

test_clone_and_skip_install() {
    echo "== Existing gh session: clone succeeds; app install is declined =="
    setup clone-skip

    local status=0
    run_bootstrap $'n\n' || status=$?

    assert_success "bootstrap succeeds after declining application installation" "$status"
    assert_contains "$MOCK_LOG" "gh repo view plexosoft/self-hosted-ai-assistant --json nameWithOwner --jq .nameWithOwner"
    assert_contains "$MOCK_LOG" "gh repo clone plexosoft/self-hosted-ai-assistant $BOOTSTRAP_DEST"
    assert_contains "$MOCK_LOG" "gh api user --jq .login"
    assert_contains "$MOCK_LOG" "gh auth logout --hostname github.com --user test-user"
    assert_contains "$MOCK_LOG" "mock clone completed"
    assert_not_contains "$MOCK_LOG" "installer ran"
    assert_not_contains "$MOCK_LOG" "BLOCKED"
    assert_contains "$CASE_DIR/output.log" "Repository cloned to:"
    assert_contains "$CASE_DIR/output.log" "Installation skipped"

    if [[ -d "$BOOTSTRAP_DEST/.git" && -x "$BOOTSTRAP_DEST/scripts/install.sh" ]]; then
        printf '  PASS: checkout exists and installer is executable\n'
        PASS=$((PASS + 1))
    else
        printf '  FAIL: checkout is missing or incomplete\n'
        FAIL=$((FAIL + 1))
    fi
}

test_token_is_not_passed_to_installer() {
    echo "== GH_TOKEN is not inherited by the application installer =="
    setup token-cleanup
    export GH_TOKEN="test-token-do-not-print"
    export MOCK_STORED_USER=""

    local status=0
    run_bootstrap $'y\n' || status=$?
    unset GH_TOKEN

    assert_success "bootstrap and mock installer complete successfully" "$status"
    assert_contains "$MOCK_LOG" "installer ran"
    assert_contains "$MOCK_LOG" "GH_TOKEN_ABSENT in installer"
    assert_not_contains "$MOCK_LOG" "GH_TOKEN_PRESENT in installer"
    assert_contains "$CASE_DIR/output.log" "No stored GitHub CLI session remains"
    assert_not_contains "$MOCK_LOG" "BLOCKED"
}

test_existing_destination() {
    echo "== Existing destination is not overwritten =="
    setup existing-destination
    mkdir -p "$BOOTSTRAP_DEST"
    printf 'keep this file\n' > "$BOOTSTRAP_DEST/keep.txt"

    local status=0
    run_bootstrap "" || status=$?

    assert_failure "bootstrap rejects an existing destination" "$status"
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
    echo "== Failed browser authentication prevents cloning =="
    setup authentication-failure
    export MOCK_AUTH_STATUS=1
    export MOCK_AUTH_LOGIN_STATUS=1

    local status=0
    run_bootstrap $'2\n' || status=$?

    assert_failure "bootstrap fails when authentication fails" "$status"
    assert_contains "$MOCK_LOG" "gh auth login --hostname github.com --git-protocol https --web"
    assert_not_contains "$MOCK_LOG" "gh repo view"
    assert_not_contains "$MOCK_LOG" "gh repo clone"
    assert_not_contains "$MOCK_LOG" "BLOCKED"
}

test_repository_access_failure() {
    echo "== Repository access failure prevents Docker setup and cloning =="
    setup repository-access-failure
    export MOCK_REPO_ACCESS=no

    local status=0
    run_bootstrap "" || status=$?

    assert_failure "bootstrap fails when repository access is denied" "$status"
    assert_contains "$CASE_DIR/output.log" "cannot access"
    assert_not_contains "$MOCK_LOG" "docker compose version"
    assert_not_contains "$MOCK_LOG" "gh repo clone"
    assert_not_contains "$MOCK_LOG" "BLOCKED"
}

test_unexpected_repository_identity() {
    echo "== Unexpected repository identity stops installation =="
    setup unexpected-repository
    export MOCK_REPO_IDENTITY="someone-else/different-repository"

    local status=0
    run_bootstrap "" || status=$?

    assert_failure "bootstrap rejects an unexpected repository identity" "$status"
    assert_contains "$CASE_DIR/output.log" "unexpected repository identity"
    assert_not_contains "$MOCK_LOG" "docker compose version"
    assert_not_contains "$MOCK_LOG" "gh repo clone"
    assert_not_contains "$MOCK_LOG" "BLOCKED"
}

test_docker_declined() {
    echo "== Missing Docker: declining installation stops before cloning =="
    setup docker-declined
    export MOCK_DOCKER_COMPOSE_STATUS=1

    local status=0
    run_bootstrap $'n\n' || status=$?

    assert_failure "bootstrap stops when Docker installation is declined" "$status"
    assert_contains "$CASE_DIR/output.log" "Installation cancelled by user"
    assert_not_contains "$MOCK_LOG" "gh repo clone"
    assert_not_contains "$MOCK_LOG" "BLOCKED"
}

test_clone_failure() {
    echo "== Clone failure is reported and installer is not run =="
    setup clone-failure
    export MOCK_CLONE_STATUS=1

    local status=0
    run_bootstrap $'y\n' || status=$?

    assert_failure "bootstrap fails when cloning fails" "$status"
    assert_contains "$MOCK_LOG" "gh repo clone plexosoft/self-hosted-ai-assistant $BOOTSTRAP_DEST"
    assert_not_contains "$MOCK_LOG" "installer ran"
    assert_not_contains "$CASE_DIR/output.log" "Repository cloned to:"
    assert_not_contains "$MOCK_LOG" "BLOCKED"

    if [[ ! -e "$BOOTSTRAP_DEST" ]]; then
        printf '  PASS: failed clone did not create a checkout\n'
        PASS=$((PASS + 1))
    else
        printf '  FAIL: failed clone unexpectedly created a checkout\n'
        FAIL=$((FAIL + 1))
    fi
}

test_logout_failure_is_reported() {
    echo "== Stored GitHub logout failure is reported =="
    setup logout-failure
    export MOCK_LOGOUT_STATUS=1

    local status=0
    run_bootstrap $'n\n' || status=$?

    assert_success "logout failure does not prevent the declined-install path from finishing" "$status"
    assert_contains "$CASE_DIR/output.log" "WARNING: Could not remove the stored GitHub CLI session"
    assert_not_contains "$MOCK_LOG" "BLOCKED"
}

test_installer_failure_propagates() {
    echo "== Application installer failure is propagated =="
    setup installer-failure
    export MOCK_INSTALLER_STATUS=7

    local status=0
    run_bootstrap $'y\n' || status=$?

    assert_failure "bootstrap reports an application installer failure" "$status"
    assert_contains "$MOCK_LOG" "installer ran"
    assert_not_contains "$MOCK_LOG" "BLOCKED"
}

test_clone_and_skip_install
test_token_is_not_passed_to_installer
test_existing_destination
test_authentication_failure
test_repository_access_failure
test_unexpected_repository_identity
test_docker_declined
test_clone_failure
test_logout_failure_is_reported
test_installer_failure_propagates

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
