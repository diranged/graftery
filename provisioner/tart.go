package provisioner

import (
	"context"
	"log/slog"
)

// TartVM holds minimal VM metadata needed by the provisioner for staleness
// checks and lifecycle management. It intentionally carries only the fields
// the provisioner needs, not the full tart output.
type TartVM struct {
	Name  string // Local tart VM name.
	State string // VM state as reported by `tart list` (e.g., "stopped").
}

// TartOperations abstracts the tart CLI into an interface for two reasons:
//
//  1. Import cycle prevention: the main tart wrapper in the root package
//     imports provisioner. If provisioner imported the root package back to
//     use the tart wrapper directly, Go would reject the circular dependency.
//     This interface breaks the cycle — the root package injects its tart
//     wrapper as a TartOperations implementation.
//
//  2. Testability: tests can supply a mock implementation that records calls
//     and returns canned responses without needing a real tart binary or VM.
//
// Each method corresponds to a tart CLI subcommand. Methods that produce
// user-visible output accept a logger; ExecQuiet is used for polling where
// failures are expected and logging would be noisy.
type TartOperations interface {
	// Clone creates a new local VM by cloning a base image (local or remote).
	Clone(ctx context.Context, logger *slog.Logger, base, name string) error
	// Run boots a VM in the foreground. Blocks until the VM shuts down.
	Run(ctx context.Context, logger *slog.Logger, name, sharedDir string) error
	// Exec runs a command inside a running VM via the tart guest agent.
	Exec(ctx context.Context, logger *slog.Logger, name string, command ...string) error
	// ExecQuiet runs a command inside a running VM without logging output.
	// Used for polling (e.g., waiting for the guest agent to become responsive).
	ExecQuiet(ctx context.Context, name string, command ...string) error
	// Stop requests a VM to stop (equivalent to pulling the power cord).
	Stop(ctx context.Context, logger *slog.Logger, name string) error
	// Delete removes a local VM image.
	Delete(ctx context.Context, logger *slog.Logger, name string) error
	// List returns all local VMs, optionally filtered by a name prefix.
	List(ctx context.Context, prefix string) ([]TartVM, error)
}
