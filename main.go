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

package main

import (
	"context"
	"os"
	"os/signal"
	"syscall"

	"github.com/actions/scaleset"
	"github.com/spf13/cobra"
)

// main is the CLI entry point. It wires up cobra flags, merges config-file and
// flag values, then delegates to run() which handles the full scale set lifecycle.
func main() {

	// Start with sensible defaults; these can be overridden by --config file or flags.
	cfg := &Config{
		MaxRunners:   DefaultMaxRunners,
		MinRunners:   DefaultMinRunners,
		RunnerPrefix: DefaultRunnerPrefix,
		RunnerGroup:  scaleset.DefaultRunnerGroup,
		LogLevel:     DefaultLogLevel,
		LogFormat:    DefaultLogFormat,
	}

	var configFile string
	var reprovision bool
	var controlSocket string
	var dryRun bool

	rootCmd := &cobra.Command{
		Use:   AppName,
		Short: "GitHub Actions runner scale set backed by Tart macOS VMs",
		RunE: func(cmd *cobra.Command, args []string) error {
			// If --config is provided, load from file first, then flags override.
			if configFile != "" {
				fileCfg, err := LoadConfigFile(configFile)
				if err != nil {
					return err
				}
				*cfg = *fileCfg
			}
			cfg.Reprovision = reprovision
			cfg.ControlSocket = controlSocket

			var err error
			appStatus := NewAppStatus()
			if dryRun {
				err = runDryRun(cmd.Context(), cfg, appStatus)
			} else {
				err = run(cmd.Context(), cfg, appStatus)
			}
			cfg.Logger().Info("shutdown complete")
			return err
		},
		SilenceUsage: true,
	}

	// Register all CLI flags. When a YAML config file is also provided,
	// flag values take precedence over file values for any explicitly set flags.
	flags := rootCmd.Flags()
	flags.StringVar(&configFile, "config", "", "Path to YAML config file")
	flags.StringVar(&cfg.RegistrationURL, "url", "", "GitHub org or repo URL for scale set registration")
	flags.StringVar(&cfg.Name, "name", "", "Scale set name (also the runs-on label)")
	flags.StringVar(&cfg.AppClientID, "app-client-id", "", "GitHub App Client ID")
	flags.Int64Var(&cfg.AppInstallationID, "app-installation-id", 0, "GitHub App Installation ID")
	flags.StringVar(&cfg.AppPrivateKeyPath, "app-private-key-path", "", "Path to GitHub App private key PEM file")
	flags.StringVar(&cfg.AppPrivateKey, "app-private-key", "", "GitHub App private key PEM contents (alternative to --app-private-key-path)")
	flags.StringVar(&cfg.Token, "token", "", "Personal access token (alternative to GitHub App)")
	flags.StringVar(&cfg.BaseImage, "base-image", DefaultBaseImage, "Tart VM image name to clone for each runner")
	flags.IntVar(&cfg.MaxRunners, "max-runners", cfg.MaxRunners, "Maximum concurrent VMs")
	flags.IntVar(&cfg.MinRunners, "min-runners", cfg.MinRunners, "Warm pool size")
	flags.StringSliceVar(&cfg.Labels, "labels", nil, "Additional labels for workflow targeting")
	flags.StringVar(&cfg.RunnerGroup, "runner-group", cfg.RunnerGroup, "GitHub runner group name")
	flags.StringVar(&cfg.RunnerPrefix, "runner-prefix", cfg.RunnerPrefix, "VM name prefix (used for orphan detection)")
	flags.StringVar(&cfg.LogLevel, "log-level", cfg.LogLevel, "Log level: debug, info, warn, error")
	flags.StringVar(&cfg.TartPath, "tart-path", "", "Path to tart binary (default: look up in PATH)")
	flags.StringVar(&cfg.LogFormat, "log-format", cfg.LogFormat, "Log format: text or json")
	flags.StringVar(&cfg.Provisioning.ScriptsDir, "scripts-dir", "", "Directory containing custom bake.d/ and hooks/ scripts")
	flags.BoolVar(&cfg.Provisioning.SkipBuiltinScripts, "skip-builtin-scripts", false, "Disable built-in provisioning scripts (use only user scripts)")
	flags.StringVar(&controlSocket, "control-socket", "", "Path for Unix domain socket control API")
	flags.BoolVar(&dryRun, "dry-run", false, "Simulate the full lifecycle without real GitHub or tart")
	flags.BoolVar(&reprovision, "reprovision", false, "Force re-provisioning of the prepared VM image")

	// Set up a context that cancels on SIGINT/SIGTERM for graceful shutdown.
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	if err := rootCmd.ExecuteContext(ctx); err != nil {
		os.Exit(1)
	}
}
