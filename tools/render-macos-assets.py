#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
# SPDX-License-Identifier: GPL-3.0-or-later

"""Deterministic pure-stdlib generator and verifier for TotalDrop macOS Kose assets.

Renders the canonical Kose brand geometry (`M55 15H97V57A42 42 0 1 1 55 15Z`)
inside a macOS Human Interface Guidelines superellipse (squircle) icon plate
using exact analytical 4x supersampling into a multi-resolution PNG-in-ICNS
bundle (`ui-swiftui-macos/Resources/AppIcon.icns`):
  - icp4 (16x16 PNG)
  - icp5 (32x32 PNG)
  - icp6 (64x64 PNG)
  - ic07 (128x128 PNG)
  - ic08 (256x256 PNG)
  - ic09 (512x512 PNG)
  - ic10 (1024x1024 PNG)

Zero third-party dependencies (runs identically on Linux and macOS CI runners).

Usage:
  python3 tools/render-macos-assets.py --write
  python3 tools/render-macos-assets.py --check
"""

from __future__ import annotations

import argparse
import math
import struct
import sys
import zlib
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
ICNS_PATH = REPO_ROOT / "ui-swiftui-macos" / "Resources" / "AppIcon.icns"

# Canonical Kose SVG mark geometry (112x112 viewBox) and brand palette (ADR 0012).
VIEWBOX = 112.0
CIRCLE_CX = 55.0
CIRCLE_CY = 57.0
CIRCLE_R = 42.0
CORNER_X_MIN = 55.0
CORNER_X_MAX = 97.0
CORNER_Y_MIN = 15.0
CORNER_Y_MAX = 57.0

# Brand colors (sRGB)
VIOLET_TOP = (0x7B, 0x58, 0xEC)
VIOLET_BOT = (0x5D, 0x3B, 0xCE)
PAPER_RGB = (0xF4, 0xF2, 0xFB)

# macOS HIG icon canvas proportions (824/1024 plate inside 1024x1024 canvas).
PLATE_FRACTION = 0.805
MARK_SCALE_IN_PLATE = 0.66
SUPERSAMPLE = 4

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
ICNS_ENTRIES: tuple[tuple[bytes, int], ...] = (
    (b"icp4", 16),
    (b"icp5", 32),
    (b"icp6", 64),
    (b"ic07", 128),
    (b"ic08", 256),
    (b"ic09", 512),
    (b"ic10", 1024),
)


