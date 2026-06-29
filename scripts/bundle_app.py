#!/usr/bin/env python3
"""Make PyMOL.app fully portable by bundling all dependencies."""

import argparse
import os
import re
import shutil
import struct
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

EXCLUDE_STDLIB = {"test", "tests", "idlelib", "tkinter", "turtledemo", "ensurepip"}

SITE_PACKAGES_DIRS = [
    "numpy",
    "objc",
    "PyObjCTools",
    "AppKit",
    "Foundation",
    "Cocoa",
    "CoreFoundation",
]

SITE_PACKAGES_DIST_INFOS = [
    "numpy",
    "pyobjc_core",
    "pyobjc_framework_cocoa",
]


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


def get_dylib_deps(path):
    """Get non-system dylib dependencies of a Mach-O binary.

    Returns list of absolute paths starting with /opt/homebrew/.
    """
    try:
        out = subprocess.check_output(
            ["otool", "-L", str(path)], text=True, stderr=subprocess.DEVNULL
        )
    except subprocess.CalledProcessError:
        return []
    deps = []
    for line in out.splitlines()[1:]:  # skip first line (filename)
        line = line.strip()
        if not line:
            continue
        # Format: /path/to/lib.dylib (compat ..., current ...)
        m = re.match(r"(/\S+)", line)
        if m:
            dep_path = m.group(1)
            if dep_path.startswith("/opt/homebrew/"):
                deps.append(dep_path)
    return deps


def collect_all_dylibs(start_paths):
    """Recursively collect all non-system dylibs starting from given paths.

    Returns deduplicated set of absolute paths.
    """
    collected = set()
    queue = list(start_paths)
    while queue:
        path = queue.pop()
        deps = get_dylib_deps(path)
        for dep in deps:
            real = str(Path(dep).resolve())
            if real not in collected and os.path.isfile(real):
                collected.add(real)
                queue.append(real)
    return collected


def find_all_macho(app_path):
    """Find all Mach-O files in the bundle."""
    results = []
    app_path = Path(app_path)
    for root, dirs, files in os.walk(app_path):
        for fname in files:
            fpath = Path(root) / fname
            if is_macho(fpath):
                results.append(fpath)
    return results


def detect_python_version(binary_path):
    """Detect Python version from the binary's linked Python.framework."""
    try:
        out = subprocess.check_output(["otool", "-L", str(binary_path)], text=True)
    except (subprocess.CalledProcessError, OSError) as e:
        # Match the rest of the script's otool error handling: return None so the
        # caller can sys.exit(1) cleanly instead of dying with a raw traceback.
        print("WARNING: otool -L failed on %s: %s" % (binary_path, e))
        return None
    for line in out.splitlines():
        if "Python.framework" in line:
            parts = line.strip().split("/")
            try:
                ver_idx = parts.index("Versions") + 1
                return parts[ver_idx]
            except (ValueError, IndexError):
                pass
    return None


def strip_signature(path):
    """Strip code signature from a Mach-O file (needed before install_name_tool)."""
    subprocess.run(
        ["codesign", "--remove-signature", str(path)],
        stderr=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
    )


