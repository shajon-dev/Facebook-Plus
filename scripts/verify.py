#!/usr/bin/env python3
"""
Facebook Plus unified verify runner.

Self-contained: the on-device operations, the clang typecheck, and the project
invariant suite all live here, with no runtime dependency on any other script.

    verify.py device install [deb] [--rebuild] [--no-restart]
    verify.py device verify | log | restart | shell <cmd>
    verify.py device --host <ip> install
    verify.py check [-q] [--config NAME]
    verify.py test [-v]
    verify.py                      # default: check + test (device needs hardware)
    verify.py --all                # same as the bare invocation

On-device log reading: this tweak writes to the os_log subsystem
"com.shajon.fbplus" rather than to a trace file, so `device log` streams the
device syslog with idevicesyslog (USB, libimobiledevice) filtered to Facebook
and fbplus. When idevicesyslog is not installed it prints how to read the same
subsystem from Console.app.
"""

import argparse
import concurrent.futures
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
THEOS = os.environ.get("THEOS", os.path.expanduser("~/theos"))
LOGOS = os.path.join(THEOS, "bin", "logos.pl")

IPROXY = "/opt/homebrew/bin/iproxy" if os.path.exists("/opt/homebrew/bin/iproxy") else "iproxy"

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

SOURCE_SUFFIXES = (".m", ".mm", ".xm", ".x", ".c")

# Build droppings that theos leaves inside the tree, and the scratch clones.
SKIP_DIRS = {".theos", ".git", ".temp", "packages", "venv", "__pycache__", "draft", "preview"}

_USE_COLOR = sys.stdout.isatty()
def _c(code, text):
    return f"\033[{code}m{text}\033[0m" if _USE_COLOR else text


# =============================================================================
# Device operations (SSH over USB via iproxy)
# =============================================================================


