# Self-Hosted AI Assistant — Installer

Bootstrap installer for Plexosoft's Self-Hosted AI Assistant.

This repository contains the public installation bootstrap. The application source code is maintained separately in a private repository.

## How It Works

The bootstrap prepares your environment and verifies that your GitHub account can access the private application repository before downloading its source code.

The installation process:

1. Checks for Git and `curl`.
2. Checks whether GitHub CLI (`gh`) is installed.
3. On supported Ubuntu systems, offers to install GitHub CLI if it is missing.
4. Checks your GitHub authentication status and starts an interactive login if necessary.
5. Verifies access to the private application repository.
6. Clones the application into your chosen destination.
7. Asks whether to run the application installer.

The bootstrap does not contain the application source code or grant repository access by itself.

## Requirements

- A supported Linux environment.
- Bash.
- Git.
- `curl`.
- A GitHub account with permission to access the private application repository.
- GitHub CLI (`gh`), installed manually or through the supported Ubuntu installation flow.

Automatic installation of GitHub CLI is supported only on Ubuntu systems with the required APT tools and `sudo` access.

On other operating systems, install GitHub CLI manually using the official instructions:

https://github.com/cli/cli/blob/trunk/docs/install_linux.md

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

Do not run the bootstrap as root. It requests `sudo` only when needed to install GitHub CLI on supported Ubuntu systems.

### 4. Authenticate with GitHub

If GitHub CLI is not authenticated, the bootstrap starts an interactive web-based login.

Complete the authentication process using the GitHub account that has access to the private application repository.

### 5. Confirm installation

After the repository has been cloned, the bootstrap asks whether to run the application installer.

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
- Authenticate through GitHub CLI's official login flow.
- The bootstrap verifies access to the private repository before cloning.
- The bootstrap checks the downloaded GitHub CLI APT keyring against a pinned SHA-256 checksum before using it.
- Installing GitHub CLI on Ubuntu modifies system APT configuration and installs a system package; the bootstrap asks for confirmation first.
- The bootstrap asks for confirmation before running the application installer.
- Review scripts before executing them and keep your operating system and dependencies updated.

Access to the private repository is controlled separately by GitHub. Authorized users may be able to inspect or retain the source code they receive.

## Troubleshooting

### GitHub CLI is missing

On Ubuntu, the bootstrap offers to install it after requesting confirmation.

On other systems, follow the official GitHub CLI installation instructions:

https://github.com/cli/cli/blob/trunk/docs/install_linux.md

### Authentication fails

Run:

```bash
gh auth login --hostname github.com
```

Then verify your authentication:

```bash
gh auth status --hostname github.com
```

Rerun the bootstrap after authentication succeeds.

### You cannot access the private repository

Verify that you are logged into the correct GitHub account and that the account has been granted access to:

`plexosoft/self-hosted-ai-assistant`

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

## Repository Layout

```text
self-hosted-ai-assistant-installer/
├── bootstrap.sh
├── README.md
└── tests/
    └── test-bootstrap.sh
```

## Running Tests

The test suite uses mocked GitHub CLI commands to exercise the bootstrap's authentication, repository-access, cloning, and failure-handling paths.

Run it with:

```bash
bash -n bootstrap.sh
bash -n tests/test-bootstrap.sh
bash tests/test-bootstrap.sh
```

The test suite requires Bash and the `script` utility for pseudo-terminal testing. It must be run as a non-root user.

These tests do not authenticate against a live GitHub account or validate a real application installation.

## Support

For access to the private application repository or assistance with installation, contact the person or organization that provided your access.