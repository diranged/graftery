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

func TestImageBaseName(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"ghcr.io/cirruslabs/macos-runner:sonoma", "macos-runner-sonoma"},
		{"ghcr.io/org/image:latest", "image-latest"},
		{"local-image", "local-image"},
		{"registry.example.com/path/to/image:v1.2.3", "image-v1-2-3"},
		{"simple", "simple"},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			got := imageBaseName(tt.input)
			if got != tt.want {
				t.Errorf("imageBaseName(%q) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

func TestPreparedImageNameIncludesHash(t *testing.T) {
	p := &DefaultProvisioner{
		cfg: Config{BaseImage: "ghcr.io/cirruslabs/macos-runner:sonoma"},
	}

	hash := "abcdef1234567890"
	name := p.preparedImageName(hash)

	// Should include base name + short hash
	if name != "arc-prepared-macos-runner-sonoma-abcdef12" {
		t.Errorf("preparedImageName = %q, want arc-prepared-macos-runner-sonoma-abcdef12", name)
	}
}

func TestPreparedImageNameExplicitOverride(t *testing.T) {
	p := &DefaultProvisioner{
		cfg: Config{
			BaseImage:         "ghcr.io/test",
			PreparedImageName: "my-custom-name",
		},
	}

	name := p.preparedImageName("anyhash")
	if name != "my-custom-name" {
		t.Errorf("preparedImageName = %q, want my-custom-name", name)
	}
}
