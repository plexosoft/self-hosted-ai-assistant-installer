# Self Hosted AI Assistant Installer

Bootstrap installer for Plexosoft's Self Hosted AI Assistant.

This repository contains the public installation bootstrap. The application source code is maintained separately in a private repository.

## How It Works

The bootstrap prepares your Ubuntu host and verifies that the supplied GitHub token can access the private application repository before installing Docker or downloading the application source.

The installation process:

1. Checks that the system is a supported Ubuntu environment and that the required system tools are available.
2. Checks whether base tools such as `ca-certificates`, `curl`, and `git` are installed, offering to install missing dependencies when needed.
3. Checks whether GitHub CLI (`gh`) is installed and offers to install it if necessary.
4. Obtains a GitHub token from the `GH_TOKEN` environment variable or prompts you to enter one securely. A saved GitHub CLI login does not replace this token requirement.
5. Validates the token and verifies access to the private application repository before installing Docker.
6. Checks whether Docker and the Docker Compose plugin are available, offering to install Docker when necessary.
7. Clones the application repository over HTTPS using a Git credential helper configured for that clone operation only.
8. Unsets `GH_TOKEN` in the bootstrap process before offering to run the application installer. It does not log out of or remove a pre-existing GitHub CLI login.
9. Asks whether to run the application installer.

The bootstrap does not contain the application source code or grant repository access by itself.

## Requirements

The bootstrap requires:

- Ubuntu.
- Bash.
- `apt-get` and `dpkg`.
- `sudo` access for system package installation.
- A GitHub account with permission to access the private application repository.
- A valid fine-grained GitHub personal access token (PAT), unless `GH_TOKEN` is supplied in the environment.

The token should be restricted to `plexosoft/self-hosted-ai-assistant` and have **Repository permissions → Contents: Read-only**. Organization approval may also be required.

The bootstrap must run as a nonroot user. It refuses to run in GitHub Codespaces and detects common container environments that are not supported.

The bootstrap can install missing base tools, GitHub CLI, and Docker after requesting confirmation where applicable.

Docker installation requires a supported Ubuntu environment and the ability to configure system packages and services.

## Getting Access

The application repository is private. Before installation, make sure your GitHub account has been granted access to:

`plexosoft/self-hosted-ai-assistant`

Making this installer repository public does not make the application repository public or grant access to its contents.

If token validation succeeds but the bootstrap reports that you cannot access the repository, verify the token's repository selection and permissions, any required organization approval, and the account's access to the repository. Contact the person who provided your application access if needed.

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

Unless `GH_TOKEN` is already set in the environment, the bootstrap prompts you to enter a fine-grained GitHub personal access token. Input is hidden while you type. This prompt appears even if the GitHub CLI already has a saved login, because the bootstrap explicitly requires a token for this run.

Create a fine-grained token with the following settings:

- **Resource owner:** the owner of `plexosoft/self-hosted-ai-assistant`.
- **Repository access:** select `self-hosted-ai-assistant` only, if that meets your access requirements.
- **Repository permissions → Contents:** Read-only.
- **Expiration:** choose an expiration appropriate for your security requirements.

Follow any organization approval requirements. Do not grant unnecessary permissions.

#### Optional: provide the token through `GH_TOKEN`

You can supply the token in the environment before launching the bootstrap. The following commands prompt for the token without displaying it or placing the value directly in shell history:

```bash
read -rsp "GitHub token: " GH_TOKEN
printf '\n'
export GH_TOKEN
bash bootstrap.sh
unset GH_TOKEN
```

The final `unset` removes the variable from your current shell after the bootstrap exits. The bootstrap itself also unsets `GH_TOKEN` in its own process before launching the application installer; it cannot modify the environment of the parent shell.

Never commit tokens to Git, put them in source files, or include them in logs, screenshots, public issues, or support requests.

#### Authentication and repository access checks

The bootstrap validates the token and checks access to `plexosoft/self-hosted-ai-assistant` before installing Docker or cloning the source. If token validation fails or the authenticated account cannot access the repository, the bootstrap stops before Docker setup and cloning.

### 5. Install or configure Docker

The bootstrap checks whether Docker and the Docker Compose plugin are available.

If Docker is missing or unusable, the bootstrap checks for conflicting packages before offering to install Docker using the official Docker Ubuntu APT repository.

Review the proposed changes before confirming. Docker installation may modify system APT configuration, install system packages, enable the Docker service, and configure Docker group membership.

Membership in the `docker` group effectively grants root-level privileges. Only add trusted users to this group.

### 6. Confirm application installation

After cloning the private repository, the bootstrap verifies that the checkout contains a `.git` directory and that `scripts/install.sh` exists and is executable. It then asks whether to run the application installer.

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

