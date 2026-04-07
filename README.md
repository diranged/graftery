<p align="center">
  <img src="docs/icon.svg" alt="Graftery" width="160" height="160" />
</p>

<h1 align="center">Graftery</h1>

<p align="center">
  <strong>Ephemeral macOS VMs for GitHub Actions — powered by <a href="https://tart.run">Tart</a></strong>
</p>

<p align="center">
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS_14+-0e6878?style=flat-square&logo=apple&logoColor=white" />
  <img alt="Protocol" src="https://img.shields.io/badge/protocol-actions%2Fscaleset-094858?style=flat-square&logo=github&logoColor=white" />
  <img alt="Virtualization" src="https://img.shields.io/badge/virt-Tart-c94a30?style=flat-square&logo=apple&logoColor=white" />
  <img alt="License" src="https://img.shields.io/badge/license-TBD-1a8090?style=flat-square" />
</p>

---

<br/>

## Overview

Graftery bridges **GitHub Actions** with **ephemeral macOS virtual machines** running on Apple hardware. It speaks the same [scale-set protocol](https://github.com/actions/scaleset) used by [Actions Runner Controller (ARC)](https://github.com/actions/actions-runner-controller) inside Kubernetes — but runs directly on a Mac host.

It ships as both a **menu bar app** and a **standalone CLI**.

<br/>

<table>
<tr>
<td width="60">

### <!-- icon placeholder -->

</td>
<td>

> **How it works** &mdash; Graftery long-polls GitHub for pending jobs, clones a Tart base VM for each one, injects JIT runner config, and tears the VM down when the job finishes. On startup it detects and removes any orphaned VMs left behind by crashes.

</td>
</tr>
</table>

<br/>

## Requirements

| Requirement | Details |
|:---|:---|
| ![macOS](https://img.shields.io/badge/-macOS_14+-0e6878?style=flat-square&logo=apple&logoColor=white) | Sonoma or later |
| ![Tart](https://img.shields.io/badge/-Tart-094858?style=flat-square&logoColor=white) | `brew install cirruslabs/cli/tart` |
| ![Auth](https://img.shields.io/badge/-GitHub_Auth-c94a30?style=flat-square&logo=github&logoColor=white) | GitHub App credentials **or** a Personal Access Token |
| ![VM](https://img.shields.io/badge/-Base_VM-1a8090?style=flat-square&logoColor=white) | Tart image with the Actions runner binary &amp; startup script ([details](#base-vm-image-requirements)) |

<br/>

## Installation

### From DMG <img src="https://img.shields.io/badge/recommended-0e6878?style=flat-square" alt="recommended" />

Download the latest DMG from the [Releases](https://github.com/diranged/graftery/releases) page, open it, and drag **Graftery** to your Applications folder.

### From Source

```bash
git clone https://github.com/diranged/graftery.git
cd graftery
make install          # builds .app bundle → /Applications/Graftery.app
```

> Requires Xcode command-line tools and Swift.

<br/>

## Quick Start

```
1.  Launch Graftery from Applications (or Spotlight)
2.  Walk through the configuration wizard → credentials, base VM, runner limits
3.  Config is saved to ~/Library/Application Support/graftery/config.yaml
4.  The runner connects to GitHub and begins listening for jobs
5.  Menu bar shows live status  (e.g. ARC: 1/2 → 1 busy / 2 total)
```

<br/>

## Configuration

<details>
<summary><img src="https://img.shields.io/badge/-Config_File_Location-094858?style=flat-square" alt="" /> &nbsp; <code>~/Library/Application Support/graftery/config.yaml</code></summary>

A default config is created on first launch. Open it from the menu bar (**Open Config File**) or with any text editor.

</details>

<br/>

### Full config reference

```yaml
# ── GitHub target ────────────────────────────────────────
url:  https://github.com/your-org        # org or repo URL
name: macos-runner                        # scale set name (= runs-on: label)

# ── Authentication (choose one) ─────────────────────────
# Option A: GitHub App
app_client_id:         "Iv1.abc123"
app_installation_id:   12345678
app_private_key_path:  /path/to/private-key.pem
# Or inline:
# app_private_key: |
#   -----BEGIN RSA PRIVATE KEY-----
#   ...

# Option B: Personal Access Token
# token: ghp_xxxxxxxxxxxx

# ── Runner settings ──────────────────────────────────────
base_image:    ghcr.io/cirruslabs/macos-runner:sonoma
max_runners:   2          # Apple allows max 2 macOS VMs per host
min_runners:   0          # warm-pool size
runner_group:  default
runner_prefix: runner     # used for orphan detection on startup
# labels:                 # defaults to scale set name
#   - macos
#   - sonoma

# ── Provisioning ─────────────────────────────────────────
# tart_path: /opt/homebrew/bin/tart
# provisioning:
#   scripts_dir: /path/to/custom/scripts
#   skip_builtin_scripts: false
#   prepared_image_name: ""

# ── Logging ──────────────────────────────────────────────
log_level:  info          # debug | info | warn | error
log_format: text          # text | json
```

### Editing via the menu bar

| Action | What it does |
|:---|:---|
| **Open Config File** | Opens the YAML in your default editor |
| **Reload Config** | Re-reads and applies changes live |
| **Open Logs** | Opens `~/Library/Logs/graftery/graftery.log` |

<br/>

## CLI Usage

The Go binary works as a standalone CLI — no macOS app wrapper required.

```bash
# Using a config file
graftery --config /path/to/config.yaml

# Using individual flags
graftery \
  --url        https://github.com/your-org \
  --name       macos-runner \
  --app-client-id       Iv1.abc123 \
  --app-installation-id 12345678 \
  --app-private-key-path /path/to/private-key.pem \
  --base-image ghcr.io/cirruslabs/macos-runner:sonoma \
  --max-runners 2

# Using a PAT instead of a GitHub App
graftery \
  --url   https://github.com/your-org \
  --name  macos-runner \
  --token ghp_xxxxxxxxxxxx \
  --base-image ghcr.io/cirruslabs/macos-runner:sonoma
```

> When `--config` is provided, the file is loaded first and any additional flags override its values.

<details>
<summary><img src="https://img.shields.io/badge/-All_CLI_Flags-0e6878?style=flat-square" alt="" /> &nbsp; expand for full table</summary>

<br/>

| Flag | Req | Default | Description |
|:---|:---:|:---|:---|
| `--config` | | | Path to YAML config file |
| `--url` | **yes** | | GitHub org or repo URL |
| `--name` | **yes** | | Scale set name (`runs-on:` label) |
| `--app-client-id` | \* | | GitHub App Client ID |
| `--app-installation-id` | \* | | GitHub App Installation ID |
| `--app-private-key-path` | \* | | Path to PEM file |
| `--app-private-key` | \* | | PEM contents inline |
| `--token` | \* | | Personal access token |
| `--base-image` | | `ghcr.io/cirruslabs/macos-runner:sonoma` | Tart VM image |
| `--max-runners` | | `2` | Max concurrent VMs |
| `--min-runners` | | `0` | Warm pool size |
| `--labels` | | _(same as `--name`)_ | Additional labels |
| `--runner-group` | | `default` | Runner group name |
| `--runner-prefix` | | `runner` | VM name prefix |
| `--log-level` | | `info` | `debug` / `info` / `warn` / `error` |
| `--log-format` | | `text` | `text` / `json` |

\* Provide **either** GitHub App credentials **or** `--token`.

</details>

<br/>

## Image Provisioning

Graftery automatically **bakes** a prepared VM image from your base Tart image. The first run (or whenever scripts change) triggers provisioning:

```
 Base image  ──▶  Clone  ──▶  Boot  ──▶  Run bake.d/* scripts  ──▶  Save prepared image
                                              (lexicographic order)
```

A content hash of all scripts is cached — subsequent runs skip provisioning if nothing changed.

### Built-in scripts

| Script | Purpose |
|:---|:---|
| ![01](https://img.shields.io/badge/01-startup--script.sh-094858?style=flat-square) | Installs `arc-runner-startup.sh` — reads JIT config, starts runner, shuts down when done |
| ![02](https://img.shields.io/badge/02-setup--info.py-094858?style=flat-square) | Generates `.setup_info` — VM info shown in GitHub Actions "Set up job" step |
| ![03](https://img.shields.io/badge/03-runner--hooks.sh-094858?style=flat-square) | Installs pre/post job hooks via `ACTIONS_RUNNER_HOOK_JOB_STARTED` / `COMPLETED` |

### Custom provisioning scripts

Drop your own scripts into the user scripts directory:

```
~/Library/Application Support/graftery/scripts/
  bake.d/
    50-install-tools.sh           # brew install jq terraform
    60-setup-xcode.sh             # sudo xcode-select -s ...
  hooks/
    pre.d/
      50-start-metrics.sh        # custom pre-job hook
    post.d/
      50-emit-metrics.sh         # custom post-job hook
```

> **Merge behavior:** User scripts merge with built-ins. Same-name files override. Execution is lexicographic (`50-*` runs after `01-*` through `03-*`).

Override the directory:

```yaml
provisioning:
  scripts_dir: /path/to/custom/scripts
```

### Forcing reprovisioning

```bash
graftery --reprovision --config config.yaml       # force a fresh bake
graftery --skip-builtin-scripts --config config.yaml  # only run user scripts
```

### Pre/post job hooks

Hooks use GitHub Actions' native runner hook mechanism and appear in the job UI as collapsible sections:

| Hook type | Location | Visible in |
|:---|:---|:---|
| **Pre-job** | `hooks/pre.d/*.sh` | "Set up runner" |
| **Post-job** | `hooks/post.d/*.sh` | "Complete runner" |

Hooks receive standard Actions environment variables (`GITHUB_REPOSITORY`, `GITHUB_RUN_ID`, etc.).

### Base VM image requirements

The base Tart image must include:

| Component | Note |
|:---|:---|
| **GitHub Actions runner** | At `~/actions-runner/` — all `cirruslabs/macos-runner` images include this |
| **Tart guest agent** | All non-vanilla Cirrus Labs images include this |
| **python3** | Required by the setup-info script |

> The default `ghcr.io/cirruslabs/macos-runner:sonoma` satisfies all requirements.

### Example: adding a tool to the baked image

Need CocoaPods for your builds? Create a bake script:

```bash
# ~/Library/Application Support/graftery/scripts/bake.d/50-install-cocoapods.sh
#!/bin/bash
set -euo pipefail
export PATH="/Users/admin/.rbenv/shims:/Users/admin/.rbenv/bin:$PATH"
eval "$(rbenv init - 2>/dev/null)" || true
gem install cocoapods
sudo ln -sf "$(rbenv which pod)" /usr/local/bin/pod
```

Restart the runner — it detects the new script, reprovisions, and every future VM ships with `pod`.

### More examples

See the [`examples/`](examples/) directory:

| Example | Description |
|:---|:---|
| [iOS / React Native](examples/ios-react-native/) | CocoaPods, ccache, Expo prebuild, workflow caching for Pods and DerivedData |

<br/>

## Troubleshooting

<details>
<summary><img src="https://img.shields.io/badge/-tart_not_found-c94a30?style=flat-square" alt="" /></summary>

The `tart` binary must be in your PATH:

```bash
brew install cirruslabs/cli/tart

# Or specify explicitly:
graftery --tart-path /opt/homebrew/bin/tart --config config.yaml
```

```yaml
tart_path: /opt/homebrew/bin/tart
```

</details>

<details>
<summary><img src="https://img.shields.io/badge/-Authentication_errors-c94a30?style=flat-square" alt="" /></summary>

| Error | Fix |
|:---|:---|
| _"either GitHub App credentials or --token is required"_ | Provide one auth method |
| _"specify either GitHub App credentials or --token, not both"_ | Use only one method |
| Private key errors | Check PEM path is correct and readable. For inline YAML, use `\|` block scalar |

</details>

<details>
<summary><img src="https://img.shields.io/badge/-Orphaned_VMs-c94a30?style=flat-square" alt="" /></summary>

On startup, Graftery auto-removes VMs matching the runner prefix. To clean up manually:

```bash
tart list                         # list all VMs
tart stop  runner-abc12345        # stop
tart delete runner-abc12345       # delete
```

</details>

<details>
<summary><img src="https://img.shields.io/badge/-Scale_set_registration_fails-c94a30?style=flat-square" alt="" /></summary>

- Verify `--url` points to a valid GitHub org or repo
- Ensure your GitHub App has the required permissions, or your PAT has `admin:org` (org-level) / `repo` (repo-level) scope

</details>

<details>
<summary><img src="https://img.shields.io/badge/-Max_runners_limit-c94a30?style=flat-square" alt="" /></summary>

Apple's virtualization framework allows **max 2 concurrent macOS VMs per host**. The default `max_runners: 2` reflects this. Setting it higher may cause VM creation failures.

</details>

<details>
<summary><img src="https://img.shields.io/badge/-Logs-1a8090?style=flat-square" alt="" /></summary>

| Mode | Location |
|:---|:---|
| **GUI** | `~/Library/Logs/graftery/graftery.log` (menu bar → Open Logs) |
| **CLI** | stderr — use `--log-level debug` for verbose output |

</details>

<br/>

## Building from Source

Requires **Go 1.26+** and **Xcode command-line tools** (for Swift UI and code signing).

```bash
make build-cli    # CLI binary only (no CGO, no Swift)
make build-app    # full macOS .app bundle
make build-dmg    # drag-and-drop DMG installer
make install      # → /Applications/Graftery.app
make clean        # remove build artifacts
```

All artifacts are placed in the `build/` directory.

<br/>

## License

TBD

<br/>

---

<p align="center">
  <sub>Built for Apple silicon &nbsp;·&nbsp; Powered by <a href="https://tart.run">Tart</a> &nbsp;·&nbsp; Speaks <a href="https://github.com/actions/scaleset">actions/scaleset</a></sub>
</p>
