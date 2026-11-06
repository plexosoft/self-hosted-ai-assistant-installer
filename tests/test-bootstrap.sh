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

    export MOCK_LATEST_TAG=v1.2.3
    export MOCK_STABLE_TAG=v1.1.0
    export MOCK_CLONE_TAG="$MOCK_LATEST_TAG"

    export MOCK_LATEST_RELEASE_STATUS=0
    export MOCK_RELEASE_LOOKUP_STATUS=0
    export MOCK_RELEASE_DRAFT=false
    export MOCK_RELEASE_PRERELEASE=false

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
        exit 0
        ;;
    "repo view")
        if [[ "${MOCK_REPO_ACCESS:-yes}" == yes ]]; then
            printf '%s\n' "${MOCK_REPO_IDENTITY:-plexosoft/self-hosted-ai-assistant}"
            exit 0
        fi
        exit 1
        ;;
    "api repos/plexosoft/self-hosted-ai-assistant/releases/latest")
        if [[ "${MOCK_LATEST_RELEASE_STATUS:-0}" -ne 0 ]]; then
            exit "$MOCK_LATEST_RELEASE_STATUS"
        fi
        printf '%s\n' "${MOCK_LATEST_TAG:-v1.2.3}"
        ;;
    "api repos/plexosoft/self-hosted-ai-assistant/releases/tags/${MOCK_STABLE_TAG}")
        if [[ "${MOCK_RELEASE_LOOKUP_STATUS:-0}" -ne 0 ]]; then
            exit "$MOCK_RELEASE_LOOKUP_STATUS"
        fi

        printf '%s\t%s\t%s\n' \
            "$MOCK_STABLE_TAG" \
            "${MOCK_RELEASE_DRAFT:-false}" \
            "${MOCK_RELEASE_PRERELEASE:-false}"
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

printf 'git %s\n' "$*" >> "$MOCK_LOG"

# Mock HTTPS clone using an explicitly fetched release tag.
args=("$@")
clone_index=-1

for i in "${!args[@]}"; do
    if [[ "${args[$i]}" == "clone" ]]; then
        clone_index="$i"
        break
    fi
done

if [[ "$clone_index" -ge 0 ]]; then
    [[ "${args[$((clone_index + 1))]:-}" == "--no-checkout" ]] || exit 93

    [[ "${args[$((clone_index + 2))]:-}" == \
        "https://github.com/plexosoft/self-hosted-ai-assistant.git" ]] || exit 94

    destination="${args[$((clone_index + 3))]:-}"

    [[ -n "$destination" && "$destination" == "$BOOTSTRAP_DEST" ]] || exit 95

    if [[ "${MOCK_CLONE_STATUS:-0}" -ne 0 ]]; then
        exit "$MOCK_CLONE_STATUS"
    fi

    mkdir -p "$destination/.git" "$destination/scripts"

    cat > "$destination/scripts/install.sh" <<'INSTALL'
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

    if [[ "${MOCK_INSTALLER_EXECUTABLE:-yes}" == yes ]]; then
        chmod +x "$destination/scripts/install.sh"
    else
        chmod 600 "$destination/scripts/install.sh"
    fi

    printf 'mock clone completed\n' >> "$MOCK_LOG"
    exit 0
fi

# Simulate fetching the selected release tag.
if [[ "${args[*]}" == *"fetch --force origin refs/tags/"* ]]; then
    exit 0
fi

# Simulate detached checkout of the resolved release commit.
if [[ "${args[*]}" == *"checkout --detach "* ]]; then
    exit 0
fi

# Simulate resolving an annotated or lightweight release tag to its commit.
if [[ "${args[*]}" == *"rev-parse"*"^{commit}"* ]]; then
    printf '%s\n' '0123456789abcdef0123456789abcdef01234567'
    exit 0
fi

# Simulate checking the exact release tag after checkout.
if [[ "${1:-}" == -C && "${3:-}" == describe ]]; then
    printf '%s\n' "${MOCK_CLONE_TAG:-v1.2.3}"
    exit 0
fi

# Mock repository-local Git configuration.
if [[ "${1:-}" == -C &&
      "${3:-}" == config &&
      "${4:-}" == --local &&
      "${5:-}" == alias.uprelease ]]; then
    [[ -n "${6:-}" ]] || exit 91
    printf 'release update alias configured\n' >> "$MOCK_LOG"
    exit 0
fi

# Mock Git file mode configuration.
if [[ "${1:-}" == -C &&
      "${3:-}" == config &&
      "${4:-}" == core.filemode &&
      "${5:-}" == false ]]; then
    exit 0
fi

