#!/usr/bin/env bash
# Rebuilds Resources/AppIcon.icns from Resources/icon_master.png (1024×1024).
# Only needed when the master image changes; the .icns is committed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET="$ROOT/build/icon.iconset"
MASTER="$ROOT/Resources/icon_master.png"
OUT="$ROOT/Resources/AppIcon.icns"

if [[ ! -f "$MASTER" ]]; then
  echo "Missing $MASTER"
  exit 1
fi

rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$MASTER" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$MASTER" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done

# sips and iconutil both add Exif chunks to the PNGs they write. Keep only the chunks
# that carry pixels, and assemble the .icns container directly so nothing is re-added.
python3 - "$ICONSET" "$OUT" <<'PY'
import struct, sys
from pathlib import Path
KEEP = {b'IHDR', b'PLTE', b'tRNS', b'sRGB', b'IDAT', b'IEND'}
TYPES = [
    (b'icp4', 'icon_16x16.png'), (b'icp5', 'icon_32x32.png'),
    (b'ic07', 'icon_128x128.png'), (b'ic08', 'icon_256x256.png'),
    (b'ic09', 'icon_512x512.png'), (b'ic10', 'icon_512x512@2x.png'),
    (b'ic11', 'icon_16x16@2x.png'), (b'ic12', 'icon_32x32@2x.png'),
    (b'ic13', 'icon_128x128@2x.png'), (b'ic14', 'icon_256x256@2x.png'),
]

def pixels_only(data):
    out, i = bytearray(data[:8]), 8
    while i < len(data):
        (length,) = struct.unpack('>I', data[i:i + 4])
        if data[i + 4:i + 8] in KEEP:
            out += data[i:i + 12 + length]
        i += 12 + length
    return bytes(out)

iconset = Path(sys.argv[1])
body = b''
for kind, name in TYPES:
    png = pixels_only((iconset / name).read_bytes())
    body += kind + struct.pack('>I', 8 + len(png)) + png
Path(sys.argv[2]).write_bytes(b'icns' + struct.pack('>I', 8 + len(body)) + body)
PY

echo "Wrote $OUT"
