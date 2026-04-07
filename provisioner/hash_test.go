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

import "testing"

func TestComputeConfigHash_Deterministic(t *testing.T) {
	content := []byte("base-image\x00script-content\x00")
	h1 := computeConfigHash("ghcr.io/test:latest", content)
	h2 := computeConfigHash("ghcr.io/test:latest", content)
	if h1 != h2 {
		t.Error("hash is not deterministic")
	}
}

func TestComputeConfigHash_DifferentImage(t *testing.T) {
	content := []byte("same-content")
	h1 := computeConfigHash("image-a", content)
	h2 := computeConfigHash("image-b", content)
	if h1 == h2 {
		t.Error("different base images should produce different hashes")
	}
}

func TestComputeConfigHash_DifferentContent(t *testing.T) {
	h1 := computeConfigHash("same-image", []byte("content-a"))
	h2 := computeConfigHash("same-image", []byte("content-b"))
	if h1 == h2 {
		t.Error("different script content should produce different hashes")
	}
}
