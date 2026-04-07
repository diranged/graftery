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