def run_install_name_tool(args):
    """Run install_name_tool, stripping signature and retrying on failure."""
    result = subprocess.run(
        ["install_name_tool"] + args,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        # Might fail due to code signature; strip and retry
        target = args[-1]
        strip_signature(target)
        result = subprocess.run(
            ["install_name_tool"] + args,
            capture_output=True,
            text=True,
        )
        # Mirror bundle_macos_dylibs.py: a failed retry must abort, not silently
        # leave stale baked-in paths (-id/-add_rpath) that phase_g never checks.
        if result.returncode != 0:
            raise RuntimeError(
                "install_name_tool failed for %s: %s"
                % (target, result.stderr.strip()))


def copytree_filtered(src, dst, exclude_dirs=None, exclude_patterns=None):
    """Copy directory tree with exclusions."""
    exclude_dirs = exclude_dirs or set()
    exclude_patterns = exclude_patterns or set()

    def _ignore(directory, contents):
        ignored = set()
        for item in contents:
            if item in exclude_dirs:
                ignored.add(item)
            for pat in exclude_patterns:
                if item.endswith(pat):
                    ignored.add(item)
        return ignored

    if os.path.exists(dst):
        shutil.rmtree(dst)
    shutil.copytree(str(src), str(dst), symlinks=True, ignore=_ignore)


def phase_a_collect_dylibs(binary_path, extra_paths=None):
    """Phase A: Collect all non-system dylibs recursively."""
    print("\n=== Phase A: Collecting non-system dylibs ===")
    start = [str(binary_path)]
    if extra_paths:
        start.extend(str(p) for p in extra_paths)
    dylibs = collect_all_dylibs(start)
    print(f"  Found {len(dylibs)} Homebrew dylibs")
    for d in sorted(dylibs):
        print(f"    {d}")
    return dylibs


def phase_b_copy_python_framework(app_path, python_version):
    """Phase B: Copy Python framework into the bundle."""
    print("\n=== Phase B: Copying Python framework ===")
    src_base = Path(f"/opt/homebrew/opt/python@{python_version}/Frameworks/Python.framework/Versions/{python_version}")
    dst_base = app_path / f"Contents/Frameworks/Python.framework/Versions/{python_version}"

    if not src_base.exists():
        print(f"  ERROR: Python framework not found at {src_base}")
        sys.exit(1)

    # Create destination
    dst_base.mkdir(parents=True, exist_ok=True)

    # Copy the Python dylib
    src_dylib = src_base / "Python"
    dst_dylib = dst_base / "Python"
    if dst_dylib.exists():
        os.remove(dst_dylib)
    print(f"  Copying Python dylib...")
    shutil.copy2(str(src_dylib), str(dst_dylib))

    # Copy stdlib
    src_lib = src_base / f"lib/python{python_version}"
    dst_lib = dst_base / f"lib/python{python_version}"
    print(f"  Copying stdlib (excluding test dirs, __pycache__, .pyc)...")
    copytree_filtered(
        src_lib,
        dst_lib,
        exclude_dirs=EXCLUDE_STDLIB | {"__pycache__"},
        exclude_patterns={".pyc"},
    )

    # Create framework symlinks
    fw_root = app_path / "Contents/Frameworks/Python.framework"
    versions_dir = fw_root / "Versions"

    current_link = versions_dir / "Current"
    if current_link.exists() or current_link.is_symlink():
        current_link.unlink()
    current_link.symlink_to(python_version)

    top_python_link = fw_root / "Python"
    if top_python_link.exists() or top_python_link.is_symlink():
        top_python_link.unlink()
    top_python_link.symlink_to(f"Versions/Current/Python")

    # Create Resources/Info.plist (required for codesign)
    resources_dir = dst_base / "Resources"
    resources_dir.mkdir(exist_ok=True)
    info_plist = resources_dir / "Info.plist"
    info_plist.write_text(f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>org.python.python</string>
    <key>CFBundleName</key>
    <string>Python</string>
    <key>CFBundleVersion</key>
    <string>{python_version}</string>
</dict>
</plist>
""")

    # Resources symlink at top level
    res_link = fw_root / "Resources"
    if res_link.exists() or res_link.is_symlink():
        res_link.unlink()
    res_link.symlink_to("Versions/Current/Resources")

    print(f"  Python framework copied to {fw_root}")


def phase_c_copy_site_packages(app_path, python_version):
    """Phase C: Copy Python site-packages."""
    print("\n=== Phase C: Copying site-packages ===")
    src_sp = Path(f"/opt/homebrew/lib/python{python_version}/site-packages")
    dst_sp = app_path / f"Contents/Resources/lib/python{python_version}/site-packages"
    dst_sp.mkdir(parents=True, exist_ok=True)

    # Copy package directories
    for pkg in SITE_PACKAGES_DIRS:
        src = src_sp / pkg
        dst = dst_sp / pkg
        if src.exists():
            print(f"  Copying {pkg}/")
            exclude_dirs = {"tests", "test", "__pycache__"} if pkg == "numpy" else {"__pycache__"}
            copytree_filtered(src, dst, exclude_dirs=exclude_dirs, exclude_patterns={".pyc"})
        else:
            print(f"  WARNING: {pkg}/ not found in site-packages")

    # Copy .dist-info directories
    for prefix in SITE_PACKAGES_DIST_INFOS:
        for entry in src_sp.iterdir():
            if entry.is_dir() and entry.name.startswith(prefix) and entry.name.endswith(".dist-info"):
                dst = dst_sp / entry.name
                print(f"  Copying {entry.name}")
                copytree_filtered(entry, dst)

    # Copy _opaque_pointers.py if present
    opaque = src_sp / "_opaque_pointers.py"
    if opaque.exists():
        print("  Copying _opaque_pointers.py")
        shutil.copy2(str(opaque), str(dst_sp / "_opaque_pointers.py"))

    print(f"  Site-packages copied to {dst_sp}")


def phase_d_copy_dylibs(app_path, dylibs):
    """Phase D: Copy collected Homebrew dylibs into Frameworks/."""
    print("\n=== Phase D: Copying Homebrew dylibs into Frameworks/ ===")
    fw_dir = app_path / "Contents/Frameworks"
    fw_dir.mkdir(parents=True, exist_ok=True)

    copied = {}
    # basename -> source realpath that claimed it. We bundle (and later rewrite
    # load commands) by basename, so two DISTINCT libraries sharing a filename
    # would silently ship only the first and crash the other consumer at runtime.
    # collect_all_dylibs dedupes by realpath, so a repeated basename here is a
    # genuine collision — fail loudly rather than ship a broken bundle.
    seen = {}

    def _place(src, label=""):
        basename = os.path.basename(src)
        real = os.path.realpath(src)
        prev = seen.get(basename)
        if prev is not None and prev != real:
            raise RuntimeError(
                "dylib basename collision for '%s':\n  %s\n  %s\n"
                "Two distinct libraries share a filename; bundling by basename "
                "would ship only one and break the other." % (basename, prev, src))
        seen[basename] = real
        dst = fw_dir / basename
        if not dst.exists():
            shutil.copy2(src, str(dst))
        copied[src] = str(dst)
        print(f"  {label}{basename}")
        return dst

    for dylib_path in sorted(dylibs):
        _place(dylib_path)

    # Now scan .so files in the bundle for additional transitive deps
    print("  Scanning bundle .so files for additional deps...")
    so_files = list(app_path.rglob("*.so"))
    extra_dylibs = collect_all_dylibs(so_files)
    new_count = 0
    for dylib_path in sorted(extra_dylibs):
        if dylib_path in copied:
            continue
        if not (fw_dir / os.path.basename(dylib_path)).exists():
            new_count += 1
        _place(dylib_path, label="(transitive) ")
    if new_count:
        print(f"  Found {new_count} additional transitive dylibs")

    print(f"  Total dylibs in Frameworks/: {len(list(fw_dir.glob('*.dylib')))}")
    return copied


def phase_e_rewrite_install_names(app_path):
    """Phase E: Rewrite install names for all Mach-O files."""
    print("\n=== Phase E: Rewriting install names ===")
    all_macho = find_all_macho(app_path)
    binary = app_path / "Contents/MacOS/PyMOL"
    fw_dir = app_path / "Contents/Frameworks"

    # Build map of basename -> exists in Frameworks
    fw_basenames = set()
    for f in fw_dir.iterdir():
        if f.is_file() and not f.is_symlink():
            fw_basenames.add(f.name)

    rewritten = 0
    for macho_path in all_macho:
        macho_path = Path(macho_path)
        deps = []
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
            if ref.startswith("/opt/homebrew/"):
                basename = os.path.basename(ref)
                new_ref = f"@rpath/{basename}"
                changes.append((ref, new_ref))

        if not changes:
            continue

        # Strip signature before modifying
        strip_signature(macho_path)

        for old, new in changes:
            run_install_name_tool(["-change", old, new, str(macho_path)])
        rewritten += 1

    # Set dylib IDs
    print("  Setting dylib IDs...")
    for f in fw_dir.rglob("*"):
        if f.is_file() and not f.is_symlink() and is_macho(f):
            basename = f.name
            strip_signature(f)
            run_install_name_tool(["-id", f"@rpath/{basename}", str(f)])

    # Also set Python framework dylib ID
    python_dylib = fw_dir / "Python.framework/Versions/Current/Python"
    if python_dylib.exists():
        real_python = python_dylib.resolve()
        strip_signature(real_python)
        run_install_name_tool(["-id", "@rpath/Python", str(real_python)])

    # Add rpaths
    print("  Adding rpaths...")

    # Main binary: @executable_path/../Frameworks
    _add_rpath(binary, "@executable_path/../Frameworks")

    # .so files: @executable_path/../Frameworks
    for so in app_path.rglob("*.so"):
        _add_rpath(so, "@executable_path/../Frameworks")

    # Dylibs in Frameworks: @loader_path
    for f in fw_dir.rglob("*"):
        if f.is_file() and not f.is_symlink() and is_macho(f):
            _add_rpath(f, "@loader_path")

    print(f"  Rewrote {rewritten} Mach-O files")


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


def _codesign(path):
    """Ad-hoc sign `path`, aborting on failure. A silently-failed signature
    produces a bundle that Gatekeeper/dyld reject at launch on a clean machine."""
    r = subprocess.run(
        ["codesign", "--force", "--sign", "-", str(path)],
        capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("codesign failed for %s: %s" % (path, r.stderr.strip()))


def phase_f_codesign(app_path):
    """Phase F: Ad-hoc code sign everything."""
    print("\n=== Phase F: Ad-hoc code signing ===")
    fw_dir = app_path / "Contents/Frameworks"

    # Sign dylibs
    for f in sorted(fw_dir.rglob("*.dylib")):
        if f.is_file() and not f.is_symlink():
            _codesign(f)

    # Sign .so files
    so_count = 0
    for so in sorted(app_path.rglob("*.so")):
        if so.is_file() and not so.is_symlink():
            _codesign(so)
            so_count += 1

    # Sign Python framework
    python_fw = fw_dir / "Python.framework"
    if python_fw.exists():
        _codesign(python_fw)

    # Sign main binary
    binary = app_path / "Contents/MacOS/PyMOL"
    _codesign(binary)

    # Sign the whole app
    _codesign(app_path)

    # Verify the seal is structurally valid before we trust the bundle (catches a
    # sign step that "succeeded" but left an inconsistent signature). phase_g only
    # checks dependency paths, not signature validity.
    verify = subprocess.run(
        ["codesign", "--verify", "--deep", "--strict", str(app_path)],
        capture_output=True, text=True)
    if verify.returncode != 0:
        raise RuntimeError(
            "codesign --verify failed for %s: %s" % (app_path, verify.stderr.strip()))

    print(f"  Signed dylibs, {so_count} .so files, Python.framework, binary, and app (verified)")


def phase_g_verify(app_path):
    """Phase G: Verify no /opt/homebrew/ references remain."""
    print("\n=== Phase G: Verification ===")
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
            if "/opt/homebrew/" in line:
                violations.append((str(macho_path), line.strip()))

    if violations:
        print(f"  ERRORS: {len(violations)} remaining /opt/homebrew/ references:")
        for path, ref in violations:
            rel = os.path.relpath(path, app_path)
            print(f"    {rel}: {ref}")
    else:
        print("  OK: No /opt/homebrew/ references found")

    # Print bundle size
    total = sum(
        f.stat().st_size
        for f in app_path.rglob("*")
        if f.is_file() and not f.is_symlink()
    )
    print(f"  Bundle size: {total / (1024 * 1024):.1f} MB")

    return len(violations) == 0


def phase_h_dmg(app_path):
    """Phase H: Create DMG."""
    print("\n=== Phase H: Creating DMG ===")
    dmg_path = app_path.parent / "PyMOL.dmg"
    subprocess.run(
        [
            "hdiutil",
            "create",
            "-volname",
            "PyMOL",
            "-srcfolder",
            str(app_path),
            "-ov",
            "-format",
            "UDZO",
            str(dmg_path),
        ],
        check=True,
    )
    size = dmg_path.stat().st_size / (1024 * 1024)
    print(f"  Created {dmg_path} ({size:.1f} MB)")


def main():
    parser = argparse.ArgumentParser(
        description="Make PyMOL.app fully portable by bundling all dependencies."
    )
    parser.add_argument("app_path", type=Path, help="Path to PyMOL.app bundle")
    parser.add_argument("--dmg", action="store_true", help="Create a DMG after bundling")
    args = parser.parse_args()

    app_path = args.app_path.resolve()
    if not app_path.exists() or not app_path.name.endswith(".app"):
        print(f"Error: {app_path} is not a valid .app bundle")
        sys.exit(1)

    binary = app_path / "Contents/MacOS/PyMOL"
    if not binary.exists():
        print(f"Error: Binary not found at {binary}")
        sys.exit(1)

    # Detect Python version
    python_version = detect_python_version(binary)
    if not python_version:
        print("Error: Could not detect Python version from binary")
        sys.exit(1)
    print(f"Detected Python version: {python_version}")
    print(f"App bundle: {app_path}")

    # Phase A: initial dylib collection from binary
    dylibs = phase_a_collect_dylibs(binary)

    # Phase B: copy Python framework
    phase_b_copy_python_framework(app_path, python_version)

    # Phase C: copy site-packages
    phase_c_copy_site_packages(app_path, python_version)

    # Phase D: copy dylibs (also scans .so files for transitive deps)
    phase_d_copy_dylibs(app_path, dylibs)

    # Phase E: rewrite install names
    phase_e_rewrite_install_names(app_path)

    # Phase F: code sign
    phase_f_codesign(app_path)

    # Phase G: verify
    ok = phase_g_verify(app_path)

    # Phase H: optional DMG
    if args.dmg:
        phase_h_dmg(app_path)

    if ok:
        print("\nDone! Bundle is portable.")
    else:
        print("\nWARNING: Some references could not be rewritten. See errors above.")
        sys.exit(1)


if __name__ == "__main__":
    main()
