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
	"crypto/sha256"
	"fmt"
)

// computeConfigHash returns a SHA-256 hex string over all inputs that affect
// the baked image: the base image name and the concatenated script contents.
// This hash is used as part of the prepared image name, so any change to
// inputs creates a new image automatically.
func computeConfigHash(baseImage string, scriptContents []byte) string {
	h := sha256.New()
	h.Write([]byte(baseImage))
	h.Write([]byte{0})
	h.Write(scriptContents)
	return fmt.Sprintf("%x", h.Sum(nil))
}
