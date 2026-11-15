#!/usr/bin/env python3
"""
Facebook Plus static audit — the tweak checked against the host app, without a
device.

Each check answers something an install would otherwise answer slowly: whether
a hook has a target, whether a pref is ever read, whether an icon name exists.
It says nothing about whether a feature behaves correctly.

    audit.py                      # all checks
    audit.py --only hooks,prefs   # some of them
    audit.py --list               # what the checks are
    audit.py --refresh            # rebuild the cached indexes first
    audit.py -v                   # list every finding, not the first few

The host app comes from test/*.ipa, extracted and indexed under .temp/facebook/.
Both are rebuilt when the IPA changes.
"""

import argparse
import gzip
import json
import plistlib
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path
from typing import ClassVar, NamedTuple

REPO = Path(__file__).resolve().parent.parent
TEMP = REPO / ".temp" / "facebook"
INDEX = TEMP / ".index"
CORE_GLYPHS = Path(
    "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist"
)

# Directories that hold build droppings, scratch clones, or third-party code,
# never the tweak's own sources.
SKIP = {".temp", ".theos", ".git", "packages", "__pycache__", "fishhook"}


def _min_ios():
    """The deployment target, read from the Makefile's TARGET line."""
    makefile = REPO / "Makefile"
    if makefile.exists():
        m = re.search(r"^TARGET\s*:?=.*:([0-9]+(?:\.[0-9]+)?)\s*$",
                      makefile.read_text(encoding="utf-8"), re.MULTILINE)
        if m:
            parts = tuple(int(p) for p in m.group(1).split(".")[:2])
            return parts + (0,) * (2 - len(parts))
    return (15, 1)


MIN_IOS = _min_ios()

# Apple framework classes the tweak hooks on purpose (CloudKit, in SideloadFix).
# They live in the dyld shared cache at runtime, never in the app binary, so the
# class index cannot see them — treat them as unverifiable, not a missing app
# class. The "CK" prefix otherwise reads as app-owned because ComponentKit ships
# hundreds of CK* classes.
SYSTEM_CLASSES = frozenset({"CKContainer", "CKEntitlements"})

# Keys the settings never offer: launch state, or values the app writes itself.
INTERNAL_KEYS = {
    "FBPKeyIntroduced",
    "FBPKeyLastNotifiedVersion",
    "FBPKeyResolvedGitHubOwner",
    "FBPKeyLanguage",
}


# =============================================================================
# Host app: extract and index
# =============================================================================


