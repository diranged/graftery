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

// Package provisioner implements the "bake and cache" strategy for preparing
// macOS VM images. It takes a base tart VM image, clones it, boots the clone,
// runs provisioning scripts inside the guest via a shared directory mount,
// and persists the result as a locally cached "prepared" image.
//
// The prepared image name includes a content hash of all inputs (base image +
// scripts), so any change to scripts or base image automatically triggers
// reprovisioning. Multiple configs with different scripts get different images.
package provisioner

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// Provisioner is the public interface consumed by the runner orchestrator (run.go).
type Provisioner interface {
	EnsurePreparedImage(ctx context.Context) (imageName string, err error)
}

// Config holds provisioner-specific configuration.
type Config struct {
	BaseImage          string
	PreparedImageName  string // Override for the image name (empty = auto with hash)
	ScriptsDir         string
	SkipBuiltinScripts bool
	Reprovision        bool
}

// DefaultProvisioner implements Provisioner using tart VMs and the bake.d
// script model. Scripts are transferred into the VM via a shared directory
// mount — no dynamic bash generation or heredoc escaping needed.
type DefaultProvisioner struct {
	logger       *slog.Logger
	cfg          Config
	tart         TartOperations
	scriptLoader *ScriptLoader
}

// New creates a DefaultProvisioner.
func New(logger *slog.Logger, cfg Config, tart TartOperations) *DefaultProvisioner {
	return &DefaultProvisioner{
		logger:       logger,
		cfg:          cfg,
		tart:         tart,
		scriptLoader: NewScriptLoader(cfg.ScriptsDir, cfg.SkipBuiltinScripts),
	}
}

// imageBaseName generates a base name from the image reference, stripping
// the registry prefix and replacing non-alphanumeric chars with hyphens.
// e.g., "ghcr.io/cirruslabs/macos-runner:sonoma" -> "macos-runner-sonoma"
func imageBaseName(baseImage string) string {
	name := baseImage
	if idx := strings.LastIndex(name, "/"); idx >= 0 {
		name = name[idx+1:]
	}
	re := regexp.MustCompile(`[^a-zA-Z0-9]+`)
	name = re.ReplaceAllString(name, "-")
	return strings.Trim(name, "-")
}

// preparedImageName returns the tart VM name for the prepared image.
// If the user set an explicit name, use it. Otherwise, generate one
// from the base image name + a short content hash, e.g.:
// "arc-prepared-macos-runner-sonoma-a1b2c3d4"
func (p *DefaultProvisioner) preparedImageName(hash string) string {
	if p.cfg.PreparedImageName != "" {
		return p.cfg.PreparedImageName
	}
	shortHash := hash
	if len(shortHash) > 8 {
		shortHash = shortHash[:8]
	}
	return preparedImagePrefix + imageBaseName(p.cfg.BaseImage) + "-" + shortHash
}

// EnsurePreparedImage returns the name of a local tart VM that is ready to
// clone for runner jobs. The image name includes a content hash of all inputs,
// so any change to scripts or base image automatically creates a new image.
func (p *DefaultProvisioner) EnsurePreparedImage(ctx context.Context) (string, error) {
	// Load all scripts — needed for both hash computation and execution.
	bakeScripts, err := p.loadBakeScripts()
	if err != nil {
		return "", fmt.Errorf("loading bake scripts: %w", err)
	}
	preHooks, postHooks, err := p.loadHookScripts()
	if err != nil {
		return "", fmt.Errorf("loading hook scripts: %w", err)
	}

	// Compute hash over base image + all script contents.
	allContent, err := p.scriptLoader.AllScriptContents()
	if err != nil {
		return "", fmt.Errorf("computing script contents: %w", err)
	}
	hash := computeConfigHash(p.cfg.BaseImage, allContent)
	imageName := p.preparedImageName(hash)

	// Check if a prepared image with this hash already exists.
	if !p.cfg.Reprovision {
		if p.imageExists(ctx, imageName) {
			p.logger.Info("prepared image is up to date, skipping provisioning",
				"image", imageName, "hash", hash[:8])
			return imageName, nil
		}
	} else {
		p.logger.Info("--reprovision flag set, forcing image rebuild")
	}

	p.logger.Info("starting image provisioning",
		"base", p.cfg.BaseImage,
		"prepared", imageName,
		"bake_scripts", len(bakeScripts),
		"hash", hash[:8],
	)

	// Clean up any old prepared images for this base image.
	p.cleanupOldImages(ctx, imageName)

	start := time.Now()
	if err := p.provision(ctx, imageName, bakeScripts, preHooks, postHooks); err != nil {
		p.logger.Error("provisioning failed, cleaning up",
			"error", err,
			"elapsed", time.Since(start).Round(time.Second),
		)
		p.cleanupImage(ctx, imageName)
		return "", err
	}

	p.logger.Info("provisioning complete",
		"image", imageName,
		"elapsed", time.Since(start).Round(time.Second),
	)
	return imageName, nil
}

