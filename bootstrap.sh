#!/usr/bin/env bash
# Bootstrap the host, authenticate to GitHub, install Docker, and clone the private app.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly REPOSITORY="plexosoft/self-hosted-ai-assistant"
readonly GH_KEYRING_URL="https://cli.github.com/packages/githubcli-archive-keyring.gpg"
readonly GH_REPO_URL="https://cli.github.com/packages"
readonly DOCKER_GPG_URL="https://download.docker.com/linux/ubuntu/gpg"
readonly DOCKER_REPO_URL="https://download.docker.com/linux/ubuntu"
INSTALL_USER="$(id -un)"
DOCKER_GROUP_ACTIVE=0

log() { printf '[bootstrap] %s\n' "$*"; }
fail() { printf '[bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

confirm() {
    local prompt="$1" reply
    [[ -t 0 ]] || fail "Interactive confirmation is required; run this script from a terminal."
    read -r -p "$prompt [y/N] " reply
    [[ "$reply" =~ ^([yY]|[yY][eE][sS])$ ]]
}

require_ubuntu() {
    [[ -r /etc/os-release ]] || fail "Cannot identify this operating system."
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || fail "Automatic host setup supports Ubuntu only. Detected: ${PRETTY_NAME:-unknown}."
    command_exists apt-get || fail "apt-get is unavailable."
    command_exists dpkg || fail "dpkg is unavailable."
    command_exists sudo || fail "sudo is required for host package installation."
    [[ "${EUID:-$(id -u)}" -ne 0 ]] || fail "Do not run this bootstrap as root. Run it as your normal user."
    [[ -n "${SUDO_USER:-}" ]] || true
}

install_base_tools() {
    local missing=() package
    for package in ca-certificates curl git; do
        dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed' || missing+=("$package")
    done
    ((${#missing[@]} == 0)) && { log "Base tools are already installed."; return; }

    log "Missing base packages: ${missing[*]}"
    log "This step updates APT metadata and installs the missing packages."
    confirm "Install required base packages?" || fail "Installation cancelled by user."
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl git
}

install_github_cli() {
    command_exists gh && { log "GitHub CLI is already installed: $(gh --version | head -n 1)"; return; }

    log "GitHub CLI (gh) is missing. The installer will add GitHub's official APT repository and install gh."
    confirm "Install GitHub CLI from its official APT repository?" || fail "Installation cancelled by user."

    local tmp keyring_tmp arch
    tmp="$(mktemp -d)"
    trap 'rm -rf "${tmp:-}"' RETURN
    keyring_tmp="$tmp/githubcli-archive-keyring.gpg"
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        "$GH_KEYRING_URL" --output "$keyring_tmp" || fail "Could not download the GitHub CLI APT keyring."

    arch="$(dpkg --print-architecture)"
    sudo install -d -m 0755 /etc/apt/keyrings
    sudo install -m 0644 "$keyring_tmp" /etc/apt/keyrings/githubcli-archive-keyring.gpg
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] %s stable main\n' \
        "$arch" "$GH_REPO_URL" | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    sudo chmod 0644 /etc/apt/sources.list.d/github-cli.list
    sudo apt-get update
    sudo apt-get install -y gh
    command_exists gh || fail "GitHub CLI installation did not provide the gh command."
    log "Installed $(gh --version | head -n 1)."
}

ensure_docker_group_access() {
    if ! getent group docker >/dev/null; then
        sudo groupadd docker
    fi

    if id -nG | tr ' ' '\n' | grep -qx docker; then
        DOCKER_GROUP_ACTIVE=1
        return
    fi

    sudo usermod -aG docker "$INSTALL_USER"
    DOCKER_GROUP_ACTIVE=0
    log "Added ${INSTALL_USER} to the docker group."
    log "Docker group access normally takes effect at the next login; bootstrap will use 'sg docker' for this installation run."
}

install_docker() {
    if command_exists docker && docker compose version >/dev/null 2>&1; then
        log "Docker and Docker Compose are already installed."
        ensure_docker_group_access
        return
    fi

    # Don't silently replace a distro-provided or third-party Docker installation.
    local conflicts=() package
    for package in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
        if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then
            conflicts+=("$package")
        fi
    done
    ((${#conflicts[@]} == 0)) || fail "Potentially conflicting packages are installed: ${conflicts[*]}. Review Docker's official migration guidance before replacing them; bootstrap will not remove packages automatically."

    [[ "${ID:-}" == "ubuntu" ]] || fail "Docker installation is supported only on Ubuntu."
    local codename arch tmp
    codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    [[ -n "$codename" ]] || fail "Could not determine the Ubuntu codename."
    arch="$(dpkg --print-architecture)"
    log "Docker Engine and the Compose plugin are missing or incomplete."
    log "The installer will add Docker's official APT repository for Ubuntu ${codename} (${arch}) and install Docker Engine."
    log "The Docker group grants root-equivalent control of this machine to its members."
    confirm "Install Docker Engine and configure access for the current user?" || fail "Installation cancelled by user."

    tmp="$(mktemp -d)"
    trap 'rm -rf "${tmp:-}"' RETURN
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        "$DOCKER_GPG_URL" --output "$tmp/docker.asc" || fail "Could not download Docker's official APT signing key."
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo install -m 0644 "$tmp/docker.asc" /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    printf 'Types: deb\nURIs: %s\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/docker.asc\n' \
        "$DOCKER_REPO_URL" "$codename" "$arch" | sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null

    sudo chmod 0644 /etc/apt/sources.list.d/docker.sources
    sudo apt-get update
    local docker_candidate
    docker_candidate="$(apt-cache policy docker-ce | sed -n 's/^[[:space:]]*Candidate: //p')"
    [[ -n "$docker_candidate" && "$docker_candidate" != "(none)" ]] ||
        fail "Docker's repository has no installable docker-ce candidate for ${codename}/${arch}. No Docker packages were installed. Check the official support matrix and try again later."
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo systemctl enable --now docker

    ensure_docker_group_access

    sudo docker version >/dev/null || fail "Docker was installed but the daemon is not responding."
    sudo docker compose version >/dev/null || fail "Docker Compose plugin is not available after installation."
    log "Docker Engine and Docker Compose are installed."
}

authenticate_github() {
    log "Checking GitHub CLI authentication..."

    if [[ -n "${GH_TOKEN:-}" ]]; then
        log "Using the GitHub token supplied through GH_TOKEN."
    elif gh auth status --hostname github.com >/dev/null 2>&1; then
        log "Existing GitHub CLI authentication is available."
    else
        log "No valid GitHub.com authentication was found."
        printf 'Choose a GitHub authentication method:\n'
        printf '  1) Fine-grained personal access token (PAT)\n'
        printf '  2) Browser/device authentication\n'

        local auth_choice
        read -r -p "Select [1/2]: " auth_choice

        case "$auth_choice" in
            1)
                local entered_token
                read -rsp "GitHub fine-grained token: " entered_token
                printf '\n'
                [[ -n "$entered_token" ]] || fail "No token supplied."
                export GH_TOKEN="$entered_token"
                unset entered_token
                ;;
            2)
                gh auth login --hostname github.com --git-protocol https --web
                ;;
            *)
                fail "Invalid authentication choice."
                ;;
        esac
    fi

    gh auth status --hostname github.com >/dev/null 2>&1 ||
        fail "GitHub authentication failed. Check the token, repository access, and any organization approval requirements."
}

main() {
    if [[ -n "${CODESPACES:-}" || -n "${CODESPACE_NAME:-}" ]]; then
        fail "This bootstrap installs software on a host system and cannot run inside GitHub Codespaces."
    fi

    if [[ -f /.dockerenv ]] ||
       grep -qaE '(docker|containerd|kubepods|podman|lxc)' /proc/1/cgroup 2>/dev/null; then
        fail "Container environments are not supported. Run this bootstrap directly on the Ubuntu host."
    fi

    require_ubuntu
    install_base_tools
    install_github_cli

    authenticate_github

    log "Verifying access to ${REPOSITORY} before installing Docker or cloning source..."
    local accessible_repository
    if ! accessible_repository="$(gh repo view "$REPOSITORY" --json nameWithOwner --jq .nameWithOwner 2>/dev/null)"; then
        fail "The authenticated GitHub account cannot access ${REPOSITORY}, or GitHub is unavailable. Check repository permissions and try again. No Docker installation was attempted."
    fi
    [[ "$accessible_repository" == "$REPOSITORY" ]] || fail "GitHub returned an unexpected repository identity; refusing to continue."

    install_docker

    local destination
    destination="${BOOTSTRAP_DEST:-${HOME}/self-hosted-ai-assistant}"
    if [[ "$destination" == '~/'* ]]; then
        destination="${HOME}/${destination#~/}"
    fi
    [[ ! -e "$destination" ]] || fail "Destination already exists: $destination. Choose another path with BOOTSTRAP_DEST=/path/to/checkout. Nothing was overwritten."
    mkdir -p "$(dirname "$destination")"

    log "Cloning the private repository..."
    gh repo clone "$REPOSITORY" "$destination"
    [[ -d "$destination/.git" ]] || fail "Clone did not create a Git checkout at $destination."
    [[ -x "$destination/scripts/install.sh" ]] || fail "The repository was cloned, but scripts/install.sh is missing or not executable. Review the checkout: $destination"

    log "Repository cloned to: $destination"

    # Do not pass the supplied token into the application installer.
    unset GH_TOKEN || true

    if confirm "Run the repository installer now? It will pull images, start services, and may download AI models."; then
        if [[ "$DOCKER_GROUP_ACTIVE" -eq 1 ]]; then
            (cd "$destination" && ./scripts/install.sh)
        else
            # Refresh supplementary group membership for this child process only.
            local quoted_destination
            printf -v quoted_destination '%q' "$destination"
            sg docker -c "cd ${quoted_destination} && exec ./scripts/install.sh"
        fi
    else
        log "Installation skipped. To install later, run: cd '$destination' && ./scripts/install.sh"
    fi
}

main "$@"
