// Copyright 2026 Matt Wise
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Package main implements graftery, a GitHub Actions runner scale set
// controller that provisions ephemeral Tart macOS VMs for each job.
package main

import (
	"fmt"
	"log/slog"
	"os"
	"strings"

	"github.com/actions/scaleset"
)

// ProvisioningConfig controls automatic VM image preparation. The provisioner
// clones the upstream base image, boots it, runs "bake" scripts via tart exec
// (installing tools, configuring the runner environment), installs pre/post job
// hooks, then saves the result as a local "prepared" image. All subsequent
// runner VMs are cloned from this prepared image rather than the upstream base,
// avoiding repeated setup work on every job.
//
// The provisioner uses a content hash of the scripts + config to detect when
// re-provisioning is needed. If the hash matches a previously prepared image,
// provisioning is skipped entirely.
type ProvisioningConfig struct {
	// ScriptsDir is the path to a directory containing user override scripts.
	// Expected structure: bake.d/*.sh, hooks/pre.d/*.sh, hooks/post.d/*.sh.
	// User scripts are merged with built-in defaults; if a user script has the
	// same filename as a built-in, the user version wins. If empty, defaults
	// to DefaultConfigDir()/scripts/.
	ScriptsDir string `yaml:"scripts_dir"`

	// PreparedImageName overrides the local tart VM name used for the prepared
	// image. This is the image that runners are cloned from at job time.
	// Defaults to "arc-prepared-<sanitized-base-image>".
	PreparedImageName string `yaml:"prepared_image_name"`

	// SkipBuiltinScripts disables all embedded scripts. Only user scripts
	// from ScriptsDir will run. Useful when the base image is fully custom
	// and the built-in bake scripts would conflict or be redundant.
	SkipBuiltinScripts bool `yaml:"skip_builtin_scripts"`
}

// Config holds all CLI and config-file settings needed to register a GitHub
// Actions runner scale set and manage its lifecycle. Fields are populated from
// CLI flags, a YAML config file, or both (flags override file values).
type Config struct {
	RegistrationURL   string   `yaml:"url"`
	Name              string   `yaml:"name"`
	AppClientID       string   `yaml:"app_client_id"`
	AppInstallationID int64    `yaml:"app_installation_id"`
	AppPrivateKeyPath string   `yaml:"app_private_key_path"`
	AppPrivateKey     string   `yaml:"app_private_key"`
	Token             string   `yaml:"token"`
	BaseImage         string   `yaml:"base_image"`
	MaxRunners        int      `yaml:"max_runners"`
	MinRunners        int      `yaml:"min_runners"`
	Labels            []string `yaml:"labels"`
	RunnerGroup       string   `yaml:"runner_group"`
	RunnerPrefix      string   `yaml:"runner_prefix"`
	TartPath          string   `yaml:"tart_path"`
	LogLevel          string   `yaml:"log_level"`
	LogFormat         string   `yaml:"log_format"`

	Provisioning ProvisioningConfig `yaml:"provisioning"`

	// ControlSocket is the Unix domain socket path for the control API.
	// Set via --control-socket flag, not persisted in YAML.
	ControlSocket string `yaml:"-"`

	// Reprovision forces re-provisioning of the prepared image even if the
	// config hash matches. Set via --reprovision flag, not persisted in YAML.
	Reprovision bool `yaml:"-"`
}

// Validate checks that all required fields are set and that values are
// internally consistent. It applies the default base image when none is
// provided and enforces mutual exclusivity between GitHub App and PAT auth.
func (c *Config) Validate() error {
	if c.RegistrationURL == "" {
		return fmt.Errorf("--url is required")
	}
	if c.Name == "" {
		return fmt.Errorf("--name is required")
	}
	if c.BaseImage == "" {
		c.BaseImage = DefaultBaseImage
	}

	// Exactly one auth method must be configured: GitHub App or PAT.
	hasApp := c.AppClientID != "" || c.AppInstallationID != 0 || c.AppPrivateKeyPath != "" || c.AppPrivateKey != ""
	hasToken := c.Token != ""

	if !hasApp && !hasToken {
		return fmt.Errorf("either GitHub App credentials (--app-client-id, --app-installation-id, --app-private-key-path) or --token is required")
	}
	if hasApp && hasToken {
		return fmt.Errorf("specify either GitHub App credentials or --token, not both")
	}
	// When using GitHub App auth, all three credentials are required,
	// and the private key can come from either a file path or inline content.
	if hasApp {
		if c.AppClientID == "" {
			return fmt.Errorf("--app-client-id is required when using GitHub App auth")
		}
		if c.AppInstallationID == 0 {
			return fmt.Errorf("--app-installation-id is required when using GitHub App auth")
		}
		if c.AppPrivateKeyPath == "" && c.AppPrivateKey == "" {
			return fmt.Errorf("--app-private-key-path or --app-private-key is required when using GitHub App auth")
		}
		if c.AppPrivateKeyPath != "" && c.AppPrivateKey != "" {
			return fmt.Errorf("specify either --app-private-key-path or --app-private-key, not both")
		}
	}

	if c.MaxRunners < 1 {
		return fmt.Errorf("--max-runners must be >= 1")
	}
	if c.MinRunners < 0 {
		return fmt.Errorf("--min-runners must be >= 0")
	}
	if c.MinRunners > c.MaxRunners {
		return fmt.Errorf("--min-runners (%d) cannot exceed --max-runners (%d)", c.MinRunners, c.MaxRunners)
	}

	return nil
}

