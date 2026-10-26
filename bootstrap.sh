#!/usr/bin/env bash
# Authenticate with GitHub before cloning the private self-hosted AI assistant repo.
# This script is intentionally distributed separately from the private repository.
set -Eeuo pipefail
IFS=$'\n\t'

readonly REPOSITORY="plexosoft/self-hosted-ai-assistant"
readonly GH_KEYRING_URL="https://cli.github.com/packages/githubcli-archive-keyring.gpg"
readonly GH_KEYRING_SHA256="6084d5d7bd8e288441e0e94fc6275570895da18e6751f70f057485dc2d1a811b"
readonly GH_REPO_URL="https://cli.github.com/packages"

log() { printf '[bootstrap] %s\n' "$*"; }
fail() { printf '[bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }

confirm() {
    local prompt="$1" reply
    [[ -t 0 ]] || fail "Interactive confirmation is required; run this script from a terminal."
    read -r -p "$prompt [y/N] " reply
    [[ "$reply" =~ ^([yY]|[yY][eE][sS])$ ]]
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

install_gh_ubuntu() {
    [[ -r /etc/os-release ]] || fail "Cannot identify this operating system. Install GitHub CLI manually: https://github.com/cli/cli/blob/trunk/docs/install_linux.md"
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || fail "Automatic GitHub CLI installation is supported only on Ubuntu. Install it manually: https://github.com/cli/cli/blob/trunk/docs/install_linux.md"
    command_exists apt-get || fail "apt-get is not available; install GitHub CLI manually."
    command_exists dpkg || fail "dpkg is not available; install GitHub CLI manually."
    command_exists curl || fail "curl is required to install GitHub CLI. Install curl and rerun this script."
    command_exists sha256sum || fail "sha256sum is required to verify the GitHub CLI keyring."
    command_exists sudo || fail "sudo is required to install GitHub CLI. Install it manually or configure sudo."

    log "GitHub CLI (gh) is missing. The installer will add GitHub's official APT repository and install gh."
    log "This changes system APT configuration and installs a system package."
    confirm "Continue with GitHub CLI installation?" || fail "Installation cancelled by user."

    local tmp keyring_tmp arch
    tmp="$(mktemp -d)"
    trap 'rm -rf "${tmp:-}"' EXIT
    keyring_tmp="$tmp/githubcli-archive-keyring.gpg"

    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        "$GH_KEYRING_URL" --output "$keyring_tmp" || fail "Could not download the official GitHub CLI APT keyring."
    printf '%s  %s\n' "$GH_KEYRING_SHA256" "$keyring_tmp" | sha256sum --check --status \
        || fail "GitHub CLI keyring checksum verification failed; refusing to install."

    arch="$(dpkg --print-architecture)"
    sudo install -d -m 0755 /etc/apt/keyrings
    sudo install -m 0644 "$keyring_tmp" /etc/apt/keyrings/githubcli-archive-keyring.gpg
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] %s stable main\n' \
        "$arch" "$GH_REPO_URL" | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    sudo apt-get update
    sudo apt-get install -y gh
    command_exists gh || fail "GitHub CLI installation did not provide the gh command."
    log "Installed $(gh --version | head -n 1)."
}

main() {
    [[ "${EUID:-$(id -u)}" -ne 0 ]] || fail "Do not run this bootstrap as root. Run it as your normal user; sudo will be requested only when needed."
    command_exists git || fail "Git is required but is not installed. Install Git for your operating system, then rerun this script. On Ubuntu: sudo apt-get update && sudo apt-get install -y git"
    command_exists curl || fail "curl is required. Install curl, then rerun this script."

    if ! command_exists gh; then
        install_gh_ubuntu
    fi

    local destination
    destination="${BOOTSTRAP_DEST:-${HOME}/self-hosted-ai-assistant}"
    # Expand a leading ~/ safely without evaluating arbitrary shell input.
    if [[ "$destination" == '~/'* ]]; then
        destination="${HOME}/${destination#~/}"
    fi

    log "Checking GitHub CLI authentication..."
    if ! gh auth status --hostname github.com >/dev/null 2>&1; then
        log "No valid GitHub.com authentication was found. Starting interactive login."
        gh auth login --hostname github.com --git-protocol https --web
    fi
    gh auth status --hostname github.com >/dev/null 2>&1 \
        || fail "GitHub authentication is still unavailable. Run 'gh auth login' and retry."

    log "Verifying access to ${REPOSITORY} before downloading its source..."
    local accessible_repository
    if ! accessible_repository="$(gh repo view "$REPOSITORY" --json nameWithOwner --jq .nameWithOwner 2>/dev/null)"; then
        fail "The authenticated GitHub account cannot access ${REPOSITORY}, or GitHub is unavailable. Check repository permissions and try again."
    fi
    [[ "$accessible_repository" == "$REPOSITORY" ]] \
        || fail "GitHub returned an unexpected repository identity; refusing to clone."

    [[ ! -e "$destination" ]] \
        || fail "Destination already exists: $destination. Choose another path with BOOTSTRAP_DEST=/path/to/checkout. Nothing was overwritten."
    mkdir -p "$(dirname "$destination")"

    log "Authentication and repository access verified. Cloning now..."
    gh repo clone "$REPOSITORY" "$destination"

    [[ -d "$destination/.git" ]] || fail "Clone did not create a Git checkout at $destination."
    [[ -x "$destination/scripts/install.sh" ]] || fail "The repository was cloned, but scripts/install.sh is missing or not executable. Review the checkout before continuing: $destination"

    log "Repository cloned to: $destination"
    if confirm "Run the repository installer now? This will start the local AI stack and may download container images and AI models."; then
        (cd "$destination" && ./scripts/install.sh)
    else
        log "Installation skipped. To install later, run: cd '$destination' && ./scripts/install.sh"
    fi
}

main "$@"
