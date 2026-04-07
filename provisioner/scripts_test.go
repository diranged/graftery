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

package provisioner

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadBakeScripts_EmbeddedOnly(t *testing.T) {
	sl := NewScriptLoader("", false)
	scripts, err := sl.LoadBakeScripts()
	if err != nil {
		t.Fatalf("LoadBakeScripts() error: %v", err)
	}
	if len(scripts) == 0 {
		t.Fatal("expected at least one embedded bake script")
	}

	// Verify scripts are sorted lexicographically.
	for i := 1; i < len(scripts); i++ {
		if scripts[i].Name < scripts[i-1].Name {
			t.Errorf("scripts not sorted: %s came after %s", scripts[i].Name, scripts[i-1].Name)
		}
	}

	// Verify all are marked as embedded.
	for _, s := range scripts {
		if s.Source != "embedded" {
			t.Errorf("script %s has source %q, want %q", s.Name, s.Source, "embedded")
		}
	}

	// Verify expected scripts exist.
	names := make(map[string]bool)
	for _, s := range scripts {
		names[s.Name] = true
	}
	for _, expected := range []string{"01-startup-script.sh", "02-setup-info.py", "03-install-hooks.sh"} {
		if !names[expected] {
			t.Errorf("expected script %s not found", expected)
		}
	}
}

func TestLoadBakeScripts_SkipBuiltin(t *testing.T) {
	sl := NewScriptLoader("", true)
	scripts, err := sl.LoadBakeScripts()
	if err != nil {
		t.Fatalf("LoadBakeScripts() error: %v", err)
	}
	if len(scripts) != 0 {
		t.Errorf("expected 0 scripts with skipBuiltin, got %d", len(scripts))
	}
}

func TestLoadBakeScripts_UserOverride(t *testing.T) {
	// Create a temp dir with a user script that overrides an embedded one.
	tmpDir := t.TempDir()
	bakeDir := filepath.Join(tmpDir, "bake.d")
	if err := os.MkdirAll(bakeDir, 0755); err != nil {
		t.Fatal(err)
	}

	// Override the startup script.
	overrideContent := []byte("#!/bin/bash\necho custom startup\n")
	if err := os.WriteFile(filepath.Join(bakeDir, "01-startup-script.sh"), overrideContent, 0755); err != nil {
		t.Fatal(err)
	}

	// Add a user-only script.
	userContent := []byte("#!/bin/bash\necho user tools\n")
	if err := os.WriteFile(filepath.Join(bakeDir, "50-install-tools.sh"), userContent, 0755); err != nil {
		t.Fatal(err)
	}

	sl := NewScriptLoader(tmpDir, false)
	scripts, err := sl.LoadBakeScripts()
	if err != nil {
		t.Fatalf("LoadBakeScripts() error: %v", err)
	}

	// Find the overridden script.
	var startupScript *Script
	var userScript *Script
	for i := range scripts {
		switch scripts[i].Name {
		case "01-startup-script.sh":
			startupScript = &scripts[i]
		case "50-install-tools.sh":
			userScript = &scripts[i]
		}
	}

	if startupScript == nil {
		t.Fatal("01-startup-script.sh not found in merged scripts")
	}
	if startupScript.Source != "user" {
		t.Errorf("overridden script source = %q, want %q", startupScript.Source, "user")
	}
	if string(startupScript.Content) != string(overrideContent) {
		t.Error("overridden script content does not match user file")
	}

	if userScript == nil {
		t.Fatal("50-install-tools.sh not found in merged scripts")
	}
	if userScript.Source != "user" {
		t.Errorf("user script source = %q, want %q", userScript.Source, "user")
	}

	// Verify ordering: 01, 02, 03 (embedded), 50 (user).
	if len(scripts) < 4 {
		t.Fatalf("expected at least 4 scripts, got %d", len(scripts))
	}
	if scripts[len(scripts)-1].Name != "50-install-tools.sh" {
		t.Errorf("last script should be 50-install-tools.sh, got %s", scripts[len(scripts)-1].Name)
	}
}

func TestLoadBakeScripts_UserOnlyWithSkipBuiltin(t *testing.T) {
	tmpDir := t.TempDir()
	bakeDir := filepath.Join(tmpDir, "bake.d")
	if err := os.MkdirAll(bakeDir, 0755); err != nil {
		t.Fatal(err)
	}

	userContent := []byte("#!/bin/bash\necho custom only\n")
	if err := os.WriteFile(filepath.Join(bakeDir, "01-custom.sh"), userContent, 0755); err != nil {
		t.Fatal(err)
	}

	sl := NewScriptLoader(tmpDir, true)
	scripts, err := sl.LoadBakeScripts()
	if err != nil {
		t.Fatalf("LoadBakeScripts() error: %v", err)
	}
	if len(scripts) != 1 {
		t.Fatalf("expected 1 script, got %d", len(scripts))
	}
	if scripts[0].Name != "01-custom.sh" {
		t.Errorf("expected 01-custom.sh, got %s", scripts[0].Name)
	}
}

func TestLoadBakeScripts_NonexistentUserDir(t *testing.T) {
	sl := NewScriptLoader("/nonexistent/path", false)
	scripts, err := sl.LoadBakeScripts()
	if err != nil {
		t.Fatalf("LoadBakeScripts() should not error for missing user dir: %v", err)
	}
	// Should still return embedded scripts.
	if len(scripts) == 0 {
		t.Fatal("expected embedded scripts even with missing user dir")
	}
}

func TestLoadHookScripts_Embedded(t *testing.T) {
	sl := NewScriptLoader("", false)

	preHooks, err := sl.LoadHookScripts("hooks/pre.d")
	if err != nil {
		t.Fatalf("LoadHookScripts(pre.d) error: %v", err)
	}
	if len(preHooks) == 0 {
		t.Fatal("expected at least one embedded pre-hook")
	}

	postHooks, err := sl.LoadHookScripts("hooks/post.d")
	if err != nil {
		t.Fatalf("LoadHookScripts(post.d) error: %v", err)
	}
	if len(postHooks) == 0 {
		t.Fatal("expected at least one embedded post-hook")
	}
}

func TestAllScriptContents_Deterministic(t *testing.T) {
	sl := NewScriptLoader("", false)

	content1, err := sl.AllScriptContents()
	if err != nil {
		t.Fatalf("AllScriptContents() error: %v", err)
	}

	content2, err := sl.AllScriptContents()
	if err != nil {
		t.Fatalf("AllScriptContents() error: %v", err)
	}

	if string(content1) != string(content2) {
		t.Error("AllScriptContents() is not deterministic")
	}
}
