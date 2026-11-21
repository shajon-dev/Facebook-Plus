#!/usr/bin/env python3
"""Facebook Plus doctor — find bugs in the repository's tracked sources.

    doctor.py                    every check
    doctor.py --only compile     one or more checks by name
    doctor.py --list             what the checks are
    doctor.py --changed          only files that differ from HEAD
    doctor.py -v                 every finding, not the first few

WHAT THIS REPLACES, AND WHY

It replaces scripts/verify.py and scripts/audit.py, which had drifted into
answering different questions about different file sets. verify.py walked the
filesystem, so it checked build droppings and scratch copies as readily as
sources; audit.py kept its own index of the host app and its own source parser.
Between them they also missed the one failure this project actually hit: on
2026-11-21 `make check` reported 128 clean compilations while `make` failed to
link, because a function the inline assembly called had C++ linkage. A tool that
claims to find bugs has to link.

So the file set here is **what git tracks** — `git ls-files`, nothing else. A
file that is not tracked cannot break someone else's build, and a file that is
tracked will.

The checks are ordered by how early they catch a mistake, and each is
independent: a missing host app disables the host-app checks and nothing else.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import glob
import os
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
THEOS = Path(os.environ.get("THEOS", Path.home() / "theos"))
LOGOS = THEOS / "bin" / "logos.pl"

SOURCE_SUFFIXES = (".m", ".mm", ".xm", ".x", ".c")

# theos's own warning flags, from `make -n`. -Werror is the one that matters: it
# is how an unused variable built only for a trace becomes a build failure.
THEOS_WARNINGS = [
    "-Wall",
    "-Werror",
    "-Wno-deprecated-declarations",
    "-Wno-unused-command-line-argument",
]

WIDTH = 80


def divider() -> None:
    print("-" * WIDTH)


def plus(message: str) -> None:
    print(f"[+] {message}")


def minus(message: str) -> None:
    print(f"[-] {message}")


def block(text: str) -> None:
    """Indent a tool's own output so it reads as quoted, not as our own."""
    for line in text.splitlines():
        print(f"    {line}")


class Finding:
    """One thing that is wrong, located precisely enough to go and fix."""

    def __init__(self, rule: str, message: str, path=None, line: int = 0, detail: str = ""):
        self.rule = rule
        self.message = message
        self.path = path
        self.line = line
        self.detail = detail

    def __str__(self) -> str:
        where = ""
        if self.path:
            where = str(self.path)
            if self.line:
                where += f":{self.line}"
            where += " "
        return f"{where}[{self.rule}] {self.message}"


class Repo:
    """The repository, as git sees it.

    Every check takes its file list from here. `git ls-files` is the whole point:
    it excludes .theos output, .temp scratch, packages/, vendored clones and
    anything gitignored, without a hand-maintained skip list to fall out of date.
    """

    def __init__(self, root: Path = REPO):
        self.root = root
        self._cache: dict[Path, str] = {}

    def _git(self, *args: str) -> list[str]:
        res = subprocess.run(
            ["git", "-C", str(self.root), *args],
            capture_output=True, text=True, errors="replace", check=False,
        )
        if res.returncode != 0:
            return []
        return [l for l in res.stdout.splitlines() if l]

    def tracked(self) -> list[Path]:
        return [self.root / p for p in self._git("ls-files")]

    def changed(self) -> set[Path]:
        """Tracked files that differ from HEAD, plus files added to the index."""
        names = self._git("diff", "--name-only", "HEAD")
        return {self.root / n for n in names}

    def untracked_sources(self) -> list[Path]:
        """Source files git does not know about yet.

        Not checked, since the file set is deliberately what git tracks, but
        reported: a new file is the likeliest place for a new bug, and omitting
        it without a word would look like it had passed.
        """
        names = self._git("ls-files", "--others", "--exclude-standard")
        return sorted(self.root / n for n in names
                      if Path(n).suffix in SOURCE_SUFFIXES)

    def sources(self, only_changed: bool = False) -> list[Path]:
        files = [p for p in self.tracked() if p.suffix in SOURCE_SUFFIXES and p.is_file()]
        if only_changed:
            changed = self.changed()
            files = [p for p in files if p in changed]
        return sorted(files)

    def text(self, path: Path) -> str:
        """File contents, read once per run."""
        if path not in self._cache:
            try:
                self._cache[path] = path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                self._cache[path] = ""
        return self._cache[path]

    def rel(self, path: Path) -> Path:
        try:
            return path.relative_to(self.root)
        except ValueError:
            return path

    @staticmethod
    def strip_comments(text: str) -> str:
        """Blank out comments, keeping every newline and every string literal.

        Comments have to go, because this project documents in prose the very
        patterns the rules look for, and a rule that matches its own
        documentation reports the explanation as the bug. String literals have
        to STAY: a preference key's value and an FBPL key live inside them, so
        blanking them makes every one of those checks silently find nothing —
        which is how the first draft of this file reported 47 keys as undefined
        and no missing localizations at all.

        Line numbers survive because each removed character becomes a space.
        """
        out = []
        i, n = 0, len(text)
        while i < n:
            two = text[i:i + 2]
            if two == "//":
                j = text.find("\n", i)
                j = n if j < 0 else j
                out.append(" " * (j - i))
                i = j
            elif two == "/*":
                j = text.find("*/", i + 2)
                j = n if j < 0 else j + 2
                out.append("".join(ch if ch == "\n" else " " for ch in text[i:j]))
                i = j
            else:
                out.append(text[i])
                i += 1
        return "".join(out)