// systemInfo returns metadata identifying this controller to the GitHub
// Actions service. The ScaleSetID is zero during initial registration and
// updated once the scale set is created.
func systemInfo(scaleSetID int) scaleset.SystemInfo {
	return scaleset.SystemInfo{
		System:     AppName,
		Subsystem:  AppSubsystem,
		Version:    AppVersion,
		ScaleSetID: scaleSetID,
	}
}

// ScalesetClient creates a GitHub Actions scaleset API client using whichever
// auth method is configured (PAT or GitHub App). The returned client is used
// to register the scale set, create message sessions, and generate JIT configs.
func (c *Config) ScalesetClient() (*scaleset.Client, error) {
	// PAT auth path: simpler, fewer fields required.
	if c.Token != "" {
		return scaleset.NewClientWithPersonalAccessToken(scaleset.NewClientWithPersonalAccessTokenConfig{
			GitHubConfigURL:     c.RegistrationURL,
			PersonalAccessToken: c.Token,
			SystemInfo:          systemInfo(0),
		})
	}

	// GitHub App auth path: requires reading the PEM private key.
	privateKey, err := c.ReadPrivateKey()
	if err != nil {
		return nil, err
	}

	return scaleset.NewClientWithGitHubApp(scaleset.ClientWithGitHubAppConfig{
		GitHubConfigURL: c.RegistrationURL,
		GitHubAppAuth: scaleset.GitHubAppAuth{
			ClientID:       c.AppClientID,
			InstallationID: c.AppInstallationID,
			PrivateKey:     privateKey,
		},
		SystemInfo: systemInfo(0),
	})
}

// ReadPrivateKey returns the PEM-encoded private key string. It prefers the
// inline AppPrivateKey value; if that is empty, it reads the file at
// AppPrivateKeyPath. Callers should ensure at least one is set via Validate.
func (c *Config) ReadPrivateKey() (string, error) {
	if c.AppPrivateKey != "" {
		return c.AppPrivateKey, nil
	}
	data, err := os.ReadFile(c.AppPrivateKeyPath)
	if err != nil {
		return "", fmt.Errorf("reading private key %s: %w", c.AppPrivateKeyPath, err)
	}
	return string(data), nil
}

// Logger returns a structured logger configured with the desired level and
// format. Output goes to stderr so it doesn't interfere with any stdout usage.
func (c *Config) Logger() *slog.Logger {
	// Map the string log level to slog's typed level; default to Info.
	var level slog.Level
	switch strings.ToLower(c.LogLevel) {
	case "debug":
		level = slog.LevelDebug
	case "warn":
		level = slog.LevelWarn
	case "error":
		level = slog.LevelError
	default:
		level = slog.LevelInfo
	}

	opts := &slog.HandlerOptions{Level: level}

	var handler slog.Handler
	if strings.ToLower(c.LogFormat) == LogFormatJSON {
		handler = slog.NewJSONHandler(os.Stderr, opts)
	} else {
		handler = slog.NewTextHandler(os.Stderr, opts)
	}

	return slog.New(handler)
}

// BuildLabels constructs the label set for scale set registration. If no
// explicit labels are configured, the scale set name is used as the sole label,
// which means workflows can target this runner with `runs-on: <name>`.
func (c *Config) BuildLabels() []scaleset.Label {
	labelNames := c.Labels
	if len(labelNames) == 0 {
		labelNames = []string{c.Name}
	}

	labels := make([]scaleset.Label, len(labelNames))
	for i, name := range labelNames {
		labels[i] = scaleset.Label{Name: name}
	}
	return labels
}
