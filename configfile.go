package main

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/actions/scaleset"
	"github.com/adrg/xdg"
	"gopkg.in/yaml.v3"
)

// DefaultConfigDir returns the platform-appropriate configuration directory
// for this app. Uses XDG Base Directory Specification:
//   - macOS: ~/Library/Application Support/graftery (default)
//   - Linux: ~/.config/graftery
//   - Overridable via $XDG_CONFIG_HOME
func DefaultConfigDir() string {
	return filepath.Join(xdg.ConfigHome, AppName)
}

// DefaultConfigPath returns the default path for the config file.
func DefaultConfigPath() string {
	return filepath.Join(DefaultConfigDir(), ConfigFileName)
}

// LoadConfigFile reads a YAML config file and returns a Config struct. Defaults
// are pre-populated before unmarshaling so that omitted fields get sensible
// values rather than zero values.
func LoadConfigFile(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading config file %s: %w", path, err)
	}

	// Pre-populate defaults; YAML unmarshal will overwrite any fields present in the file.
	cfg := &Config{
		MaxRunners:   DefaultMaxRunners,
		MinRunners:   DefaultMinRunners,
		RunnerPrefix: DefaultRunnerPrefix,
		RunnerGroup:  scaleset.DefaultRunnerGroup,
		LogLevel:     DefaultLogLevel,
		LogFormat:    DefaultLogFormat,
	}

	if err := yaml.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("parsing config file %s: %w", path, err)
	}

	return cfg, nil
}

// SaveConfigFile writes a Config to a YAML file, creating parent directories
// as needed. The file is prefixed with a human-readable header comment and
// written with 0640 permissions (owner read/write, group read).
func SaveConfigFile(path string, cfg *Config) error {
	if err := os.MkdirAll(filepath.Dir(path), 0750); err != nil {
		return fmt.Errorf("creating config directory: %w", err)
	}

	data, err := yaml.Marshal(cfg)
	if err != nil {
		return fmt.Errorf("marshaling config: %w", err)
	}

	return os.WriteFile(path, append([]byte(ConfigFileHeader), data...), 0640)
}

// EnsureConfigFile creates a default config file if one does not already exist
// at the given path. If path is empty, the platform default is used. This is
// called on first launch to bootstrap a config that the user can then edit.
func EnsureConfigFile(path string) (string, error) {
	if path == "" {
		path = DefaultConfigPath()
	}

	// If the file already exists, nothing to do.
	if _, err := os.Stat(path); err == nil {
		return path, nil
	}

	// Write a skeleton config with sensible defaults.
	cfg := &Config{
		MaxRunners:   DefaultMaxRunners,
		MinRunners:   DefaultMinRunners,
		RunnerPrefix: DefaultRunnerPrefix,
		RunnerGroup:  scaleset.DefaultRunnerGroup,
		LogLevel:     DefaultLogLevel,
		LogFormat:    DefaultLogFormat,
	}

	if err := SaveConfigFile(path, cfg); err != nil {
		return "", err
	}

	return path, nil
}