printf 'Unexpected git invocation: %s\n' "$*" >&2
exit 92
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
        printf '\n--- Actual output from %s ---\n' "$file"
        cat "$file"
        printf '%s\n' '--- End actual output ---'
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
    local args="${2:-}"
    local output="$CASE_DIR/output.log"
    local status=0

    # A pseudo-terminal is needed because confirm() requires terminal stdin.
    # Delay feeding input until the child has started and disabled terminal echo
    # for the secret prompt. Otherwise script(1) can echo piped input before
    # read -s runs, causing a false secret-leak failure in output.log.
    {
        sleep 0.5
        printf '%s' "$input" 2>/dev/null || true
    } |
        script -qec "bash '$BOOTSTRAP' $args" /dev/null > "$output" 2>&1 ||
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
    assert_contains "$MOCK_LOG" "gh api repos/plexosoft/self-hosted-ai-assistant/releases/latest --jq .tag_name GH_TOKEN_PRESENT"
    assert_contains "$MOCK_LOG" "clone --no-checkout"
    assert_contains "$MOCK_LOG" \
        "https://github.com/plexosoft/self-hosted-ai-assistant.git"

    assert_contains "$MOCK_LOG" \
        "fetch --force origin refs/tags/$MOCK_LATEST_TAG:refs/tags/$MOCK_LATEST_TAG"

    assert_contains "$MOCK_LOG" \
        "rev-parse $MOCK_LATEST_TAG"

    assert_contains "$MOCK_LOG" \
        "checkout --detach 0123456789abcdef0123456789abcdef01234567"

    assert_contains "$MOCK_LOG" \
        "describe --tags --exact-match HEAD"

    assert_contains "$CASE_DIR/output.log" \
        "Selected stable release: $MOCK_LATEST_TAG"
    assert_contains "$MOCK_LOG" "mock clone completed"
    assert_contains "$MOCK_LOG" "release update alias configured"
    assert_contains "$CASE_DIR/output.log" \
    "Git release update shortcut configured: git uprelease"
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

test_non_executable_installer_permissions_repaired() {
    echo "== Non-executable installer permissions are repaired automatically =="
    setup non-executable-installer

    export MOCK_INSTALLER_EXECUTABLE=no

    local status=0
    run_bootstrap $'valid-token\nn\n' || status=$?

    assert_success "bootstrap repairs installer permissions and completes" "$status"
    assert_contains "$CASE_DIR/output.log" "Corrected executable permissions"
    assert_contains "$CASE_DIR/output.log" "Installation skipped"

    if [[ -x "$BOOTSTRAP_DEST/scripts/install.sh" ]]; then
        printf '  PASS: installer is executable after permission repair\n'
        PASS=$((PASS + 1))
    else
        printf '  FAIL: installer is not executable after permission repair\n'
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
    assert_contains "$MOCK_LOG" "clone --no-checkout"
    assert_contains "$MOCK_LOG" \
        "https://github.com/plexosoft/self-hosted-ai-assistant.git"
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

test_specific_stable_release_override() {
    echo "== Explicit version selects and validates the requested stable release =="
    setup version-override
    export MOCK_CLONE_TAG="$MOCK_STABLE_TAG"
    local status=0
    run_bootstrap $'valid-token\nn\n' "--version $MOCK_STABLE_TAG" || status=$?
    assert_success "bootstrap accepts a published stable version override" "$status"
    assert_contains "$MOCK_LOG" \
        "gh api repos/plexosoft/self-hosted-ai-assistant/releases/tags/$MOCK_STABLE_TAG"

    assert_contains "$MOCK_LOG" \
        "fetch --force origin refs/tags/$MOCK_STABLE_TAG:refs/tags/$MOCK_STABLE_TAG"

    assert_contains "$MOCK_LOG" \
        "rev-parse $MOCK_STABLE_TAG"

    assert_contains "$CASE_DIR/output.log" \
        "Selected stable release: $MOCK_STABLE_TAG"
}

test_prerelease_override_rejected() {
    echo "== Prereleases cannot be selected for production installation =="
    setup prerelease-override
    export MOCK_RELEASE_PRERELEASE=true
    local status=0
    run_bootstrap $'valid-token\n' "--version $MOCK_STABLE_TAG" || status=$?
    assert_failure "bootstrap rejects a prerelease version" "$status"
    assert_contains "$CASE_DIR/output.log" "is a prerelease"
    assert_not_contains "$MOCK_LOG" "docker compose version"
    assert_not_contains "$MOCK_LOG" "git -c"
}

test_draft_override_rejected() {
    echo "== Draft releases cannot be selected for production installation =="
    setup draft-override
    export MOCK_RELEASE_DRAFT=true
    local status=0
    run_bootstrap $'valid-token\n' "--version $MOCK_STABLE_TAG" || status=$?
    assert_failure "bootstrap rejects a draft release" "$status"
    assert_contains "$CASE_DIR/output.log" "is a draft"
    assert_not_contains "$MOCK_LOG" "docker compose version"
    assert_not_contains "$MOCK_LOG" "git -c"
}

test_missing_latest_release_rejected() {
    echo "== Missing stable release prevents cloning =="
    setup no-latest-release
    export MOCK_LATEST_RELEASE_STATUS=1
    local status=0
    run_bootstrap $'valid-token\n' || status=$?
    assert_failure "bootstrap fails when no stable release exists" "$status"
    assert_contains "$CASE_DIR/output.log" "No published stable release"
    assert_not_contains "$MOCK_LOG" "docker compose version"
    assert_not_contains "$MOCK_LOG" "git -c"
}

test_invalid_version_format_rejected() {
    echo "== Invalid version argument is rejected =="
    setup invalid-version
    local status=0
    run_bootstrap $'valid-token\n' "--version ../main" || status=$?
    assert_failure "bootstrap rejects an unsafe release tag" "$status"
    assert_contains "$CASE_DIR/output.log" "Invalid stable release tag format"
    assert_not_contains "$MOCK_LOG" "docker compose version"
    assert_not_contains "$MOCK_LOG" "git -c"
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
test_non_executable_installer_permissions_repaired
test_invalid_token_stops_early
test_repository_access_failure
test_unexpected_repository_identity
test_existing_destination
test_clone_failure
test_specific_stable_release_override
test_prerelease_override_rejected
test_draft_override_rejected
test_missing_latest_release_rejected
test_invalid_version_format_rejected
test_token_not_passed_to_installer
test_environment_token
test_installer_failure_propagates

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]