# Graftery

A lightweight macOS app and CLI that connects GitHub Actions to ephemeral [Tart](https://tart.run) macOS VMs using the [actions/scaleset](https://github.com/actions/scaleset) protocol.

## What It Does

Graftery bridges GitHub Actions with ephemeral macOS virtual machines running on Apple hardware. It uses the same scale-set protocol that [Actions Runner Controller (ARC)](https://github.com/actions/actions-runner-controller) uses inside Kubernetes, but runs directly on a Mac host.

The app sits in your menu bar and:

- Long-polls GitHub for pending workflow jobs
- Clones a Tart base VM image for each job
- Injects JIT runner configuration into the VM via a shared directory
- Cleans up the VM automatically after the job completes
- Recovers from crashes by detecting and removing orphaned VMs on startup

<!-- Screenshots

TODO: Add screenshots of the menu bar app, configuration wizard, and status display.

-->

## Requirements

- **macOS 14 (Sonoma)** or later
- **[Tart](https://tart.run)** installed and available in PATH (`brew install cirruslabs/cli/tart`)
- **GitHub App** credentials (Client ID, Installation ID, private key PEM) **or** a Personal Access Token with appropriate scopes
- A **Tart base VM image** with the GitHub Actions runner binary and a startup script (see [Base VM Image Requirements](#base-vm-image-requirements))

## Installation

### From DMG (recommended)

Download the latest DMG from the releases page, open it, and drag **Graftery** to your Applications folder.

### From source

```bash
git clone https://github.com/diranged/graftery.git
cd graftery
make install
```

This builds the full `.app` bundle (requires Xcode command-line tools and Swift) and copies it to `/Applications/Graftery.app`.

## Quick Start

1. **Launch Graftery** from your Applications folder (or Spotlight).
2. On first launch, the **configuration wizard** guides you through entering your GitHub credentials, selecting a base VM image, and setting runner limits.
3. The configuration is saved to `~/Library/Application Support/graftery/config.yaml`.
4. The runner connects to GitHub and begins listening for jobs automatically.
5. The menu bar icon shows the current runner status (e.g., `ARC: 1/2` for 1 busy out of 2 total runners).

## Configuration

### Config file location

```
~/Library/Application Support/graftery/config.yaml
```

A default config file is created on first launch. You can edit it through the app (menu bar -> Open Config File) or with any text editor.

### Config fields

```yaml
# GitHub org or repo URL for scale set registration
url: https://github.com/your-org

# Scale set name (also the runs-on: label in workflows)
name: macos-runner

# --- Authentication (choose one) ---

# Option A: GitHub App
app_client_id: "Iv1.abc123"
app_installation_id: 12345678
app_private_key_path: /path/to/private-key.pem
# Or inline:
# app_private_key: |
#   -----BEGIN RSA PRIVATE KEY-----
#   ...

# Option B: Personal Access Token
# token: ghp_xxxxxxxxxxxx

# --- Runner settings ---

# Tart VM image to clone for each runner
base_image: ghcr.io/cirruslabs/macos-runner:sonoma

# Maximum concurrent VMs (Apple allows max 2 macOS VMs per host)
max_runners: 2

# Warm pool size (VMs kept ready before jobs arrive)
min_runners: 0

# Additional labels for workflow targeting (defaults to the scale set name)
# labels:
#   - macos
#   - sonoma

# GitHub runner group name
runner_group: default

# VM name prefix (used for orphan detection on startup)
runner_prefix: runner

# --- Provisioning ---

# Path to tart binary (default: look up in PATH)
# tart_path: /opt/homebrew/bin/tart

# Custom scripts directory for image baking and hooks
# provisioning:
#   scripts_dir: /path/to/custom/scripts
#   skip_builtin_scripts: false
#   prepared_image_name: ""  # auto-generated from base_image

# --- Logging ---

# Log level: debug, info, warn, error
log_level: info

# Log format: text or json
log_format: text
```

### Editing via the UI

From the menu bar dropdown:

- **Open Config File** -- opens the YAML file in your default editor
- **Reload Config** -- re-reads the config file and applies changes

Logs are written to `~/Library/Logs/graftery/graftery.log` and can be opened from the menu bar via **Open Logs**.

## CLI Usage

The Go binary can also be used as a standalone CLI without the macOS app wrapper:

```bash
# Using a config file
graftery --config /path/to/config.yaml

# Using individual flags
graftery \
  --url        https://github.com/your-org \
  --name       macos-runner \
  --app-client-id      Iv1.abc123 \
  --app-installation-id 12345678 \
  --app-private-key-path /path/to/private-key.pem \
  --base-image ghcr.io/cirruslabs/macos-runner:sonoma \
  --max-runners 2 \
  --min-runners 0 \
  --log-level  info

# Using a PAT instead of a GitHub App
graftery \
  --url   https://github.com/your-org \
  --name  macos-runner \
  --token ghp_xxxxxxxxxxxx \
  --base-image ghcr.io/cirruslabs/macos-runner:sonoma
```

When `--config` is provided, the file is loaded first and any additional flags override the file values.

### All flags

| Flag | Required | Default | Description |
|---|---|---|---|
| `--config` | no | | Path to YAML config file |
| `--url` | yes | | GitHub org or repo URL for scale set registration |
| `--name` | yes | | Scale set name (also the `runs-on:` label) |
| `--app-client-id` | * | | GitHub App Client ID |
| `--app-installation-id` | * | | GitHub App Installation ID |
| `--app-private-key-path` | * | | Path to PEM file |
| `--app-private-key` | * | | PEM contents inline (alternative to path) |
| `--token` | * | | Personal access token (alternative to GitHub App) |
| `--base-image` | no | `ghcr.io/cirruslabs/macos-runner:sonoma` | Tart VM image to clone for each runner |
| `--max-runners` | no | `2` | Maximum concurrent VMs |
| `--min-runners` | no | `0` | Warm pool size |
| `--labels` | no | (same as `--name`) | Additional labels for workflow targeting |
| `--runner-group` | no | `default` | GitHub runner group name |
| `--runner-prefix` | no | `runner` | VM name prefix (used for orphan detection) |
| `--log-level` | no | `info` | `debug`, `info`, `warn`, `error` |
| `--log-format` | no | `text` | `text` or `json` |

\* Either GitHub App credentials (`--app-client-id`, `--app-installation-id`, and `--app-private-key-path` or `--app-private-key`) **or** `--token` is required.

## Image Provisioning

Graftery automatically prepares ("bakes") VM images from a base Tart image. On first run (or when scripts change), it:

1. Clones the base image (e.g., `ghcr.io/cirruslabs/macos-runner:sonoma`)
2. Boots the clone and waits for the guest agent
3. Runs provisioning scripts from `bake.d/` in lexicographic order via `tart exec`
4. Shuts down the VM and saves it as a local "prepared" image
5. Caches a hash of all script contents — subsequent runs skip provisioning if nothing changed

### Built-in scripts

The following scripts are embedded in the binary and run by default:

| Script | Purpose |
|--------|---------|
| `01-startup-script.sh` | Installs `/usr/local/bin/arc-runner-startup.sh` — reads JIT config from shared mount, starts the runner, shuts down when done |
| `02-setup-info.py` | Generates `~/actions-runner/.setup_info` — shows VM info (OS, Xcode, Node, etc.) in the GitHub Actions "Set up job" step |
| `03-runner-hooks.sh` | Installs pre/post job hooks using GitHub Actions' native `ACTIONS_RUNNER_HOOK_JOB_STARTED` / `ACTIONS_RUNNER_HOOK_JOB_COMPLETED` |

### Custom provisioning scripts

Add your own scripts to the user scripts directory:

```
~/Library/Application Support/graftery/scripts/
  bake.d/
    50-install-tools.sh       # brew install jq terraform
    60-setup-xcode.sh         # sudo xcode-select -s /Applications/Xcode_16.1.app
  hooks/
    pre.d/
      50-start-metrics.sh    # custom pre-job hook
    post.d/
      50-emit-metrics.sh     # custom post-job hook
```

**Merge behavior:** User scripts are merged with built-in scripts. Scripts with the same filename override the built-in version. Scripts are executed in lexicographic order, so `50-*` runs after `01-*`, `02-*`, `03-*`.

Override the scripts directory with `--scripts-dir /path/to/scripts` or in config:

```yaml
provisioning:
  scripts_dir: /path/to/custom/scripts
```

### Forcing reprovisioning

```bash
# Force a fresh bake (e.g., after updating scripts)
graftery --reprovision --config config.yaml

# Skip all built-in scripts (only run user scripts)
graftery --skip-builtin-scripts --config config.yaml
```

### Pre/post job hooks

Hooks use GitHub Actions' native runner hook mechanism. They show up in the job UI as collapsible sections:

- **Pre-job hooks** (`hooks/pre.d/*.sh`) — run before each job starts, visible in "Set up runner"
- **Post-job hooks** (`hooks/post.d/*.sh`) — run after each job completes, visible in "Complete runner"

Hooks receive standard GitHub Actions environment variables (`GITHUB_REPOSITORY`, `GITHUB_RUN_ID`, etc.).

### Base VM image requirements

The base Tart image must include:

1. **GitHub Actions runner binary** at `~/actions-runner/` (all `cirruslabs/macos-runner` images include this)
2. **Tart guest agent** (all non-vanilla Cirrus Labs images include this)
3. **python3** (required by the setup-info script)

The default `ghcr.io/cirruslabs/macos-runner:sonoma` image satisfies all requirements.

### Quick example: adding a tool to the image

Need `pod` (CocoaPods) available for your builds? Create a bake script:

```bash
# ~/Library/Application Support/graftery/scripts/bake.d/50-install-cocoapods.sh
#!/bin/bash
set -euo pipefail
export PATH="/Users/admin/.rbenv/shims:/Users/admin/.rbenv/bin:$PATH"
eval "$(rbenv init - 2>/dev/null)" || true
gem install cocoapods
sudo ln -sf "$(rbenv which pod)" /usr/local/bin/pod
```

Restart the runner — it detects the new script, reprovisions the image, and every future VM has `pod` available.

### More examples

See the [`examples/`](examples/) directory for complete setups:

| Example | Description |
|---------|-------------|
| [iOS / React Native](examples/ios-react-native/) | CocoaPods, ccache, Expo prebuild, workflow caching for Pods and DerivedData |

Each example includes bake scripts to copy into your scripts directory and a recommended workflow configuration.

## Troubleshooting

### `tart` not found

The `tart` binary must be in your PATH, or specify its location explicitly:

```bash
brew install cirruslabs/cli/tart

# Or specify the path directly:
graftery --tart-path /opt/homebrew/bin/tart --config config.yaml
```

In the config file:
```yaml
tart_path: /opt/homebrew/bin/tart
```

### Authentication errors

- **"either GitHub App credentials or --token is required"** -- You must provide either a GitHub App configuration (client ID, installation ID, and private key) or a personal access token. You cannot omit both.
- **"specify either GitHub App credentials or --token, not both"** -- Use one authentication method, not both simultaneously.
- **Private key errors** -- Ensure the PEM file path is correct and readable. If using `app_private_key` inline in YAML, use a literal block scalar (`|`) to preserve newlines.

### VM cleanup / orphaned VMs

On startup, the app automatically detects and removes any VMs whose names start with the configured runner prefix (default: `runner-`). If you need to manually clean up:

```bash
# List all Tart VMs
tart list

# Stop and delete a specific runner VM
tart stop runner-abc12345
tart delete runner-abc12345
```

### Scale set registration fails

- Verify the `--url` points to a valid GitHub organization or repository.
- Ensure your GitHub App is installed on the target org/repo with the required permissions, or that your PAT has the `admin:org` scope (for org-level runners) or `repo` scope (for repo-level runners).

### Max runners limit

Apple's macOS virtualization framework allows a maximum of 2 concurrent macOS VMs per host. The default `max_runners: 2` reflects this limit. Setting it higher may cause VM creation failures.

### Logs

- **GUI app**: `~/Library/Logs/graftery/graftery.log` (also accessible via menu bar -> Open Logs)
- **CLI**: Logs are written to stderr by default. Use `--log-level debug` for verbose output.

## Building from Source

Requires Go 1.26+ and Xcode command-line tools (for the Swift UI and code signing).

```bash
# Build just the CLI binary (no CGO, no Swift)
make build-cli

# Build the full macOS .app bundle (CLI + Swift UI)
make build-app

# Create a drag-and-drop DMG installer
make build-dmg

# Install to /Applications
make install

# Clean build artifacts
make clean
```

The built artifacts are placed in the `build/` directory.

## License

TBD
