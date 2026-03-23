#!/usr/bin/env python3
"""Compile Metal shader sources into a .metallib for PyMOL.

Usage:
    python scripts/compile_metal_shaders.py [--sdk macosx] [--output build/pymol.metallib]

Requires Xcode command line tools (xcrun, metal, metallib).
"""

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

SHADER_DIR = Path(__file__).resolve().parent.parent / "data" / "shaders_metal"

# Metal shader files to compile (order doesn't matter for metallib)
SHADER_FILES = [
    "default.metal",
    "surface.metal",
    "sphere.metal",
    "cylinder.metal",
    "label.metal",
    "bg.metal",
    "line.metal",
    "trilines.metal",
    "oit.metal",
    "screen.metal",
    "copy.metal",
    "indicator.metal",
    "volume.metal",
    "ramp.metal",
    "bezier.metal",
    "connector.metal",
]


def find_sdk_path(sdk: str) -> str:
    """Get the SDK path using xcrun."""
    result = subprocess.run(
        ["xcrun", "--sdk", sdk, "--show-sdk-path"],
        capture_output=True, text=True, check=True,
    )
    return result.stdout.strip()


def compile_metal_to_air(src: Path, air: Path, sdk: str, include_dir: Path) -> None:
    """Compile a .metal source file to a .air intermediate."""
    cmd = [
        "xcrun", "-sdk", sdk, "metal",
        "-c", str(src),
        "-o", str(air),
        "-I", str(include_dir),
        "-std=metal2.0",
        "-mmacosx-version-min=10.15",
        "-Wall",
    ]
    subprocess.run(cmd, check=True)


def link_metallib(air_files: list, output: Path, sdk: str) -> None:
    """Link .air files into a .metallib."""
    cmd = ["xcrun", "-sdk", sdk, "metallib"] + [str(f) for f in air_files] + ["-o", str(output)]
    subprocess.run(cmd, check=True)


def main():
    parser = argparse.ArgumentParser(description="Compile PyMOL Metal shaders")
    parser.add_argument("--sdk", default="macosx", help="SDK to use (default: macosx)")
    parser.add_argument("--output", default=None, help="Output .metallib path")
    args = parser.parse_args()

    if sys.platform != "darwin":
        print("Metal shader compilation is only supported on macOS", file=sys.stderr)
        sys.exit(1)

    # Check that the Metal compiler toolchain is available
    try:
        subprocess.run(
            ["xcrun", "-sdk", args.sdk, "--find", "metal"],
            capture_output=True, check=True,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        print(
            "WARNING: Metal compiler toolchain not found (install Xcode).\n"
            "  Skipping metallib compilation — shaders will compile at runtime.",
            file=sys.stderr,
        )
        sys.exit(0)

    output = Path(args.output) if args.output else SHADER_DIR / "pymol.metallib"
    output.parent.mkdir(parents=True, exist_ok=True)

    print(f"Compiling Metal shaders from {SHADER_DIR}")
    print(f"Output: {output}")

    with tempfile.TemporaryDirectory(prefix="pymol_metal_") as tmpdir:
        tmpdir = Path(tmpdir)
        air_files = []

        for shader_name in SHADER_FILES:
            src = SHADER_DIR / shader_name
            if not src.exists():
                print(f"  WARNING: {shader_name} not found, skipping", file=sys.stderr)
                continue

            air = tmpdir / (src.stem + ".air")
            print(f"  Compiling {shader_name} -> {air.name}")
            try:
                compile_metal_to_air(src, air, args.sdk, SHADER_DIR)
                air_files.append(air)
            except subprocess.CalledProcessError as e:
                print(f"  ERROR compiling {shader_name}: {e}", file=sys.stderr)
                sys.exit(1)

        if not air_files:
            print("No shader files compiled", file=sys.stderr)
            sys.exit(1)

        print(f"  Linking {len(air_files)} shaders -> {output.name}")
        try:
            link_metallib(air_files, output, args.sdk)
        except subprocess.CalledProcessError as e:
            print(f"  ERROR linking metallib: {e}", file=sys.stderr)
            sys.exit(1)

    print(f"Successfully created {output} ({output.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
