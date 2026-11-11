#!/usr/bin/env python3
"""
Facebook Plus Unified Project Test Runner (test-projects.py)

Consolidates the compilation, localization, documentation, release-policy and
per-feature invariant checks into one suite. Nothing here needs a device or a
network: every test reads the tree or shells out to the toolchain.

Usage:
    python3 test/test-projects.py [OPTIONS]

Options:
    --all            Run every suite (default)
    --syntax         Compile every source in all four configurations
    --localization   Localizable.strings syntax, duplicate keys, catalog coverage
    --docs           .agent/ documentation integrity
    --policy         The no-.ipa release policy and its enforcement
    --downloads      Quality picker, DASH muxing, AV1 conversion, download manager
    --notifications  The NSE session bridge and the client-sync path
    --prefs          Preference keys, defaults registration, settings UI coverage
    --verbose, -v    Show detailed execution output
    --help, -h       Display this help message
"""

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Tuple

REPO_ROOT = Path(__file__).resolve().parents[1]
SRC = REPO_ROOT / "src"
LOCALIZATIONS = REPO_ROOT / "Localizations"
STRINGS_FILE = LOCALIZATIONS / "Base.lproj" / "Localizable.strings"
AGENT_DIR = REPO_ROOT / ".agent"
CHECK_SCRIPT = REPO_ROOT / "scripts" / "check.py"
WORKFLOWS = REPO_ROOT / ".github" / "workflows"

GREEN, RED, YELLOW, CYAN, BOLD, RESET = (
    "\033[92m", "\033[91m", "\033[93m", "\033[96m", "\033[1m", "\033[0m"
)
if not sys.stdout.isatty():
    GREEN = RED = YELLOW = CYAN = BOLD = RESET = ""


def read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except Exception:
        return ""


class TestRunner:
    def __init__(self, verbose: bool = False):
        self.verbose = verbose
        self.passed = 0
        self.failed = 0
        self.errors: List[str] = []
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
            self.record_fail(name, f"{path.relative_to(REPO_ROOT)} is missing")
            return
        text = read(path)
        missing = []
        for needle in needles:
            options = needle if isinstance(needle, tuple) else (needle,)
            if not any(o in text for o in options):
                missing.append(options[0])
        if missing:
            self.record_fail(name, reason or f"not found in "
                             f"{path.relative_to(REPO_ROOT)}: {missing[:3]}")
        else:
            self.record_pass(name)

    # =========================================================================
    # 1. SYNTAX & COMPILATION
    # =========================================================================
    def run_syntax_tests(self):
        self.heading("Syntax & Compilation Verification")
        if not CHECK_SCRIPT.exists():
            self.record_fail("check.py existence", "scripts/check.py not found")
            return

        try:
            res = subprocess.run(
                [sys.executable, str(CHECK_SCRIPT), "-q"],
                cwd=str(REPO_ROOT), capture_output=True, text=True, timeout=600,
            )
        except subprocess.TimeoutExpired:
            self.record_fail("Full project typecheck", "scripts/check.py timed out after 600s")
            return
        except Exception as exc:
            self.record_fail("Full project typecheck", str(exc))
            return

        if self.verbose:
            print(res.stdout)

        if res.returncode == 0 and "passed cleanly with 0 errors" in res.stdout:
            m = re.search(r"All (\d+) compilations across (\d+) configuration", res.stdout)
            detail = (f"{m.group(1)} compilations across {m.group(2)} configurations"
                      if m else "every source")
            self.record_pass(f"{detail} typecheck cleanly under -Wall -Werror")
        else:
            output = res.stdout + res.stderr
            self.record_fail("Full project typecheck",
                             f"scripts/check.py exited {res.returncode}:\n{output[-600:]}")

        # The four configurations must each be checkable on their own, since
        # that is how a regression in one of them is bisected.
        for config in ("tweak", "bridge"):
            res = subprocess.run(
                [sys.executable, str(CHECK_SCRIPT), "-q", "--config", config],
                cwd=str(REPO_ROOT), capture_output=True, text=True,
            )
            self.expect(f"--config {config} runs on its own",
                        res.returncode == 0 and "0 errors" in res.stdout,
                        f"exited {res.returncode}")

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
                                 capture_output=True, text=True)
            if res.returncode != 0:
                bad_lint.append(f"{catalog.parent.name}: {res.stderr.strip()}")
        self.expect(f"All {len(catalogs)} catalogs are valid property lists (plutil)",
                    not bad_lint, "; ".join(bad_lint[:3]))

        # 2. No duplicate keys, in any language. A duplicate is not an error for
        #    plutil, it silently keeps the last one, so the earlier translation
        #    is simply lost.
        key_pattern = re.compile(r'^\s*"([^"\\]*(?:\\.[^"\\]*)*)"\s*=\s*')
        keys_by_lang: Dict[str, Dict[str, int]] = {}
        duplicates: List[str] = []
        for catalog in catalogs:
            lang = catalog.parent.name
            seen: Dict[str, int] = {}
            for idx, line in enumerate(read(catalog).splitlines(), 1):
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
        unresolved: List[Tuple[str, str]] = []
        fbpl = re.compile(r'\bFBPL\(\s*@"([^"\\]*(?:\\.[^"\\]*)*)"')
        for path in sorted(SRC.rglob("*")):
            if path.suffix not in (".m", ".mm", ".h", ".xm", ".x"):
                continue
            for key in fbpl.findall(read(path)):
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
                self.record_fail(f"{doc_name} exists", f"{path.relative_to(REPO_ROOT)} not found")
                continue
            size = path.stat().st_size
            if size < min_bytes:
                self.record_fail(f"{doc_name} content length",
                                 f"only {size} bytes, expected >= {min_bytes}")
                continue
            content = read(path).lower()
            missing = [kw for kw in expected if kw not in content]
            if missing:
                self.record_fail(f"{doc_name} key topics", f"missing concepts: {missing}")
            else:
                self.record_pass(f"{doc_name} present & verified ({size} bytes)")

        # No device identifiers anywhere in the tree. This has had to be
        # scrubbed out of committed files once already.
        udid = re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{16}\b|\b[0-9a-fA-F]{40}\b")
        hits = []
        tracked = subprocess.run(["git", "ls-files"], cwd=str(REPO_ROOT),
                                 capture_output=True, text=True).stdout.split()
        for rel in tracked:
            path = REPO_ROOT / rel
            if path.suffix.lower() in (".png", ".jpg", ".ipa", ".deb", ".ttf", ".otf", ".woff2"):
                continue
            for match in udid.findall(read(path)):
                hits.append(f"{rel}: {match[:12]}…")
        self.expect("No device UDID or serial in any tracked file",
                    not hits, f"found: {hits[:3]}")

    # =========================================================================
    # 4. RELEASE POLICY
    # =========================================================================
    def run_policy_tests(self):
        self.heading("Release Policy (no .ipa may be published)")

        self.expect("RELEASE-POLICY.md exists",
                    (REPO_ROOT / ".github" / "RELEASE-POLICY.md").exists(),
                    ".github/RELEASE-POLICY.md not found")

        # 1. .gitignore refuses an .ipa anywhere, not only under test/.
        for candidate in ("packages/x.ipa", "src/x.ipa", "a/b/c.ipa"):
            res = subprocess.run(["git", "check-ignore", "-q", candidate],
                                 cwd=str(REPO_ROOT), capture_output=True)
            if res.returncode != 0:
                self.record_fail("*.ipa is ignored everywhere", f"{candidate} is not ignored")
                break
        else:
            self.record_pass("*.ipa is ignored everywhere in the tree")

        # 2. Nothing resembling an .ipa is tracked.
        tracked = subprocess.run(["git", "ls-files"], cwd=str(REPO_ROOT),
                                 capture_output=True, text=True).stdout.split()
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
        readme = read(REPO_ROOT / "README.md")
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
            text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
            return re.sub(r"//[^\n]*", " ", text)

        linkage = []
        for path in sorted(SRC.rglob("*")):
            if path.suffix not in (".m", ".mm", ".h", ".xm", ".x", ".c"):
                continue
            code = strip_comments(read(path))
            if re.search(r"#\s*include\s*[<\"]libav", code) or re.search(r"\bav_\w+\s*\(", code):
                linkage.append(path.name)
        makefiles = read(REPO_ROOT / "Makefile") + read(
            REPO_ROOT / "FBPNotifyBridge" / "src" / "Makefile")
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

        bridge_src = REPO_ROOT / "FBPNotifyBridge" / "src"
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

        declared = set(re.findall(r"extern NSString \*const (FBPKey\w+)", read(header)))
        defined = set(re.findall(r"NSString \*const (FBPKey\w+)\s*=", read(impl)))

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
        prefs_text = read(prefs)
        self.expect_in_file("Defaults are registered once at launch",
                            prefs,
                            [("registerDefaults", "defaultValues")],
                            "an unregistered key reads NO, so an on-by-default toggle ships off")

        unreferenced = sorted(
            key for key in defined
            if key not in read(settings) and key not in prefs_text
        )
        # A key may legitimately be read only by a hook, so this reports rather
        # than fails on keys the settings page does not show.
        hook_only = []
        for key in unreferenced:
            found = subprocess.run(["git", "grep", "-l", key, "--", "src"],
                                   cwd=str(REPO_ROOT), capture_output=True, text=True)
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


