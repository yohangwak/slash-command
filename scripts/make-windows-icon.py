#!/usr/bin/env python3
"""Build Resources/AppIcon.ico from make-icon.swift (macOS; no third-party tools)."""
import pathlib
import struct
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
sizes = [16, 32, 48, 64, 128, 256]
images = []
with tempfile.TemporaryDirectory(prefix='slashcommand-icon-') as tmp:
    for size in sizes:
        png = pathlib.Path(tmp) / f'{size}.png'
        subprocess.run(['swift', str(root / 'scripts/make-icon.swift'), '--preview', str(png), str(size)], check=True)
        images.append(png.read_bytes())
offset = 6 + 16 * len(images)
entries = []
for size, data in zip(sizes, images):
    entries.append(struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0, 1, 32, len(data), offset))
    offset += len(data)
output = root / 'Resources/AppIcon.ico'
output.write_bytes(struct.pack('<HHH', 0, 1, len(images)) + b''.join(entries) + b''.join(images))
print(f'Created {output}')
