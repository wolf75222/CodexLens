#!/usr/bin/env python3
"""Verify local macOS icon assets; Python standard library + Apple's iconutil.

The sRGB PNG chunk embeds the declaration of the standard sRGB profile. Apple's
ImageIO/iconutil may serialize an sRGB ICC profile as this chunk instead of iCCP.
No source asset is modified by this verifier.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import zlib


SLOTS = {
    "icon_16x16.png": (16, "ic04"),
    "icon_16x16@2x.png": (32, "ic11"),
    "icon_32x32.png": (32, "ic05"),
    "icon_32x32@2x.png": (64, "ic12"),
    "icon_128x128.png": (128, "ic07"),
    "icon_128x128@2x.png": (256, "ic13"),
    "icon_256x256.png": (256, "ic08"),
    "icon_256x256@2x.png": (512, "ic14"),
    "icon_512x512.png": (512, "ic09"),
    "icon_512x512@2x.png": (1024, "ic10"),
}


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def paeth(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if pa <= pb and pa <= pc else b if pb <= pc else c


def inspect_png(path: Path, expected: int, require_profile: bool = True) -> dict:
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"Not PNG: {path}"
    position, chunks, compressed = 8, [], bytearray()
    profile = None
    header = None
    while position < len(data):
        assert position + 12 <= len(data), f"Incomplete chunk: {path}"
        size = struct.unpack(">I", data[position:position + 4])[0]
        kind = data[position + 4:position + 8]
        payload = data[position + 8:position + 8 + size]
        end = position + size + 12
        assert end <= len(data), f"Incomplete payload: {path}"
        crc = struct.unpack(">I", data[end - 4:end])[0]
        assert zlib.crc32(kind + payload) & 0xffffffff == crc, f"CRC: {path}"
        chunks.append(kind.decode("ascii"))
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", payload)
        elif kind == b"IDAT":
            compressed.extend(payload)
        elif kind == b"sRGB":
            assert len(payload) == 1 and payload[0] <= 3, f"sRGB intent: {path}"
            profile = {"encoding": "sRGB", "name": "sRGB IEC61966-2.1",
                       "renderingIntent": payload[0]}
        elif kind == b"iCCP":
            name, encoded = payload.split(b"\0", 1)
            assert encoded[0] == 0, f"ICC compression: {path}"
            icc = zlib.decompress(encoded[1:])
            assert len(icc) >= 128 and icc[36:40] == b"acsp", f"ICC header: {path}"
            assert icc[16:20] == b"RGB ", f"ICC color space: {path}"
            profile = {"encoding": "iCCP", "name": name.decode("latin1"),
                       "bytes": len(icc), "sha256": digest(icc)}
        position = end
    assert chunks[0] == "IHDR" and chunks[-1] == "IEND", f"PNG structure: {path}"
    assert header == (expected, expected, 8, 6, 0, 0, 0), f"PNG RGBA8/size/interlace: {path}"
    assert profile is not None or not require_profile, f"No embedded color profile declaration: {path}"
    width, height = header[:2]
    stride = width * 4
    raw = zlib.decompress(compressed)
    assert len(raw) == height * (stride + 1), f"Pixel payload: {path}"
    previous = bytearray(stride)
    pixels = bytearray()
    for row_index in range(height):
        start = row_index * (stride + 1)
        filtering = raw[start]
        row = bytearray(raw[start + 1:start + 1 + stride])
        assert filtering <= 4, f"PNG filter: {path}"
        for column in range(stride):
            left = row[column - 4] if column >= 4 else 0
            up = previous[column]
            upper_left = previous[column - 4] if column >= 4 else 0
            prediction = (0, left, up, (left + up) // 2,
                          paeth(left, up, upper_left))[filtering]
            row[column] = (row[column] + prediction) & 255
        pixels.extend(row)
        previous = row
    return {"bytes": len(data), "sha256": digest(data), "width": width,
            "height": height, "bitsPerChannel": 8, "channels": "RGBA",
            "interlace": 0, "chunks": chunks, "profile": profile,
            "rgbaSHA256": digest(pixels)}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--asset-dir", type=Path,
                        default=Path(__file__).resolve().parent.parent / "Assets")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--name", choices=["CodexLens", "CodexLens-Light", "CodexLens-Dark"], default="CodexLens")
    args = parser.parse_args()
    assets = args.asset_dir.resolve()
    svg = (assets / (args.name + ".svg")).read_bytes()
    assert b'<svg' in svg and b'viewBox="0 0 1024 1024"' in svg, "Missing SVG master"
    png = inspect_png(assets / (args.name + ".png"), 512)
    icns = (assets / (args.name + ".icns")).read_bytes()
    assert icns[:4] == b"icns", "ICNS signature"
    assert struct.unpack(">I", icns[4:8])[0] == len(icns), "ICNS length"
    position, slots = 8, []
    while position < len(icns):
        kind = icns[position:position + 4].decode("ascii")
        size = struct.unpack(">I", icns[position + 4:position + 8])[0]
        assert size >= 8 and position + size <= len(icns), "ICNS slot length"
        slots.append({"slot": kind, "bytes": size})
        position += size
    assert len({entry["slot"] for entry in slots}) == len(slots), "Duplicate ICNS slot"
    assert {slot for _, slot in SLOTS.values()} <= {entry["slot"] for entry in slots}, "Missing ICNS slot"
    with tempfile.TemporaryDirectory(prefix="codex-lens-icon-verify.") as scratch:
        iconset = Path(scratch) / "CodexLens.iconset"
        subprocess.run(["/usr/bin/iconutil", "-c", "iconset", str(assets / (args.name + ".icns")),
                        "-o", str(iconset)], check=True)
        assert {p.name for p in iconset.glob("*.png")} == set(SLOTS), "Iconset coverage"
        extracted = {name: {"slot": slot, **inspect_png(iconset / name, size)}
                     for name, (size, slot) in SLOTS.items()}
        assert png["rgbaSHA256"] == extracted["icon_512x512.png"]["rgbaSHA256"], "Standalone/master pixels differ"
    receipt = {"passed": True, "assetDirectory": str(assets), "svgSHA256": digest(svg),
               "png": png, "icns": {"bytes": len(icns), "sha256": digest(icns),
                                      "slots": slots, "extracted": extracted},
               "coverage": "16, 32, 128, 256, 512 pt at 1x and 2x",
               "limits": ["No Finder/Dock rendering assertion", "No wide-gamut display calibration",
                          "No macOS 14 or Intel runtime assertion"]}
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(receipt, indent=2) + "\n")
    print("Icon assets verified: PNG RGBA8 noninterlaced with color profile; 10 macOS 1x/2x representations.")


if __name__ == "__main__":
    main()