class Toolchain:
    """clang, the SDK, logos, and the four configurations this project ships.

    src/PluginsInject/ is compiled twice — into the tweak and into
    FBPNotifyBridge.dylib — under different defines, and a change that is clean
    in one can fail -Werror in the other. Checking one configuration is checking
    half the build.
    """

    CONFIGS = ("tweak", "tweak+diag", "bridge", "bridge+diag")

    def __init__(self, repo: Repo):
        self.repo = repo
        self.clang = self._find_clang()
        self.sdk = self._find_sdk()
        self.min_ios = self._min_ios()

    @staticmethod
    def _find_clang() -> str:
        res = subprocess.run(["xcrun", "--find", "clang"], capture_output=True, text=True, errors="replace", check=False)
        if res.returncode == 0 and res.stdout.strip():
            return res.stdout.strip()
        return "clang"

    def _find_sdk(self) -> str:
        """The SDK theos builds against, so a check matches the build.

        FBP_SDK=xcode asks for Xcode's current iphoneos SDK instead, which is how
        to find out early what a newer SDK will say.
        """
        if os.environ.get("FBP_SDK") == "xcode":
            res = subprocess.run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"],
                                 capture_output=True, text=True, errors="replace", check=False)
            if res.returncode == 0 and Path(res.stdout.strip()).is_dir():
                return res.stdout.strip()

        def version_key(path: str):
            m = re.search(r"iPhoneOS([\d.]+)\.sdk", os.path.basename(path))
            return tuple(int(x) for x in m.group(1).split(".")) if m else (0,)

        sdks = sorted(glob.glob(str(THEOS / "sdks" / "iPhoneOS*.sdk")), key=version_key)
        if sdks:
            return sdks[-1]
        res = subprocess.run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"],
                             capture_output=True, text=True, errors="replace", check=False)
        return res.stdout.strip() if res.returncode == 0 else ""

    def _min_ios(self) -> str:
        """The deployment target, read from the Makefile rather than hardcoded."""
        makefile = self.repo.root / "Makefile"
        if makefile.exists():
            m = re.search(r"^TARGET\s*:?=\s*\S+:\S+:\S+:([\d.]+)",
                          makefile.read_text(encoding="utf-8"), re.M)
            if m:
                return m.group(1)
        return "15.1"

    def version(self) -> str:
        control = self.repo.root / "control"
        if control.exists():
            for line in control.read_text(encoding="utf-8").splitlines():
                if line.startswith("Version:"):
                    return line.split(":", 1)[1].strip()
        return "0.0.0"

    def configurations(self, sources: list[Path], which: str | None = None):
        """(name, files, defines) per configuration, from the tracked file list.

        Which sources belong to which target is decided by path, exactly as the
        two Makefiles list them: everything under src/ builds into the tweak,
        and the bridge builds its own source plus the shared PluginsInject and
        fishhook sources.
        """
        src = self.repo.root / "src"
        bridge_src = self.repo.root / "FBPNotifyBridge" / "src"
        shared = (src / "PluginsInject", src / "Core" / "fishhook")

        def under(path: Path, *roots: Path) -> bool:
            return any(root in path.parents for root in roots)

        tweak_files = [p for p in sources if under(p, src)]
        bridge_files = [p for p in sources if under(p, bridge_src, *shared)]

        defines = [f'-DFBP_VERSION=@"{self.version()}"']
        bridge_defines = ["-DFBP_NOTIFY_BRIDGE=1"]
        all_configs = [
            ("tweak", tweak_files, defines),
            ("tweak+diag", tweak_files, defines + ["-DFBP_DIAG=1"]),
            ("bridge", bridge_files, bridge_defines),
            ("bridge+diag", bridge_files, bridge_defines + ["-DFBP_DIAG=1"]),
        ]
        if not which:
            return [c for c in all_configs if c[1]]
        return [c for c in all_configs if c[0] == which or c[0].startswith(which + "+")]

    def include_dirs(self) -> list[str]:
        """Every directory a sibling header could live in, from tracked files."""
        dirs = {str(self.repo.root)}
        for path in self.repo.tracked():
            if path.suffix in (".h", ".hpp") or path.suffix in SOURCE_SUFFIXES:
                dirs.add(str(path.parent))
        return sorted(dirs)

    def base_command(self, tmpdir: str) -> list[str]:
        cmd = [
            self.clang,
            "-fsyntax-only",
            "-target", f"arm64-apple-ios{self.min_ios}",
            "-isysroot", self.sdk,
            "-I" + str(THEOS / "include"),
            "-I" + str(THEOS / "include" / "iphone"),
            "-I" + str(THEOS / "vendor" / "include"),
            "-I" + str(THEOS / "include" / "_fallback"),
            "-I" + tmpdir,
            "-F" + str(Path(self.sdk) / "System" / "Library" / "Frameworks"),
            "-F" + str(Path(self.sdk) / "System" / "Library" / "PrivateFrameworks"),
            "-F" + str(THEOS / "vendor" / "lib"),
            "-F" + str(THEOS / "vendor" / "lib" / "iphone" / "rootless"),
            "-DTARGET_IPHONE=1",
            "-DDEBUG",
            "-fobjc-arc",
            "-ferror-limit=0",
        ] + THEOS_WARNINGS
        for inc in self.include_dirs():
            cmd += ["-I", inc]
        return cmd

    @staticmethod
    def language_for(path: Path) -> str:
        if path.suffix == ".c":
            return "c"
        if path.suffix in (".mm", ".xm"):
            return "objective-c++"
        return "objective-c"