def main():
    parser = argparse.ArgumentParser(
        description="Facebook Plus Unified Test Runner (test-projects.py)",
        formatter_class=argparse.RawTextHelpFormatter,
    )
    parser.add_argument("--all", action="store_true", help="Run every suite (default)")
    parser.add_argument("--syntax", action="store_true", help="Compilation across all configurations")
    parser.add_argument("--localization", action="store_true", help="Catalog hygiene")
    parser.add_argument("--docs", action="store_true", help=".agent/ documentation integrity")
    parser.add_argument("--policy", action="store_true", help="The no-.ipa release policy")
    parser.add_argument("--downloads", action="store_true", help="Download pipeline invariants")
    parser.add_argument("--notifications", action="store_true", help="Notification bridge & client sync")
    parser.add_argument("--prefs", action="store_true", help="Preference keys & settings")
    parser.add_argument("-v", "--verbose", action="store_true", help="Show verbose output")

    args = parser.parse_args()

    selected = (args.syntax or args.localization or args.docs or args.policy or
                args.downloads or args.notifications or args.prefs)
    run_all = args.all or not selected

    runner = TestRunner(verbose=args.verbose)
    if not run_all:
        runner.total_steps = sum([args.syntax, args.localization, args.docs, args.policy,
                                  args.downloads, args.notifications, args.prefs])

    print(f"\n{BOLD}🚀 Facebook Plus Unified Test Runner{RESET}")
    print(f"   {REPO_ROOT}")

    if run_all or args.syntax:
        runner.run_syntax_tests()
    if run_all or args.localization:
        runner.run_localization_tests()
    if run_all or args.docs:
        runner.run_docs_tests()
    if run_all or args.policy:
        runner.run_policy_tests()
    if run_all or args.downloads:
        runner.run_downloads_tests()
    if run_all or args.notifications:
        runner.run_notifications_tests()
    if run_all or args.prefs:
        runner.run_prefs_tests()

    sys.exit(runner.summarize())


if __name__ == "__main__":
    main()
