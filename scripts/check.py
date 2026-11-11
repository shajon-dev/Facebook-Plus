#!/usr/bin/env python3
"""
Facebook Plus Diagnostic & Lint Checker

Runs compilation diagnostics on every Objective-C, Objective-C++ and Logos
source in the project and reports each error and warning in the terminal.

`make` stops at the first object that fails and takes minutes; this uses
-fsyntax-only, runs in parallel, and reports everything at once in a couple of
seconds. It compiles with the same warning flags theos does, -Wall -Werror
included, so what passes here is what the build accepts.

It checks all four configurations the project actually ships, because
src/PluginsInject/ is compiled twice, into the tweak and into
FBPNotifyBridge.dylib, under different defines:

    tweak              the FacebookPlus tweak
    tweak+diag         the same with FBP_DIAG=1 (the [FBPDIAG] trace)
    bridge             FBPNotifyBridge.dylib (FBP_NOTIFY_BRIDGE=1)
    bridge+diag        the same with FBP_DIAG=1

A trace-only variable is used in the diagnostic build and unused in the plain
one, so a change can compile in one and fail the other. Checking a single
configuration is what let that reach main once already.

    python3 scripts/check.py                  all four
    python3 scripts/check.py --config tweak   one of them
    python3 scripts/check.py -q               failures and the summary only
"""

import argparse
import concurrent.futures
import glob
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
THEOS = os.environ.get("THEOS", os.path.expanduser("~/theos"))
LOGOS = os.path.join(THEOS, "bin", "logos.pl")

# The deployment target both Makefiles set: iphone:clang:latest:15.1
MIN_IOS = "15.1"

# theos's own warning flags, from `make -n`. -Werror is the important one: it is
# how an unused trace variable becomes a build failure.
THEOS_WARNINGS = [
    "-Wall",
    "-Werror",
    "-Wno-deprecated-declarations",
    "-Wno-unused-command-line-argument",
]

USE_COLOR = sys.stdout.isatty()
def c(code, text):
    return f"\033[{code}m{text}\033[0m" if USE_COLOR else text


# --------------------------------------------------------------------------- #
# Toolchain
# --------------------------------------------------------------------------- #

def find_sdk():
    """The SDK theos builds against, so a check matches the build.

    FBP_SDK=xcode asks for Xcode's current iphoneos SDK instead, which is how
    you find out early what a newer SDK will say.
    """
    if os.environ.get("FBP_SDK") == "xcode":
        res = subprocess.run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"],
                             capture_output=True, text=True)
        if res.returncode == 0 and os.path.isdir(res.stdout.strip()):
            return res.stdout.strip()
        print("warning: FBP_SDK=xcode but no Xcode iphoneos SDK found; "
              "falling back to theos.", file=sys.stderr)

    def version_key(path):
        m = re.search(r"iPhoneOS([\d.]+)\.sdk", os.path.basename(path))
        return tuple(int(x) for x in m.group(1).split(".")) if m else (0,)

    sdks = sorted(glob.glob(os.path.join(THEOS, "sdks", "iPhoneOS*.sdk")), key=version_key)
    if sdks:
        return sdks[-1]

    res = subprocess.run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"],
                         capture_output=True, text=True)
    if res.returncode == 0 and os.path.isdir(res.stdout.strip()):
        return res.stdout.strip()

    print(f"error: no iPhoneOS SDK found under {THEOS}/sdks, and xcrun has none either.",
          file=sys.stderr)
    sys.exit(1)


def find_clang():
    res = subprocess.run(["xcrun", "--find", "clang"], capture_output=True, text=True)
    if res.returncode == 0 and res.stdout.strip():
        return res.stdout.strip()
    for candidate in ("/usr/bin/clang", "clang"):
        if subprocess.run(["which", candidate], capture_output=True).returncode == 0:
            return candidate
    print("error: no clang found (tried xcrun and PATH).", file=sys.stderr)
    sys.exit(1)


def tweak_version():
    path = os.path.join(ROOT, "control")
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                if line.startswith("Version:"):
                    return line.split(":", 1)[1].strip()
    return "0.0.0"


# --------------------------------------------------------------------------- #
# What to check
# --------------------------------------------------------------------------- #

SOURCE_SUFFIXES = (".m", ".mm", ".xm", ".x", ".c")