class Check:
    """A named, independent pass over the repository."""

    name = "check"
    summary = ""

    def run(self, ctx: "Doctor") -> list[Finding]:
        raise NotImplementedError


class CompileCheck(Check):
    name = "compile"
    summary = "typecheck every tracked source, in all four shipped configurations"

    def run(self, ctx: "Doctor") -> list[Finding]:
        tool, repo = ctx.toolchain, ctx.repo
        configs = tool.configurations(ctx.sources, ctx.config)
        if not configs:
            return [Finding(self.name, f"no such configuration: {ctx.config}")]

        findings: list[Finding] = []
        with tempfile.TemporaryDirectory() as tmpdir:
            base = tool.base_command(tmpdir)
            for name, files, defines in configs:
                ctx.detail(f"{name}: {len(files)} file(s)  {' '.join(defines)}")
                with concurrent.futures.ThreadPoolExecutor(max_workers=ctx.jobs) as pool:
                    futures = {
                        pool.submit(self._one, tool, base, defines, tmpdir, path): path
                        for path in files
                    }
                    for future in concurrent.futures.as_completed(futures):
                        path, errors, output = future.result()
                        rel = repo.rel(path)
                        if errors:
                            findings.append(Finding(
                                self.name, f"does not compile in {name}",
                                path=rel, detail=output))
                        else:
                            ctx.detail(f"ok {rel}")
        return findings

    @staticmethod
    def _one(tool: Toolchain, base: list[str], defines: list[str], tmpdir: str, path: Path):
        """Typecheck one file, preprocessing Logos sources first."""
        to_check = path
        lang = tool.language_for(path)

        if path.suffix in (".xm", ".x"):
            suffix = ".mm" if path.suffix == ".xm" else ".m"
            generated = Path(tmpdir) / (path.name + suffix)
            res = subprocess.run(["perl", str(LOGOS), str(path)],
                                 capture_output=True, text=True, errors="replace", check=False)
            if res.returncode != 0:
                return path, 1, f"Logos preprocessor failed:\n{res.stderr.strip()}"
            # Logos emits #line directives pointing back at the original, so
            # clang reports the real file and line, not the generated copy.
            generated.write_text(res.stdout, encoding="utf-8")
            to_check = generated

        cmd = base + defines + ["-x", lang, str(to_check)]
        res = subprocess.run(cmd, capture_output=True, text=True, errors="replace", check=False)
        output = (res.stderr or "").strip()
        errors = len(re.findall(r":\d+:\d+: error:", output))
        if res.returncode != 0 and errors == 0:
            errors = 1
        return path, errors, output