class DeviceController:
    REMOTE_TMP = "/var/jb/tmp"
    DYLIB_DIRS = (
        "/var/jb/Library/MobileSubstrate/DynamicLibraries",
        "/Library/MobileSubstrate/DynamicLibraries",
    )
    PACKAGE_ID = "com.shajon.fbplus"
    APP = "Facebook"
    SUBSYSTEM = "com.shajon.fbplus"

    def __init__(self, root=REPO_ROOT):
        self.root = root
        self.iproxy = None

    # -- iproxy + ssh transport ----------------------------------------------

    def _target(self, args):
        if getattr(args, "host", None):
            return f"root@{args.host}", "22"
        return "root@127.0.0.1", str(args.port)

    def _start_iproxy(self, args):
        if getattr(args, "host", None):
            return
        cmd = [IPROXY, str(args.port), "22"]
        if getattr(args, "udid", None):
            cmd += ["-u", args.udid]
        print("-" * 80)
        print(f"==> Forwarding local port {args.port} to device :22 via iproxy…")
        self.iproxy = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1.5)

    def _stop_iproxy(self):
        if not self.iproxy:
            return
        self.iproxy.terminate()
        try:
            self.iproxy.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.iproxy.kill()
        self.iproxy = None

    def _ssh_base(self, args):
        target, port = self._target(args)
        return ["ssh", "-p", port, "-i", os.path.expanduser(args.key), "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=10", target]

    def _scp_base(self, args):
        target, port = self._target(args)
        return ["scp", "-P", port, "-i", os.path.expanduser(args.key), "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=10"], target

    def _ssh(self, args, remote_cmd, capture=False):
        full = self._ssh_base(args) + [remote_cmd]
        if capture:
            return subprocess.run(full, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
        return subprocess.run(full, check=False)

    def _scp(self, args, local, remote):
        scp_cmd, target = self._scp_base(args)
        return subprocess.run(scp_cmd + [local, f"{target}:{remote}"], check=False)

    def _dylib_listing(self, args, pattern="fbplus"):
        # Either MobileSubstrate directory may be the live one depending on the
        # jailbreak; concatenate both and keep whichever matches.
        globs = " ".join(f"{d}/" for d in self.DYLIB_DIRS)
        return self._ssh(args, f"ls -la {globs} 2>/dev/null | grep -iE 'fbplus|facebook'", capture=True)

    # -- Package helpers -----------------------------------------------------

    def find_latest_deb(self, scheme="rootless"):
        pkg_dir = os.path.join(self.root, "packages")
        if not os.path.exists(pkg_dir):
            return None
        cands = glob.glob(os.path.join(pkg_dir, f"Facebook-Plus-*{scheme}.deb")) + glob.glob(os.path.join(pkg_dir, f"*{scheme}*.deb"))
        if not cands:
            return None
        return max(cands, key=os.path.getmtime)

    def build_deb(self, scheme="rootless"):
        print("-" * 80)
        print(f"==> Building {scheme} package via build.py --{scheme} --no-ipa…")
        cmd = ["python3", os.path.join(self.root, "build.py"), f"--{scheme}", "--no-ipa"]
        res = subprocess.run(cmd, cwd=self.root, check=False)
        if res.returncode != 0:
            sys.exit(f"Error: build failed with exit code {res.returncode}")
        deb = self.find_latest_deb(scheme)
        if not deb:
            sys.exit(f"Error: No {scheme} .deb found in packages/ after build.")
        return deb

    # -- SSH actions ---------------------------------------------------------

    def install(self, args):
        if args.rebuild:
            self.build_deb("rootless")
        deb = args.deb or self.find_latest_deb("rootless")
        if not deb:
            sys.exit("Error: No rootless .deb in packages/ — pass a path or use --rebuild.")

        remote = f"{self.REMOTE_TMP}/{os.path.basename(deb)}"
        print("-" * 80)
        print(f"==> Uploading {os.path.basename(deb)} to device {remote}…")
        if self._scp(args, deb, remote).returncode != 0:
            sys.exit("Error: scp upload failed.")

        print("-" * 80)
        print("==> Installing package with dpkg…")
        res = self._ssh(args, f"dpkg -i {remote}; rm -f {remote}", capture=True)
        print(res.stdout.strip())
        if res.returncode != 0:
            sys.exit(f"Error: dpkg -i failed with exit code {res.returncode}")

        print("-" * 80)
        print("==> Verifying installed tweak files:")
        out = self._dylib_listing(args).stdout.strip()
        if out:
            print("[+] Active tweak files:")
            print(out)
        else:
            print(f"[-] Warning: No fbplus files found in {' or '.join(self.DYLIB_DIRS)}!")

        if not args.no_restart:
            print("-" * 80)
            print(f"==> Restarting {self.APP} app…")
            self._ssh(args, f"killall -9 {self.APP} 2>/dev/null; echo restarted")
            print(f"[+] {self.APP} restarted. Facebook Plus is active!")

    def verify(self, args):
        print("-" * 80)
        print("==> Checking tweak files on device:")
        print(self._dylib_listing(args).stdout.strip() or "[-] Facebook Plus not found in MobileSubstrate directories")

        print("-" * 80)
        print("==> Checking dpkg package status:")
        r2 = self._ssh(args, f"dpkg -s {self.PACKAGE_ID} 2>&1 | grep -E 'Package|Status|Version'", capture=True)
        print(r2.stdout.strip() or "[-] Package not installed")

    def log(self, args):
        # No on-device trace file is written; detailed diagnostics go to the
        # os_log subsystem below. idevicesyslog reads it over USB without SSH.
        print("-" * 80)
        idevicesyslog = shutil.which("idevicesyslog")
        if not idevicesyslog:
            print("[-] idevicesyslog not found (install libimobiledevice: brew install libimobiledevice).")
            print(f"    Detailed logs are read in Console.app on the subsystem '{self.SUBSYSTEM}',")
            print(f"    or filtered to the {self.APP} process.")
            return

        print(f"==> Streaming device syslog filtered to {self.APP}/fbplus (Ctrl-C to stop)…")
        print(f"    (full detail is in Console.app on subsystem '{self.SUBSYSTEM}')")
        cmd = [idevicesyslog]
        if getattr(args, "udid", None):
            cmd += ["-u", args.udid]
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            for line in proc.stdout:
                low = line.lower()
                if "fbplus" in low or "facebook" in low:
                    sys.stdout.write(line)
        except KeyboardInterrupt:
            pass
        finally:
            try:
                proc.terminate()
            except Exception:  # noqa: S110,BLE001 - best-effort cleanup; proc may be unbound if Popen failed
                pass

    def restart(self, args):
        print("-" * 80)
        print(f"==> Restarting {self.APP}…")
        self._ssh(args, f"killall -9 {self.APP} 2>/dev/null; echo restarted")
        print("[+] Restarted.")

    def shell(self, args):
        res = self._ssh(args, " ".join(args.command))
        sys.exit(res.returncode)

    # -- Dispatch ------------------------------------------------------------

    def dispatch(self, args):
        action = args.device_action
        if action == "log":
            # idevicesyslog uses its own USB transport, so skip iproxy/SSH.
            self.log(args)
            return

        self._start_iproxy(args)
        try:
            if action == "install":
                self.install(args)
            elif action == "verify":
                self.verify(args)
            elif action == "restart":
                self.restart(args)
            elif action == "shell":
                self.shell(args)
        finally:
            self._stop_iproxy()


# =============================================================================
# Clang typecheck (every source, every shipped configuration)
# =============================================================================
#
# `make` stops at the first object that fails and takes minutes; this uses
# -fsyntax-only, runs in parallel, and reports everything at once. It compiles
# with the same warning flags theos does, -Wall -Werror included, so what
# passes here is what the build accepts.
#
# All four configurations the project ships are checked, because
# src/PluginsInject/ is compiled twice — into the tweak and into
# FBPNotifyBridge.dylib — under different defines:
#
#     tweak              the FacebookPlus tweak
#     tweak+diag         the same with FBP_DIAG=1 (the [FBPDIAG] trace)
#     bridge             FBPNotifyBridge.dylib (FBP_NOTIFY_BRIDGE=1)
#     bridge+diag        the same with FBP_DIAG=1


class SyntaxResult:
    def __init__(self, errors, warnings, checked, configs, aborted=None):
        self.errors = errors
        self.warnings = warnings
        self.checked = checked
        self.configs = configs
        self.aborted = aborted


class SyntaxChecker:
    def __init__(self, root=REPO_ROOT, jobs=None):
        self.root = root
        self.jobs = jobs or os.cpu_count() or 4
        self.src = os.path.join(root, "src")
        self.fishhook = os.path.join(self.src, "Core", "fishhook")
        self.bridge_dir = os.path.join(root, "FBPNotifyBridge", "src")
        self.plugins_inject = os.path.join(self.src, "PluginsInject")

    # -- Toolchain -----------------------------------------------------------

    def find_sdk(self):
        """The SDK theos builds against, so a check matches the build.

        FBP_SDK=xcode asks for Xcode's current iphoneos SDK instead, which is how
        you find out early what a newer SDK will say.
        """
        if os.environ.get("FBP_SDK") == "xcode":
            res = subprocess.run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"],
                                 capture_output=True, text=True, check=False)
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
                             capture_output=True, text=True, check=False)
        if res.returncode == 0 and os.path.isdir(res.stdout.strip()):
            return res.stdout.strip()

        print(f"error: no iPhoneOS SDK found under {THEOS}/sdks, and xcrun has none either.",
              file=sys.stderr)
        sys.exit(1)

    def find_clang(self):
        res = subprocess.run(["xcrun", "--find", "clang"], capture_output=True, text=True, check=False)
        if res.returncode == 0 and res.stdout.strip():
            return res.stdout.strip()
        for candidate in ("/usr/bin/clang", "clang"):
            if subprocess.run(["which", candidate], capture_output=True, check=False).returncode == 0:
                return candidate
        print("error: no clang found (tried xcrun and PATH).", file=sys.stderr)
        sys.exit(1)

    def tweak_version(self):
        path = os.path.join(self.root, "control")
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                for line in f:
                    if line.startswith("Version:"):
                        return line.split(":", 1)[1].strip()
        return "0.0.0"

    # -- What to check -------------------------------------------------------

    def walk_sources(self, *roots):
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

    def include_dirs(self, *roots):
        """Every directory a sibling header could live in, plus the repo root.

        Discovered by walking rather than listed, so a new feature directory
        needs no edit here. This is a superset of the Makefile's include path,
        which is what you want for a syntax check.
        """
        dirs = [self.root]
        for base in roots:
            for dirpath, dirnames, _ in os.walk(base):
                dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
                dirs.append(dirpath)
        return dirs

    def configurations(self, which):
        version = self.tweak_version()

        # The tweak: everything under src/, which includes the fishhook submodule
        # at src/Core/fishhook.
        tweak_files = self.walk_sources(self.src)
        tweak_defines = [f'-DFBP_VERSION=@"{version}"']

        # The bridge: its own source plus the shared PluginsInject sources,
        # exactly as FBPNotifyBridge/src/Makefile lists them.
        bridge_files = self.walk_sources(self.bridge_dir, self.plugins_inject, self.fishhook)
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

    # -- Checking one file ---------------------------------------------------

    def base_command(self, clang, sdk, incs, tmpdir):
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
            # theos ships CydiaSubstrate as a framework here; without it every
            # .xm that pulls in substrate.h fails on <CydiaSubstrate/...>.
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

    def language_for(self, path):
        if path.endswith(".c"):
            return "c"
        if path.endswith((".mm", ".xm")):
            return "objective-c++"
        return "objective-c"           # .m, .x

    def check_one(self, clang, sdk, incs, tmpdir, defines, path):
        """Return (relative path, error count, warning count, output)."""
        rel = os.path.relpath(path, self.root)
        to_check = path
        lang = self.language_for(path)

        if path.endswith((".xm", ".x")):
            # theos preprocesses Logos into <name>.xm.mm and compiles that. The
            # generated file carries #line directives back to the original, so
            # clang's diagnostics already point at the .xm.
            generated = os.path.join(tmpdir, os.path.basename(path) + (".mm" if path.endswith(".xm") else ".m"))
            res = subprocess.run(["perl", LOGOS, path], capture_output=True, text=True, check=False)
            if res.returncode != 0:
                return rel, 1, 0, f"Logos preprocessor failed:\n{res.stderr.strip()}"
            with open(generated, "w", encoding="utf-8") as f:
                f.write(res.stdout)
            to_check = generated
            lang = "objective-c++" if path.endswith(".xm") else "objective-c"

        cmd = self.base_command(clang, sdk, incs, tmpdir)
        if lang == "c":
            cmd = [a for a in cmd if a != "-fobjc-arc"]
        cmd += defines + ["-x", lang, to_check]

        proc = subprocess.run(cmd, capture_output=True, text=True, cwd=self.root, check=False)
        output = proc.stderr
        if to_check != path:
            output = output.replace(to_check, rel)

        errors = output.count(": error:") + output.count(": fatal error:")
        warnings = output.count(": warning:")
        if proc.returncode != 0 and errors == 0:
            errors = 1                 # failed for a reason it did not spell out
        return rel, errors, warnings, output.strip()

    # -- Run -----------------------------------------------------------------

    def run(self, config=None, quiet=False, report=True):
        """Check the selected configurations. Returns a SyntaxResult. When
        report is False nothing is printed, which is how the test suite calls
        it; otherwise it prints the same diagnostic report the CLI shows."""
        if not os.path.exists(LOGOS):
            if report:
                print(f"error: {LOGOS} not found. Is THEOS set correctly?", file=sys.stderr)
            return SyntaxResult(1, 0, 0, 0, aborted=f"{LOGOS} not found")

        clang = self.find_clang()
        sdk = self.find_sdk()
        configs = self.configurations(config)
        incs = self.include_dirs(self.src, self.bridge_dir, self.fishhook)

        if report:
            print(f"\n{_c('1', 'Facebook Plus diagnostic check')}")
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
                if report:
                    print(f"\n{_c('1', '[' + name + ']')} checking {len(files)} source files"
                          f"{'' if not defines else '  ' + ' '.join(defines)}")

                results = []
                with concurrent.futures.ThreadPoolExecutor(max_workers=self.jobs) as pool:
                    futures = {
                        pool.submit(self.check_one, clang, sdk, incs, tmpdir, defines, f): f
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
                        if report:
                            print(f"  {_c('91', '❌')} {rel} ({errors} error{'s' if errors != 1 else ''})")
                    elif warnings:
                        if report:
                            print(f"  {_c('93', '⚠️ ')} {rel} ({warnings} warning{'s' if warnings != 1 else ''})")
                            if not quiet:
                                print(output)
                    elif report and not quiet:
                        print(f"  {_c('92', '✅')} {rel}")

        if report:
            if failures:
                print("\n" + "=" * 68)
                for name, rel, output in failures:
                    print(f"\n{_c('91', _c('1', f'[{name}] {rel}'))}")
                    print(output)
                print("\n" + "=" * 68)
                print(_c("91", _c("1", f"💥 {total_errors} error(s) and {total_warnings} warning(s) "
                                        f"across {total_checked} compilation(s).")))
                print("=" * 68 + "\n")
            else:
                print("\n" + "=" * 68)
                print(_c("92", _c("1", f"🎉 All {total_checked} compilations across {len(configs)} "
                                        f"configuration(s) passed cleanly with 0 errors! "
                                        f"({total_warnings} warnings)")))
                print("=" * 68 + "\n")

        return SyntaxResult(total_errors, total_warnings, total_checked, len(configs))


# =============================================================================
# Project verification: compilation, localization, docs, policy, feature
# invariants. Every test reads the tree or shells out to the toolchain; none
# needs a device or a network.
# =============================================================================


SRC = Path(REPO_ROOT) / "src"
LOCALIZATIONS = Path(REPO_ROOT) / "Localizations"
STRINGS_FILE = LOCALIZATIONS / "Base.lproj" / "Localizable.strings"
AGENT_DIR = Path(REPO_ROOT) / ".agent"
WORKFLOWS = Path(REPO_ROOT) / ".github" / "workflows"

GREEN, RED, YELLOW, CYAN, BOLD, RESET = (
    "\033[92m", "\033[91m", "\033[93m", "\033[96m", "\033[1m", "\033[0m"
)
if not sys.stdout.isatty():
    GREEN = RED = YELLOW = CYAN = BOLD = RESET = ""


def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return ""


class TestRunner:
    def __init__(self, root=REPO_ROOT, verbose: bool = False):
        self.root = Path(root)
        self.verbose = verbose
        self.passed = 0
        self.failed = 0
        self.errors: list[str] = []
        self.step = 0
        self.total_steps = 7

    def log(self, msg: str):
        print(msg)

    def heading(self, title: str):
        self.step += 1
        print(f"\n{BOLD}[{self.step}/{self.total_steps}] {title}{RESET}")

    def log_verbose(self, msg: str):
        if self.verbose:
            print(f"  {CYAN}↳{RESET} {msg}")

    def record_pass(self, name: str):
        self.passed += 1
        print(f"  {GREEN}✅ PASS:{RESET} {name}")

    def record_fail(self, name: str, reason: str):
        self.failed += 1
        self.errors.append(f"{name}: {reason}")
        print(f"  {RED}❌ FAIL:{RESET} {name} - {reason}")

    def expect(self, name: str, condition: bool, reason: str):
        if condition:
            self.record_pass(name)
        else:
            self.record_fail(name, reason)

    def expect_in_file(self, name: str, path: Path, needles, reason: str = ""):
        """Every needle must appear in the file. A needle may be a tuple, meaning
        any one of its alternatives is enough."""
        if not path.exists():
            self.record_fail(name, f"{path.relative_to(self.root)} is missing")
            return
        text = _read(path)
        missing = []
        for needle in needles:
            options = needle if isinstance(needle, tuple) else (needle,)
            if not any(o in text for o in options):
                missing.append(options[0])
        if missing:
            self.record_fail(name, reason or f"not found in "
                             f"{path.relative_to(self.root)}: {missing[:3]}")
        else:
            self.record_pass(name)

    # =========================================================================
    # 1. SYNTAX & COMPILATION
    # =========================================================================
    def run_syntax_tests(self):
        self.heading("Syntax & Compilation Verification")

        try:
            res = SyntaxChecker(str(self.root)).run(report=False)
        except SystemExit as exc:
            self.record_fail("Full project typecheck", f"clang check aborted: {exc}")
            return
        except Exception as exc:  # noqa: BLE001 - any typecheck failure is recorded as a test fail, not allowed to abort the suite
            self.record_fail("Full project typecheck", str(exc))
            return

        if res.aborted:
            self.record_fail("Full project typecheck", res.aborted)
            return

        if res.errors == 0:
            detail = f"{res.checked} compilations across {res.configs} configurations"
            self.record_pass(f"{detail} typecheck cleanly under -Wall -Werror")
        else:
            self.record_fail("Full project typecheck",
                             f"the in-file clang check reported {res.errors} error(s)")

        # The four configurations must each be checkable on their own, since
        # that is how a regression in one of them is bisected.
        for config in ("tweak", "bridge"):
            try:
                cres = SyntaxChecker(str(self.root)).run(config=config, report=False)
                ok = cres.aborted is None and cres.errors == 0
                reason = cres.aborted or f"reported {cres.errors} error(s)"
            except Exception as exc:  # noqa: BLE001 - a per-config failure is recorded as a test fail, not allowed to abort the suite
                ok, reason = False, str(exc)
            self.expect(f"--config {config} runs on its own", ok, reason)

    # =========================================================================
    # 2. LOCALIZATION HYGIENE
    # =========================================================================
    def run_localization_tests(self):
        self.heading("Localization & Catalog Hygiene")

        if not STRINGS_FILE.exists():
            self.record_fail("Localizable.strings exists", f"{STRINGS_FILE} not found")
            return

        catalogs = sorted(LOCALIZATIONS.glob("*.lproj/Localizable.strings"))

        # 1. Every catalog is a well-formed property list.
        bad_lint = []
        for catalog in catalogs:
            res = subprocess.run(["plutil", "-lint", str(catalog)],
                                 capture_output=True, text=True, check=False)
            if res.returncode != 0:
                bad_lint.append(f"{catalog.parent.name}: {res.stderr.strip()}")
        self.expect(f"All {len(catalogs)} catalogs are valid property lists (plutil)",
                    not bad_lint, "; ".join(bad_lint[:3]))

        # 2. No duplicate keys, in any language. A duplicate is not an error for
        #    plutil, it silently keeps the last one, so the earlier translation
        #    is simply lost.
        key_pattern = re.compile(r'^\s*"([^"\\]*(?:\\.[^"\\]*)*)"\s*=\s*')
        keys_by_lang: dict[str, dict[str, int]] = {}
        duplicates: list[str] = []
        for catalog in catalogs:
            lang = catalog.parent.name
            seen: dict[str, int] = {}
            for idx, line in enumerate(_read(catalog).splitlines(), 1):
                m = key_pattern.match(line)
                if not m:
                    continue
                key = m.group(1)
                if key in seen:
                    duplicates.append(f"{lang}: '{key}' at lines {seen[key]} and {idx}")
                else:
                    seen[key] = idx
            keys_by_lang[lang] = seen

        base_keys = set(keys_by_lang.get("Base.lproj", {}))
        self.expect(f"Zero duplicate keys across {len(catalogs)} catalogs "
                    f"({len(base_keys)} entries in Base)",
                    not duplicates, f"duplicates: {duplicates[:4]}")

        # 3. Every translation covers Base, and adds nothing Base does not have.
        #    A key only a translation has can never be looked up.
        incomplete, orphaned = [], []
        for lang, keys in keys_by_lang.items():
            if lang == "Base.lproj":
                continue
            missing = base_keys - set(keys)
            extra = set(keys) - base_keys
            if missing:
                incomplete.append(f"{lang} missing {len(missing)} "
                                  f"(e.g. {sorted(missing)[:2]})")
            if extra:
                orphaned.append(f"{lang} has {len(extra)} not in Base "
                                f"(e.g. {sorted(extra)[:2]})")
        self.expect(f"All {len(catalogs) - 1} translations cover every Base key",
                    not incomplete, "; ".join(incomplete[:3]))
        self.expect("No translation defines a key Base does not have",
                    not orphaned, "; ".join(orphaned[:3]))

        # 4. Every FBPL("…") in the code resolves to a catalog key.
        unresolved: list[tuple[str, str]] = []
        fbpl = re.compile(r'\bFBPL\(\s*@"([^"\\]*(?:\\.[^"\\]*)*)"')
        for path in sorted(SRC.rglob("*")):
            if path.suffix not in (".m", ".mm", ".h", ".xm", ".x"):
                continue
            for key in fbpl.findall(_read(path)):
                if key not in base_keys:
                    unresolved.append((path.name, key))
        self.expect("Every FBPL(@\"…\") reference resolves to a catalog key",
                    not unresolved, f"unresolved: {unresolved[:4]}")

        # 5. The lookup itself, so the macro is not quietly a no-op.
        self.expect_in_file("FBPLocalizedString falls back to Base",
                            SRC / "Core" / "FBPResources.m",
                            ["FBPLocalizedString", "Base"],
                            "the Base fallback is what keeps an untranslated key readable")

    # =========================================================================
    # 3. DOCUMENTATION INTEGRITY
    # =========================================================================
    def run_docs_tests(self):
        self.heading(".agent/ Documentation Integrity")

        # Each entry: file, minimum bytes, concepts it must actually cover.
        # The sizes are deliberately well below the current ones; they catch a
        # file emptied or stubbed out, not one being edited.
        req_docs = [
            ("README.md", 800, ["agent", "md"]),
            ("video-download-pipeline.md", 2000, ["dash", "audio", "muxer"]),
            ("av1-photos-and-conversion.md", 3000, ["av1", "hevc", "photos"]),
            ("why-no-ffmpeg.md", 2000, ["ffmpeg", "avfoundation"]),
            ("notification-extension.md", 5000, ["app group", "keychain", "extension"]),
            ("sideload-resigning.md", 3000, ["entitlement", "keychain", "sign"]),
            ("feed-model-and-filters.md", 2000, ["feed", "token"]),
            ("survey-card-suppression.md", 1500, ["survey", "reel"]),
            ("confirmation-routing.md", 1500, ["confirm", "like"]),
            ("font-subsystem.md", 1500, ["font"]),
        ]

        for doc_name, min_bytes, expected in req_docs:
            path = AGENT_DIR / doc_name
            if not path.exists():
                self.record_fail(f"{doc_name} exists", f"{path.relative_to(self.root)} not found")
                continue
            size = path.stat().st_size
            if size < min_bytes:
                self.record_fail(f"{doc_name} content length",
                                 f"only {size} bytes, expected >= {min_bytes}")
                continue
            content = _read(path).lower()
            missing = [kw for kw in expected if kw not in content]
            if missing:
                self.record_fail(f"{doc_name} key topics", f"missing concepts: {missing}")
            else:
                self.record_pass(f"{doc_name} present & verified ({size} bytes)")

        # No device identifiers anywhere in the tree. This has had to be
        # scrubbed out of committed files once already.
        udid = re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{16}\b|\b[0-9a-fA-F]{40}\b")
        hits = []
        tracked = subprocess.run(["git", "ls-files"], cwd=str(self.root),
                                 capture_output=True, text=True, check=False).stdout.split()
        for rel in tracked:
            path = self.root / rel
            if path.suffix.lower() in (".png", ".jpg", ".ipa", ".deb", ".ttf", ".otf", ".woff2"):
                continue
            for match in udid.findall(_read(path)):
                hits.append(f"{rel}: {match[:12]}…")
        self.expect("No device UDID or serial in any tracked file",
                    not hits, f"found: {hits[:3]}")

    # =========================================================================
    # 4. RELEASE POLICY
    # =========================================================================
    def run_policy_tests(self):
        self.heading("Release Policy (no .ipa may be published)")

        self.expect("RELEASE-POLICY.md exists",
                    (self.root / ".github" / "RELEASE-POLICY.md").exists(),
                    ".github/RELEASE-POLICY.md not found")

        # 1. .gitignore refuses an .ipa anywhere, not only under test/.
        for candidate in ("packages/x.ipa", "src/x.ipa", "a/b/c.ipa"):
            res = subprocess.run(["git", "check-ignore", "-q", candidate],
                                 cwd=str(self.root), capture_output=True, check=False)
            if res.returncode != 0:
                self.record_fail("*.ipa is ignored everywhere", f"{candidate} is not ignored")
                break
        else:
            self.record_pass("*.ipa is ignored everywhere in the tree")

        # 2. Nothing resembling an .ipa is tracked.
        tracked = subprocess.run(["git", "ls-files"], cwd=str(self.root),
                                 capture_output=True, text=True, check=False).stdout.split()
        self.expect("No .ipa is tracked",
                    not [f for f in tracked if f.lower().endswith(".ipa")],
                    "an .ipa is in the index")

        # 3. The guard workflow exists, runs on release events, and skips drafts.
        guard = WORKFLOWS / "no-ipa-in-releases.yml"
        self.expect_in_file("Guard workflow deletes .ipa assets on published releases",
                            guard,
                            ["release:", "schedule:", "workflow_dispatch:",
                             "contents: write", ".draft == false",
                             'endswith(".ipa")', "-X DELETE"],
                            "the guard is what catches a hand-attached asset")

        # 4. The build workflow keeps its output in a draft, which is the one
        #    place an .ipa is allowed to exist.
        self.expect_in_file("Build workflow publishes a draft, never a release",
                            WORKFLOWS / "build-ipa.yml",
                            ["draft: true", "packages/*.ipa"],
                            "a sideloader needs the draft; publishing it is the line")

        # 5. The README must not advertise a pre-built IPA.
        readme = _read(self.root / "README.md")
        self.expect("README does not offer a pre-built .ipa download",
                    "Download the pre-built `.ipa`" not in readme,
                    "the install section still points at a published IPA")

    # =========================================================================
    # 5. DOWNLOAD PIPELINE
    # =========================================================================
    def run_downloads_tests(self):
        self.heading("Download Pipeline: picker, muxing, conversion, manager")
        downloads = SRC / "Features" / "Downloads"

        # The ladder comes from the manifest the app already holds, so a picker
        # row exists for every rung rather than just HD and SD.
        self.expect_in_file("Quality ladder is read from the DASH manifest",
                            downloads / "FBPDashManifest.m",
                            [("Representation", "representation"),
                             ("mimeType", "codecs")],
                            "the manifest parse is what makes every rung appear")

        # Each row states the size of the file that will be saved, and for a
        # converted rung that is not the download's size.
        self.expect_in_file("Picker rows carry a predicted output size",
                            downloads / "FBPDownloadVariants.m",
                            ["FBPDownloadSizeDetail", "FBPConverterExpectedOutputBytes"],
                            "the size line was removed once by mistake; this is the guard")

        # AVFoundation only. A bundled ffmpeg would add tens of megabytes, and
        # the .agent/ note explains at length why Facebook's own copy is not
        # ours to call either. Comments are stripped first: the sources discuss
        # libavcodec on purpose, and discussing it is not linking it.
        def strip_comments(text: str) -> str:
            text = re.sub(r"/\*.*?\*/", " ", text, flags=re.DOTALL)
            return re.sub(r"//[^\n]*", " ", text)

        linkage = []
        for path in sorted(SRC.rglob("*")):
            if path.suffix not in (".m", ".mm", ".h", ".xm", ".x", ".c"):
                continue
            code = strip_comments(_read(path))
            if re.search(r"#\s*include\s*[<\"]libav", code) or re.search(r"\bav_\w+\s*\(", code):
                linkage.append(path.name)
        makefiles = _read(self.root / "Makefile") + _read(
            self.root / "FBPNotifyBridge" / "src" / "Makefile")
        if re.search(r"-l\s*av(codec|format|util)", makefiles):
            linkage.append("Makefile links a libav library")
        self.expect("No ffmpeg or libav is called or linked anywhere",
                    not linkage, f"found in: {linkage[:3]}")

        self.expect_in_file("Video and audio are merged with AVFoundation, losslessly",
                            downloads / "FBPMediaMuxer.m",
                            ["AVAssetWriter", ("AVAssetReaderTrackOutput", "AVAssetReader"),
                             ("passthrough", "nil")],
                            "a stream copy, not a re-encode")

        self.expect_in_file("AV1 rungs are converted because Photos refuses them",
                            downloads / "FBPMediaConverter.m",
                            [("av01", "AV1"), ("hevc", "HEVC")],
                            "the conversion is what makes an AV1 Reel saveable")

        self.expect_in_file("Every download is a job that survives the sheet",
                            downloads / "FBPDownloadStore.m",
                            [("cancel", "Cancel"), ("retry", "Retry"), "progress"],
                            "the old progress alert *was* the download")

    # =========================================================================
    # 6. NOTIFICATIONS
    # =========================================================================
    def run_notifications_tests(self):
        self.heading("Notification Bridge & Client Sync")

        bridge_src = self.root / "FBPNotifyBridge" / "src"
        self.expect("FBPNotifyBridge sources exist",
                    (bridge_src / "FBPNotifyBridge.mm").exists(),
                    "FBPNotifyBridge/src/FBPNotifyBridge.mm not found")

        # The bridge shares PluginsInject with the tweak on purpose: the
        # container mapping and the keychain probe must not drift between the
        # app and the extension.
        self.expect_in_file("Bridge shares the PluginsInject sources with the tweak",
                            bridge_src / "Makefile",
                            ["../../src/PluginsInject/Paths.mm",
                             "../../src/PluginsInject/SecRebinds.xm",
                             "FBP_NOTIFY_BRIDGE=1"],
                            "a second copy would let the two processes disagree")

        # Facebook's own app group cannot be granted to a third-party
        # certificate, so it is redirected to one the signer owns, and every
        # failure path has to return nil rather than crash.
        self.expect_in_file("App group lookup degrades instead of crashing",
                            SRC / "PluginsInject" / "Paths.mm",
                            ["group.com.facebook.", "getAppGroupPathIfExists"],
                            "a certificate with no app group must still run the app")

        # The keychain rewrite decides per query. Rewriting every call in the
        # process broke system frameworks; passing everything through broke the
        # extension's token lookup.
        self.expect_in_file("Keychain access-group rewrite is decided per query",
                            SRC / "PluginsInject" / "SecRebinds.xm",
                            ["kSecAttrAccessGroup",
                             ("kSecUseDataProtectionKeychain", "AfterFirstUnlock")],
                            "both a blanket rewrite and a blanket pass-through have broken this")

        # The gap that made notifications arrive without text: the app takes a
        # badge-only branch and never runs the sync that fetches the words.
        self.expect_in_file("Client sync is driven for a badge-only push",
                            SRC / "Features" / "Notifications" / "FBPNotifClientSync.xm",
                            ["FBPushNotifClientSyncManager",
                             ("pnid", "PushNotifID"),
                             ("badge_update", "badgeUpdate")],
                            "without this a like or comment stays 'a new notification'")

        self.expect_in_file("The diagnostic trace compiles away but keeps its arguments",
                            SRC / "PluginsInject" / "Header.h",
                            ["FBP_DIAG", "FBPDiagLogSink", "if (0)"],
                            "a bare do-while discards them and the plain build then fails -Werror")

    # =========================================================================
    # 7. PREFERENCES & SETTINGS
    # =========================================================================
    def run_prefs_tests(self):
        self.heading("Preferences & Settings Integrity")

        header = SRC / "Core" / "FBPlus.h"
        impl = SRC / "Core" / "FBPlus.m"
        prefs = SRC / "Core" / "FBPPrefs.m"
        settings = SRC / "Settings" / "FBPSettingsController.m"

        if not all(p.exists() for p in (header, impl, prefs, settings)):
            self.record_fail("Preference files exist",
                             "one of FBPlus.h / FBPlus.m / FBPPrefs.m / FBPSettingsController.m is missing")
            return

        declared = set(re.findall(r"extern NSString \*const (FBPKey\w+)", _read(header)))
        defined = set(re.findall(r"NSString \*const (FBPKey\w+)\s*=", _read(impl)))

        self.expect(f"Catalog of {len(defined)} FBPKey constants is defined",
                    len(defined) >= 25, f"only {len(defined)} found, expected >= 25")

        self.expect("Every declared FBPKey is defined",
                    not (declared - defined),
                    f"declared but never defined: {sorted(declared - defined)[:4]}")

        self.expect("Every defined FBPKey is declared",
                    not (defined - declared),
                    f"defined but not in the header: {sorted(defined - declared)[:4]}")

        # A key with no registered default reads as NO, which silently turns a
        # feature that should ship on into one that ships off.
        prefs_text = _read(prefs)
        self.expect_in_file("Defaults are registered once at launch",
                            prefs,
                            [("registerDefaults", "defaultValues")],
                            "an unregistered key reads NO, so an on-by-default toggle ships off")

        unreferenced = sorted(
            key for key in defined
            if key not in _read(settings) and key not in prefs_text
        )
        # A key may legitimately be read only by a hook, so this reports rather
        # than fails on keys the settings page does not show.
        hook_only = []
        for key in unreferenced:
            found = subprocess.run(["git", "grep", "-l", key, "--", "src"],
                                   cwd=str(self.root), capture_output=True, text=True, check=False)
            if len(found.stdout.split()) <= 1:
                hook_only.append(key)
        self.expect("No FBPKey is defined and then never read",
                    not hook_only, f"defined but unused: {hook_only[:4]}")

        self.expect_in_file("Settings commit posts a change notification",
                            prefs,
                            ["FBPSettingsDidChangeNotification"],
                            "a hook that caches a preference needs to hear about a change")

    # =========================================================================
    # SUMMARY
    # =========================================================================
    def summarize(self) -> int:
        total = self.passed + self.failed
        self.log(f"\n{BOLD}{'=' * 68}{RESET}")
        self.log(f"{BOLD}Test Suite Summary: {self.passed}/{total} Passed{RESET}")
        self.log(f"{BOLD}{'=' * 68}{RESET}")

        if self.failed == 0:
            print(f"{GREEN}{BOLD}🎉 ALL TESTS PASSED CLEANLY WITH ZERO ERRORS!{RESET}\n")
            return 0

        print(f"{RED}{BOLD}⚠️  {self.failed} TEST(S) FAILED:{RESET}")
        for err in self.errors:
            print(f"  {RED}• {err}{RESET}")
        print()
        return 1

    def run(self) -> int:
        print(f"\n{BOLD}🚀 Facebook Plus Unified Test Runner{RESET}")
        print(f"   {self.root}")
        self.run_syntax_tests()
        self.run_localization_tests()
        self.run_docs_tests()
        self.run_policy_tests()
        self.run_downloads_tests()
        self.run_notifications_tests()
        self.run_prefs_tests()
        return self.summarize()


# =============================================================================
# CLI dispatcher
# =============================================================================


class Verify:
    def __init__(self, root=REPO_ROOT):
        self.root = root

    def build_parser(self):
        p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
        p.add_argument("--all", action="store_true", help="Run check + test (default when no group is given)")
        sub = p.add_subparsers(dest="group")

        pd = sub.add_parser("device", help="On-device operations over SSH (USB via iproxy)")
        pd.add_argument("--port", type=int, default=2222, help="Local iproxy port forwarded to device :22 (default: 2222)")
        pd.add_argument("--key", default="~/.ssh/id_ed25519", help="SSH private key (default: ~/.ssh/id_ed25519)")
        pd.add_argument("--host", "--ip", dest="host", help="SSH directly to this device IP over Wi-Fi (skips iproxy)")
        pd.add_argument("--udid", help="Device UDID passed to iproxy -u / idevicesyslog -u")
        pd.add_argument("--rebuild", action="store_true", help="Always rebuild before installing")
        dsub = pd.add_subparsers(dest="device_action", required=True)
        pdi = dsub.add_parser("install", help="Push .deb, install with dpkg, verify and restart Facebook")
        pdi.add_argument("deb", nargs="?", help="Specific .deb path (optional)")
        pdi.add_argument("--rebuild", action="store_true", help="Always rebuild before installing")
        pdi.add_argument("--no-restart", action="store_true", help="Do not restart Facebook")
        dsub.add_parser("verify", help="Verify tweak is installed on device")
        dsub.add_parser("log", help="Stream the device log filtered to the fbplus subsystem")
        dsub.add_parser("restart", help="Restart Facebook app on device")
        pds = dsub.add_parser("shell", help="Run shell command on device as root")
        pds.add_argument("command", nargs="+", help="Command to run")

        pc = sub.add_parser("check", help="Typecheck every source in all four configurations")
        pc.add_argument("-q", "--quiet", action="store_true", help="Only failures and the summary")
        pc.add_argument("--config", metavar="NAME", help="Only one configuration: tweak, tweak+diag, bridge, bridge+diag")

        pt = sub.add_parser("test", help="Run the full project invariant suite")
        pt.add_argument("-v", "--verbose", action="store_true", help="Show verbose output")
        return p

    def run(self, argv=None):
        args = self.build_parser().parse_args(argv)

        if args.group == "device":
            DeviceController(self.root).dispatch(args)
            return 0

        if args.group == "check":
            res = SyntaxChecker(self.root).run(config=args.config, quiet=args.quiet)
            return 0 if res.errors == 0 else 1

        if args.group == "test":
            return TestRunner(self.root, verbose=args.verbose).run()

        # Default (no group, or top-level --all): check then test.
        res = SyntaxChecker(self.root).run(config=None, quiet=False)
        rc_check = 0 if res.errors == 0 else 1
        rc_test = TestRunner(self.root).run()
        return rc_check or rc_test


def main():
    sys.exit(Verify(REPO_ROOT).run())


if __name__ == "__main__":
    main()