# Build droppings that theos leaves inside the tree, and the scratch clones.
SKIP_DIRS = {".theos", ".git", ".temp", "packages", "venv", "__pycache__", "draft", "preview"}


def walk_sources(*roots):
    found = []
    for base in roots:
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for name in sorted(filenames):
                if name.endswith(SOURCE_SUFFIXES):
                    found.append(os.path.join(dirpath, name))
    return sorted(set(found))


def include_dirs(*roots):
    """Every directory a sibling header could live in, plus the repo root.

    Discovered by walking rather than listed, so a new feature directory needs
    no edit here. FBP_INCLUDE_DIRS in the Makefile is what the build uses; this
    is a superset of it, which is what you want for a syntax check.
    """
    dirs = [ROOT]
    for base in roots:
        for dirpath, dirnames, _ in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            dirs.append(dirpath)
    return dirs


SRC = os.path.join(ROOT, "src")
FISHHOOK = os.path.join(ROOT, "fishhook")
BRIDGE_DIR = os.path.join(ROOT, "FBPNotifyBridge", "src")
PLUGINS_INJECT = os.path.join(SRC, "PluginsInject")


def configurations(which):
    version = tweak_version()

    # The tweak: everything under src/, plus fishhook, which the root Makefile
    # compiles from outside src/.
    tweak_files = walk_sources(SRC, FISHHOOK)
    tweak_defines = [f'-DFBP_VERSION=@"{version}"']

    # The bridge: its own source plus the shared PluginsInject sources, exactly
    # as FBPNotifyBridge/src/Makefile lists them.
    bridge_files = walk_sources(BRIDGE_DIR, PLUGINS_INJECT, FISHHOOK)
    bridge_defines = ["-DFBP_NOTIFY_BRIDGE=1"]

    all_configs = [
        ("tweak",       tweak_files,  tweak_defines),
        ("tweak+diag",  tweak_files,  tweak_defines + ["-DFBP_DIAG=1"]),
        ("bridge",      bridge_files, bridge_defines),
        ("bridge+diag", bridge_files, bridge_defines + ["-DFBP_DIAG=1"]),
    ]
    if not which:
        return all_configs
    chosen = [cfg for cfg in all_configs if cfg[0] == which or cfg[0].startswith(which + "+")]
    if not chosen:
        names = ", ".join(cfg[0] for cfg in all_configs)
        print(f"error: unknown config {which!r}. Pick one of: {names}", file=sys.stderr)
        sys.exit(2)
    return chosen


# --------------------------------------------------------------------------- #
# Checking one file
# --------------------------------------------------------------------------- #

def base_command(clang, sdk, incs, tmpdir):
    cmd = [
        clang,
        "-fsyntax-only",
        "-target", f"arm64-apple-ios{MIN_IOS}",
        "-isysroot", sdk,
        "-I" + os.path.join(THEOS, "include"),
        "-I" + os.path.join(THEOS, "include", "iphone"),
        "-I" + os.path.join(THEOS, "vendor", "include"),
        "-I" + os.path.join(THEOS, "include", "_fallback"),
        "-I" + tmpdir,
        "-F" + os.path.join(sdk, "System", "Library", "Frameworks"),
        "-F" + os.path.join(sdk, "System", "Library", "PrivateFrameworks"),
        # theos ships CydiaSubstrate as a framework here; without it every .xm
        # that pulls in substrate.h fails on <CydiaSubstrate/CydiaSubstrate.h>.
        "-F" + os.path.join(THEOS, "vendor", "lib"),
        "-F" + os.path.join(THEOS, "vendor", "lib", "iphone", "rootless"),
        "-DTARGET_IPHONE=1",
        "-DDEBUG",
        "-fobjc-arc",
        "-ferror-limit=0",
    ] + THEOS_WARNINGS
    for inc in incs:
        cmd += ["-I", inc]
    return cmd


def language_for(path):
    if path.endswith(".c"):
        return "c"
    if path.endswith((".mm", ".xm")):
        return "objective-c++"
    return "objective-c"           # .m, .x