class LinkCheck(Check):
    """The step `make check` never did.

    A typecheck sees one translation unit at a time, so it cannot see a symbol
    that nothing defines. On 2026-11-21 that gap cost a build: inline assembly
    called `_FBPFdsDecide` while the C++ compiler had given the function a
    mangled name, 128 files typechecked clean, and the link failed. This runs
    the real thing and reports what the linker said.
    """

    name = "link"
    summary = "build and link both targets, which a typecheck cannot do"

    TARGETS = (
        ("tweak", ["make"]),
        ("bridge", ["make", "-C", "FBPNotifyBridge/src", "FINALPACKAGE=1"]),
    )

    def run(self, ctx: "Doctor") -> list[Finding]:
        findings: list[Finding] = []
        for name, cmd in self.TARGETS:
            ctx.detail(f"{name}: {' '.join(cmd)}")
            res = subprocess.run(cmd, cwd=str(ctx.repo.root),
                                 capture_output=True, text=True, errors="replace", check=False)
            if res.returncode == 0:
                continue
            combined = (res.stdout or "") + (res.stderr or "")
            # Undefined symbols are the interesting case and the verbose one:
            # keep the linker's own lines, which name the symbol, the object it
            # was referenced from, and often the fix.
            lines = [l for l in combined.splitlines()
                     if "Undefined symbol" in l or "error:" in l
                     or l.strip().startswith('"') or "referenced from" in l
                     or "possibly missing" in l]
            findings.append(Finding(
                self.name, f"[{name}] failed to build",
                detail="\n".join(lines[:40]) or combined.strip()[-2000:]))
        return findings


