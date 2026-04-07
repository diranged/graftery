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
	"testing"
)

// TestTartRunArgs verifies the shared argument builder for tart run commands.
func TestTartRunArgs_NoSharedDir(t *testing.T) {
	args := tartRunArgs("my-vm", "")

	if len(args) != 3 {
		t.Fatalf("args length = %d, want 3", len(args))
	}
	if args[0] != "run" {
		t.Errorf("args[0] = %q, want %q", args[0], "run")
	}
	if args[1] != TartRunNoGraphicsFlag {
		t.Errorf("args[1] = %q, want %q", args[1], TartRunNoGraphicsFlag)
	}
	if args[2] != "my-vm" {
		t.Errorf("args[2] = %q, want %q", args[2], "my-vm")
	}
}

// TestTartRunArgs_WithSharedDir verifies the --dir flag is added when a
// shared directory is specified.
func TestTartRunArgs_WithSharedDir(t *testing.T) {
	args := tartRunArgs("my-vm", "/tmp/shared")

	if len(args) != 4 {
		t.Fatalf("args length = %d, want 4", len(args))
	}
	expected := "--dir=shared:/tmp/shared"
	if args[2] != expected {
		t.Errorf("args[2] = %q, want %q", args[2], expected)
	}
	if args[3] != "my-vm" {
		t.Errorf("args[3] = %q, want %q", args[3], "my-vm")
	}
}
