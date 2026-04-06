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
