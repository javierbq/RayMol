#!/usr/bin/env python3
"""Make PyMOL.app fully portable by bundling embedded Python and dependencies.

Assumes:
  - C dependencies (libpng, freetype, GLEW, etc.) are statically linked
  - Python is provided by python-build-standalone in deps/python/
  - Python packages are specified in requirements-bundle.txt

Usage:
    python3 scripts/bundle_app.py build_appkit/PyMOL.app [--dmg] [--identity ID]
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


# Mach-O magic numbers (native and universal)
MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce",  # MH_MAGIC
    b"\xfe\xed\xfa\xcf",  # MH_MAGIC_64
    b"\xce\xfa\xed\xfe",  # MH_CIGAM
    b"\xcf\xfa\xed\xfe",  # MH_CIGAM_64
    b"\xca\xfe\xba\xbe",  # FAT_MAGIC
    b"\xbe\xba\xfe\xca",  # FAT_CIGAM
}

# Stdlib directories to exclude from the bundle (saves ~30 MB)
EXCLUDE_STDLIB = {
    "test", "tests", "idlelib", "tkinter", "turtledemo", "ensurepip",
    "lib2to3", "distutils",
}


def is_macho(path):
    """Check if a file is a Mach-O binary."""
    path = Path(path)
    if not path.is_file() or path.is_symlink():
        return False
    try:
        with open(path, "rb") as f:
            magic = f.read(4)
        return magic in MACHO_MAGICS
    except (OSError, PermissionError):
        return False


def find_all_macho(app_path):
    """Find all Mach-O files in the bundle."""
    results = []
    for root, dirs, files in os.walk(app_path):
        for fname in files:
            fpath = Path(root) / fname
            if is_macho(fpath):
                results.append(fpath)
    return results


def get_non_system_refs(path):
    """Get non-system library references from a Mach-O binary.

    Returns list of paths that are NOT system frameworks or @rpath/@loader_path.
    """
    try:
        out = subprocess.check_output(
            ["otool", "-L", str(path)], text=True, stderr=subprocess.DEVNULL
        )
    except subprocess.CalledProcessError:
        return []
    refs = []
    for line in out.splitlines()[1:]:
        line = line.strip()
        m = re.match(r"(/\S+)", line)
        if m:
            ref = m.group(1)
            # Skip system libraries and frameworks
            if ref.startswith("/usr/lib/") or ref.startswith("/System/"):
                continue
            refs.append(ref)
    return refs


def detect_python_version(python_prefix):
    """Detect Python major.minor version from a python-build-standalone install."""
    python_bin = Path(python_prefix) / "bin" / "python3"
    if not python_bin.exists():
        raise FileNotFoundError(f"Python binary not found at {python_bin}")
    out = subprocess.check_output(
        [str(python_bin), "-c",
         "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"],
        text=True
    ).strip()
    return out


def strip_signature(path):
    """Strip code signature from a Mach-O file."""
    subprocess.run(
        ["codesign", "--remove-signature", str(path)],
        stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
    )


def run_install_name_tool(args):
    """Run install_name_tool, stripping signature and retrying on failure."""
    result = subprocess.run(
        ["install_name_tool"] + args, capture_output=True, text=True,
    )
    if result.returncode != 0:
        strip_signature(args[-1])
        subprocess.run(
            ["install_name_tool"] + args, capture_output=True, text=True,
        )


def _add_rpath(path, rpath):
    """Add an rpath if not already present."""
    try:
        out = subprocess.check_output(
            ["otool", "-l", str(path)], text=True, stderr=subprocess.DEVNULL
        )
    except subprocess.CalledProcessError:
        return
    if rpath in out:
        return
    strip_signature(path)
    run_install_name_tool(["-add_rpath", rpath, str(path)])


def _remove_absolute_rpaths(path):
    """Remove non-portable (absolute) rpaths from a Mach-O binary."""
    try:
        out = subprocess.check_output(
            ["otool", "-l", str(path)], text=True, stderr=subprocess.DEVNULL
        )
    except subprocess.CalledProcessError:
        return
    # Parse LC_RPATH entries
    lines = out.splitlines()
    removed = 0
    for i, line in enumerate(lines):
        if "cmd LC_RPATH" in line:
            # The path is 2 lines after "cmd LC_RPATH"
            for j in range(i + 1, min(i + 4, len(lines))):
                m = re.match(r"\s+path\s+(/\S+)", lines[j])
                if m:
                    rpath = m.group(1)
                    # Remove absolute paths (not @executable_path, @loader_path, etc.)
                    if not rpath.startswith("@"):
                        strip_signature(path)
                        run_install_name_tool(["-delete_rpath", rpath, str(path)])
                        removed += 1
                    break
    if removed:
        print(f"    Removed {removed} absolute rpath(s) from {Path(path).name}")


# ==========================================================================
# Phase A: Copy embedded Python
# ==========================================================================

def phase_a_copy_python(app_path, python_prefix, python_version):
    """Copy python-build-standalone into the app bundle."""
    print("\n=== Phase A: Copying embedded Python ===")

    src = Path(python_prefix)
    dst = app_path / "Contents" / "Resources" / "python"

    if dst.exists():
        shutil.rmtree(dst)
    dst.mkdir(parents=True)

    # Copy bin/ (just python3 and python3.X)
    bin_dst = dst / "bin"
    bin_dst.mkdir()
    for name in ["python3", f"python{python_version}"]:
        src_bin = src / "bin" / name
        if src_bin.exists() and not src_bin.is_symlink():
            shutil.copy2(str(src_bin), str(bin_dst / name))
        elif src_bin.is_symlink():
            link_target = os.readlink(src_bin)
            os.symlink(link_target, str(bin_dst / name))

    # Copy lib/pythonX.Y/ (stdlib)
    src_lib = src / "lib" / f"python{python_version}"
    dst_lib = dst / "lib" / f"python{python_version}"
    print(f"  Copying stdlib (python{python_version})...")

    def _ignore(directory, contents):
        ignored = set()
        for item in contents:
            if item in EXCLUDE_STDLIB or item == "__pycache__":
                ignored.add(item)
            if item.endswith(".pyc"):
                ignored.add(item)
        return ignored

    shutil.copytree(str(src_lib), str(dst_lib), symlinks=True, ignore=_ignore)

    # Copy libpython dylib
    lib_dir = dst / "lib"
    dylib_name = f"libpython{python_version}.dylib"
    src_dylib = src / "lib" / dylib_name
    if src_dylib.exists():
        shutil.copy2(str(src_dylib), str(lib_dir / dylib_name))
        print(f"  Copied {dylib_name}")
    else:
        # Try without minor version
        for f in (src / "lib").glob("libpython3*.dylib"):
            if f.is_file() and not f.is_symlink():
                shutil.copy2(str(f), str(lib_dir / f.name))
                print(f"  Copied {f.name}")

    # Copy include/ (needed at runtime for some extensions)
    src_inc = src / "include" / f"python{python_version}"
    dst_inc = dst / "include" / f"python{python_version}"
    if src_inc.exists():
        shutil.copytree(str(src_inc), str(dst_inc), symlinks=True)

    print(f"  Python {python_version} copied to {dst}")
    return dst


# ==========================================================================
# Phase B: Install Python packages
# ==========================================================================

def phase_b_install_packages(app_path, python_prefix, python_version, requirements_file):
    """Install Python packages into the bundle via pip."""
    print("\n=== Phase B: Installing Python packages ===")

    python_bin = Path(python_prefix) / "bin" / "python3"
    site_packages = (
        app_path / "Contents" / "Resources"
        / "lib" / f"python{python_version}" / "site-packages"
    )
    site_packages.mkdir(parents=True, exist_ok=True)

    cmd = [
        str(python_bin), "-m", "pip", "install",
        "--target", str(site_packages),
        "--only-binary=:all:",
        "-r", str(requirements_file),
    ]

    print(f"  Installing packages to {site_packages}")
    subprocess.check_call(cmd)

    # Remove unnecessary files
    for pattern in ["__pycache__"]:
        for f in site_packages.rglob(pattern):
            if f.is_dir():
                shutil.rmtree(f)

    # List installed packages
    for d in sorted(site_packages.iterdir()):
        if d.is_dir() and not d.name.startswith("."):
            print(f"    {d.name}/")

    print(f"  Packages installed to {site_packages}")


# ==========================================================================
# Phase C: Collect and copy remaining dylibs
# ==========================================================================

def phase_c_copy_dylibs(app_path):
    """Copy any non-system dylibs referenced by .so files in the bundle.

    With static C deps, this mainly handles libpython and any dylibs
    pulled in by numpy or pyobjc .so extensions.
    """
    print("\n=== Phase C: Collecting remaining dylibs ===")

    fw_dir = app_path / "Contents" / "Frameworks"
    fw_dir.mkdir(parents=True, exist_ok=True)

    all_macho = find_all_macho(app_path)
    needed = set()

    for macho_path in all_macho:
        for ref in get_non_system_refs(macho_path):
            if ref.startswith("@"):
                continue  # already relocated
            real = str(Path(ref).resolve())
            if os.path.isfile(real):
                needed.add(real)

    # Recursively collect transitive deps
    queue = list(needed)
    while queue:
        path = queue.pop()
        for ref in get_non_system_refs(path):
            if ref.startswith("@"):
                continue
            real = str(Path(ref).resolve())
            if real not in needed and os.path.isfile(real):
                needed.add(real)
                queue.append(real)

    # Copy to Frameworks (skip if already inside the bundle)
    app_str = str(app_path)
    copied = 0
    for dylib_path in sorted(needed):
        if dylib_path.startswith(app_str):
            continue  # already in bundle
        basename = os.path.basename(dylib_path)
        dst = fw_dir / basename
        if not dst.exists():
            shutil.copy2(dylib_path, str(dst))
            print(f"  Copied {basename}")
            copied += 1

    if copied == 0:
        print("  No additional dylibs needed (static deps working)")
    else:
        print(f"  Copied {copied} dylibs to Frameworks/")


# ==========================================================================
# Phase D: Rewrite install names
# ==========================================================================

def phase_d_rewrite_install_names(app_path):
    """Rewrite non-system library references to @rpath."""
    print("\n=== Phase D: Rewriting install names ===")

    binary = app_path / "Contents" / "MacOS" / "PyMOL"
    fw_dir = app_path / "Contents" / "Frameworks"

    all_macho = find_all_macho(app_path)
    rewritten = 0

    for macho_path in all_macho:
        try:
            out = subprocess.check_output(
                ["otool", "-L", str(macho_path)], text=True, stderr=subprocess.DEVNULL
            )
        except subprocess.CalledProcessError:
            continue

        changes = []
        for line in out.splitlines()[1:]:
            m = re.match(r"\s+(/\S+)", line)
            if not m:
                continue
            ref = m.group(1)
            if ref.startswith("/usr/lib/") or ref.startswith("/System/"):
                continue
            if ref.startswith("@"):
                continue
            basename = os.path.basename(ref)
            new_ref = f"@rpath/{basename}"
            changes.append((ref, new_ref))

        if not changes:
            continue

        strip_signature(macho_path)
        for old, new in changes:
            run_install_name_tool(["-change", old, new, str(macho_path)])
        rewritten += 1

    # Set dylib IDs in Frameworks/
    print("  Setting dylib IDs...")
    for f in fw_dir.rglob("*"):
        if f.is_file() and not f.is_symlink() and is_macho(f):
            strip_signature(f)
            run_install_name_tool(["-id", f"@rpath/{f.name}", str(f)])

    # Also fix libpython inside Frameworks/python/lib/
    python_lib_dir = fw_dir / "python" / "lib"
    if python_lib_dir.exists():
        for f in python_lib_dir.glob("libpython*.dylib"):
            if f.is_file() and not f.is_symlink():
                strip_signature(f)
                run_install_name_tool(["-id", f"@rpath/{f.name}", str(f)])

    # Remove absolute rpaths baked in by CMake (e.g., /Users/runner/.../deps/python/lib)
    print("  Removing absolute rpaths...")
    _remove_absolute_rpaths(binary)
    for so in app_path.rglob("*.so"):
        _remove_absolute_rpaths(so)

    # Add rpaths
    print("  Adding rpaths...")

    # Main binary
    _add_rpath(binary, "@executable_path/../Frameworks")
    _add_rpath(binary, "@executable_path/../Resources/python/lib")

    # .so files (numpy, pyobjc extensions)
    for so in app_path.rglob("*.so"):
        _add_rpath(so, "@executable_path/../Frameworks")
        _add_rpath(so, "@executable_path/../Resources/python/lib")

    # Dylibs in Frameworks/
    for f in fw_dir.rglob("*"):
        if f.is_file() and not f.is_symlink() and is_macho(f):
            _add_rpath(f, "@loader_path")
            _add_rpath(f, "@loader_path/../Resources/python/lib")

    print(f"  Rewrote {rewritten} Mach-O files")


# ==========================================================================
# Phase E: Code signing
# ==========================================================================

def phase_e_codesign(app_path, identity="-"):
    """Code sign the bundle."""
    print("\n=== Phase E: Code signing ===")

    sign_args = ["codesign", "--force", "--sign", identity]
    if identity != "-":
        sign_args.append("--options=runtime")  # hardened runtime for notarization

    fw_dir = app_path / "Contents" / "Frameworks"

    # Sign dylibs
    for f in sorted(fw_dir.rglob("*.dylib")):
        if f.is_file() and not f.is_symlink():
            subprocess.run(sign_args + [str(f)], capture_output=True)

    # Sign .so files
    so_count = 0
    for so in sorted(app_path.rglob("*.so")):
        if so.is_file() and not so.is_symlink():
            subprocess.run(sign_args + [str(so)], capture_output=True)
            so_count += 1

    # Sign Python binary
    python_bin = fw_dir / "python" / "bin" / "python3"
    if python_bin.exists():
        subprocess.run(sign_args + [str(python_bin)], capture_output=True)

    # Sign main binary
    binary = app_path / "Contents" / "MacOS" / "PyMOL"
    subprocess.run(sign_args + [str(binary)], capture_output=True)

    # Sign the whole app
    subprocess.run(sign_args + [str(app_path)], capture_output=True)

    sign_type = "Developer ID" if identity != "-" else "ad-hoc"
    print(f"  Signed ({sign_type}): dylibs, {so_count} .so files, binary, and app")


# ==========================================================================
# Phase F: Verification
# ==========================================================================

def phase_f_verify(app_path):
    """Verify no non-system, non-@rpath references remain."""
    print("\n=== Phase F: Verification ===")

    all_macho = find_all_macho(app_path)
    violations = []

    for macho_path in all_macho:
        try:
            out = subprocess.check_output(
                ["otool", "-L", str(macho_path)], text=True, stderr=subprocess.DEVNULL
            )
        except subprocess.CalledProcessError:
            continue
        for line in out.splitlines()[1:]:
            m = re.match(r"\s+(/\S+)", line)
            if not m:
                continue
            ref = m.group(1)
            if ref.startswith("/usr/lib/") or ref.startswith("/System/"):
                continue
            if ref.startswith("@"):
                continue
            violations.append((str(macho_path), ref))

    if violations:
        print(f"  ERRORS: {len(violations)} non-portable references:")
        for path, ref in violations[:20]:
            rel = os.path.relpath(path, app_path)
            print(f"    {rel}: {ref}")
        if len(violations) > 20:
            print(f"    ... and {len(violations) - 20} more")
    else:
        print("  OK: All references are system or @rpath-relative")

    # Check architecture
    binary = app_path / "Contents" / "MacOS" / "PyMOL"
    arch_out = subprocess.check_output(["lipo", "-info", str(binary)], text=True).strip()
    print(f"  Architecture: {arch_out}")

    # Bundle size
    total = sum(
        f.stat().st_size
        for f in app_path.rglob("*")
        if f.is_file() and not f.is_symlink()
    )
    print(f"  Bundle size: {total / (1024 * 1024):.1f} MB")

    return len(violations) == 0


# ==========================================================================
# Phase G: DMG
# ==========================================================================

def phase_g_dmg(app_path):
    """Create DMG."""
    print("\n=== Phase G: Creating DMG ===")
    dmg_path = app_path.parent / "AiMOL.dmg"
    if dmg_path.exists():
        dmg_path.unlink()
    subprocess.run(
        [
            "hdiutil", "create",
            "-volname", "AiMOL",
            "-srcfolder", str(app_path),
            "-ov", "-format", "UDZO",
            str(dmg_path),
        ],
        check=True,
    )
    size = dmg_path.stat().st_size / (1024 * 1024)
    print(f"  Created {dmg_path} ({size:.1f} MB)")


# ==========================================================================
# Main
# ==========================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Make PyMOL.app portable by bundling embedded Python and dependencies."
    )
    parser.add_argument("app_path", type=Path, help="Path to PyMOL.app bundle")
    parser.add_argument("--dmg", action="store_true", help="Create a DMG after bundling")
    parser.add_argument("--identity", default="-",
                        help="Code signing identity (default: ad-hoc). "
                             "Use 'Developer ID Application: ...' for distribution.")
    parser.add_argument("--python-prefix", type=Path, default=None,
                        help="Path to python-build-standalone install (default: deps/python/)")
    parser.add_argument("--requirements", type=Path, default=None,
                        help="Path to requirements-bundle.txt (default: auto-detect)")
    args = parser.parse_args()

    app_path = args.app_path.resolve()
    if not app_path.exists() or not app_path.name.endswith(".app"):
        print(f"Error: {app_path} is not a valid .app bundle")
        sys.exit(1)

    binary = app_path / "Contents" / "MacOS" / "PyMOL"
    if not binary.exists():
        print(f"Error: Binary not found at {binary}")
        sys.exit(1)

    # Find repo root (parent of scripts/)
    script_dir = Path(__file__).resolve().parent
    repo_root = script_dir.parent

    # Python prefix
    python_prefix = args.python_prefix or (repo_root / "deps" / "python")
    if not python_prefix.exists():
        print(f"Error: Python prefix not found at {python_prefix}")
        print("Run ./scripts/fetch_python.sh first")
        sys.exit(1)

    # Requirements file
    requirements = args.requirements or (repo_root / "requirements-bundle.txt")
    if not requirements.exists():
        print(f"Error: Requirements file not found at {requirements}")
        sys.exit(1)

    # Detect Python version
    python_version = detect_python_version(python_prefix)
    print(f"Python version: {python_version}")
    print(f"Python prefix:  {python_prefix}")
    print(f"App bundle:     {app_path}")
    print(f"Signing:        {'ad-hoc' if args.identity == '-' else args.identity}")

    # Phase A: Copy embedded Python
    phase_a_copy_python(app_path, python_prefix, python_version)

    # Phase B: Install Python packages
    phase_b_install_packages(app_path, python_prefix, python_version, requirements)

    # Phase C: Copy remaining dylibs
    phase_c_copy_dylibs(app_path)

    # Phase D: Rewrite install names
    phase_d_rewrite_install_names(app_path)

    # Phase E: Code sign
    phase_e_codesign(app_path, args.identity)

    # Phase F: Verify
    ok = phase_f_verify(app_path)

    # Phase G: Optional DMG
    if args.dmg:
        phase_g_dmg(app_path)

    if ok:
        print("\nDone! Bundle is portable.")
    else:
        print("\nWARNING: Some non-portable references remain. See errors above.")
        sys.exit(1)


if __name__ == "__main__":
    main()