class SourceIndex:
    """What the tweak's own sources say, parsed once.

    Everything here reads comment-stripped text, so a rule cannot match the
    prose that documents it.
    """

    HOOK = re.compile(r"^\s*%hook\s+([A-Za-z_][A-Za-z0-9_]*)", re.M)
    GROUP = re.compile(r"^\s*%group\s+([A-Za-z_][A-Za-z0-9_]*)", re.M)
    INIT = re.compile(r"%init\(\s*([A-Za-z_][A-Za-z0-9_]*)")
    FBPL = re.compile(r'FBPL\(\s*@"([^"]+)"')
    KEY_DECL = re.compile(r"^extern\s+NSString\s*\*const\s+(FBPKey[A-Za-z0-9_]*)\s*;", re.M)
    KEY_DEF = re.compile(r'^NSString\s*\*const\s+(FBPKey[A-Za-z0-9_]*)\s*=\s*@"([^"]+)"', re.M)
    KEY_USE = re.compile(r"\b(FBPKey[A-Za-z0-9_]*)\b")
    ICON = re.compile(r'@"([a-z][a-z0-9]*(?:\.[a-z0-9]+)+)"')
    # %init(Group, Placeholder = cls) binds a stand-in class name declared in
    # our own sources to whatever the runtime resolved. The placeholder is
    # deliberately not a real class, so it must never be reported as missing.
    BOUND = re.compile(r"%init\([^)]*?([A-Za-z_][A-Za-z0-9_]*)\s*=")

    def __init__(self, repo: Repo, sources: list[Path]):
        self.repo = repo
        self.sources = sources
        self.clean = {p: Repo.strip_comments(repo.text(p)) for p in sources}
        headers = [p for p in repo.tracked() if p.suffix == ".h" and p.is_file()]
        self.clean.update({p: Repo.strip_comments(repo.text(p)) for p in headers})

    def lines(self, path: Path) -> list[str]:
        return self.clean[path].splitlines()

    def declared_keys(self) -> dict[str, Path]:
        found = {}
        for path, text in self.clean.items():
            for name in self.KEY_DECL.findall(text):
                found[name] = path
        return found

    def defined_keys(self) -> dict[str, tuple[str, Path]]:
        found = {}
        for path, text in self.clean.items():
            for name, value in self.KEY_DEF.findall(text):
                found[name] = (value, path)
        return found

    def key_uses(self) -> dict[str, set[Path]]:
        uses: dict[str, set[Path]] = {}
        for path, text in self.clean.items():
            if path.suffix == ".h":
                continue
            for name in self.KEY_USE.findall(text):
                uses.setdefault(name, set()).add(path)
        return uses

    def bound_placeholders(self) -> set[str]:
        return {m for text in self.clean.values() for m in self.BOUND.findall(text)}

    def localization_uses(self) -> list[tuple[str, Path, int]]:
        out = []
        for path, text in self.clean.items():
            for i, line in enumerate(text.splitlines(), 1):
                for key in self.FBPL.findall(line):
                    out.append((key, path, i))
        return out


class PrefCheck(Check):
    """A preference that is declared, defined, defaulted and read — or named."""

    name = "prefs"
    summary = "every FBPKey is declared, defined, given a default and read"

    def run(self, ctx: "Doctor") -> list[Finding]:
        index, repo = ctx.index, ctx.repo
        declared = index.declared_keys()
        defined = index.defined_keys()
        uses = index.key_uses()
        findings: list[Finding] = []

        for name, path in sorted(declared.items()):
            if name not in defined:
                findings.append(Finding(
                    self.name, f"{name} is declared but never defined",
                    path=repo.rel(path)))
        for name, (_, path) in sorted(defined.items()):
            if name not in declared:
                findings.append(Finding(
                    self.name, f"{name} is defined but never declared",
                    path=repo.rel(path)))

        # Only boolean switches: a key read through FBPEnabled() reads as NO
        # when it has no registered default, which silently disables a feature
        # that is supposed to ship on. A string preference legitimately has no
        # entry in that table, so flagging those would be noise.
        prefs_impl = repo.root / "src" / "Core" / "FBPPrefs.m"
        defaults = index.clean.get(prefs_impl, "")
        boolean = {m for text in index.clean.values()
                   for m in re.findall(r"FBPEnabled\(\s*(FBPKey[A-Za-z0-9_]*)", text)}
        for name in sorted(boolean & set(defined)):
            if defaults and name not in defaults:
                findings.append(Finding(
                    self.name,
                    f"{name} is read with FBPEnabled() but has no registered default — "
                    f"it reads as NO until someone sets it",
                    path=repo.rel(prefs_impl)))

        # A key read nowhere but its own definition is a switch wired to
        # nothing: the UI offers it and no code consults it.
        core = {repo.root / "src" / "Core" / "FBPlus.m", repo.root / "src" / "Core" / "FBPlus.h"}
        for name, (_, path) in sorted(defined.items()):
            readers = uses.get(name, set()) - core
            if not readers:
                findings.append(Finding(
                    self.name, f"{name} is never read outside its own definition",
                    path=repo.rel(path)))
        return findings