// loadBakeScripts returns the merged bake.d/ scripts.
func (p *DefaultProvisioner) loadBakeScripts() ([]Script, error) {
	return p.scriptLoader.LoadBakeScripts()
}

// loadHookScripts returns all merged hook scripts (pre.d + post.d).
func (p *DefaultProvisioner) loadHookScripts() (preHooks, postHooks []Script, err error) {
	pre, err := p.scriptLoader.LoadHookScripts(hooksPreSubdir)
	if err != nil {
		return nil, nil, err
	}
	post, err := p.scriptLoader.LoadHookScripts(hooksPostSubdir)
	if err != nil {
		return nil, nil, err
	}
	return pre, post, nil
}

// imageExists checks if a tart VM with the given name exists locally.
func (p *DefaultProvisioner) imageExists(ctx context.Context, name string) bool {
	vms, err := p.tart.List(ctx, "")
	if err != nil {
		return false
	}
	for _, vm := range vms {
		if vm.Name == name {
			return true
		}
	}
	return false
}

// cleanupOldImages deletes any arc-prepared-* images that don't match the
// current image name. This prevents accumulation of stale images.
func (p *DefaultProvisioner) cleanupOldImages(ctx context.Context, keepName string) {
	prefix := preparedImagePrefix + imageBaseName(p.cfg.BaseImage)
	vms, err := p.tart.List(ctx, prefix)
	if err != nil {
		return
	}
	for _, vm := range vms {
		if vm.Name != keepName {
			p.logger.Info("removing old prepared image", "image", vm.Name)
			_ = p.tart.Delete(ctx, p.logger, vm.Name)
		}
	}
}

