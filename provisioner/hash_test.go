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