def png_chunk(chunk_type: bytes, data: bytes) -> bytes:
    crc = zlib.crc32(chunk_type + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + chunk_type + data + struct.pack(">I", crc)


def encode_rgba_png(width: int, height: int, rgba_rows: list[bytes]) -> bytes:
    """Encode deterministic uncompressed-filter RGBA PNG using stdlib zlib."""
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    raw = bytearray()
    for row in rgba_rows:
        raw.append(0)  # Filter type 0 (None)
        raw.extend(row)
    idat = zlib.compress(bytes(raw), level=9)
    return (
        PNG_SIGNATURE
        + png_chunk(b"IHDR", ihdr)
        + png_chunk(b"IDAT", idat)
        + png_chunk(b"IEND", b"")
    )


def render_icon_rgba_rows(size: int) -> list[bytes]:
    """Analytically render one square macOS Kose icon with 4x supersampling."""
    ss = SUPERSAMPLE if size <= 256 else 2
    inv_ss = 1.0 / ss
    inv_samples = 1.0 / (ss * ss)
    half = size * 0.5
    plate_half = half * PLATE_FRACTION
    inv_plate_half = 1.0 / plate_half

    # Map canvas coords to Kose 112x112 viewBox centered inside plate.
    mark_span = (size * PLATE_FRACTION) * MARK_SCALE_IN_PLATE
    scale_to_vb = VIEWBOX / mark_span
    vb_half = VIEWBOX * 0.5
    r_sq = CIRCLE_R * CIRCLE_R

    # Precompute vertical gradient per row for speed.
    rows: list[bytes] = []
    for y in range(size):
        row = bytearray(size * 4)
        ty = max(0.0, min(1.0, (y + 0.5 - (half - plate_half)) / (2.0 * plate_half)))
        bg_r = VIOLET_TOP[0] + (VIOLET_BOT[0] - VIOLET_TOP[0]) * ty
        bg_g = VIOLET_TOP[1] + (VIOLET_BOT[1] - VIOLET_TOP[1]) * ty
        bg_b = VIOLET_TOP[2] + (VIOLET_BOT[2] - VIOLET_TOP[2]) * ty

        for x in range(size):
            plate_hits = 0
            mark_hits = 0
            for sy in range(ss):
                py = y + (sy + 0.5) * inv_ss
                ny = abs(py - half) * inv_plate_half
                if ny > 1.0:
                    continue
                ny5 = ny ** 4.5
                vy = (py - half) * scale_to_vb + vb_half
                dy = vy - CIRCLE_CY
                dy_sq = dy * dy
                in_corner_y = CORNER_Y_MIN <= vy <= CORNER_Y_MAX

                for sx in range(ss):
                    px = x + (sx + 0.5) * inv_ss
                    nx = abs(px - half) * inv_plate_half
                    if nx > 1.0:
                        continue
                    # Apple-style continuous superellipse (n = 4.5).
                    if (nx ** 4.5) + ny5 <= 1.0:
                        plate_hits += 1
                        vx = (px - half) * scale_to_vb + vb_half
                        if in_corner_y and CORNER_X_MIN <= vx <= CORNER_X_MAX:
                            mark_hits += 1
                        else:
                            dx = vx - CIRCLE_CX
                            if dx * dx + dy_sq <= r_sq:
                                mark_hits += 1

            if plate_hits == 0:
                continue

            alpha = plate_hits * inv_samples
            mark_cov = mark_hits / plate_hits
            r = bg_r * (1.0 - mark_cov) + PAPER_RGB[0] * mark_cov
            g = bg_g * (1.0 - mark_cov) + PAPER_RGB[1] * mark_cov
            b = bg_b * (1.0 - mark_cov) + PAPER_RGB[2] * mark_cov

            off = x * 4
            row[off] = min(255, max(0, int(round(r))))
            row[off + 1] = min(255, max(0, int(round(g))))
            row[off + 2] = min(255, max(0, int(round(b))))
            row[off + 3] = min(255, max(0, int(round(alpha * 255.0))))
        rows.append(bytes(row))
    return rows


def build_icns_bytes() -> bytes:
    """Assemble a deterministic Apple ICNS container holding all 7 PNG entries."""
    chunks: list[bytes] = []
    for ostype, size in ICNS_ENTRIES:
        png = encode_rgba_png(size, size, render_icon_rgba_rows(size))
        chunks.append(ostype + struct.pack(">I", 8 + len(png)) + png)
    body = b"".join(chunks)
    return b"icns" + struct.pack(">I", 8 + len(body)) + body


def verify_icns_structure(data: bytes) -> list[tuple[str, int, int]]:
    """Parse an ICNS binary and verify every required PNG slot & pixel size."""
    if len(data) < 8 or data[:4] != b"icns":
        raise ValueError("missing 'icns' magic header")
    declared_len = struct.unpack(">I", data[4:8])[0]
    if declared_len != len(data):
        raise ValueError(f"icns header length {declared_len} != actual {len(data)}")
    pos = 8
    found: dict[bytes, tuple[int, int]] = {}
    while pos < len(data):
        if pos + 8 > len(data):
            raise ValueError(f"truncated icns chunk at offset {pos}")
        ostype = data[pos : pos + 4]
        chunk_len = struct.unpack(">I", data[pos + 4 : pos + 8])[0]
        if chunk_len < 8 or pos + chunk_len > len(data):
            raise ValueError(f"invalid icns chunk length {chunk_len} for {ostype!r}")
        payload = data[pos + 8 : pos + chunk_len]
        if not payload.startswith(PNG_SIGNATURE) or len(payload) < 24:
            raise ValueError(f"chunk {ostype!r} does not contain a valid PNG")
        w, h = struct.unpack(">II", payload[16:24])
        found[ostype] = (w, h)
        pos += chunk_len

    summary: list[tuple[str, int, int]] = []
    for ostype, expected_size in ICNS_ENTRIES:
        if ostype not in found:
            raise ValueError(f"missing required icns slot {ostype.decode('ascii')}")
        w, h = found[ostype]
        if (w, h) != (expected_size, expected_size):
            raise ValueError(
                f"icns slot {ostype.decode('ascii')} size {(w, h)} != {(expected_size, expected_size)}"
            )
        summary.append((ostype.decode("ascii"), w, h))
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true", help="Generate AppIcon.icns")
    mode.add_argument("--check", action="store_true", help="Verify AppIcon.icns matches deterministically")
    args = parser.parse_args()

    expected = build_icns_bytes()
    slots = verify_icns_structure(expected)

    if args.write:
        ICNS_PATH.parent.mkdir(parents=True, exist_ok=True)
        ICNS_PATH.write_bytes(expected)
        print(
            f"wrote {ICNS_PATH.relative_to(REPO_ROOT)} "
            f"({len(expected)} bytes, {len(slots)} PNG slots: "
            + ", ".join(f"{t}={w}x{h}" for t, w, h in slots)
            + ")"
        )
        return 0

    if not ICNS_PATH.is_file():
        print(f"error: missing {ICNS_PATH.relative_to(REPO_ROOT)}", file=sys.stderr)
        return 1
    actual = ICNS_PATH.read_bytes()
    verify_icns_structure(actual)
    if actual != expected:
        print(
            f"error: {ICNS_PATH.relative_to(REPO_ROOT)} drifted from deterministic generator "
            f"(run `python3 tools/render-macos-assets.py --write`)",
            file=sys.stderr,
        )
        return 1
    print(
        f"macos Kose assets OK: {ICNS_PATH.relative_to(REPO_ROOT)} "
        f"({len(actual)} bytes, {len(slots)} verified PNG slots)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
