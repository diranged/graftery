package provisioner

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"
	"time"
)

// RunBakeScripts executes each provisioning script inside the VM. Scripts
// are available at /Volumes/My Shared Files/shared/bake.d/ via the shared
// directory mount — no heredoc or file copying needed.
func (p *DefaultProvisioner) RunBakeScripts(ctx context.Context, vmName string, scripts []Script) error {
	total := len(scripts)
	for i, script := range scripts {
		step := i + 1
		p.logger.Info(fmt.Sprintf("running bake script (%d/%d)", step, total),
			"script", script.Name,
			"source", script.Source,
		)

		start := time.Now()
		if err := p.runScriptFromMount(ctx, vmName, script); err != nil {
			return fmt.Errorf("bake script %s (%d/%d) failed: %w", script.Name, step, total, err)
		}

		p.logger.Info(fmt.Sprintf("bake script complete (%d/%d)", step, total),
			"script", script.Name,
			"duration", time.Since(start).Round(time.Millisecond),
		)
	}
	return nil
}

// runScriptFromMount executes a script from the shared directory mount.
// No heredoc or file transfer needed — the script is already available
// in the guest filesystem via the tart --dir mount.
func (p *DefaultProvisioner) runScriptFromMount(ctx context.Context, vmName string, script Script) error {
	guestPath := filepath.Join(sharedMountPath, bakeScriptsSubdir, script.Name)

	interpreter := interpreterBash
	ext := strings.ToLower(filepath.Ext(script.Name))
	if ext == pythonExtension {
		interpreter = interpreterPython
	}

	cmd := fmt.Sprintf(
		"%s=%q %s=%s %s %q",
		envArcBaseImage, p.cfg.BaseImage,
		envGrafteryDir, defaultRunnerDir,
		interpreter, guestPath,
	)
	return p.tart.Exec(ctx, p.logger, vmName, interpreterBash, "-c", cmd)
}
