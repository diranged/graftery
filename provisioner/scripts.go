package provisioner

import (
	"embed"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Script represents a single executable provisioning script with its content
// loaded into memory. The Name field is the bare filename (e.g.,
// "01-startup-script.sh") which determines execution order since scripts are
// sorted lexicographically. Source tracks provenance for logging and merge
// conflict resolution.
type Script struct {
	Name    string // Bare filename, e.g., "01-startup-script.sh". Controls sort order.
	Content []byte // Full script content, ready to be written into the VM.
	Source  string // Provenance: "embedded", "user", or "generated".
}

// ScriptLoader handles the two-layer script resolution strategy:
//
//  1. Embedded scripts compiled into the binary provide sensible defaults.
//  2. User scripts on disk can extend or override the defaults.
//
// The merge algorithm uses filename as the key: when both layers contain a
// script with the same name, the user version wins (allowing customization
// without forking). Scripts are always returned in lexicographic order by
// filename, so numeric prefixes (01-, 02-, ...) control execution order.
type ScriptLoader struct {
	embeddedFS     embed.FS
	userScriptsDir string // Empty string means no user overrides are loaded.
	skipBuiltin    bool   // When true, embedded scripts are skipped entirely.
}

// NewScriptLoader creates a loader that merges embedded and user scripts.
// The userScriptsDir should point to the root of the user's scripts directory
// (mirroring the embedded layout: bake.d/, hooks/pre.d/, hooks/post.d/).
func NewScriptLoader(userScriptsDir string, skipBuiltin bool) *ScriptLoader {
	return &ScriptLoader{
		embeddedFS:     embeddedScripts,
		userScriptsDir: userScriptsDir,
		skipBuiltin:    skipBuiltin,
	}
}

// LoadBakeScripts returns the merged bake.d/ scripts in lexicographic order.
// These are the main provisioning scripts that run inside the VM during image
// preparation (e.g., installing packages, configuring the runner).
func (sl *ScriptLoader) LoadBakeScripts() ([]Script, error) {
	return sl.loadScripts(embeddedScriptsPrefix + bakeScriptsSubdir)
}

// LoadHookScripts returns the merged hook scripts for a given subdirectory
// (e.g., "hooks/pre.d" or "hooks/post.d") in lexicographic order.
func (sl *ScriptLoader) LoadHookScripts(subdir string) ([]Script, error) {
	return sl.loadScripts(embeddedScriptsPrefix + subdir)
}

// loadScripts implements the two-layer merge algorithm for a given subdirectory:
//
//  1. Load embedded scripts from the compiled-in FS (unless skipBuiltin is set).
//  2. Load user scripts from disk (if the corresponding directory exists).
//  3. Merge using a map keyed by filename — since user scripts are loaded
//     second, they overwrite any embedded script with the same name.
//  4. Sort the final list by filename to ensure deterministic execution order.
//
// The embeddedDir parameter uses the embedded FS path convention (e.g.,
// "scripts/bake.d"). The corresponding user directory strips the "scripts/"
// prefix, so the user just needs bake.d/ at the root of their scripts dir.
func (sl *ScriptLoader) loadScripts(embeddedDir string) ([]Script, error) {
	merged := make(map[string]Script)

	// Layer 1: Embedded (compiled-in) scripts provide the defaults.
	if !sl.skipBuiltin {
		entries, err := fs.ReadDir(sl.embeddedFS, embeddedDir)
		if err != nil {
			// Some embedded directories may legitimately not exist (e.g.,
			// hooks/pre.d when no default pre-hooks are shipped).
			if !os.IsNotExist(err) && !strings.Contains(err.Error(), "does not exist") {
				return nil, fmt.Errorf("reading embedded %s: %w", embeddedDir, err)
			}
		} else {
			for _, entry := range entries {
				if entry.IsDir() {
					continue
				}
				content, err := fs.ReadFile(sl.embeddedFS, filepath.Join(embeddedDir, entry.Name()))
				if err != nil {
					return nil, fmt.Errorf("reading embedded script %s: %w", entry.Name(), err)
				}
				merged[entry.Name()] = Script{
					Name:    entry.Name(),
					Content: content,
					Source:  scriptSourceEmbedded,
				}
			}
		}
	}

	// Layer 2: User scripts from disk override embedded ones on filename collision.
	if sl.userScriptsDir != "" {
		// The user dir mirrors the embedded structure but without the "scripts/" prefix.
		// e.g., embedded "scripts/bake.d/" maps to user "<dir>/bake.d/"
		userDir := filepath.Join(sl.userScriptsDir, strings.TrimPrefix(embeddedDir, embeddedScriptsPrefix))
		entries, err := os.ReadDir(userDir)
		if err != nil {
			if !os.IsNotExist(err) {
				return nil, fmt.Errorf("reading user scripts %s: %w", userDir, err)
			}
			// Directory doesn't exist — no user overrides for this category.
		} else {
			for _, entry := range entries {
				if entry.IsDir() {
					continue
				}
				content, err := os.ReadFile(filepath.Join(userDir, entry.Name()))
				if err != nil {
					return nil, fmt.Errorf("reading user script %s: %w", entry.Name(), err)
				}
				// This overwrites any embedded script with the same filename,
				// giving the user full control over individual scripts.
				merged[entry.Name()] = Script{
					Name:    entry.Name(),
					Content: content,
					Source:  scriptSourceUser,
				}
			}
		}
	}

	// Flatten the map and sort by filename for deterministic execution order.
	scripts := make([]Script, 0, len(merged))
	for _, s := range merged {
		scripts = append(scripts, s)
	}
	sort.Slice(scripts, func(i, j int) bool {
		return scripts[i].Name < scripts[j].Name
	})

	return scripts, nil
}

// AllScriptContents returns the concatenated content of all bake + hook
// scripts, suitable for computing a content-addressed hash. The output is
// deterministic: scripts are sorted by name within each category, and
// categories are iterated in a fixed order (bake.d, hooks/pre.d, hooks/post.d).
//
// Each script contributes its filename and content, separated by null bytes,
// so that renaming a script or changing its content both produce a different
// hash. This drives the staleness detection in hash.go.
func (sl *ScriptLoader) AllScriptContents() ([]byte, error) {
	var all []byte

	bake, err := sl.LoadBakeScripts()
	if err != nil {
		return nil, err
	}
	for _, s := range bake {
		// Include the filename so that renaming a script invalidates the hash
		// even if content is identical. Null byte separators prevent ambiguity
		// between name and content boundaries.
		all = append(all, []byte(s.Name)...)
		all = append(all, 0)
		all = append(all, s.Content...)
		all = append(all, 0)
	}

	for _, hookDir := range []string{hooksPreSubdir, hooksPostSubdir} {
		hooks, err := sl.LoadHookScripts(hookDir)
		if err != nil {
			return nil, err
		}
		for _, s := range hooks {
			all = append(all, []byte(s.Name)...)
			all = append(all, 0)
			all = append(all, s.Content...)
			all = append(all, 0)
		}
	}

	return all, nil
}
