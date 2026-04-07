#!/bin/bash

# Copyright 2026 Matt Wise
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Generates AppIcon.icns from a source PNG.
# Usage: ./generate-icons.sh [source.png]
#
# If no source PNG is provided, creates a simple placeholder icon.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ICONSET_DIR="$SCRIPT_DIR/AppIcon.iconset"
ICNS_FILE="$SCRIPT_DIR/AppIcon.icns"

SOURCE_PNG="${1:-}"

if [ -z "$SOURCE_PNG" ]; then
    # Generate a simple placeholder: white circle with "ARC" text on blue background
    SOURCE_PNG="$SCRIPT_DIR/_icon_source.png"

    # Use Python to create a simple icon if available
    python3 -c "
import struct, zlib

def create_png(width, height):
    '''Create a simple blue square PNG with rounded appearance.'''
    raw = []
    cx, cy = width // 2, height // 2
    r = min(cx, cy) - 2
    for y in range(height):
        row = bytearray([0])  # filter byte
        for x in range(width):
            dx, dy = x - cx, y - cy
            dist = (dx*dx + dy*dy) ** 0.5
            if dist <= r:
                # Blue gradient
                row.extend([30, 100, 220, 255])
            else:
                row.extend([0, 0, 0, 0])
        raw.append(bytes(row))

    raw_data = b''.join(raw)

    def chunk(chunk_type, data):
        c = chunk_type + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)

    ihdr = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)
    return (b'\x89PNG\r\n\x1a\n' +
            chunk(b'IHDR', ihdr) +
            chunk(b'IDAT', zlib.compress(raw_data)) +
            chunk(b'IEND', b''))

with open('$SOURCE_PNG', 'wb') as f:
    f.write(create_png(1024, 1024))
" 2>/dev/null || {
        echo "Warning: Could not generate placeholder icon. Please provide a source PNG."
        echo "Usage: $0 <source-1024x1024.png>"
        exit 0
    }
    echo "Generated placeholder icon at $SOURCE_PNG"
fi

# Create iconset directory
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

# Generate all required sizes
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$SOURCE_PNG" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null 2>&1
    double=$((size * 2))
    sips -z "$double" "$double" "$SOURCE_PNG" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null 2>&1
done

# Convert to icns
iconutil -c icns "$ICONSET_DIR" -o "$ICNS_FILE"
rm -rf "$ICONSET_DIR"

# Clean up generated placeholder if we made one
if [ -z "${1:-}" ] && [ -f "$SCRIPT_DIR/_icon_source.png" ]; then
    rm "$SCRIPT_DIR/_icon_source.png"
fi

echo "Created $ICNS_FILE"
