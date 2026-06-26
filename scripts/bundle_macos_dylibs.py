#!/usr/bin/env python3
"""Make a built macOS RayMol.app self-contained.

The macOS app links freetype/libpng (and any other non-system dylib) out of
Homebrew (/opt/homebrew). The linker bakes those absolute install names (e.g.
/opt/homebrew/opt/freetype/lib/libfreetype.6.dylib) into the binary as hard
LC_LOAD_DYLIB commands. On any Mac without those exact Homebrew kegs (every end
user, a clean VM, the App Store sandbox) dyld can't resolve them and aborts the
process at launch:

    Termination Reason: Namespace DYLD, Code 1, Library missing
    Library not loaded: /opt/homebrew/.../libfreetype.6.dylib

This script fixes that by, for a given .app:
  1. recursively collecting every copyable (package-manager) dylib the main
     binary depends on, and their transitive copyable deps,
  2. copying each into Contents/Frameworks/,
  3. rewriting every load command whose basename we bundled (and each copied
     dylib's own id) to @rpath/<basename>,
  4. adding an @executable_path/../Frameworks rpath to the main binary (and
     @loader_path to each copied dylib so siblings resolve),
  5. optionally re-signing the copied dylibs,
  6. verifying that NO Mach-O anywhere in the bundle still has a non-system
     absolute dependency (the real safety net — fails the build if it does).

It is idempotent: once the binary points at @rpath there is nothing left to
collect or rewrite, so re-running is a no-op. Safe to run from an Xcode
post-build phase on every build.

The embedded standalone CPython under Contents/Resources/python is already
self-contained (uses @loader_path/@executable_path internally) and is signed
separately by the build's Python phase, so this script does NOT modify it — but
step 6 DOES verify it (read-only), so a future Homebrew-linked extension there
would fail the build loudly instead of shipping a crash.

Usage:
    bundle_macos_dylibs.py <RayMol.app> [--sign-identity ID] [--hardened]

    --sign-identity ID  codesign the COPIED Frameworks dylibs with this identity
                        ("-" for ad-hoc). The main binary is intentionally left
                        for the caller / Xcode's final CodeSign step to sign (so
                        its entitlements + hardened runtime are applied there).
                        Omit when a later step signs the whole bundle (e.g.
                        make_dmg.sh signs everything deepest-first afterward).
    --hardened          add --options runtime when signing the dylibs.
"""

import argparse
import os
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path


# Mach-O magic numbers (native + universal, both byte orders).
MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce",
    b"\xfe\xed\xfa\xcf",
    b"\xce\xfa\xed\xfe",
    b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
}

# Prefixes we know how to bundle (package managers that install relocatable
# dylibs). Apple-silicon Homebrew is /opt/homebrew; Intel Homebrew /usr/local;
# MacPorts /opt/local. Collecting all three keeps the script correct if a dep
# ever comes from a different toolchain.
COPYABLE_PREFIXES = ("/opt/homebrew/", "/usr/local/", "/opt/local/")

# Absolute prefixes that exist on every Mac and are therefore portable. Anything
# else absolute is a non-portable dependency that would crash on a clean machine.
SYSTEM_PREFIXES = ("/usr/lib/", "/System/")


def is_macho(path):
    path = Path(path)
    if not path.is_file() or path.is_symlink():
        return False
    try:
        with open(path, "rb") as f:
            return f.read(4) in MACHO_MAGICS
    except OSError:
        return False


def otool_L(path):
    """Dependency paths from `otool -L`.

    The regex requires leading whitespace, which naturally drops both the
    leading `<file>:` line and the `<file> (architecture X):` headers that fat
    binaries print (those start at column 0) — only the indented dependency
    lines match. Includes the dylib's own LC_ID line; callers that must exclude
    it use deps_of().
    """
    try:
        out = subprocess.check_output(
            ["otool", "-L", str(path)], text=True, stderr=subprocess.DEVNULL
        )
    except subprocess.CalledProcessError:
        return []
    deps = []
    for line in out.splitlines():
        m = re.match(r"\s+(\S+)\s+\(compatibility", line)
        if m:
            deps.append(m.group(1))
    return deps