The destination must not already exist. The bootstrap refuses to overwrite an existing path.

## Security

- Review the bootstrap script before executing it.
- Use a fine-grained token with only the repository access and permissions required for cloning.
- The bootstrap validates the token and verifies access to the private repository before installing Docker or cloning it.
- The application repository is cloned over HTTPS. The token is not embedded in the repository URL, and the bootstrap does not change your global Git credential-helper configuration.
- The Git credential helper is configured for the clone command only.
- The bootstrap unsets `GH_TOKEN` in its own process before launching the application installer.
- The bootstrap does not revoke the token on GitHub, modify the parent shell's environment, or log out of or remove credentials from a pre-existing GitHub CLI login.
- The bootstrap verifies the downloaded GitHub CLI APT keyring against a pinned SHA-256 checksum before using it.
- Installing GitHub CLI or Docker can modify system APT configuration and install system packages. Review and confirm these operations before proceeding.
- The bootstrap asks for confirmation before running the application installer.
- Docker group membership effectively grants root-level privileges.
- Keep your operating system and dependencies updated.

Access to the private repository is controlled separately by GitHub. Authorized users may be able to inspect or retain the source code they receive.

### GitHub Credential Handling

The bootstrap uses the supplied `GH_TOKEN` or the token entered at its hidden interactive prompt for authentication and repository operations. It unsets `GH_TOKEN` in its own process before offering to start the application installer.

This reduces the chance that the application installer inherits the token through the environment, but it does not revoke the token or guarantee that no other process could access it while the bootstrap is running.

The bootstrap does **not** log out of a saved GitHub CLI session or delete credentials stored by the GitHub CLI. Any pre-existing GitHub CLI login remains available after the bootstrap finishes. Unsetting `GH_TOKEN` also does not change the parent shell's environment; if you exported it in your shell, run `unset GH_TOKEN` there when it is no longer needed.

Manage token permissions, expiration, and revocation through GitHub. Do not assume that all GitHub credentials have been removed when the bootstrap completes.

## Troubleshooting

### The environment is not supported

The bootstrap is intended for supported Ubuntu systems. It refuses to run as root and does not support GitHub Codespaces or detected container environments.

Run it from a supported Ubuntu host using a nonroot account with `sudo` access.

### GitHub CLI is missing

The bootstrap offers to install GitHub CLI when it is missing and the system meets the installation requirements.

If you need to install it manually, follow the official GitHub CLI instructions:

[GitHub CLI installation instructions](https://github.com/cli/cli/blob/trunk/docs/install_linux.md)

### Token validation fails

- Check that the fine-grained token is valid and has not expired.
- Verify that the token is configured for the correct resource owner and repository.
- Verify that **Contents: Read-only** is granted.
- Check whether organization approval is required.
- If you use `GH_TOKEN`, verify that it is set in the shell from which you launch the bootstrap and that its value is correct.

The bootstrap requires a token even if `gh auth status` reports an existing login. A saved GitHub CLI session alone is not sufficient.

### You cannot access the private repository

Verify that the authenticated account has access to `plexosoft/self-hosted-ai-assistant` and that the token is authorized for that repository. Successful token validation does not necessarily mean the token can access the private repository.

If access is still denied, contact the person who provided your repository access.

### Cloning fails with an SSH public-key error

The bootstrap is designed to clone the application repository over HTTPS using a Git credential helper configured for that clone operation. It does not rely on an SSH key for the clone.

If you see an SSH public-key error, verify that you are running the updated `bootstrap.sh` and that the clone command uses the HTTPS URL and temporary GitHub CLI credential helper.

### The application installer does not receive `GH_TOKEN`

This is intentional. The bootstrap unsets `GH_TOKEN` in its own process before launching the application installer. It does not revoke the token or log out of an existing GitHub CLI session. If you supplied `GH_TOKEN` from your shell, the variable may still be set in that parent shell until you unset it yourself.

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

The test suite uses mocked GitHub CLI, Git, Docker, and system-changing commands to exercise authentication, repository access, cloning, and failure-handling paths without intentionally changing the host system.

Run the syntax checks with:

```bash
bash -n bootstrap.sh
bash -n tests/test-bootstrap.sh
```

The integration-style test suite must be run as a nonroot user on a supported Ubuntu host or VM outside a container. It requires the `script` utility for pseudo-terminal testing:

```bash
bash tests/test-bootstrap.sh
```

These tests do not authenticate against a live GitHub account or validate a real application installation. They use mocks and should be treated as automated regression tests, not as a substitute for reviewing the script or testing the full installation on a disposable supported host.

## Support

For access to the private application repository or assistance with installation, contact the person or organization that provided your access.
