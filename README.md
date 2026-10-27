# Self Hosted AI Assistant Installer

Bootstrap installer for Plexosoft's Self Hosted AI Assistant.

This repository contains the public installation bootstrap. The application source code is maintained separately in a private repository.

## How It Works

The bootstrap prepares your environment and verifies that your GitHub account can access the private application repository before downloading its source code.

The installation process:

1. Checks that the system is a supported Ubuntu environment and that the required system tools are available.
2. Checks whether Git, `curl`, and other base tools are installed, offering to install missing dependencies when supported.
3. Checks whether GitHub CLI (`gh`) is installed and offers to install it if necessary.
4. Authenticates with GitHub using an existing CLI session, a personal access token, or an interactive browser login.
5. Verifies access to the private application repository before installing Docker.
6. Checks whether Docker and the Docker Compose plugin are available, offering to install Docker when necessary.
7. Clones the application into your chosen destination.
8. Attempts to clean up the GitHub authentication used by the bootstrap.
9. Asks whether to run the application installer.

The bootstrap does not contain the application source code or grant repository access by itself.

## Requirements

The bootstrap requires:

- Ubuntu.
- Bash.
- `apt-get` and `dpkg`.
- `sudo` access for system package installation.
- A GitHub account with permission to access the private application repository.

The bootstrap must run as a nonroot user. It refuses to run in GitHub Codespaces and detects common container environments that are not supported.

The bootstrap can install missing base tools, GitHub CLI, and Docker after requesting confirmation where applicable.

Docker installation requires a supported Ubuntu environment and the ability to configure system packages and services.

## Getting Access

The application repository is private. Before installation, make sure your GitHub account has been granted access to:

`plexosoft/self-hosted-ai-assistant`

Making this installer repository public does not make the application repository public or grant access to its contents.

If authentication succeeds but the bootstrap reports that you cannot access the repository, contact the person who provided your application access.

## Installation

### 1. Download the bootstrap

Review the script before running it.

```bash
curl --fail --silent --show-error --location \
  https://raw.githubusercontent.com/plexosoft/self-hosted-ai-assistant-installer/main/bootstrap.sh \
  --output bootstrap.sh
```

### 2. Review the downloaded script

```bash
less bootstrap.sh
```

### 3. Run the bootstrap

```bash
bash bootstrap.sh
```

Do not run the bootstrap as root. It uses `sudo` when necessary for system-level installation and configuration.

The bootstrap checks the environment before proceeding. If required dependencies are missing, it explains the proposed changes and requests confirmation where applicable.

### 4. Authenticate with GitHub

The bootstrap supports these authentication methods:

- **Existing GitHub CLI session:** Uses an existing authenticated `gh` session when available.
- **Personal access token:** Accepts a token through the `GH_TOKEN` environment variable.
- **Interactive token entry:** Allows you to enter a personal access token securely when prompted.
- **Browser login:** Allows you to authenticate through GitHub CLI's interactive web-based login.

Use the GitHub account that has access to `plexosoft/self-hosted-ai-assistant`.

If you use a personal access token, ensure it has the permissions required to access the private repository. For a fine-grained token, grant access to the relevant repository and provide read-only access to its contents. Follow any additional requirements imposed by your organization's GitHub policies.

Never paste a personal access token into a public issue, chat, or terminal command that may be saved in shell history.

### 5. Install or configure Docker

The bootstrap checks whether Docker and the Docker Compose plugin are available.

If Docker is missing or unusable, the bootstrap checks for conflicting packages before offering to install Docker using the official Docker Ubuntu APT repository.

Review the proposed changes before confirming. Docker installation may modify system APT configuration, install system packages, enable the Docker service, and configure Docker group membership.

Membership in the `docker` group effectively grants root-level privileges. Only add trusted users to this group.

### 6. Confirm application installation

After cloning the private repository, the bootstrap asks whether to run the application installer.

Review the prompt before confirming. The application installer may start containers and download container images and AI models.

Declining the prompt leaves the application repository cloned but does not run its installer.

## Installation Destination

By default, the application is cloned to:

```text
~/self-hosted-ai-assistant
```

To select another destination, set `BOOTSTRAP_DEST` when launching the bootstrap:

```bash
BOOTSTRAP_DEST="$HOME/my-ai-assistant" bash bootstrap.sh
```