def check_one(clang, sdk, incs, tmpdir, defines, path):
    """Return (relative path, error count, warning count, output)."""
    rel = os.path.relpath(path, ROOT)
    to_check = path
    lang = language_for(path)

    if path.endswith((".xm", ".x")):
        # theos preprocesses Logos into <name>.xm.mm and compiles that. The
        # generated file carries #line directives back to the original, so
        # clang's diagnostics already point at the .xm.
        generated = os.path.join(tmpdir, os.path.basename(path) + (".mm" if path.endswith(".xm") else ".m"))
        res = subprocess.run(["perl", LOGOS, path], capture_output=True, text=True)
        if res.returncode != 0:
            return rel, 1, 0, f"Logos preprocessor failed:\n{res.stderr.strip()}"
        with open(generated, "w", encoding="utf-8") as f:
            f.write(res.stdout)
        to_check = generated
        lang = "objective-c++" if path.endswith(".xm") else "objective-c"

    cmd = base_command(clang, sdk, incs, tmpdir)
    if lang == "c":
        cmd = [a for a in cmd if a != "-fobjc-arc"]
    cmd += defines + ["-x", lang, to_check]

    proc = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
    output = proc.stderr
    if to_check != path:
        output = output.replace(to_check, rel)

    errors = output.count(": error:") + output.count(": fatal error:")
    warnings = output.count(": warning:")
    if proc.returncode != 0 and errors == 0:
        errors = 1                 # failed for a reason it did not spell out
    return rel, errors, warnings, output.strip()


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #

def main():
    ap = argparse.ArgumentParser(description="Typecheck every source without building.")
    ap.add_argument("--config", metavar="NAME",
                    help="only this configuration: tweak, tweak+diag, bridge, bridge+diag")
    ap.add_argument("-q", "--quiet", action="store_true",
                    help="only failures and the summary")
    ap.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 4,
                    help="parallel compiles (default: one per core)")
    args = ap.parse_args()

    if not os.path.exists(LOGOS):
        print(f"error: {LOGOS} not found. Is THEOS set correctly?", file=sys.stderr)
        return 1

    clang = find_clang()
    sdk = find_sdk()
    configs = configurations(args.config)
    incs = include_dirs(SRC, BRIDGE_DIR, FISHHOOK)

    print(f"\n{c('1', 'Facebook Plus diagnostic check')}")
    print(f"  clang  {clang}")
    print(f"  sdk    {os.path.basename(sdk)}, deployment target iOS {MIN_IOS}")
    print(f"  theos  {THEOS}")
    print(f"  flags  {' '.join(THEOS_WARNINGS)}")

    total_errors = total_warnings = total_checked = 0
    failures = []

    with tempfile.TemporaryDirectory(prefix="fbp-check-") as tmproot:
        for name, files, defines in configs:
            tmpdir = os.path.join(tmproot, name.replace("+", "_"))
            os.makedirs(tmpdir, exist_ok=True)
            print(f"\n{c('1', '[' + name + ']')} checking {len(files)} source files"
                  f"{'' if not defines else '  ' + ' '.join(defines)}")

            results = []
            with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
                futures = {
                    pool.submit(check_one, clang, sdk, incs, tmpdir, defines, f): f
                    for f in files
                }
                for fut in concurrent.futures.as_completed(futures):
                    results.append(fut.result())

            for rel, errors, warnings, output in sorted(results):
                total_checked += 1
                total_errors += errors
                total_warnings += warnings
                if errors:
                    failures.append((name, rel, output))
                    print(f"  {c('91', '❌')} {rel} ({errors} error{'s' if errors != 1 else ''})")
                elif warnings:
                    print(f"  {c('93', '⚠️ ')} {rel} ({warnings} warning{'s' if warnings != 1 else ''})")
                    if not args.quiet:
                        print(output)
                elif not args.quiet:
                    print(f"  {c('92', '✅')} {rel}")

    if failures:
        print("\n" + "=" * 68)
        for name, rel, output in failures:
            print(f"\n{c('91', c('1', f'[{name}] {rel}'))}")
            print(output)
        print("\n" + "=" * 68)
        print(c("91", c("1", f"💥 {total_errors} error(s) and {total_warnings} warning(s) "
                              f"across {total_checked} compilation(s).")))
        print("=" * 68 + "\n")
        return 1

    print("\n" + "=" * 68)
    print(c("92", c("1", f"🎉 All {total_checked} compilations across {len(configs)} "
                          f"configuration(s) passed cleanly with 0 errors! "
                          f"({total_warnings} warnings)")))
    print("=" * 68 + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