class HostApp:
    """The Facebook build under test/, with its Obj-C and asset indexes."""

    # A prefix this many classes share belongs to the host app, so a missing
    # class with it is a finding rather than a framework class out of reach.
    OWNED_PREFIX_MIN = 100

    def __init__(self, ipa=None, refresh=False):
        self.ipa = Path(ipa) if ipa else self._find_ipa()
        self.refresh = refresh
        self._classes = None
        self._selectors = None
        self._assets = None
        self._linked = None
        self._prefixes = None

    @staticmethod
    def _find_ipa():
        found = sorted((REPO / "test").glob("*.ipa"))
        if not found:
            sys.exit("[-] No .ipa in test/ — put the host app build there first.")
        return found[0]

    @property
    def binary(self):
        apps = sorted((TEMP / "Payload").glob("*.app"))
        if not apps:
            sys.exit(f"[-] No .app inside {TEMP}/Payload")
        app = apps[0]
        return app / app.stem

    def _macho_images(self):
        """The main executable plus every bundled framework binary.

        Facebook's main binary links only FBSharedFramework at launch and
        dlopens the rest; the classes most hooks target live in those framework
        binaries (FBSharedFramework alone defines tens of thousands), so an
        index of the main binary by itself would report nearly every FB hook as
        missing. Each framework executable is indexed as well.
        """
        images = [self.binary]
        frameworks = self.binary.parent / "Frameworks"
        if frameworks.is_dir():
            for fw in sorted(frameworks.glob("*.framework")):
                exe = fw / fw.stem
                if exe.is_file():
                    images.append(exe)
        return images

    def _stamp(self):
        st = self.ipa.stat()
        return f"{self.ipa.name} {st.st_size} {int(st.st_mtime)}"

    def prepare(self):
        stamp_file = INDEX / "stamp"
        if not self.refresh and stamp_file.exists() and stamp_file.read_text() == self._stamp():
            return
        if TEMP.exists():
            shutil.rmtree(TEMP)
        INDEX.mkdir(parents=True)
        print(f"==> Extracting {self.ipa.name}")
        with zipfile.ZipFile(self.ipa) as z:
            z.extractall(TEMP)
        self._build_objc_index()
        self._build_linked_index()
        self._build_asset_index()
        stamp_file.write_text(self._stamp())

    def _build_objc_index(self):
        r2 = shutil.which("r2") or shutil.which("radare2")
        if not r2:
            sys.exit("[-] radare2 not on PATH — needed to index the host app's classes.")
        print("==> Indexing Obj-C classes (radare2)")
        classes = {}
        for image in self._macho_images():
            self._index_image(r2, image, classes)
        for rec in classes.values():
            rec["inst"] = sorted(set(rec["inst"]))
            rec["cls"] = sorted(set(rec["cls"]))
        with gzip.open(INDEX / "objc.json.gz", "wt", encoding="utf-8") as fh:
            json.dump(classes, fh)
        print(f"    {len(classes)} classes total")

    @staticmethod
    def _index_image(r2, image, classes):
        """Merge one binary's Obj-C classes into the shared index."""
        res = subprocess.run(
            [r2, "-e", "bin.cache=true", "-qc", "icj", str(image)],
            capture_output=True, text=True, check=False,
        )
        if res.returncode != 0 or not res.stdout.strip():
            return
        try:
            data = json.loads(res.stdout)
        except json.JSONDecodeError:
            return
        for entry in data:
            name = entry["classname"]
            base = name.split("(", 1)[0]
            rec = classes.setdefault(base, {"super": None, "own": False,
                                            "inst": [], "cls": []})
            if base == name:
                # Categories share the base name; only the class itself counts.
                rec["own"] = True
                if entry.get("super"):
                    rec["super"] = entry["super"][0]
            for m in entry.get("methods", []):
                bucket = "cls" if "class" in (m.get("flags") or []) else "inst"
                rec[bucket].append(m["name"])
        print(f"    {image.name}: {len(data)} classes")

    def _build_linked_index(self):
        """Framework classes the app links against, by name."""
        raw = subprocess.run(["nm", "-mu", str(self.binary)],
                             capture_output=True, text=True, check=False).stdout
        names = sorted(set(re.findall(r"_OBJC_CLASS_\$_(\w+)", raw)))
        (INDEX / "linked.txt").write_text("\n".join(names))
        print(f"    {len(names)} linked framework classes")

    def _build_asset_index(self):
        print("==> Indexing the asset catalog (assetutil)")
        car = self.binary.parent / "Assets.car"
        raw = subprocess.run(
            ["xcrun", "--sdk", "iphoneos", "assetutil", "--info", str(car)],
            capture_output=True, text=True, check=True,
        ).stdout
        names = sorted({e["Name"] for e in json.loads(raw) if isinstance(e, dict) and "Name" in e})
        (INDEX / "assets.txt").write_text("\n".join(names))
        print(f"    {len(names)} assets")

    @property
    def classes(self):
        if self._classes is None:
            with gzip.open(INDEX / "objc.json.gz", "rt", encoding="utf-8") as fh:
                self._classes = json.load(fh)
        return self._classes

    @property
    def selectors(self):
        """Every selector any class in the binary implements."""
        if self._selectors is None:
            self._selectors = {s for rec in self.classes.values()
                               for s in rec["inst"] + rec["cls"]}
        return self._selectors

    @property
    def assets(self):
        if self._assets is None:
            self._assets = set((INDEX / "assets.txt").read_text().split("\n"))
        return self._assets

    @property
    def linked(self):
        if self._linked is None:
            self._linked = set((INDEX / "linked.txt").read_text().split("\n"))
        return self._linked

    @property
    def owned_prefixes(self):
        if self._prefixes is None:
            counts = {}
            for name in self.classes:
                m = re.match(r"[A-Z]{2,}", name)
                if m:
                    p = m.group(0)[:2]
                    counts[p] = counts.get(p, 0) + 1
            self._prefixes = {p for p, n in counts.items() if n >= self.OWNED_PREFIX_MIN}
        return self._prefixes

    def has_class(self, cls):
        """'defined', 'linked', 'missing', or 'unknown' — a framework class
        resolved at runtime, which this index cannot see."""
        if cls in SYSTEM_CLASSES:
            return "unknown"
        rec = self.classes.get(cls)
        if rec and rec["own"]:
            return "defined"
        if cls in self.linked:
            return "linked"
        m = re.match(r"[A-Z]{2,}", cls)
        return "missing" if m and m.group(0)[:2] in self.owned_prefixes else "unknown"

    def ancestry(self, cls):
        out, seen = [], set()
        while cls and cls not in seen:
            seen.add(cls)
            out.append(cls)
            rec = self.classes.get(cls)
            if rec is None:
                break
            cls = rec["super"]
        return out

    def implements(self, cls, selector, class_method=False):
        """Whether cls or an ancestor implements selector. None when the
        chain leaves the binary, at a UIKit or Foundation ancestor.
        """
        bucket = "cls" if class_method else "inst"
        for name in self.ancestry(cls):
            rec = self.classes.get(name)
            if rec is None:
                return None
            if selector in rec[bucket]:
                return True
        return False

    def has_dynamic_accessors(self, cls):
        """Protobuf messages resolve accessors at runtime, so a selector
        absent from the metadata proves nothing."""
        return "GPBMessage" in self.ancestry(cls)


