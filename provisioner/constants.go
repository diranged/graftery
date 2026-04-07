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

// ---------------------------------------------------------------------------
// VM shared directory paths
// ---------------------------------------------------------------------------

const (
	// sharedMountPath is where the host's staging directory appears inside
	// the guest VM. Tart mounts --dir=shared:/path at this location.
	sharedMountPath = "/Volumes/My Shared Files/shared"
)

// ---------------------------------------------------------------------------
// Provisioning directories and prefixes
// ---------------------------------------------------------------------------

const (
	// preparedImagePrefix is the prefix used for auto-generated prepared
	// image names (followed by the sanitized base image name and hash).
	preparedImagePrefix = "arc-prepared-"

	// bakeStagingPrefix is the prefix for the temp directory used to stage
	// scripts before mounting into the VM.
	bakeStagingPrefix = "arc-bake-"

	// bakeScriptsSubdir is the subdirectory name for bake scripts inside
	// the staging directory and embedded FS.
	bakeScriptsSubdir = "bake.d"

	// hooksPreSubdir is the subdirectory path for pre-job hook scripts.
	hooksPreSubdir = "hooks/pre.d"

	// hooksPostSubdir is the subdirectory path for post-job hook scripts.
	hooksPostSubdir = "hooks/post.d"

	// embeddedScriptsPrefix is the path prefix for embedded scripts in
	// the compiled-in filesystem.
	embeddedScriptsPrefix = "scripts/"
)

// ---------------------------------------------------------------------------
// Script interpreters
// ---------------------------------------------------------------------------

const (
	// interpreterBash is the default interpreter for provisioning scripts.
	interpreterBash = "bash"

	// interpreterPython is the interpreter used for .py scripts.
	interpreterPython = "python3"

	// pythonExtension is the file extension that selects the Python
	// interpreter.
	pythonExtension = ".py"
)

// ---------------------------------------------------------------------------
// Guest VM environment and paths
// ---------------------------------------------------------------------------

const (
	// envArcBaseImage is the environment variable name set when running
	// bake scripts, containing the upstream base image reference.
	envArcBaseImage = "ARC_BASE_IMAGE"

	// envGrafteryDir is the environment variable name set when running
	// bake scripts, containing the path to the runner installation.
	envGrafteryDir = "GRAFTERY_DIR"

	// defaultRunnerDir is the default path to the GitHub Actions runner
	// installation inside the guest VM.
	defaultRunnerDir = "/Users/admin/actions-runner"

	// guestShutdownCommand is the shutdown command executed inside the VM
	// after provisioning completes.
	guestShutdownBin = "/sbin/shutdown"
)

// ---------------------------------------------------------------------------
// Script source labels
// ---------------------------------------------------------------------------

const (
	// scriptSourceEmbedded identifies scripts compiled into the binary.
	scriptSourceEmbedded = "embedded"

	// scriptSourceUser identifies scripts loaded from the user's disk.
	scriptSourceUser = "user"
)

// ---------------------------------------------------------------------------
// Guest agent polling
// ---------------------------------------------------------------------------

const (
	// guestAgentReadyCommand is the command used to probe the guest agent.
	guestAgentReadyCommand = "echo"

	// guestAgentReadyArg is the argument passed to the readiness probe.
	guestAgentReadyArg = "ready"

	// guestAgentMaxAttempts is the maximum number of guest agent polls.
	guestAgentMaxAttempts = 60

	// guestAgentPollIntervalSeconds is seconds between guest agent polls.
	guestAgentPollIntervalSeconds = 2

	// guestAgentLogInterval is the number of attempts between progress logs.
	guestAgentLogInterval = 10

	// guestAgentInitialWaitSeconds is the initial delay before the first
	// guest agent poll (to let the VM boot).
	guestAgentInitialWaitSeconds = 5
)