The destination must not already exist. The bootstrap will refuse to overwrite an existing path.

## Security

- Never share your GitHub credentials or personal access tokens with anyone.
- Review the bootstrap script before executing it.
- Authenticate only through the supported GitHub CLI authentication methods.
- The bootstrap verifies access to the private repository before cloning it.
- The bootstrap verifies the downloaded GitHub CLI APT keyring against a pinned SHA-256 checksum before using it.
- Installing GitHub CLI or Docker can modify system APT configuration and install system packages. Review and confirm these operations before proceeding.
- The bootstrap asks for confirmation before running the application installer.
- Docker group membership effectively grants root-level privileges.
- Keep your operating system and dependencies updated.

Access to the private repository is controlled separately by GitHub. Authorized users may be able to inspect or retain the source code they receive.

### GitHub Credential Cleanup

After cloning the private application repository, the bootstrap unsets `GH_TOKEN` in its own process and attempts to log out the stored GitHub CLI account.

This cleanup is intended to prevent the bootstrap's GitHub authentication from remaining available to subsequent installation steps.

However, there are important limitations:

- Unsetting `GH_TOKEN` affects only the bootstrap process. It does not modify the environment of the parent shell or revoke the token at GitHub.
- Logging out removes local GitHub CLI authentication for the account being logged out. It does not revoke a personal access token at GitHub.
- If the bootstrap cannot identify or remove a stored authentication session, it may report a warning or be unable to verify the remaining authentication state.

Do not assume that all GitHub credentials have been removed merely because the bootstrap completed successfully. Verify the remaining authentication state manually if necessary.

## Troubleshooting

### The environment is not supported

The bootstrap is intended for supported Ubuntu systems. It refuses to run as root and does not support GitHub Codespaces or detected container environments.

Run it from a supported Ubuntu host using a nonroot account with `sudo` access.

### GitHub CLI is missing

The bootstrap offers to install GitHub CLI when it is missing and the system meets the installation requirements.

If you need to install it manually, follow the official GitHub CLI instructions:

[GitHub CLI installation instructions](https://github.com/cli/cli/blob/trunk/docs/install_linux.md?utm_source=chatgpt.com)

### Authentication fails

Check the current GitHub CLI authentication status:

```bash
gh auth status --hostname github.com
```

If necessary, authenticate interactively:

```bash
gh auth login --hostname github.com --git-protocol https --web
```

Rerun the bootstrap after authentication succeeds.

If you previously supplied `GH_TOKEN`, check whether the environment variable is still set in your current shell. Remember that the bootstrap cannot unset variables in its parent shell.

### You cannot access the private repository

Verify that you are using the correct GitHub account and that the account has been granted access to:

`plexosoft/self-hosted-ai-assistant`

Successful GitHub authentication does not necessarily mean that you have permission to access the private repository.

If access is still denied, contact the person who provided your repository access.

### Docker installation fails

Review the error output and check whether conflicting container packages are installed.

The bootstrap stops rather than automatically removing conflicting packages. Resolve any package conflicts deliberately before rerunning it.

### The destination already exists

Choose a different destination:

```bash
BOOTSTRAP_DEST="$HOME/self-hosted-ai-assistant-new" bash bootstrap.sh
```

Alternatively, inspect the existing directory and decide whether to use it or move it yourself. The bootstrap will not overwrite it.

### The installer was not run

If you declined the installation prompt, you can run the installer later:

```bash
cd "$HOME/self-hosted-ai-assistant"
./scripts/install.sh
```

If you selected a custom destination, substitute that path.

If Docker group membership was newly configured during the bootstrap, you may need to start a new login session for the group change to take effect when running commands manually.

## Repository Layout

```text
self-hosted-ai-assistant-installer/
├── bootstrap.sh
├── README.md
└── tests/
    └── test-bootstrap.sh
```

## Running Tests

The test suite uses mocked GitHub CLI commands to exercise the bootstrap's authentication, repository access, cloning, and failure handling paths.

Run it with:

```bash
bash -n bootstrap.sh
bash -n tests/test-bootstrap.sh
bash tests/test-bootstrap.sh
```

The test suite requires Bash and the `script` utility for pseudo-terminal testing. It must be run as a nonroot user.

These tests do not authenticate against a live GitHub account or validate a real application installation.

## Support

For access to the private application repository or assistance with installation, contact the person or organization that provided your access.