# =============================================================================
# Facebook Plus sources
# =============================================================================


class Hook(NamedTuple):
    """One hooked method, plus what an `fbp:legacy` comment says about it."""
    where: str
    line: int
    cls: str
    selector: str
    class_method: bool
    is_new: bool
    cls_legacy: object      # the class that replaced this one, per the marker
    sel_legacy: object      # the selector that replaced this one, per the marker


class Sources:
    """What the tweak's own sources declare."""

    SRC = REPO / "src"
    SETTINGS = SRC / "Settings" / "FBPSettingsController.m"
    STRINGS = REPO / "Localizations" / "Base.lproj" / "Localizable.strings"
    ENTRY = SRC / "Core" / "FBPEntry.xm"
    CONSTANTS = SRC / "Core" / "FBPlus.m"
    DEFAULTS = SRC / "Core" / "FBPPrefs.m"
    RESOURCES = REPO / "resources"

    # Icon argument index per settings row builder.
    ICON_ARG: ClassVar[dict] = {"FBPSwitchRow": 3, "FBPActionRow": 3, "FBPInfoRow": 2}
    # Only the switch row carries a pref key, in its first argument.
    PREF_ARG = ("FBPSwitchRow",)

    def __init__(self):
        self.raw = {p: p.read_text(encoding="utf-8")
                    for p in self._source_paths()}
        self.files = {p: self._strip_comments(text) for p, text in self.raw.items()}
        self.all_source = "\n".join(self.files.values())
        self.settings = self.SETTINGS.read_text(encoding="utf-8")

    def _source_paths(self):
        found = []
        for ext in ("*.m", "*.mm", "*.h", "*.x", "*.xm"):
            for p in self.SRC.rglob(ext):
                if not set(p.parts) & SKIP:
                    found.append(p)
        return sorted(set(found))

    @staticmethod
    def _strip_comments(text):
        """Blank out comments, keeping every line and column so reported
        line numbers still match the file."""
        out, i, n = [], 0, len(text)
        while i < n:
            c = text[i]
            if c == '"':
                j = i + 1
                while j < n and text[j] != '"':
                    j += 2 if text[j] == "\\" else 1
                out.append(text[i:j + 1])
                i = j + 1
            elif text.startswith("//", i):
                j = text.find("\n", i)
                j = n if j < 0 else j
                out.append(" " * (j - i))
                i = j
            elif text.startswith("/*", i):
                j = text.find("*/", i + 2)
                j = n - 2 if j < 0 else j
                out.append(re.sub(r"[^\n]", " ", text[i:j + 2]))
                i = j + 2
            else:
                out.append(c)
                i += 1
        return "".join(out)

    def where(self, path):
        return str(path.relative_to(REPO))

    # -- Logos ---------------------------------------------------------------

    def hooks(self):
        """One Hook per hooked method."""
        out = []
        for path, text in self.files.items():
            if path.suffix not in (".x", ".xm"):
                continue
            raw = self.raw[path].split("\n")
            cls = cls_legacy = None
            pending_new = False
            for n, line in enumerate(text.split("\n"), 1):
                s = line.strip()
                if s.startswith("%hook "):
                    cls = s.split()[1].rstrip(";")
                    cls_legacy = self._legacy_marker(raw, n)
                    continue
                if s == "%end":
                    cls = cls_legacy = None
                    continue
                if cls is None:
                    continue
                if s.startswith("%new"):
                    pending_new = True
                    continue
                m = re.match(r"([-+])\s*\([^)]*\)\s*(.+?)\s*\{", s)
                if not m:
                    continue
                sel = self._selector_of(m.group(2))
                if sel:
                    out.append(Hook(self.where(path), n, cls, sel, m.group(1) == "+",
                                    pending_new, cls_legacy,
                                    self._legacy_marker(raw, n)))
                pending_new = False
        return out

    @staticmethod
    def _legacy_marker(raw, line):
        """The replacement named by an `fbp:legacy` comment above line, if any."""
        for i in range(max(0, line - 4), line - 1):
            m = re.search(r"fbp:legacy\s+([A-Za-z_][A-Za-z0-9_:]*)", raw[i])
            if m:
                return m.group(1)
        return None

    @staticmethod
    def _selector_of(signature):
        """`playerView:didTap:(id)sender` -> `playerView:didTap:`"""
        if ":" not in signature:
            return signature.split()[0] if signature else None
        parts = re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*:", signature.replace("(", " ("))
        kept = []
        depth = 0
        # only the identifiers outside a parameter's parentheses
        for token in re.finditer(r"[()]|([A-Za-z_][A-Za-z0-9_]*)\s*:", signature):
            if token.group(0) == "(":
                depth += 1
            elif token.group(0) == ")":
                depth -= 1
            elif depth == 0 and token.group(1):
                kept.append(token.group(1))
        return "".join(p + ":" for p in (kept or parts))

    def groups(self):
        declared, initialised = {}, set()
        for path, text in self.files.items():
            for n, line in enumerate(text.split("\n"), 1):
                s = line.strip()
                if s.startswith("%group "):
                    declared[s.split()[1].rstrip(";")] = (self.where(path), n)
                for m in re.finditer(r"%init\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)", line):
                    initialised.add(m.group(1))
        return declared, initialised

    def installers(self):
        """(declared, called, defined) for the FBPInit* installers.

        FBPEntry.xm both declares each installer with an `extern` prototype and
        calls it inside FBPInstallHooks; the definition lives in a feature file.
        """
        entry = self._strip_comments(self.ENTRY.read_text(encoding="utf-8"))
        declared = re.findall(
            r'extern\s+(?:"C"\s+)?void\s+(FBPInit[A-Za-z0-9_]*)\s*\(\s*void\s*\)\s*;', entry)
        called = set(re.findall(r"\b(FBPInit[A-Za-z0-9_]*)\s*\(\s*\)", entry))
        defined = set(re.findall(
            r"\bvoid\s+(FBPInit[A-Za-z0-9_]*)\s*\(\s*void\s*\)\s*\{", self.all_source))
        return declared, called, defined

    def exported(self):
        """Every FBP* function a header declares, and how often the sources
        name it. Twice is the declaration and the definition, and nothing
        else."""
        decls = {}
        for path, text in self.files.items():
            if path.suffix != ".h":
                continue
            for pat in (r"^(?:FOUNDATION_EXPORT|extern)\s+[\w\s\*<>,]+?\b(FBP\w+)\s*[(;]",
                        r"^\s*(?:[A-Za-z_][\w\s\*<>,]*?)\b(FBP\w+)\s*\([^;{]*\)\s*;"):
                for m in re.finditer(pat, text, re.MULTILINE):
                    decls.setdefault(m.group(1), self.where(path))
        return {n: (where, len(re.findall(r"\b" + n + r"\b", self.all_source)))
                for n, where in decls.items()}

    def runtime_classes(self):
        """(file, line, class, is_guard) per NSClassFromString lookup. One a
        condition tests is a guard, written for the build where the class is
        absent."""
        out = []
        for path, text in self.files.items():
            for n, line in enumerate(text.split("\n"), 1):
                for m in re.finditer(r'NSClassFromString\(@"([^"]+)"\)', line):
                    before = line[:m.start()]
                    guard = bool(re.search(r"\b(?:if|while)\s*\(|\|\||&&|[?:]\s*$",
                                           before)) or "||" in line[m.end():]
                    out.append((self.where(path), n, m.group(1), guard))
        return out

    # -- Settings ------------------------------------------------------------

    def _rows(self):
        """(builder, line, args) per settings row builder call.

        The builders are defined in this same file, so a match preceded by `*`
        (the definition's pointer return type) is the function itself, not a
        call, and is skipped.
        """
        for builder in self.ICON_ARG:
            for m in re.finditer(r"\b" + builder + r"\(", self.settings):
                if m.start() > 0 and self.settings[m.start() - 1] == "*":
                    continue
                args = self._split_args(self.settings, m.end())
                yield builder, self.settings[:m.start()].count("\n") + 1, args

    @staticmethod
    def _split_args(src, i):
        out, depth, cur, instr = [], 0, "", False
        while i < len(src):
            c = src[i]
            if instr:
                cur += c
                if c == "\\":
                    cur += src[i + 1]
                    i += 2
                    continue
                if c == '"':
                    instr = False
                i += 1
                continue
            if c == '"':
                instr = True
                cur += c
                i += 1
                continue
            if c in "([{":
                depth += 1
            elif c in ")]}":
                if depth == 0:
                    out.append(cur)
                    return out
                depth -= 1
            if c == "," and depth == 0:
                out.append(cur)
                cur = ""
                i += 1
                continue
            cur += c
            i += 1
        return out

    def icons(self):
        """icon name -> [(line, builder)]"""
        out = {}
        for builder, line, args in self._rows():
            idx = self.ICON_ARG[builder]
            if len(args) <= idx:
                continue
            m = re.fullmatch(r'@"([^"]*)"', args[idx].strip())
            if m:
                out.setdefault(m.group(1), []).append((line, builder))
        # The category menu glyphs are set as a literal kRowIcon in the category
        # dictionaries rather than through a row builder.
        for m in re.finditer(r'kRowIcon\s*:\s*@"([^"]+)"', self.settings):
            out.setdefault(m.group(1), []).append(
                (self.settings[:m.start()].count("\n") + 1, "category"))
        return out

    def shipped_images(self):
        """Basenames of the images bundled under resources/, with the @2x/@3x
        scale suffix and extension stripped."""
        names = set()
        for ext in ("*.png", "*.pdf", "*.svg"):
            for p in self.RESOURCES.rglob(ext):
                names.add(re.sub(r"@[23]x$", "", p.stem))
        return names

    def offered_prefs(self):
        """pref key (string value) -> line, for every key the settings expose."""
        constants = self.pref_constants()
        out = {}
        for builder, line, args in self._rows():
            if builder not in self.PREF_ARG or not args:
                continue
            tok = args[0].strip()
            lit = re.fullmatch(r'@"([^"]*)"', tok)
            key = lit.group(1) if lit else constants.get(tok, tok)
            out.setdefault(key, line)
        return out

    def read_prefs(self):
        """Every pref key (string value) some feature reads or registers a
        default for."""
        constants = self.pref_constants()
        raw = set()
        for path, text in self.files.items():
            if path == self.SETTINGS:
                continue
            # A key is named by its FBPKey* constant or by the literal itself.
            raw |= set(re.findall(r"\bFBPEnabled\(\s*(FBPKey[A-Za-z0-9_]*)", text))
            raw |= set(re.findall(r'\bFBPEnabled\(\s*@"([^"]+)"', text))
            raw |= set(re.findall(
                r"(?:boolForKey|stringForKey|integerForKey|setBool|setString|setInteger)"
                r":\s*(FBPKey[A-Za-z0-9_]*)", text))
            raw |= set(re.findall(
                r"(?:boolForKey|stringForKey|integerForKey|setBool|setString|setInteger)"
                r':\s*@"([^"]+)"', text))
        # The default-registration dict in FBPPrefs.m: every key with a default.
        defaults = self._strip_comments(self.DEFAULTS.read_text(encoding="utf-8"))
        raw |= set(re.findall(r"^\s*(FBPKey[A-Za-z0-9_]*)\s*:", defaults, re.MULTILINE))
        return {constants.get(k, k) for k in raw}

    def pref_constants(self):
        """FBPKey* constant name -> its string value."""
        return dict(re.findall(
            r'NSString\s*\*const\s+(FBPKey[A-Za-z0-9_]*)\s*=\s*@"([^"]+)"', self.all_source))

    def localization(self):
        """(FBPL sites, declared keys, every key the sources name).

        The third is wider than the first: a key reaches FBPL through a
        variable as often as directly, so any literal matching a declared key
        counts.
        """
        declared = {}
        for n, line in enumerate(self.STRINGS.read_text(encoding="utf-8").split("\n"), 1):
            m = re.match(r'\s*"([^"]+)"\s*=', line)
            if m:
                declared[m.group(1)] = n

        sites, named = {}, set()
        for path, text in self.files.items():
            for n, line in enumerate(text.split("\n"), 1):
                for m in re.finditer(r'FBPL\(@"([^"]+)"\)', line):
                    sites.setdefault(m.group(1), (self.where(path), n))
                for m in re.finditer(r'@"([^"]+)"', line):
                    if m.group(1) in declared:
                        named.add(m.group(1))
        return sites, declared, named


# =============================================================================
# SF Symbols
# =============================================================================


class Symbols:
    """The SF Symbol names this Mac knows, and the iOS each arrived in."""

    def __init__(self):
        if not CORE_GLYPHS.exists():
            self.names, self.release = {}, {}
            return
        with CORE_GLYPHS.open("rb") as fh:
            plist = plistlib.load(fh)
        self.names = plist["symbols"]
        self.release = {y: r.get("iOS") for y, r in plist["year_to_release"].items()}

    def available(self, name):
        """(known, iOS version string or None)"""
        year = self.names.get(name)
        if year is None:
            return False, None
        return True, self.release.get(year)

    @staticmethod
    def at_least(version, minimum=MIN_IOS):
        parts = tuple(int(p) for p in version.split(".")[:2])
        parts += (0,) * (2 - len(parts))
        return parts <= minimum


# =============================================================================
# Checks
# =============================================================================


class Audit:
    def __init__(self, app, src, symbols, verbose=False):
        self.app, self.src, self.sym, self.verbose = app, src, symbols, verbose

    # Each returns (ok, summary, findings).

    def hooks(self):
        """%hook targets exist in the host app, or say what replaced them"""
        bad, unverifiable, legacy = [], [], []
        hooks = self.src.hooks()
        for h in hooks:
            at = f"{h.where}:{h.line}"
            state = self.app.has_class(h.cls)
            if state == "missing":
                if h.cls_legacy:
                    legacy.append(self._seam(at, h.cls, h.cls_legacy, bad))
                else:
                    bad.append(f"{at} {h.cls} is not in this build and names no "
                               f"replacement — add an `fbp:legacy <class>` comment if "
                               f"that is deliberate")
                continue
            if state in ("linked", "unknown"):
                unverifiable.append(f"{at} {h.cls} is a framework class, not indexed here")
                continue
            if h.is_new:
                if self.app.implements(h.cls, h.selector, h.class_method):
                    bad.append(f"{at} %new {h.cls} -{h.selector} already exists — "
                               f"it would override")
                continue
            if self.app.implements(h.cls, h.selector, h.class_method):
                continue
            if self.app.has_dynamic_accessors(h.cls):
                unverifiable.append(f"{at} {h.cls} -{h.selector} "
                                    f"(protobuf, resolved at runtime)")
            elif h.sel_legacy:
                legacy.append(self._seam(at, f"{h.cls} -{h.selector}", h.sel_legacy, bad,
                                         cls=h.cls, class_method=h.class_method))
            elif h.selector in self.app.selectors:
                unverifiable.append(f"{at} {h.cls} -{h.selector} "
                                    f"(inherited from a framework class)")
            else:
                bad.append(f"{at} {h.cls} -{h.selector} exists on no class in this build "
                           f"and names no replacement — add an `fbp:legacy <selector>` "
                           f"comment if that is deliberate")
        summary = f"{len(hooks)} hooked methods across {len({h.cls for h in hooks})} classes"
        notes = []
        if legacy:
            notes.append(f"{len(legacy)} legacy seams")
        if unverifiable:
            notes.append(f"{len(unverifiable)} not checkable statically")
        note = "; " + ", ".join(notes) if notes else ""
        detail = legacy + unverifiable
        if bad:
            return False, f"{len(bad)} of {summary} have no target{note}", bad + (
                detail if self.verbose else [])
        return True, f"{summary} resolve{note}", detail if self.verbose else []

    def _seam(self, at, what, replacement, bad, cls=None, class_method=False):
        """Record a declared legacy seam. If its replacement is missing too,
        nothing covers this build."""
        if cls is None:
            live = self.app.has_class(replacement) in ("defined", "linked")
        else:
            live = bool(self.app.implements(cls, replacement, class_method))
        if not live:
            bad.append(f"{at} {what} is gone and so is {replacement}, which it names "
                       f"as the replacement — nothing covers this build")
        return f"{at} {what} -> {replacement} (legacy seam)"

    def groups(self):
        """every %group is initialised, and every %init names one"""
        declared, initialised = self.src.groups()
        orphan = [f"{where}:{line} %group {g} is never %init'd"
                  for g, (where, line) in sorted(declared.items()) if g not in initialised]
        unknown = [f"%init({g}) names no %group" for g in sorted(initialised - set(declared))]
        bad = orphan + unknown
        if bad:
            return False, f"{len(bad)} of {len(declared)} groups are wired wrong", bad
        return True, f"All {len(declared)} hook groups are declared and initialised", []

    def installers(self):
        """FBPEntry.xm declares, calls and defines each FBPInit* installer"""
        declared, called, defined = self.src.installers()
        bad = [f"{n} is declared in FBPEntry.xm but defined nowhere" for n in declared
               if n not in defined]
        bad += [f"{n} is declared twice in FBPEntry.xm"
                for n in sorted({n for n in declared if declared.count(n) > 1})]
        bad += [f"{n} is declared but FBPInstallHooks never calls it"
                for n in sorted(set(declared) - called)]
        bad += [f"{n} is called in FBPEntry.xm but declared nowhere there"
                for n in sorted(called - set(declared))]
        bad += [f"{n} is defined but FBPEntry.xm never calls it"
                for n in sorted(defined - called)]
        if bad:
            return False, f"{len(bad)} installers do not line up", bad
        return True, f"All {len(set(declared))} feature installers are declared, defined and called", []

    def classes(self):
        """NSClassFromString targets exist, unless the lookup is a guard"""
        lookups = self.src.runtime_classes()
        bad, notes = [], []
        for where, line, cls, guard in lookups:
            state = self.app.has_class(cls)
            if state == "missing" and not guard:
                bad.append(f"{where}:{line} {cls} is not in this build, and the lookup "
                           f"is not guarding anything")
            elif state == "missing":
                notes.append(f"{where}:{line} {cls} is absent — the guard takes the "
                             f"other branch")
            elif state == "unknown":
                notes.append(f"{where}:{line} {cls} (framework class, not indexed)")
        note = f"; {len(notes)} not checkable or guarded" if notes else ""
        if bad:
            return False, (f"{len(bad)} of {len(lookups)} runtime lookups "
                           f"cannot resolve{note}"), bad + (notes if self.verbose else [])
        return True, f"All {len(lookups)} NSClassFromString targets resolve{note}", (
            notes if self.verbose else [])

    def icons(self):
        """settings icons resolve to a shipped image or an SF Symbol"""
        icons = self.src.icons()
        shipped = self.src.shipped_images()
        bad, with_image, with_symbol = [], 0, 0
        for name, uses in sorted(icons.items()):
            at = f"{self.src.where(Sources.SETTINGS)}:{uses[0][0]}"
            if name in shipped:
                with_image += 1
                continue
            known, since = self.sym.available(name)
            if not known:
                bad.append(f"{at} {name} is neither a shipped image nor an SF Symbol")
            elif since and not self.sym.at_least(since):
                bad.append(f"{at} {name} is an SF Symbol that needs iOS {since}")
            else:
                with_symbol += 1
        notes = [f"shipped image {k} is referenced by no settings row"
                 for k in sorted(shipped - set(icons))]
        if bad:
            return False, f"{len(bad)} icon problems across {len(icons)} names", bad + (
                notes if self.verbose else [])
        return True, (f"All {len(icons)} icons resolve — {with_image} to a shipped image, "
                      f"{with_symbol} to an SF Symbol"), notes if self.verbose else []

    def prefs(self):
        """every pref the settings offer is read by a feature"""
        offered = self.src.offered_prefs()
        constants = self.src.pref_constants()
        internal = {constants.get(k, k) for k in INTERNAL_KEYS} | INTERNAL_KEYS
        read = self.src.read_prefs()
        known = set(constants.values())
        dead = [f"{self.src.where(Sources.SETTINGS)}:{line} {k}"
                for k, line in sorted(offered.items())
                if k not in read and k not in internal]
        # The other direction is a note only: a feature may be the sole writer
        # of a key, or a dedicated editor may own it (fonts, language).
        elsewhere = [f"{k} is read but no settings row offers it"
                     for k in sorted(read - set(offered) - internal)
                     if k in known]
        if dead:
            return False, (f"{len(dead)} of {len(offered)} prefs the settings offer are "
                           f"read by nothing — those rows do nothing"), dead + (
                               elsewhere if self.verbose else [])
        return True, f"All {len(offered)} prefs the settings offer are read by a feature", (
            elsewhere if self.verbose else [])

    def strings(self):
        """every FBPL key is in the catalog, and every entry is reachable"""
        sites, declared, named = self.src.localization()
        bad = [f'{w}:{l} FBPL("{k}") is not in the catalog'
               for k, (w, l) in sorted(sites.items()) if k not in declared]
        bad += [f"catalog entry {k} is named nowhere in the sources"
                for k in sorted(set(declared) - named)]
        if bad:
            return False, f"{len(bad)} of {len(declared)} catalog entries are adrift", bad
        return True, (f"All {len(declared)} catalog entries are reachable, and every "
                      f"FBPL key resolves"), []

    def symbols(self):
        """every FBP* function a header declares is called somewhere"""
        exported = self.src.exported()
        bad = [f"{where} {name} is declared and defined, and called nowhere"
               for name, (where, uses) in sorted(exported.items()) if uses <= 2]
        if bad:
            return False, f"{len(bad)} of {len(exported)} exported functions are dead", bad
        return True, f"All {len(exported)} functions the headers declare are called", []

    ORDER = ("hooks", "groups", "installers", "classes", "icons", "prefs", "strings", "symbols")

    def run(self, only=None):
        names = only or self.ORDER
        print()
        print("Facebook Plus static audit — the tweak against " + self.app.ipa.name)
        print()
        passed, results = 0, []
        for name in names:
            ok, summary, findings = getattr(self, name)()
            results.append((name, ok, summary, findings))
            passed += ok
        for name, ok, summary, findings in results:
            print(f"[{'+' if ok else '-'}] {name}: {summary}")
            shown = findings if self.verbose else findings[:8]
            for f in shown:
                print(f"      {f}")
            if len(findings) > len(shown):
                print(f"      … {len(findings) - len(shown)} more (-v for all)")
        print()
        print("-" * 80)
        print(f"Summary: {passed}/{len(results)} passed")
        print("-" * 80)
        print()
        return 0 if passed == len(results) else 1


def main():
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--ipa", help="host app to audit against (default: test/*.ipa)")
    p.add_argument("--refresh", action="store_true", help="rebuild the cached indexes")
    p.add_argument("--only", help="comma-separated subset of the checks")
    p.add_argument("--list", action="store_true", help="list the checks and exit")
    p.add_argument("-v", "--verbose", action="store_true", help="print every finding")
    args = p.parse_args()

    if args.list:
        for name in Audit.ORDER:
            print(f"  {name:<12} {getattr(Audit, name).__doc__}")
        return 0

    only = None
    if args.only:
        only = [n.strip() for n in args.only.split(",")]
        unknown = [n for n in only if n not in Audit.ORDER]
        if unknown:
            sys.exit(f"[-] No such check: {', '.join(unknown)}")

    app = HostApp(args.ipa, args.refresh)
    app.prepare()
    return Audit(app, Sources(), Symbols(), args.verbose).run(only)


if __name__ == "__main__":
    sys.exit(main())