def dylib_id(path):
    """The install id (LC_ID_DYLIB) of a dylib, or None for executables."""
    try:
        out = subprocess.check_output(
            ["otool", "-D", str(path)], text=True, stderr=subprocess.DEVNULL
        )
    except subprocess.CalledProcessError:
        return None
    lines = [ln.strip() for ln in out.splitlines() if ln.strip()]
    # Format: "<file>:" then the id on the next line (absent for executables).
    return lines[1] if len(lines) >= 2 else None


def deps_of(path):
    """LC_LOAD_DYLIB dependencies, excluding the file's own LC_ID."""
    own = dylib_id(path)
    return [d for d in otool_L(path) if d != own]


def copyable_deps(path):
    return [d for d in deps_of(path) if d.startswith(COPYABLE_PREFIXES)]


def nonportable_refs(path):
    """Every otool ref (incl. the id) that is an absolute, non-system path."""
    return [
        r for r in otool_L(path)
        if r.startswith("/") and not r.startswith(SYSTEM_PREFIXES)
    ]


def strip_signature(path):
    subprocess.run(
        ["codesign", "--remove-signature", str(path)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def install_name_tool(args):
    """Run install_name_tool; on failure strip the (now-stale) signature + retry."""
    r = subprocess.run(["install_name_tool"] + args, capture_output=True, text=True)
    if r.returncode != 0:
        strip_signature(args[-1])
        r = subprocess.run(["install_name_tool"] + args, capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(
                f"install_name_tool {' '.join(args)} failed: {r.stderr.strip()}"
            )


def existing_rpaths(path):
    """Parse actual LC_RPATH `path` entries (exact, not a substring match)."""
    try:
        out = subprocess.check_output(["otool", "-l", str(path)], text=True)
    except subprocess.CalledProcessError:
        return set()
    paths, in_rpath = set(), False
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("cmd "):
            in_rpath = s == "cmd LC_RPATH"
        elif in_rpath and s.startswith("path "):
            # "path <value> (offset N)"
            paths.add(re.sub(r"\s+\(offset \d+\)$", "", s[len("path "):]))
            in_rpath = False
    return paths


def add_rpath(path, rpath):
    if rpath in existing_rpaths(path):
        return  # idempotent — never add a duplicate LC_RPATH
    install_name_tool(["-add_rpath", rpath, str(path)])


def main_executable(app):
    """Resolve Contents/MacOS/<CFBundleExecutable> for the bundle."""
    plist = app / "Contents/Info.plist"
    name = None
    if plist.is_file():
        with open(plist, "rb") as f:
            name = plistlib.load(f).get("CFBundleExecutable")
    macos = app / "Contents/MacOS"
    if name and (macos / name).is_file():
        return macos / name
    machos = [p for p in macos.iterdir() if is_macho(p)] if macos.is_dir() else []
    if len(machos) == 1:
        return machos[0]
    raise SystemExit(f"Could not resolve main executable under {macos}")


def all_macho(app):
    for root, _dirs, files in os.walk(app):
        for fn in files:
            p = Path(root) / fn
            if is_macho(p):
                yield p


def collect(start):
    """BFS the copyable-dependency graph from `start`.

    Returns {basename: resolved_source_path}, keyed by the basename used in the
    load command so the @rpath/<basename> rewrite matches exactly.
    """
    found = {}
    queue = [start]
    while queue:
        f = queue.pop()
        for ref in copyable_deps(f):
            base = os.path.basename(ref)
            if base in found:
                continue
            real = Path(ref).resolve()  # follow Homebrew's opt/ -> Cellar symlinks
            if real.is_file():
                found[base] = real
                queue.append(real)
            else:
                print(f"  WARNING: dependency not found on disk: {ref}")
    return found


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("app", type=Path, help="Path to the built RayMol.app")
    ap.add_argument("--sign-identity", default=None,
                    help='codesign identity for the copied dylibs ("-" = ad-hoc)')
    ap.add_argument("--hardened", action="store_true",
                    help="add --options runtime when signing the dylibs")
    args = ap.parse_args()

    app = args.app.resolve()
    if not (app.is_dir() and app.suffix == ".app"):
        raise SystemExit(f"Not a .app bundle: {app}")

    binary = main_executable(app)
    fw_dir = app / "Contents/Frameworks"
    print(f"App:        {app}")
    print(f"Main binary: {binary.relative_to(app)}")

    # ---- 1. collect -----------------------------------------------------------
    deps = collect(binary)
    if deps:
        print(f"Collected {len(deps)} bundleable dylib(s):")
        for base, src in sorted(deps.items()):
            print(f"    {base}  <-  {src}")
    else:
        print("No bundleable dependencies found (already self-contained?).")

    # ---- 2. copy into Frameworks/ ---------------------------------------------
    fw_dir.mkdir(parents=True, exist_ok=True)
    for base, src in deps.items():
        dst = fw_dir / base
        if dst.exists():
            dst.chmod(0o644)            # ensure overwritable on a re-run
        shutil.copy2(src, dst)          # follows symlink -> copies the real file
        dst.chmod(0o644)                # Homebrew dylibs are often 0444; need +w
        print(f"  copied -> Contents/Frameworks/{base}")

    # ---- 3. rewrite install names (driven by what we actually bundled) --------
    copied = set(deps)
    for t in [binary] + [fw_dir / b for b in deps]:
        changes = [(ref, f"@rpath/{os.path.basename(ref)}")
                   for ref in deps_of(t)
                   if ref.startswith("/") and os.path.basename(ref) in copied]
        if changes:
            strip_signature(t)
            for old, new in changes:
                install_name_tool(["-change", old, new, str(t)])
    for base in deps:
        install_name_tool(["-id", f"@rpath/{base}", str(fw_dir / base)])

    # ---- 4. rpaths ------------------------------------------------------------
    if deps:
        add_rpath(binary, "@executable_path/../Frameworks")
        for base in deps:
            add_rpath(fw_dir / base, "@loader_path")

    # ---- 5. optional signing of the copied dylibs -----------------------------
    # Only the dylibs we dropped in are signed here; the main binary is left for
    # the caller (make_dmg.sh) or Xcode's final CodeSign step to seal WITH its
    # entitlements + hardened runtime. (We rewrote the main binary's load
    # commands above, invalidating any prior signature — expected; re-signed
    # downstream.)
    if args.sign_identity and deps:
        sign = ["codesign", "--force", "--sign", args.sign_identity]
        if args.hardened:
            sign += ["--options", "runtime"]
        for base in deps:
            subprocess.run(sign + [str(fw_dir / base)], check=True)
        print(f"  signed {len(deps)} copied dylib(s) with '{args.sign_identity}'")

    # ---- 6. verify EVERY Mach-O in the bundle ---------------------------------
    # The real guarantee: nothing anywhere in the app may depend on an absolute
    # path that is not a system path. This covers the main binary, the copied
    # dylibs, nested frameworks (Sparkle), helper executables, and the embedded
    # CPython tree — so any non-portable reference fails the build loudly rather
    # than shipping a dyld crash.
    print("Verifying (whole bundle)...")
    violations = []
    for p in all_macho(app):
        for ref in nonportable_refs(p):
            violations.append((p.relative_to(app), ref))
    if violations:
        print(f"  FAIL: {len(violations)} non-portable absolute reference(s):")
        for rel, ref in violations:
            print(f"    {rel}: {ref}")
        sys.exit(1)
    print("  OK: no Mach-O in the bundle depends on a non-system absolute path")
    print("Done — bundle is self-contained.")


if __name__ == "__main__":
    main()
