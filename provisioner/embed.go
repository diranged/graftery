package provisioner

import "embed"

// embeddedScripts contains the built-in provisioning and hook scripts that are
// compiled into the binary at build time via go:embed. These serve as sensible
// defaults for image baking (scripts/bake.d/) and runner job hooks
// (scripts/hooks/pre.d/, scripts/hooks/post.d/).
//
// The ScriptLoader merges these with any user-supplied scripts on disk. When
// a user script has the same filename as an embedded one, the user version
// takes precedence, allowing customization without modifying the binary.
//
//go:embed scripts/*
var embeddedScripts embed.FS
