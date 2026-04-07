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
	"log/slog"
	"os/exec"

	"github.com/diranged/graftery/provisioner"
)

// TartAdapter bridges the provisioner package and the main package's tart
// functions. The provisioner package defines a TartOperations interface so it
// can run tart commands without importing main (which would create a circular
// dependency). TartAdapter satisfies that interface by forwarding each call to
// the corresponding exported function in tart.go.
//
// This adapter pattern also makes the provisioner independently testable: tests
// can supply a mock TartOperations without needing a real tart binary.
type TartAdapter struct{}

// Clone delegates to TartClone (tart.go).
func (a *TartAdapter) Clone(ctx context.Context, logger *slog.Logger, base, name string) error {
	return TartClone(ctx, logger, base, name)
}

// Run delegates to TartRun (tart.go).
func (a *TartAdapter) Run(ctx context.Context, logger *slog.Logger, name, sharedDir string) error {
	return TartRun(ctx, logger, name, sharedDir)
}

// Exec delegates to TartExec (tart.go), which streams output through the logger.
func (a *TartAdapter) Exec(ctx context.Context, logger *slog.Logger, name string, command ...string) error {
	return TartExec(ctx, logger, name, command...)
}

// ExecQuiet runs tart exec directly without streaming output. Unlike Exec, it
// bypasses the logger entirely -- used by the provisioner for commands where
// output is uninteresting or expected to fail (e.g., readiness probes).
func (a *TartAdapter) ExecQuiet(ctx context.Context, name string, command ...string) error {
	args := append([]string{"exec", name}, command...)
	cmd := exec.CommandContext(ctx, tartBinary, args...)
	return cmd.Run()
}

// Stop delegates to TartStop (tart.go).
func (a *TartAdapter) Stop(ctx context.Context, logger *slog.Logger, name string) error {
	return TartStop(ctx, logger, name)
}

// Delete delegates to TartDelete (tart.go).
func (a *TartAdapter) Delete(ctx context.Context, logger *slog.Logger, name string) error {
	return TartDelete(ctx, logger, name)
}

// List delegates to TartList (tart.go) and converts the result from the main
// package's TartVM type to provisioner.TartVM. This type conversion is needed
// because the provisioner package defines its own TartVM to avoid importing main.
func (a *TartAdapter) List(ctx context.Context, prefix string) ([]provisioner.TartVM, error) {
	vms, err := TartList(ctx, prefix)
	if err != nil {
		return nil, err
	}
	result := make([]provisioner.TartVM, len(vms))
	for i, vm := range vms {
		result[i] = provisioner.TartVM{Name: vm.Name, State: vm.State}
	}
	return result, nil
}