class StringCheck(Check):
    name = "strings"
    summary = "every FBPL(@\"…\") resolves to a key in Base.lproj"

    def run(self, ctx: "Doctor") -> list[Finding]:
        base = ctx.repo.root / "Localizations" / "Base.lproj" / "Localizable.strings"
        if not base.exists():
            return [Finding(self.name, "Base.lproj/Localizable.strings is missing",
                            path=ctx.repo.rel(base))]
        # `.strings` is the old NeXTSTEP format, not an XML plist — plistlib
        # refuses it outright, so validity comes from plutil (which does read
        # it) and the keys from a line scan. Getting this wrong makes the check
        # report the catalog as broken and every lookup as missing.
        lint = subprocess.run(["plutil", "-lint", str(base)],
                              capture_output=True, text=True, errors="replace", check=False)
        if lint.returncode != 0:
            return [Finding(self.name,
                            f"Base.lproj/Localizable.strings is not a valid catalog: "
                            f"{(lint.stdout or lint.stderr).strip()}",
                            path=ctx.repo.rel(base))]
        catalog = set(re.findall(r'^\s*"([^"]+)"\s*=',
                                 base.read_text(encoding="utf-8"), re.M))

        findings = []
        for key, path, line in ctx.index.localization_uses():
            if key not in catalog:
                findings.append(Finding(
                    self.name, f'FBPL(@"{key}") has no entry in Base.lproj',
                    path=ctx.repo.rel(path), line=line))
        return findings


class LintCheck(Check):
    """Rules this repository learned the hard way.

    Each one is here because it shipped as a bug, not because it reads badly.
    """

    name = "lint"
    summary = "repository rules whose violations have shipped before"

    # The installers re-run for every image dyld loads — 781 of them in one
    # device launch — so a report placed next to an FBP_ONCE install instead of
    # inside it logs 781 times. Five such lines filled a 4,000-line log and
    # pushed everything else out of it.
    ONCE = re.compile(r"^(\s*)FBP_ONCE\(")
    LOG = re.compile(r"^\s*FBPLog\(")

    def run(self, ctx: "Doctor") -> list[Finding]:
        findings: list[Finding] = []
        for path in ctx.sources:
            lines = ctx.index.lines(path)
            rel = ctx.repo.rel(path)
            for i, line in enumerate(lines):
                if not self.ONCE.match(line):
                    continue
                # A report on the line after a one-line FBP_ONCE, at the same
                # indentation, is outside the guard.
                indent = self.ONCE.match(line).group(1)
                if not line.rstrip().endswith("}"):
                    continue
                # The offset matters: reporting a fixed line number sends the
                # reader to the wrong line whenever the report is not exactly
                # one line down, which is most of the time.
                for offset, follow in enumerate(lines[i + 1:i + 3], start=1):
                    if follow.startswith(indent + "FBPLog("):
                        findings.append(Finding(
                            self.name,
                            "install report sits outside its FBP_ONCE — use FBPLogOnce, "
                            "or the installer's every re-run logs it again",
                            path=rel, line=i + 1 + offset,
                            detail=follow.strip()))
                        break

        # The sideload redirects must ask whether this process actually holds
        # the entitlement before rewriting anything: on a jailbroken App Store
        # install they do hold it, and redirecting moves the session somewhere
        # the notification extension never looks.
        for name in ("src/PluginsInject/SideloadFix.xm",
                     "FBPNotifyBridge/src/FBPNotifyBridge.mm"):
            path = ctx.repo.root / name
            text = ctx.index.clean.get(path)
            if text is None:
                continue
            if "containerURLForSecurityApplicationGroupIdentifier" in text \
                    and "fbpShouldLeaveAppGroupAlone" not in text:
                findings.append(Finding(
                    self.name,
                    "container redirect does not check whether this signature holds "
                    "the group (fbpShouldLeaveAppGroupAlone)",
                    path=ctx.repo.rel(path)))
        return findings


