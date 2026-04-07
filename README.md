<p align="center">
  <img src="icons/icon.png" alt="Graftery" width="160" height="160" />
</p>

<h1 align="center">Graftery</h1>

<p align="center">
  <strong>Ephemeral macOS VMs for GitHub Actions — powered by <a href="https://tart.run">Tart</a></strong>
</p>

<p align="center">
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS_14+-0e6878?style=flat-square&logo=apple&logoColor=white" />
  <img alt="Protocol" src="https://img.shields.io/badge/protocol-actions%2Fscaleset-094858?style=flat-square&logo=github&logoColor=white" />
  <img alt="Virtualization" src="https://img.shields.io/badge/virt-Tart-c94a30?style=flat-square&logo=apple&logoColor=white" />
  <img alt="License" src="https://img.shields.io/badge/license-Apache_2.0-1a8090?style=flat-square" />
</p>

---

## Why Graftery?

If you run iOS, macOS, or Apple-platform CI on GitHub Actions, you need macOS runners. GitHub's hosted runners work, but they're expensive and you can't customize the image. Self-hosted runners on bare metal are fast and cheap — but managing them is painful: stale state bleeds between jobs, runner registration is manual, and there's no easy way to scale.

**Graftery fixes this.** It brings the same ephemeral, scale-to-zero model that [Actions Runner Controller (ARC)](https://github.com/actions/actions-runner-controller) provides on Kubernetes — but runs directly on a Mac. Every job gets a **fresh VM clone**. When the job finishes, the VM is destroyed. No state leaks, no drift, no cleanup scripts.

### How it works

```
GitHub Actions                        Your Mac
─────────────                         ────────
  Job queued  ──── scaleset poll ────▶  Graftery sees demand
                                        │
                                        ├─ Clones base VM image
                                        ├─ Injects JIT runner config
                                        ├─ Boots ephemeral Tart VM
                                        ├─ Runner picks up the job
                                        └─ VM destroyed on completion
```

Graftery speaks the [actions/scaleset](https://github.com/actions/scaleset) protocol natively — the same wire protocol ARC uses. No custom API, no webhook glue.

### Core capabilities

**Clean room every job** — Each job runs in a fresh VM clone. No state leaks between jobs, ever.

**Scale to zero** — No jobs? No VMs. Runners spin up on demand and tear down when done. Configure a warm pool (`min_runners`) for faster pickup.

**Custom VM images** — Drop shell scripts into `bake.d/` and Graftery bakes them into a prepared image. Install Xcode, CocoaPods, Homebrew packages — whatever your builds need. Content-hashed so reprovisioning only happens when scripts change.

**Pre/post job hooks** — Native GitHub Actions runner hooks (`ACTIONS_RUNNER_HOOK_JOB_STARTED` / `COMPLETED`). They show up as collapsible sections in the Actions UI.

**Orphan cleanup** — On startup, Graftery finds and removes VMs left behind by crashes. Session conflicts with GitHub are retried automatically with exponential backoff.

**Prometheus metrics** — Host CPU/memory/disk, per-VM CPU/memory/uptime, job counters — all exposed via a `/metrics` endpoint. Includes Apple hypervisor (XPC) process tracking for accurate VM resource attribution.

**Dry-run mode** — Test your setup without GitHub or Tart. Simulates the full lifecycle with fake jobs so you can validate config, control socket, and UI integration end-to-end.

### Two ways to run it

Graftery ships as both a **macOS menu bar app** and a **standalone CLI**. They share the same Go backend — the app wraps the CLI in a native Swift UI.

| | <img src="https://img.shields.io/badge/-macOS_App-0e6878?style=flat-square&logo=apple&logoColor=white" /> | <img src="https://img.shields.io/badge/-CLI-094858?style=flat-square&logo=gnubash&logoColor=white" /> |
|:---|:---|:---|
| **Best for** | Interactive use on a Mac with a display | Headless servers, automation, launchd/systemd |
| **Install** | [Download DMG](#-macos-app) | [Download binary](#-cli) |
| **Runner sets** | **Multiple** — manage unlimited independent configs | **One** per process |
| **Config** | 6-step setup wizard + tabbed editor with auto-save | YAML file + CLI flags |
| **Metrics** | Live time-series charts (CPU & memory), menu bar gauges | Prometheus `/metrics` endpoint |
| **Logs** | Built-in log viewer with search, level filtering, color | Structured logs to stderr |
| **Controls** | Menu bar start/stop per runner, enable/disable auto-start | SIGINT/SIGTERM |
| **Runs as** | Menu bar app | Foreground process |

> [!TIP]
> **Already using ARC on Kubernetes?** Graftery uses the same protocol and the same `runs-on:` label convention. Your workflows don't need to change — just point a scale set name at your Mac and go.

---

## Requirements

| Requirement | Details |
|:---|:---|
| ![macOS](https://img.shields.io/badge/-macOS_14+-0e6878?style=flat-square&logo=apple&logoColor=white) | Sonoma or later |
| ![Tart](https://img.shields.io/badge/-Tart-094858?style=flat-square&logoColor=white) | `brew install cirruslabs/cli/tart` |
| ![Auth](https://img.shields.io/badge/-GitHub_Auth-c94a30?style=flat-square&logo=github&logoColor=white) | GitHub App credentials **or** a Personal Access Token |
| ![VM](https://img.shields.io/badge/-Base_VM-1a8090?style=flat-square&logoColor=white) | Tart image with the Actions runner binary & startup script ([details](#base-vm-image-requirements)) |

---

# <img src="https://img.shields.io/badge/-macOS_App-0e6878?style=for-the-badge&logo=apple&logoColor=white" alt="macOS App" />

## Installation

Download the latest **DMG** from the [Releases](https://github.com/diranged/graftery/releases) page, open it, and drag **Graftery** into your Applications folder.

That's it — no dependencies beyond [Tart](#requirements).

> [!TIP]
> Building from source? See [Building from Source](#building-from-source) at the bottom of this page.

## Quick Start

1. **Launch Graftery** from Applications (or Spotlight).
2. The **setup wizard** walks you through creating your first runner configuration — name it, enter your GitHub credentials, choose a base VM image, and set runner limits.

<table align="center">
<tr>
<td align="center" valign="top"><img src="docs/screenshots/wizard-name.png" alt="Setup wizard — name your configuration" width="400" /></td>
<td align="center" valign="top"><img src="docs/screenshots/wizard-auth.png" alt="Setup wizard — authentication" width="400" /></td>
</tr>
<tr>
<td align="center"><sub>Step 1 — Name your configuration</sub></td>
<td align="center"><sub>Step 3 — Authentication</sub></td>
</tr>
</table>

3. The runner connects to GitHub and begins listening for jobs automatically.
4. The **menu bar icon** shows live status. Click it to start/stop runners, add new configurations, or open the management window.

<p align="center">
  <img src="docs/screenshots/menu-bar.png" alt="Menu bar dropdown" width="220" />
</p>

5. Open **Manage Configurations** for the full editor — tabbed settings, live CPU & memory charts, and a built-in log viewer.

<p align="center">
  <img src="docs/screenshots/config-editor.png" alt="Configuration editor with metrics" width="700" />
</p>

## Configuration

Each runner configuration is stored as a YAML file in `~/Library/Application Support/graftery/configs/`. You can manage everything through the UI — the setup wizard for new configs, and the tabbed editor for changes (auto-saved on every edit).

You can also edit the YAML files directly with any text editor if you prefer.

### Config file reference

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

---

# <img src="https://img.shields.io/badge/-CLI-094858?style=for-the-badge&logo=gnubash&logoColor=white" alt="CLI" />

## Installation

Download the latest **`graftery` binary** from the [Releases](https://github.com/diranged/graftery/releases) page and place it somewhere in your `PATH`.

```bash
# Example: install to /usr/local/bin
curl -fSL https://github.com/diranged/graftery/releases/latest/download/graftery-darwin-arm64 \
  -o /usr/local/bin/graftery
chmod +x /usr/local/bin/graftery
```

> [!TIP]
> Building from source? See [Building from Source](#building-from-source) at the bottom of this page.

## Usage

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

When `--config` is provided, the file is loaded first and any additional flags override its values.

## CLI Flags

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

## Logging

Logs go to stderr by default. Use `--log-level debug` for verbose output, or `--log-format json` for structured logs.

---

# <img src="https://img.shields.io/badge/-Image_Provisioning-1a8090?style=for-the-badge&logoColor=white" alt="Image Provisioning" />

_Applies to both the macOS app and CLI._

Graftery automatically **bakes** a prepared VM image from your base Tart image. The first run (or whenever scripts change) triggers provisioning:

```
 Base image  ──▶  Clone  ──▶  Boot  ──▶  Run bake.d/* scripts  ──▶  Save prepared image
                                              (lexicographic order)
```

A content hash of all scripts is cached — subsequent runs skip provisioning if nothing changed.

## Built-in scripts

| Script | Purpose |
|:---|:---|
| ![01](https://img.shields.io/badge/01-startup--script.sh-094858?style=flat-square) | Installs `arc-runner-startup.sh` — reads JIT config, starts runner, shuts down when done |
| ![02](https://img.shields.io/badge/02-setup--info.py-094858?style=flat-square) | Generates `.setup_info` — VM info shown in GitHub Actions "Set up job" step |
| ![03](https://img.shields.io/badge/03-runner--hooks.sh-094858?style=flat-square) | Installs pre/post job hooks via `ACTIONS_RUNNER_HOOK_JOB_STARTED` / `COMPLETED` |

## Custom provisioning scripts

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

> [!NOTE]
> **Merge behavior:** User scripts merge with built-ins. Same-name files override. Execution is lexicographic (`50-*` runs after `01-*` through `03-*`).

Override the directory:

```yaml
provisioning:
  scripts_dir: /path/to/custom/scripts
```

## Forcing reprovisioning

```bash
graftery --reprovision --config config.yaml           # force a fresh bake
graftery --skip-builtin-scripts --config config.yaml  # only run user scripts
```

## Pre/post job hooks

Hooks use GitHub Actions' native runner hook mechanism and appear in the job UI as collapsible sections:

| Hook type | Location | Visible in |
|:---|:---|:---|
| **Pre-job** | `hooks/pre.d/*.sh` | "Set up runner" |
| **Post-job** | `hooks/post.d/*.sh` | "Complete runner" |

Hooks receive standard Actions environment variables (`GITHUB_REPOSITORY`, `GITHUB_RUN_ID`, etc.).

## Base VM image requirements

The base Tart image must include:

| Component | Note |
|:---|:---|
| **GitHub Actions runner** | At `~/actions-runner/` — all `cirruslabs/macos-runner` images include this |
| **Tart guest agent** | All non-vanilla Cirrus Labs images include this |
| **python3** | Required by the setup-info script |

> The default `ghcr.io/cirruslabs/macos-runner:sonoma` satisfies all requirements.

## Example: adding a tool to the baked image

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

## More examples

See the [`examples/`](examples/) directory:

| Example | Description |
|:---|:---|
| [iOS / React Native](examples/ios-react-native/) | CocoaPods, ccache, Expo prebuild, workflow caching for Pods and DerivedData |

---

# <img src="https://img.shields.io/badge/-Troubleshooting-c94a30?style=for-the-badge&logoColor=white" alt="Troubleshooting" />

<details>
<summary><strong><code>tart</code> not found</strong></summary>

The `tart` binary must be in your PATH:

```bash
brew install cirruslabs/cli/tart
```

Or specify the path explicitly via CLI flag or config:

```bash
graftery --tart-path /opt/homebrew/bin/tart --config config.yaml
```

```yaml
tart_path: /opt/homebrew/bin/tart
```

</details>

<details>
<summary><strong>Authentication errors</strong></summary>

| Error | Fix |
|:---|:---|
| _"either GitHub App credentials or --token is required"_ | Provide one auth method |
| _"specify either GitHub App credentials or --token, not both"_ | Use only one method |
| Private key errors | Check PEM path is correct and readable. For inline YAML, use `\|` block scalar |

</details>

<details>
<summary><strong>Orphaned VMs</strong></summary>

On startup, Graftery auto-removes VMs matching the runner prefix. To clean up manually:

```bash
tart list                         # list all VMs
tart stop  runner-abc12345        # stop
tart delete runner-abc12345       # delete
```

</details>

<details>
<summary><strong>Scale set registration fails</strong></summary>

- Verify `--url` points to a valid GitHub org or repo
- Ensure your GitHub App has the required permissions, or your PAT has `admin:org` (org-level) / `repo` (repo-level) scope

</details>

<details>
<summary><strong>Max runners limit</strong></summary>

Apple's virtualization framework allows **max 2 concurrent macOS VMs per host**. The default `max_runners: 2` reflects this. Setting it higher may cause VM creation failures.

</details>

<details>
<summary><strong>Logs</strong></summary>

| Mode | Location |
|:---|:---|
| **macOS App** | `~/Library/Logs/graftery/graftery.log` (menu bar -> Open Logs) |
| **CLI** | stderr — use `--log-level debug` for verbose output |

</details>

---

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

## License

[Apache License 2.0](LICENSE)

---

<p align="center">
  <sub>Built for Apple silicon &nbsp;·&nbsp; Powered by <a href="https://tart.run">Tart</a> &nbsp;·&nbsp; Speaks <a href="https://github.com/actions/scaleset">actions/scaleset</a></sub>
</p>
