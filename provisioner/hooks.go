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

// Hook scripts are now handled entirely via the shared directory mount:
//
// 1. The provisioner writes hook scripts to the host staging directory
//    at hooks/pre.d/ and hooks/post.d/
// 2. The staging directory is mounted into the VM via tart --dir
// 3. The static bake script 03-install-hooks.sh copies them from the
//    mount into /opt/arc-runner/hooks/ and configures the runner's .env
//
// No dynamic bash generation (GenerateHookInstaller) is needed anymore.
// The 03-install-hooks.sh script is a real file in scripts/bake.d/,
// not a Go-generated script.