class HostApp:
    """The extracted Facebook app's Objective-C class list, cached.

    Optional by design: without the extracted app, or without radare2, the one
    check that needs it says so and the rest of the run is unaffected.

    The index comes from radare2's class listing, not from `nm`. That is not a
    preference — `nm` only reports classes with an exported symbol, which most
    of Facebook's are not, and the first draft of this file used it and declared
    thirty working hooks dead, FBBaseAppDelegate among them. A check that reports
    working code as broken is worse than no check.

    Building the index reads every Mach-O image in the bundle and takes the best
    part of a minute, so it is cached next to the app and rebuilt only when an
    image changes.
    """

    def __init__(self, root: Path = REPO / ".temp" / "facebook"):
        self.root = root
        self.cache = root / ".doctor-classes.json"
        self._classes: set[str] | None = None

    @property
    def available(self) -> bool:
        return self.root.is_dir() and bool(self._radare2())

    @staticmethod
    def _radare2() -> str | None:
        for name in ("r2", "radare2"):
            found = shutil.which(name)
            if found:
                return found
        return None

    def _images(self) -> list[Path]:
        """Every Mach-O image in the bundle: the app, its frameworks, its appexes."""
        images = []
        for path in sorted(self.root.rglob("*")):
            if not path.is_file() or path.suffix:
                continue
            try:
                with path.open("rb") as handle:
                    magic = handle.read(4)
            except OSError:
                continue
            if magic in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe"):
                images.append(path)
        return images

    def _stamp(self, images: list[Path]) -> str:
        return "|".join(f"{p.relative_to(self.root)}:{p.stat().st_size}" for p in images)

    def classes(self) -> set[str]:
        if self._classes is not None:
            return self._classes

        images = self._images()
        stamp = self._stamp(images)
        if self.cache.exists():
            try:
                cached = json.loads(self.cache.read_text(encoding="utf-8"))
                if cached.get("stamp") == stamp:
                    self._classes = set(cached["classes"])
                    return self._classes
            except (OSError, ValueError, KeyError):
                pass

        r2 = self._radare2()
        found: set[str] = set()
        for image in images:
            res = subprocess.run(
                [r2, "-e", "scr.color=0", "-qc", "icq", str(image)],
                capture_output=True, text=True, errors="replace", check=False,
            )
            for line in res.stdout.splitlines():
                # icq prints one class per line as
                #
                #     0x1000198f8 [0x100004a24 - 0x10000ab28] objc Name Super
                #
                # so the name is the token after the language. A category
                # arrives as Class(Category) and its class still counts; a Swift
                # class arrives as Module.Class, and the bare name is recorded
                # too because the sources hook whichever spelling resolves.
                parts = line.split()
                for marker in ("objc", "swift"):
                    if marker in parts:
                        index = parts.index(marker)
                        if index + 1 < len(parts):
                            name = parts[index + 1].split("(", 1)[0]
                            if name:
                                found.add(name)
                                if "." in name:
                                    found.add(name.rsplit(".", 1)[-1])
                        break
        self._classes = found
        try:
            self.cache.write_text(
                json.dumps({"stamp": stamp, "classes": sorted(found)}), encoding="utf-8")
        except OSError:
            pass
        return found


class HookCheck(Check):
    name = "hooks"
    summary = "every %hook names a class the host app actually has"

    def run(self, ctx: "Doctor") -> list[Finding]:
        app = ctx.host
        if not app.root.is_dir():
            ctx.skip(f"no extracted app at {ctx.repo.rel(app.root)}")
            return []
        if not app.available:
            ctx.skip("radare2 is not on PATH, so the class list cannot be read")
            return []
        ctx.detail("indexing the host app's classes (cached after the first run)")
        classes = app.classes()
        if not classes:
            ctx.skip("no class could be read from the extracted app")
            return []

        placeholders = ctx.index.bound_placeholders()
        findings = []
        for path in ctx.sources:
            text = ctx.index.clean[path]
            for match in SourceIndex.HOOK.finditer(text):
                name = match.group(1)
                if name in classes or name in placeholders:
                    continue
                # A mangled Swift name is how the sources reach a Swift class;
                # r2 reports the same class as Module.Class, so compare the
                # decoded spelling as well.
                decoded = self.demangle_swift(name)
                if decoded and (decoded in classes or decoded.rsplit(".", 1)[-1] in classes):
                    continue
                # Only namespaces this check can actually judge. An Apple class
                # is hooked by name too and is not in the app's own images, so
                # a report there describes where the class lives, not the hook.
                if not name.startswith(self.OWNED_PREFIXES):
                    continue
                line = text[:match.start()].count("\n") + 1
                findings.append(Finding(
                    self.name,
                    f"%hook {name} — no such class in the extracted app "
                    f"(renamed, or the group never installs)",
                    path=ctx.repo.rel(path), line=line))
        return findings

    # Prefixes Meta owns. Everything else belongs to Apple or to a vendored
    # library, where "not in the app's images" is the normal state.
    OWNED_PREFIXES = ("FB", "META", "MSG", "FDS", "IG", "Luna", "Snacks", "MRC", "FNF")

    @staticmethod
    def demangle_swift(name: str) -> str | None:
        """_TtC18FBRADLConfigHelper18FBRADLConfigHelper -> Module.Class.

        Only the one shape the sources use: a class nested directly in a module.
        Anything else returns None rather than a guess.
        """
        if not name.startswith("_TtC"):
            return None
        rest, parts = name[4:], []
        while rest and rest[0].isdigit():
            digits = len(rest) - len(rest.lstrip("0123456789"))
            length = int(rest[:digits])
            parts.append(rest[digits:digits + length])
            rest = rest[digits + length:]
        return ".".join(parts) if len(parts) == 2 and not rest else None


