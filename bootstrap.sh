#!/usr/bin/env bash
# Bootstrap the host, authenticate to GitHub, install Docker, and clone the private app.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly REPOSITORY="plexosoft/self-hosted-ai-assistant"
readonly GH_KEYRING_URL="https://cli.github.com/packages/githubcli-archive-keyring.gpg"
readonly GH_KEYRING_SHA256="6084d5d7bd8e288441e0e94fc6275570895da18e6751f70f057485dc2d1a811b"
readonly GH_REPO_URL="https://cli.github.com/packages"
readonly DOCKER_GPG_URL="https://download.docker.com/linux/ubuntu/gpg"
readonly DOCKER_REPO_URL="https://download.docker.com/linux/ubuntu"
INSTALL_USER="$(id -un)"
DOCKER_GROUP_ACTIVE=0
RELEASE_VERSION=""
INSTANCE="production"

log() { printf '[bootstrap] %s\n' "$*"; }
fail() { printf '[bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

usage() {
    cat <<'USAGE'
Usage: bootstrap.sh [--instance production|sandbox] [--version TAG] [--help]

Options:
  --instance NAME  Select production or sandbox (default: production).
  --version TAG  Install a specific published stable GitHub Release.
                 Defaults to the latest published stable release.
  --help         Show this help message.
USAGE
}

parse_arguments() {
    while (($#)); do
        case "$1" in
            --instance)
                (($# >= 2)) || fail "--instance requires production or sandbox."
                INSTANCE="$2"
                [[ "$INSTANCE" == "production" || "$INSTANCE" == "sandbox" ]] ||
                    fail "Invalid instance: ${INSTANCE}. Choose production or sandbox."
                shift 2
                ;;
            --instance=*)
                INSTANCE="${1#*=}"
                [[ "$INSTANCE" == "production" || "$INSTANCE" == "sandbox" ]] ||
                    fail "Invalid instance: ${INSTANCE}. Choose production or sandbox."
                shift
                ;;
            --version)
                (($# >= 2)) || fail "--version requires a release tag, for example v1.1.0."
                [[ -n "$2" ]] || fail "Release version cannot be empty."
                RELEASE_VERSION="$2"
                shift 2
                ;;
            --version=*)
                RELEASE_VERSION="${1#*=}"
                [[ -n "$RELEASE_VERSION" ]] || fail "Release version cannot be empty."
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                fail "Unknown argument: $1. Use --help to see supported options."
                ;;
        esac
    done
}

validate_release_tag_format() {
    local tag="$1"
    [[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
        fail "Invalid stable release tag format: ${tag}. Expected vMAJOR.MINOR.PATCH."
}

select_release_tag() {
    local release_data tag draft prerelease

    if [[ -n "$RELEASE_VERSION" ]]; then
        validate_release_tag_format "$RELEASE_VERSION"
        printf '[bootstrap] Validating requested stable release: %s\n' "$RELEASE_VERSION" >&2
        if ! release_data="$(gh api "repos/${REPOSITORY}/releases/tags/${RELEASE_VERSION}" \
            --jq '[.tag_name, (.draft | tostring), (.prerelease | tostring)] | @tsv' 2>/dev/null)"; then
            fail "Release ${RELEASE_VERSION} was not found or is not accessible in ${REPOSITORY}."
        fi
        IFS=$'\t' read -r tag draft prerelease <<< "$release_data"
        [[ "$tag" == "$RELEASE_VERSION" ]] || fail "GitHub returned a different tag than requested."
        [[ "$draft" == false ]] || fail "Release ${RELEASE_VERSION} is a draft and cannot be installed."
        [[ "$prerelease" == false ]] || fail "Release ${RELEASE_VERSION} is a prerelease and cannot be installed."
    else
        printf '[bootstrap] Resolving the latest published stable release...\n' >&2
        if ! tag="$(gh api "repos/${REPOSITORY}/releases/latest" --jq .tag_name 2>/dev/null)"; then
            fail "No published stable release is available for ${REPOSITORY}. Publish a stable GitHub Release first."
        fi
        [[ -n "$tag" ]] || fail "GitHub returned an empty latest release tag."
        validate_release_tag_format "$tag"
    fi

    printf '%s\n' "$tag"
}

resolve_destination() {
    local default_destination

    if [[ "$INSTANCE" == "sandbox" ]]; then
        default_destination="${HOME}/self-hosted-ai-assistant-sandbox"
    else
        default_destination="${HOME}/self-hosted-ai-assistant"
    fi

    DESTINATION="${BOOTSTRAP_DEST:-$default_destination}"
    if [[ "$DESTINATION" == '~/'* ]]; then
        DESTINATION="${HOME}/${DESTINATION#~/}"
    fi

    [[ ! -e "$DESTINATION" && ! -L "$DESTINATION" ]] ||
        fail "Destination already exists: $DESTINATION. Choose another path with BOOTSTRAP_DEST=/path/to/checkout. Nothing was overwritten."
}

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
    printf '%s  %s\n' "$GH_KEYRING_SHA256" "$keyring_tmp" | sha256sum --check --status ||
        fail "The GitHub CLI APT keyring checksum does not match the pinned official checksum. Refusing to install it."

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
    log "GitHub authentication is required for ${REPOSITORY}."

    # Prefer an explicitly supplied token; otherwise prompt securely even if
    # gh has a saved login. A saved login may use SSH or lack repository access.
    if [[ -z "${GH_TOKEN:-}" ]]; then
        [[ -t 0 ]] || fail "A fine-grained GitHub token is required. Run this script interactively or provide GH_TOKEN in the environment."
        local entered_token
        printf 'Create a fine-grained PAT with Contents: Read-only access to %s.\n' "$REPOSITORY"
        read -rsp "GitHub fine-grained token: " entered_token
        printf '\n'
        [[ -n "$entered_token" ]] || fail "No token supplied."
        export GH_TOKEN="$entered_token"
        unset entered_token
    else
        log "Using the GitHub token supplied through GH_TOKEN."
    fi

    gh auth status --hostname github.com >/dev/null 2>&1 ||
        fail "GitHub token validation failed. Check that the token is valid, has access to ${REPOSITORY}, and has any required organization approval."
}

main() {
    parse_arguments "$@"
    if [[ -n "$RELEASE_VERSION" ]]; then
        validate_release_tag_format "$RELEASE_VERSION"
    fi
    resolve_destination

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

    local release_tag
    release_tag="$(select_release_tag)"
    log "Selected stable release: ${release_tag}"

    install_docker

    local destination="$DESTINATION"
    mkdir -p "$(dirname "$destination")"

    log "Cloning the private repository over HTTPS..."

    # Do not use `gh repo clone` here: its configured git_protocol may be SSH.
    # Configure the credential helper for this Git invocation only.
    git -c credential.helper= -c 'credential.helper=!gh auth git-credential' \
        clone --no-checkout \
        "https://github.com/${REPOSITORY}.git" "$destination"

    [[ -d "$destination/.git" ]] ||
        fail "Clone did not create a Git checkout at $destination."

    log "Fetching the selected release tag..."

    git -c credential.helper= \
        -c 'credential.helper=!gh auth git-credential' \
        -C "$destination" fetch --force origin \
        "refs/tags/${release_tag}:refs/tags/${release_tag}" ||
        fail "Could not fetch release tag ${release_tag}."

    local release_commit
    release_commit="$(git -C "$destination" rev-parse "${release_tag}^{commit}")" ||
        fail "Could not resolve release tag ${release_tag} to a commit."

    [[ "$release_commit" =~ ^[0-9a-f]{40}$ ]] ||
        fail "Resolved release tag does not point to a valid commit."

    log "Checking out release ${release_tag} at ${release_commit}..."

    git -C "$destination" checkout --detach "$release_commit" ||
        fail "Could not check out release commit ${release_commit}."

    local checked_out_tag
    if ! checked_out_tag="$(git -C "$destination" describe --tags --exact-match HEAD 2>/dev/null)"; then
        fail "The cloned checkout is not positioned at an exact Git tag. Refusing to install."
    fi
    [[ "$checked_out_tag" == "$release_tag" ]] ||
        fail "The cloned tag (${checked_out_tag}) does not match the selected release (${release_tag})."
    # Verify that the main installer exists and is readable.
    [[ -f "$destination/scripts/install.sh" && -r "$destination/scripts/install.sh" ]] ||
        fail "The repository was cloned, but scripts/install.sh is missing or unreadable. Review the checkout: $destination"

    # Configure a repository-local shortcut for updating to the latest stable release.
    log "Configuring Git release update shortcut..."

    git -C "$destination" config --local alias.uprelease \
        '!f() {
            gh auth status --hostname github.com >/dev/null 2>&1 || {
                printf "GitHub CLI is not authenticated. Run: gh auth login\n" >&2
                exit 1
            }

            tag="$(gh api repos/plexosoft/self-hosted-ai-assistant/releases/latest --jq .tag_name)" || exit 1

            git -c credential.helper= \
                -c "credential.helper=!gh auth git-credential" \
                fetch origin "+refs/tags/${tag}:refs/tags/${tag}" &&
            git switch --detach "$tag"
        }; f' ||
        fail "Could not configure the release update shortcut."

    log "Git release update shortcut configured: git uprelease"

    # Detect shell scripts that need executable permissions.
    local script permissions_need_repair=0

    for script in "$destination"/scripts/*.sh; do
        [[ -f "$script" ]] || continue

        if [[ ! -x "$script" ]]; then
            permissions_need_repair=1
            break
        fi
    done

    # Repair permissions without making the release checkout appear dirty.
    if [[ "$permissions_need_repair" -eq 1 ]]; then
        git -C "$destination" config core.filemode false ||
            fail "Could not configure Git file mode handling."

        for script in "$destination"/scripts/*.sh; do
            [[ -f "$script" ]] || continue

            chmod u+x "$script" ||
                fail "Could not make installation script executable: $script"
        done

        log "Corrected executable permissions for application scripts."
    fi

    [[ -x "$destination/scripts/install.sh" ]] ||
        fail "scripts/install.sh is still not executable: $destination/scripts/install.sh"

    log "Repository release ${release_tag} cloned to: $destination"

    # A PAT entered for this run is kept only in this process environment.
    # Clear it before launching the application installer. Do not log out a
    # pre-existing gh account or alter the user's stored authentication.
    unset GH_TOKEN || true

    if confirm "Install release ${release_tag} now? It will pull images, start services, and may download AI models."; then
        if [[ "$DOCKER_GROUP_ACTIVE" -eq 1 ]]; then
            (cd "$destination" && ./scripts/install.sh --instance "$INSTANCE")
        else
            # Refresh supplementary group membership for this child process only.
            local quoted_destination
            printf -v quoted_destination '%q' "$destination"
            sg docker -c "cd ${quoted_destination} && exec ./scripts/install.sh --instance ${INSTANCE}"
        fi
    else
        log "Installation skipped. To install later, run: cd '$destination' && ./scripts/install.sh --instance $INSTANCE"
    fi
}

main "$@"