// provision runs the full provisioning flow using a shared directory mount
// to transfer scripts into the VM. No dynamic bash generation needed.
func (p *DefaultProvisioner) provision(ctx context.Context, imageName string, bakeScripts []Script, preHooks, postHooks []Script) error {
	// Delete any existing image with this name.
	_ = p.tart.Delete(ctx, p.logger, imageName)

	// Step 1: Clone base image.
	p.logger.Info("[1/4] Cloning base image", "base", p.cfg.BaseImage)
	cloneStart := time.Now()
	if err := p.tart.Clone(ctx, p.logger, p.cfg.BaseImage, imageName); err != nil {
		return fmt.Errorf("cloning base image: %w", err)
	}
	p.logger.Info("[1/4] Clone complete",
		"elapsed", time.Since(cloneStart).Round(time.Second))

	// Step 2: Write all scripts to a staging directory on the host.
	// This directory will be mounted into the VM as a shared directory.
	stagingDir, err := os.MkdirTemp("", bakeStagingPrefix)
	if err != nil {
		return fmt.Errorf("creating staging dir: %w", err)
	}
	defer os.RemoveAll(stagingDir)

	if err := p.writeScriptsToStaging(stagingDir, bakeScripts, preHooks, postHooks); err != nil {
		return fmt.Errorf("writing scripts to staging: %w", err)
	}

	// Step 3: Boot the VM with the scripts directory mounted.
	p.logger.Info("[2/4] Booting VM for provisioning")
	vmErr := make(chan error, 1)
	go func() {
		// Mount the staging dir as "scripts" — appears at
		// /Volumes/My Shared Files/scripts/ inside the guest.
		vmErr <- p.tart.Run(ctx, p.logger, imageName, stagingDir)
	}()

	// Wait for guest agent.
	p.logger.Info("[3/4] Waiting for macOS to boot and guest agent to start")
	bootStart := time.Now()
	if err := p.waitForGuestAgent(ctx, imageName); err != nil {
		p.tart.Stop(ctx, p.logger, imageName)
		<-vmErr
		return fmt.Errorf("waiting for guest agent: %w", err)
	}
	p.logger.Info("[3/4] VM booted, guest agent ready",
		"boot_time", time.Since(bootStart).Round(time.Second))

	// Step 4: Execute bake scripts from the shared mount.
	p.logger.Info("[4/4] Running bake scripts", "count", len(bakeScripts))
	if err := p.RunBakeScripts(ctx, imageName, bakeScripts); err != nil {
		p.tart.Stop(ctx, p.logger, imageName)
		<-vmErr
		return err
	}

	// Shut down the VM cleanly.
	p.logger.Info("Shutting down provisioned VM")
	_ = p.tart.ExecQuiet(ctx, imageName, "sudo", guestShutdownBin, "-h", "now")

	if err := <-vmErr; err != nil {
		p.logger.Debug("VM exited after provisioning shutdown", "error", err)
	}

	return nil
}

// writeScriptsToStaging writes all bake and hook scripts to the staging
// directory so they can be mounted into the VM via --dir.
func (p *DefaultProvisioner) writeScriptsToStaging(stagingDir string, bakeScripts []Script, preHooks, postHooks []Script) error {
	// Write bake scripts to bake.d/
	bakeDir := filepath.Join(stagingDir, bakeScriptsSubdir)
	if err := os.MkdirAll(bakeDir, 0755); err != nil {
		return err
	}
	for _, s := range bakeScripts {
		if err := os.WriteFile(filepath.Join(bakeDir, s.Name), s.Content, 0755); err != nil {
			return fmt.Errorf("writing bake script %s: %w", s.Name, err)
		}
	}

	// Write hook scripts to hooks/pre.d/ and hooks/post.d/
	for _, subdir := range []struct {
		dir     string
		scripts []Script
	}{
		{hooksPreSubdir, preHooks},
		{hooksPostSubdir, postHooks},
	} {
		dir := filepath.Join(stagingDir, subdir.dir)
		if err := os.MkdirAll(dir, 0755); err != nil {
			return err
		}
		for _, s := range subdir.scripts {
			if err := os.WriteFile(filepath.Join(dir, s.Name), s.Content, 0755); err != nil {
				return fmt.Errorf("writing hook script %s: %w", s.Name, err)
			}
		}
	}

	return nil
}

// waitForGuestAgent polls tart exec until the guest agent responds.
func (p *DefaultProvisioner) waitForGuestAgent(ctx context.Context, vmName string) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(guestAgentInitialWaitSeconds * time.Second):
	}

	start := time.Now()
	for i := 1; i <= guestAgentMaxAttempts; i++ {
		if err := p.tart.ExecQuiet(ctx, vmName, guestAgentReadyCommand, guestAgentReadyArg); err == nil {
			return nil
		}
		elapsed := time.Since(start).Round(time.Second)
		if i%guestAgentLogInterval == 0 {
			p.logger.Info("still waiting for guest agent", "elapsed", elapsed)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(guestAgentPollIntervalSeconds * time.Second):
		}
	}
	return fmt.Errorf("guest agent not ready after %s", time.Since(start).Round(time.Second))
}

// cleanupImage removes a prepared image (used after provisioning failure).
func (p *DefaultProvisioner) cleanupImage(ctx context.Context, imageName string) {
	p.logger.Info("cleaning up failed provisioning")
	_ = p.tart.Stop(ctx, p.logger, imageName)
	_ = p.tart.Delete(ctx, p.logger, imageName)
}