class Doctor:
    """Runs the checks and reports what they found."""

    CHECKS = (CompileCheck, LinkCheck, PrefCheck, StringCheck, LintCheck, HookCheck)

    # Enough to act on without burying the summary; -v prints the rest.
    LIMIT = 25

    def __init__(self, args):
        self.repo = Repo()
        self.toolchain = Toolchain(self.repo)
        self.host = HostApp()
        self.verbose = args.verbose
        self.jobs = args.jobs or os.cpu_count() or 4
        self.config = args.config
        self.only_changed = args.changed
        self.sources = self.repo.sources(only_changed=args.changed)
        self.index = SourceIndex(self.repo, self.sources)
        self._only = {n.strip() for n in args.only.split(",")} if args.only else None

    def detail(self, message: str) -> None:
        """Progress, printed only when asked for. A clean run should say little."""
        if self.verbose:
            plus(message)

    def skip(self, reason: str) -> None:
        plus(f"Skipped: {reason}")

    def selected(self):
        for cls in self.CHECKS:
            if self._only is None or cls.name in self._only:
                yield cls()

    def run(self) -> int:
        divider()
        plus("FACEBOOK PLUS DOCTOR")
        divider()

        if not self.sources:
            minus("git tracks no source files here — nothing to check")
            divider()
            return 0

        plus(f"Tracked Sources: {len(self.sources)}"
             f"{' (changed only)' if self.only_changed else ''}")
        plus(f"Deployment Target: arm64-apple-ios{self.toolchain.min_ios}")
        plus(f"SDK: {self.toolchain.sdk or '(none found)'}")

        untracked = self.repo.untracked_sources()
        if untracked:
            minus(f"Not checked, because git does not track them yet: "
                  f"{', '.join(str(self.repo.rel(p)) for p in untracked)}")

        findings: list[Finding] = []
        for check in self.selected():
            divider()
            plus(f"{check.name.upper()}: {check.summary}")
            found = check.run(self)
            findings.extend(found)
            if found:
                minus(f"{len(found)} finding(s)")
            else:
                plus("Clean")

        divider()
        if not findings:
            plus("No findings. Every tracked source compiles, links, and holds "
                 "to the repository's rules.")
            divider()
            return 0

        minus(f"{len(findings)} finding(s)")
        divider()
        shown = findings if self.verbose else findings[:self.LIMIT]
        for finding in shown:
            minus(str(finding))
            if finding.detail:
                block(finding.detail)
        if len(shown) < len(findings):
            plus(f"{len(findings) - len(shown)} more — re-run with -v to see them all")
        divider()
        return 1


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="doctor.py",
        description="Find bugs in the repository's git-tracked sources.")
    parser.add_argument("--only", help="comma-separated check names (see --list)")
    parser.add_argument("--list", action="store_true", help="list the checks and exit")
    parser.add_argument("--changed", action="store_true",
                        help="only sources that differ from HEAD")
    parser.add_argument("--config", help="limit the compile check to one configuration")
    parser.add_argument("-j", "--jobs", type=int, help="parallel compile jobs")
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="every file and every finding")
    args = parser.parse_args()

    if args.list:
        divider()
        plus("CHECKS")
        divider()
        for cls in Doctor.CHECKS:
            plus(f"{cls.name:<9} {cls.summary}")
        divider()
        return 0

    return Doctor(args).run()


if __name__ == "__main__":
    sys.exit(main())
