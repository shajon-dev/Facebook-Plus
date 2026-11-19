#!/usr/bin/env python3
# Facebook Plus build driver. Self-contained: it builds every packaging scheme
# with theos, injects the rootless build into a decrypted Facebook IPA with cyan
# (custom icons, the keychain patch, the Safari web extensions and the NSE
# session bridge), and signs + installs the result over USB or SSH. The only
# external build tool it relies on is the theos Makefile (`make`).
#
# Options:
#   --all / --rootless / --rootfull   scheme(s) to build (default --all)
#   --debug                           build with FBP_DIAG=1 (the [FBPDIAG] trace)
#   --ipa                             inject the rootless .deb into the Facebook IPA
#   --no-ipa                          build the .deb package(s) only, no injection
#   --install                         sign + install over USB; given ALONE it skips
#                                     the build and installs the existing packages/ IPA
#   --install --ssh                   dpkg the rootless .deb onto a jailbroken device
#                                     over SSH (iproxy over USB, or --host over network)
#   --host <ip> / --port <n> / --key  SSH transport options for --ssh
#   --no-restart                      don't restart Facebook after an SSH install
#   --drop-nse                        sign/install without the notification extension
#                                     (for a certificate that carries no App Group)
#   -u / --udid <UDID>                target this device
#   --clean                           remove build artifacts and packages/
#   -h / --help                       usage
#
# --install prefers `xcrun devicectl` and falls back to `ideviceinstaller` for
# older iOS, asking which device when several are connected.

import copy
import os
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path
from typing import ClassVar

try:
    from dotenv import load_dotenv
except ImportError:
    # python-dotenv is a local-dev convenience for loading .env; CI has neither
    # the package nor a .env, so fall back to a no-op there.
    def load_dotenv(*_args, **_kwargs):
        return False

ROOT = str(Path(__file__).resolve().parent)

# Simulator UUID, physical iPhone id, and the legacy 40-hex form.
UDID_RE = re.compile(
    r"[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}"
    r"|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}"
    r"|[0-9A-Fa-f]{40}"
)


def rel(path):
    return str(path).replace(ROOT + os.sep, "")


class Log:
    @staticmethod
    def section():
        print("-" * 80)

    @staticmethod
    def info(message):
        print("[+] " + rel(message))

    @staticmethod
    def warn(message):
        print("[-] " + rel(message), file=sys.stderr)

    @staticmethod
    def error(message):
        print("[-] " + rel(message), file=sys.stderr)

    @staticmethod
    def blank():
        print()


class Paths:
    def __init__(self):
        self.root = Path(__file__).resolve().parent
        self.control = self.root / "control"
        self.packages = self.root / "packages"
        self.ipa_in = self.root / "test" / "com.facebook.Facebook.ipa"
        self.logo_dir = self.root / "resources" / "logo"
        self.certificates = self.root / "test" / "certificates"
        self.safari_ext = self.root / "OpenInFacebookSafariExtension"
        self.bridge_dir = self.root / "FBPNotifyBridge" / "src"
        self.bridge_built = self.bridge_dir / ".theos" / "obj" / "FBPNotifyBridge.dylib"
        self.bridge_dylib = self.packages / "FBPNotifyBridge.dylib"

    def theos(self):
        return os.environ.get("THEOS") or str(Path.home() / "theos")

    def make_env(self, debug=False):
        env = dict(os.environ)
        env["THEOS"] = self.theos()
        if debug:
            # The Makefile's own diagnostic switch; there is no FBP_EXTRA_CFLAGS
            # or version-suffix knob, so a debug build keeps the release names.
            env["FBP_DIAG"] = "1"
        return env


class Control:
    def __init__(self, paths):
        self.version = "0.0.0"
        self.package_id = "com.unknown"
        for line in paths.control.read_text(encoding="utf-8").splitlines():
            if line.startswith("Version:"):
                self.version = line.split(":", 1)[1].strip()
            elif line.startswith("Package:"):
                self.package_id = line.split(":", 1)[1].strip()


class IpaVersion:
    # Marketing version from an IPA's own top-level Info.plist, used to name the
    # injected IPA after the exact Facebook build it targets.
    @staticmethod
    def read(ipa_path):
        with zipfile.ZipFile(ipa_path) as ipa:
            plists = sorted(
                (name for name in ipa.namelist()
                 if name.startswith("Payload/") and name.endswith(".app/Info.plist")),
                key=lambda name: name.count("/"),
            )
            if not plists:
                return "unknown"
            info = plistlib.loads(ipa.read(plists[0]))
            return info.get("CFBundleShortVersionString") or info.get("CFBundleVersion") or "unknown"


class IconPlist:
    # Builds the CFBundleIcons merge plist cyan's -l needs. cyan's -l does a
    # shallow top-level overwrite, so a bare CFBundleIcons would wipe Facebook's
    # own icons; the target's real CFBundleIcons are read and the fbplus_* logos
    # are added as alternates, leaving the originals in place.
    VARIANT_SUFFIXES = ("@2x", "@3x", "-iPad@2x", "-iPadPro@2x")

    def __init__(self, paths):
        self.logo_dir = paths.logo_dir

    def _read_info(self, target):
        target = str(target)
        if target.lower().endswith(".ipa"):
            with zipfile.ZipFile(target) as zf:
                names = [n for n in zf.namelist()
                         if n.startswith("Payload/") and n.endswith(".app/Info.plist")
                         and n.count("/") == 2]
                if not names:
                    raise SystemExit("error: no Payload/*.app/Info.plist in the ipa")
                return plistlib.loads(zf.read(names[0]))
        with open(target, "rb") as f:
            return plistlib.load(f)

    def _discover_icons(self):
        # { base -> [existing CFBundleIconFiles entries] }. The base is the plain
        # iPhone @2x file; the -iPad@2x / -iPadPro@2x files are idiom variants.
        icons = {}
        for path in sorted(self.logo_dir.glob("fbplus_*@2x.png")):
            stem = path.name[: -len("@2x.png")]
            if stem.endswith(("-iPad", "-iPadPro")):
                continue
            files = [stem + s for s in self.VARIANT_SUFFIXES
                     if (self.logo_dir / (stem + s + ".png")).is_file()]
            icons[stem] = files
        return icons

    def build(self, target):
        info = self._read_info(target)
        custom = self._discover_icons()
        if not custom:
            raise SystemExit("error: no fbplus_* logos in resources/logo/")
        merged = {}
        for key in ("CFBundleIcons", "CFBundleIcons~ipad"):
            if key not in info:
                continue
            icons = copy.deepcopy(info[key])
            alternates = icons.setdefault("CFBundleAlternateIcons", {})
            for base, files in custom.items():
                alternates[base] = {"CFBundleIconFiles": files, "UIPrerenderedIcon": False}
            merged[key] = icons
        if not merged:
            raise SystemExit("error: target Info.plist has no CFBundleIcons — cannot register alternates")
        return merged, custom

    def write(self, target, out_path):
        merged, custom = self.build(target)
        with open(out_path, "wb") as f:
            plistlib.dump(merged, f)
        Log.info("Built custom app-icon plist: " + str(len(custom)) + " icon(s) [" + ", ".join(custom) + "]")
        return out_path


class TweakBuilder:
    # Per-scheme `make package` + the versioned rename to
    # packages/Facebook-Plus-v<version>-<label>.deb. Each entry is
    # (THEOS_PACKAGE_SCHEME, Architecture-override): rootfull is theos's empty
    # scheme; roothide is the rootless layout (/var/jb) repackaged as arm64e,
    # which roothide's package manager expects. (A roothide-native build would
    # need roothide's own theos fork; this theos has no "roothide" scheme, so the
    # arch relabel is the portable approximation, matching how comparable projects
    # ship a roothide .deb.)
    SCHEME_VALUES: ClassVar[dict] = {
        "rootless": ("rootless", None),
        "rootfull": ("", None),
        "roothide": ("", "iphoneos-arm64e"),
    }

    def __init__(self, paths, control, debug):
        self.paths = paths
        self.control = control
        self.debug = debug
        self.version = control.version

    def output_deb(self, label):
        return self.paths.packages / ("Facebook-Plus-v" + self.version + "-" + label + ".deb")

    def clean_packages(self):
        # Every run starts from an empty packages/: a stale artifact next to a
        # fresh one is how the wrong file ends up signed and shipped. Scoped to
        # packages/ — the input IPA in test/ is never touched.
        self.paths.packages.mkdir(parents=True, exist_ok=True)
        for pattern in ("*.deb", "*.dylib", "*.ipa", "*.zip"):
            for stale in self.paths.packages.glob(pattern):
                stale.unlink()

    def build_scheme(self, label):
        scheme, arch = self.SCHEME_VALUES[label]
        out = self.output_deb(label)
        env = self.paths.make_env(self.debug)
        Log.section()
        Log.info("Building " + label + " (THEOS_PACKAGE_SCHEME='" + scheme + "'" +
                 (", Architecture=" + arch if arch else "") + ")")
        subprocess.run(["make", "clean"], cwd=str(self.paths.root), env=env, check=True, stdout=subprocess.DEVNULL)
        # Clear any previous raw theos output so the freshest build is unambiguous.
        for stale in self.paths.packages.glob(self.control.package_id + "_*.deb"):
            stale.unlink()

        # roothide is the default (rootful) layout under an arm64e arch label, the
        # same way comparable projects ship one. theos writes the package's
        # Architecture from THEOS_PACKAGE_ARCH (makefiles/package/deb.mk), and a
        # command-line value overrides what it would otherwise read from control,
        # so no file is touched.
        cmd = ["make", "package", "FINALPACKAGE=1", "THEOS_PACKAGE_SCHEME=" + scheme]
        if arch:
            cmd.append("THEOS_PACKAGE_ARCH=" + arch)
        subprocess.run(cmd, cwd=str(self.paths.root), env=env, check=True)

        produced = sorted(self.paths.packages.glob(self.control.package_id + "_*.deb"),
                          key=lambda p: p.stat().st_mtime, reverse=True)
        if not produced:
            raise SystemExit("error: no .deb was produced for the " + label + " scheme.")
        if out.exists():
            out.unlink()
        produced[0].replace(out)
        Log.info(label + ": " + str(out))
        return out

    def build_trollfools(self):
        # The TrollFools variant is just our own code — the compiled dylib and the
        # resource bundle — zipped for the TrollFools app to inject into a
        # user's own installed Facebook. No Facebook binary is involved, so unlike
        # the injected .ipa this is safe to publish. The substrate the dylib links
        # (@rpath/CydiaSubstrate.framework) is NOT shipped: theos only carries a
        # link-time .tbd stub, and TrollFools supplies ElleKit itself at inject
        # time. App extensions (Safari, the NSE bridge) cannot ride along this way
        # — they live in the app's PlugIns — so this variant is tweak-only.
        obj = self.paths.root / ".theos" / "obj"
        dylib = obj / "FacebookPlus.dylib"
        bundle = obj / "FacebookPlus.bundle"
        if not dylib.is_file() or not bundle.is_dir():
            raise SystemExit("error: .theos/obj/FacebookPlus.{dylib,bundle} missing — "
                             "build a scheme before the TrollFools zip.")
        out = self.paths.packages / ("Facebook-Plus-v" + self.version + "-TrollFools.zip")
        if out.exists():
            out.unlink()
        Log.section()
        Log.info("Packaging TrollFools (dylib + bundle)")
        with tempfile.TemporaryDirectory() as td:
            staged = Path(td)
            shutil.copy2(dylib, staged / "FacebookPlus.dylib")
            shutil.copytree(bundle, staged / "FacebookPlus.bundle", symlinks=True)
            # The `zip` CLI keeps the bundle's symlinks intact, which a naive
            # zipfile walk would flatten.
            subprocess.run(
                ["zip", "-qry", "-X", str(out), "FacebookPlus.dylib", "FacebookPlus.bundle"],
                cwd=str(staged), check=True,
            )
        Log.info("TrollFools: " + str(out))
        return out

    def build(self, labels):
        self.clean_packages()
        results = [self.build_scheme(label) for label in labels]
        Log.section()
        Log.info("Built package(s):")
        for deb in results:
            print("  " + rel(deb))
        return results


class SafariExtensions:
    # Builds each Safari web extension under OpenInFacebookSafariExtension/*/ and
    # returns the finished .appex bundles for cyan to place under PlugIns.
    def __init__(self, paths, debug):
        self.paths = paths
        self.debug = debug

    def build_all(self):
        plugins = []
        if not self.paths.safari_ext.is_dir():
            return plugins
        env = self.paths.make_env(self.debug)
        for ext_mk in sorted(self.paths.safari_ext.glob("*/Makefile")):
            ext_dir = ext_mk.parent
            Log.info("Building Safari web extension in " + str(ext_dir))
            subprocess.run(["make", "-C", str(ext_dir), "FINALPACKAGE=1"],
                           cwd=str(self.paths.root), env=env, check=True, stdout=subprocess.DEVNULL)
            # Only the final bundle at .theos/obj/*.appex carries the resources
            # and Info.plist; the per-arch intermediates hold just the binary.
            appex = None
            for candidate in sorted((ext_dir / ".theos" / "obj").glob("*.appex")):
                if (candidate / "Info.plist").is_file():
                    appex = candidate
                    break
            if appex:
                plugins.append(appex)
            else:
                Log.warn("no complete .appex produced in " + str(ext_dir) + " — skipping.")
        return plugins


class NSEBridge:
    # Builds FBPNotifyBridge.dylib and injects it into the IPA's notification
    # service extension. The bridge applies the main app's container/keychain
    # redirects inside the appex, so a re-signed build can still resolve the
    # logged-in session and render real notification text.
    APPEX_REL = "Payload/Facebook.app/PlugIns/NotificationServiceExtension.appex"

    def __init__(self, paths, debug):
        self.paths = paths
        self.debug = debug

    def build(self):
        # Returns the built dylib path, or None (every failure is a warning: an
        # IPA without the bridge is still a valid build of everything else).
        # The dylib is deliberately not a Makefile target of the tweak, so cyan
        # cannot also inject it into the main binary.
        env = self.paths.make_env(self.debug)
        for stale in (self.paths.bridge_built, self.paths.bridge_dylib):
            if stale.exists():
                stale.unlink()
        result = None
        try:
            r = subprocess.run(["make", "-C", str(self.paths.bridge_dir), "FINALPACKAGE=1"],
                               cwd=str(self.paths.root), env=env, stdout=subprocess.DEVNULL, check=False)
            if r.returncode != 0:
                Log.warn("the NSE session bridge failed to build — continuing without it.")
            elif not self.paths.bridge_built.is_file():
                Log.warn("the NSE session bridge built no dylib — continuing without it.")
            else:
                shutil.copy2(self.paths.bridge_built, self.paths.bridge_dylib)
                Log.info("NSE session bridge: " + str(self.paths.bridge_dylib))
                result = self.paths.bridge_dylib
        finally:
            # theos mirrors the shared-source relative paths into stamp dirs under
            # FBPNotifyBridge/src/src/; they hold only empty markers. Remove them
            # to keep the tree clean (theos recreates them on the next build).
            shutil.rmtree(self.paths.bridge_dir / "src", ignore_errors=True)
        return result

    @staticmethod
    def _insert_dylib_tool():
        # cyan ships its own per-platform insert_dylib inside its Python package;
        # neither it nor optool is on PATH. Resolve it from the cyan entry point.
        cyan_bin = shutil.which("cyan")
        if not cyan_bin:
            return None
        real = os.path.realpath(cyan_bin)
        pkg = None
        venv_py = Path(real).parent / "python3"
        if venv_py.exists():
            r = subprocess.run([str(venv_py), "-c", "import cyan; print(list(cyan.__path__)[0])"],
                               capture_output=True, text=True, check=False)
            if r.returncode == 0 and r.stdout.strip():
                pkg = r.stdout.strip()
        if not pkg:
            lib = Path(real).parent.parent / "lib"
            for candidate in sorted(lib.glob("python*/site-packages/cyan")):
                if candidate.is_dir():
                    pkg = str(candidate)
                    break
        if not pkg:
            return None
        tool = Path(pkg) / "tools" / platform.system() / platform.machine() / "insert_dylib"
        return str(tool) if tool.is_file() and os.access(str(tool), os.X_OK) else None

    def inject(self, ipa_path, dylib):
        if not dylib or not Path(dylib).is_file():
            Log.warn(str(dylib) + " not built — IPA ships without the NSE session bridge.")
            return
        ldid = shutil.which("ldid")
        if not ldid:
            Log.warn("ldid not found — IPA ships without the NSE session bridge.")
            return
        tool = self._insert_dylib_tool()
        if not tool:
            Log.warn("cyan's bundled insert_dylib not found — IPA ships without the NSE session bridge.")
            return

        ipa_abs = Path(ipa_path).resolve()
        work = Path(tempfile.mkdtemp())
        new_ipa = Path(str(work) + ".ipa")
        try:
            Log.info("Injecting the NSE session bridge into " + str(ipa_path))
            subprocess.run(["unzip", "-q", str(ipa_abs), "-d", str(work)], check=True)
            appex = work / self.APPEX_REL
            exe = appex / "NotificationServiceExtension"
            if not exe.is_file():
                Log.warn(self.APPEX_REL + "/NotificationServiceExtension not in the IPA — skipping the bridge.")
                return

            # Capture the appex's original entitlements before insert_dylib strips
            # the signature; preserving them is what keeps the extension working
            # under TrollStore.
            ents = work / "nse.entitlements"
            try:
                with open(ents, "wb") as fh:
                    subprocess.run([ldid, "-e", str(exe)], stdout=fh, stderr=subprocess.DEVNULL, check=False)
            except OSError:
                pass

            shutil.copy2(dylib, appex / "FBPNotifyBridge.dylib")
            subprocess.run([tool, "--weak", "--inplace", "--all-yes",
                            "@executable_path/FBPNotifyBridge.dylib", str(exe)],
                           stdout=subprocess.DEVNULL, check=True)

            # Match cyan's -s treatment: fakesign the added dylib and the rewritten
            # appex binary, re-applying the captured entitlements where present.
            subprocess.run([ldid, "-S", str(appex / "FBPNotifyBridge.dylib")], check=True)
            if ents.is_file() and ents.stat().st_size > 0:
                subprocess.run([ldid, "-S" + str(ents), str(exe)], check=True)
            else:
                subprocess.run([ldid, "-S", str(exe)], check=True)
            if ents.is_file():
                ents.unlink()

            # -y keeps symlinks as symlinks; the app bundle contains some.
            subprocess.run(["zip", "-qry", str(new_ipa), "Payload"], cwd=str(work), check=True)
            shutil.move(str(new_ipa), str(ipa_abs))
            Log.info("NSE session bridge injected (@executable_path/FBPNotifyBridge.dylib).")
        finally:
            shutil.rmtree(work, ignore_errors=True)
            if new_ipa.exists():
                new_ipa.unlink()


class IpaInjector:
    # The cyan injection step: rootless .deb + custom icons + Safari extensions
    # + icon-merge plist, then the NSE bridge after cyan.
    def __init__(self, paths, control, debug):
        self.paths = paths
        self.control = control
        self.debug = debug

    def _cyan(self):
        local = Path.home() / ".local" / "bin" / "cyan"
        if local.exists():
            return str(local)
        return shutil.which("cyan")

    def inject(self, rootless_deb):
        if not self.paths.ipa_in.is_file():
            Log.section()
            Log.info(str(self.paths.ipa_in) + " not found — built the .deb package(s) only.")
            print("    Drop a decrypted Facebook IPA there and re-run to produce an injected IPA.")
            return None
        if not rootless_deb or not Path(rootless_deb).is_file():
            Log.info(str(rootless_deb) + " not built (rootless not in schemes) — skipping injection.")
            return None
        cyan = self._cyan()
        if not cyan:
            raise SystemExit("error: cyan not found — install it with 'pip install --user cyan' (pyzule-rw).")

        fb_version = IpaVersion.read(self.paths.ipa_in)
        ipa_out = self.paths.packages / ("Facebook-Plus-v" + fb_version + "-rootless.ipa")
        if ipa_out.exists():
            ipa_out.unlink()

        logos = sorted(self.paths.logo_dir.glob("fbplus_*.png")) if self.paths.logo_dir.is_dir() else []
        icon_merge = None
        if logos:
            fd, icon_merge = tempfile.mkstemp(suffix=".plist")
            os.close(fd)
            IconPlist(self.paths).write(self.paths.ipa_in, icon_merge)

        plugins = SafariExtensions(self.paths, self.debug).build_all()

        nse_enabled = (os.environ.get("NSE_BRIDGE") or "1") != "0"
        bridge = NSEBridge(self.paths, self.debug).build() if nse_enabled else None

        bundle_id = os.environ.get("BUNDLE_ID")

        # Every injectable goes under ONE -f. cyan's -f replaces on repeat rather
        # than appending, so a second -f would silently drop the first — which is
        # exactly how the tweak .deb went missing once a second injectable was
        # added as its own -f. Order: tweak .deb, app-icon PNGs, Safari
        # extension(s).
        inject = [str(rootless_deb)]
        inject += [str(logo) for logo in logos]
        inject += [str(appex) for appex in plugins]

        cmd = [cyan, "-i", str(self.paths.ipa_in), "-o", str(ipa_out), "-f", *inject]
        if icon_merge:
            cmd += ["-l", str(icon_merge)]
        if bundle_id:
            cmd += ["-b", bundle_id]
        cmd += ["--overwrite", "-uwsgq"]

        try:
            Log.section()
            Log.info("Injecting " + str(rootless_deb) + " into " + str(self.paths.ipa_in) + " with cyan")
            subprocess.run(cmd, cwd=str(self.paths.root), check=True)
        finally:
            if icon_merge and os.path.exists(icon_merge):
                os.remove(icon_merge)

        if nse_enabled:
            NSEBridge(self.paths, self.debug).inject(ipa_out, bridge)
        else:
            Log.info("NSE_BRIDGE=0 — skipped the notification-service bridge.")

        Log.info("Done. Injected IPA: " + str(ipa_out))
        return ipa_out


class Signer:
    # Signs with the per-device material in test/certificate/, named by UDID. A
    # profile provisions only its own device, and the wrong one signs cleanly
    # before the device rejects it.
    ZSIGN = "/opt/homebrew/bin/zsign"
    NSE_PATH = "Payload/Facebook.app/PlugIns/NotificationServiceExtension.appex"

    def __init__(self, paths):
        self.paths = paths

    @staticmethod
    def _password_opens(p12, password):
        # openssl needs -legacy for the old RC2/3DES PKCS#12 these p12 use.
        for extra in (["-legacy"], []):
            r = subprocess.run(["openssl", "pkcs12", "-in", str(p12), "-nokeys", "-passin", "pass:" + password, *extra],
                               capture_output=True, check=False)
            if r.returncode == 0:
                return True
        return False

    def _password(self):
        password = os.environ.get("FBP_CERT_PASSWORD")
        if password is not None:
            return password
        pw_file = self.paths.certificates / "password.txt"
        return pw_file.read_text(encoding="utf-8").strip() if pw_file.is_file() else "1"

    def _credentials(self, udid=""):
        certs = self.paths.certificates
        if not certs.is_dir():
            Log.error("test/certificate/ not found — add <UDID>.p12 + <UDID>.mobileprovision to sign.")
            return None
        if udid:
            p12 = certs / (udid + ".p12")
            profile = certs / (udid + ".mobileprovision")
            if not p12.is_file() or not profile.is_file():
                Log.error("No certificate for device " + udid + " — expected " + rel(p12) + " and " + rel(profile) + ".")
                available = sorted(p.stem for p in certs.glob("*.p12"))
                if available:
                    print("    Certificates on hand (by device UDID): " + ", ".join(available))
                return None
        else:
            p12s = sorted(certs.glob("*.p12"))
            if len(p12s) != 1:
                Log.error("Can't choose a certificate automatically — pass -u <UDID> so the matching <UDID>.p12 is used.")
                return None
            p12 = p12s[0]
            profile = p12.with_suffix(".mobileprovision")
            if not profile.is_file():
                Log.error("Provisioning profile not found: " + rel(profile))
                return None
        password = self._password()
        if not self._password_opens(p12, password):
            Log.error("Certificate password is wrong for " + p12.name + " — set $FBP_CERT_PASSWORD (default '1').")
            return None
        return {"p12": p12, "profile": profile, "password": password}


    def drop_nse(self, ipa):
        # A copy without the notification service extension, for a certificate
        # with no App Group. An App Group cannot be re-prefixed to the signer's
        # team, so the extension carries an entitlement the profile cannot grant
        # and the install is refused because of it.
        trimmed = (ipa.removesuffix(".ipa")) + "-nonse.ipa"
        Log.info("Removing the notification service extension...")
        shutil.copyfile(ipa, trimmed)
        r = subprocess.run(["zip", "-q", "-d", trimmed, self.NSE_PATH + "/*"], capture_output=True, text=True, check=False)
        if r.returncode == 12:  # zip: nothing to do
            Log.warn("This IPA has no notification service extension — nothing to drop.")
        elif r.returncode != 0:
            try:
                os.remove(trimmed)
            except OSError:
                pass
            raise SystemExit("error: could not remove the extension from the IPA:\n" + (r.stderr or "").strip())
        else:
            Log.warn("Generic notifications will not be fixed in this build — the extension that does that is gone.")
        return trimmed

    def sign(self, ipa_path, udid="", drop_nse=False):
        # Return the signed IPA path, or None when signing was skipped or failed.
        if not ipa_path or not Path(ipa_path).is_file():
            return None
        creds = self._credentials(udid)
        if not creds:
            return None
        zsign = self.ZSIGN if Path(self.ZSIGN).exists() else shutil.which("zsign")
        if not zsign:
            Log.error("zsign not found at " + self.ZSIGN + " or on PATH — cannot sign.")
            return None

        source = str(ipa_path)
        if drop_nse:
            source = self.drop_nse(source)

        base = Path(source).stem
        base = base.removesuffix("-signed")
        signed = Path(source).with_name(base + "-signed.ipa")
        in_place = signed.resolve() == Path(source).resolve()
        out = signed.with_name(base + "-signing.tmp.ipa") if in_place else signed
        if out.exists():
            out.unlink()

        # The IPA already carries the NSE session bridge, injected once at build
        # time (NSEBridge.inject). Signing only re-signs it — it never re-injects,
        # so install is install. (drop_nse above removes the appex entirely for a
        # certificate without the App Group entitlement.)
        Log.section()
        Log.info("Signing " + source + " for device " + (udid or "(sole certificate)"))
        Log.info("Certificate: " + creds["p12"].name)
        cmd = [zsign, "-f", "-k", str(creds["p12"]), "-p", creds["password"], "-m", str(creds["profile"]),
               "-o", str(out), source]
        subprocess.run(cmd, cwd=str(self.paths.root), check=True)
        if in_place:
            out.replace(signed)
        Log.info("Signed IPA: " + str(signed))
        return signed


class DeviceInstaller:
    # Device discovery + install. devicectl is tried first (iOS 17+);
    # ideviceinstaller (libimobiledevice) is the fallback that reaches an older
    # iOS. With several devices connected and a TTY, input() asks which one.
    IDEVICEINSTALLER = "/opt/homebrew/bin/ideviceinstaller"

    def __init__(self, paths):
        self.paths = paths

    # --- discovery ---------------------------------------------------------
    @staticmethod
    def _list_devicectl():
        # Slice by the header's fixed column positions: the State column can carry
        # spaces ("available (paired)"), so whitespace splitting breaks.
        try:
            raw = subprocess.run(["xcrun", "devicectl", "list", "devices"], capture_output=True, text=True, check=False).stdout
        except FileNotFoundError:
            return [], ""
        lines = raw.splitlines()
        header_idx = next((i for i, ln in enumerate(lines) if "Identifier" in ln and "State" in ln), None)
        if header_idx is None:
            return [], raw
        header = lines[header_idx]
        columns = ["Name", "Hostname", "Identifier", "State", "Model", "Reality"]
        starts = [header.index(c) for c in columns]
        devices = []
        for ln in lines[header_idx + 1:]:
            if not ln.strip() or set(ln.strip()) <= {"-", " "}:
                continue
            fields = {}
            for i, col in enumerate(columns):
                end = starts[i + 1] if i + 1 < len(starts) else None
                fields[col] = ln[starts[i]:end].strip()
            m = UDID_RE.search(fields["Identifier"])
            if not m:
                continue
            devices.append({"name": fields["Name"], "udid": m.group(0), "state": fields["State"],
                            "model": fields["Model"], "reality": fields["Reality"], "ios": ""})
        return devices, raw

    @staticmethod
    def _lockdown_value(udid, key):
        if not shutil.which("ideviceinfo"):
            return ""
        try:
            out = subprocess.run(["ideviceinfo", "-u", udid, "-k", key], capture_output=True, text=True, timeout=10, check=False)
        except (FileNotFoundError, subprocess.TimeoutExpired):
            return ""
        return out.stdout.strip() if out.returncode == 0 else ""

    @classmethod
    def _list_usbmux(cls):
        # libimobiledevice sees the older half of the world — a jailbroken phone
        # on an old iOS is invisible to devicectl without this.
        if not shutil.which("idevice_id"):
            return []
        try:
            raw = subprocess.run(["idevice_id", "-l"], capture_output=True, text=True, timeout=10, check=False).stdout
        except (FileNotFoundError, subprocess.TimeoutExpired):
            return []
        devices = []
        for line in raw.splitlines():
            udid = line.strip()
            if not UDID_RE.fullmatch(udid):
                continue
            devices.append({"name": cls._lockdown_value(udid, "DeviceName"), "udid": udid,
                            "state": "connected (usbmux)", "model": cls._lockdown_value(udid, "ProductType"),
                            "reality": "physical", "ios": cls._lockdown_value(udid, "ProductVersion")})
        return devices

    @classmethod
    def _all_devices(cls):
        devices, raw = cls._list_devicectl()
        known = {d["udid"].lower() for d in devices}
        for d in cls._list_usbmux():
            if d["udid"].lower() not in known:
                devices.append(d)
        return devices, raw

    @staticmethod
    def _is_physical(device):
        # Never a simulator — this pushes an IPA down a USB cable.
        return "simul" not in (device.get("reality") or "").lower()

    @classmethod
    def select_udid(cls, override=""):
        if override:
            return override
        Log.info("Looking for connected devices...")
        devices, raw = cls._all_devices()
        devices = [d for d in devices if cls._is_physical(d)]
        if not devices:
            if raw.strip():
                print(raw)
            raise SystemExit("error: no device found. Plug in & unlock the iPhone, trust this computer, then rerun (or pass -u <UDID>).")

        def describe(d):
            extra = (", iOS " + d["ios"]) if d.get("ios") else ""
            return (d["model"] or d["name"] or "iPhone") + "  [" + d["state"] + "]  " + d["udid"] + "  (" + d["reality"] + extra + ")"

        def chosen(d):
            if "connected" not in d["state"].lower() and "usbmux" not in d["state"].lower():
                Log.warn("Device state is '" + d["state"] + "' — it is paired but may not be plugged in/unlocked right now, which will fail the install.")
            return d["udid"]

        if len(devices) == 1:
            Log.info("Only one device — selecting it: " + (devices[0]["model"] or devices[0]["udid"]))
            return chosen(devices[0])

        if not sys.stdin.isatty():
            raise SystemExit("error: multiple devices connected — pass -u <UDID> to choose:\n    " + "\n    ".join(describe(d) for d in devices))

        Log.section()
        print("[*] Available devices\n")
        for i, d in enumerate(devices, 1):
            print("      " + str(i) + ". " + describe(d))
        print()
        while True:
            choice = input("Select a device [1-" + str(len(devices)) + "]: ").strip()
            if choice.isdigit() and 1 <= int(choice) <= len(devices):
                return chosen(devices[int(choice) - 1])
            Log.warn("Invalid choice, try again.")

    # --- transports --------------------------------------------------------
    @staticmethod
    def _have_devicectl():
        return subprocess.run(["xcrun", "--find", "devicectl"], capture_output=True, check=False).returncode == 0

    def _ideviceinstaller(self):
        return self.IDEVICEINSTALLER if Path(self.IDEVICEINSTALLER).exists() else shutil.which("ideviceinstaller")

    @staticmethod
    def _install_devicectl(udid, target):
        Log.info("Installing onto " + udid + " with devicectl...")
        r = subprocess.run(["xcrun", "devicectl", "device", "install", "app", "--device", udid, target],
                           capture_output=True, text=True, check=False)
        out = (r.stdout or "") + (r.stderr or "")
        if out.strip():
            print(out.rstrip())
        return r.returncode == 0, out

    def _install_ideviceinstaller(self, udid, target):
        installer = self._ideviceinstaller()
        Log.info("Installing onto " + udid + " with ideviceinstaller...")
        r = subprocess.run([installer, "-u", udid, "install", target], capture_output=True, text=True, check=False)
        out = (r.stdout or "") + (r.stderr or "")
        if out.strip():
            print(out.rstrip())
        # ideviceinstaller has been known to exit 0 after printing a failure.
        failed = "ERROR" in out or "Could not" in out
        return (r.returncode == 0 and not failed), out

    @staticmethod
    def _unreachable_by_devicectl(output):
        # CoreDeviceError 4016: devicectl cannot reach the device at all. It reads
        # like a lock/trust problem but means too-old iOS or not plugged in.
        return "4016" in output or "usage assertion" in output.lower()

    def install(self, ipa_path, udid):
        # Returns True only when the app actually installed, so the caller can
        # clean up the one-device signed IPA afterward.
        Log.section()
        if not ipa_path or not Path(ipa_path).is_file():
            Log.info("No IPA to install — skipping install.")
            return False
        if not udid:
            udid = self.select_udid("")
        Log.info("Target device UDID: " + udid)
        target = str(ipa_path)

        transports = []
        if self._have_devicectl():
            transports.append(("devicectl", self._install_devicectl))
        if self._ideviceinstaller():
            transports.append(("ideviceinstaller", self._install_ideviceinstaller))
        if not transports:
            Log.error("No installer available — install Xcode for 'xcrun devicectl', or 'brew install ideviceinstaller'.")
            print("    The IPA is ready at " + rel(ipa_path) + " — install it yourself.")
            return False

        last = ""
        for index, (name, run) in enumerate(transports):
            succeeded, out = run(udid, target)
            if succeeded:
                Log.info("Installed with " + name + ". Unlock the iPhone and launch the app.")
                return True
            last = out
            if name == "devicectl" and self._unreachable_by_devicectl(out):
                Log.warn("devicectl cannot reach this device (CoreDeviceError 4016): either the iOS is older than it speaks to, or the phone is not plugged in.")
            if index + 1 < len(transports):
                Log.warn(name + " could not install it — trying " + transports[index + 1][0] + ".")
        Log.error("Install failed. Make sure the phone is unlocked, trusted, and Developer Mode is on.")
        if self._unreachable_by_devicectl(last):
            print("    devicectl answered 4016 — the device may be on an iOS older than 17; install ideviceinstaller to reach it.")
        print("    The IPA is kept at " + rel(ipa_path))
        return False


class SSHInstaller:
    # Installs the rootless .deb on a jailbroken device: scp, dpkg -i, restart.
    # Over USB through an iproxy port forward, or straight to :22 with --host.
    IPROXY = "/opt/homebrew/bin/iproxy" if Path("/opt/homebrew/bin/iproxy").exists() else "iproxy"
    REMOTE_TMP = "/var/jb/tmp"
    DYLIB_DIRS = ("/var/jb/Library/MobileSubstrate/DynamicLibraries", "/Library/MobileSubstrate/DynamicLibraries")

    def __init__(self, paths, control, host="", port=2222, key="", udid="", no_restart=False):
        self.paths = paths
        self.control = control
        self.host = host or os.environ.get("SSH_HOST", "")
        self.port = port
        self.key = key or os.environ.get("SSH_KEY", "~/.ssh/id_ed25519")
        self.udid = udid
        self.no_restart = no_restart
        self.iproxy = None

    # -- transport ----------------------------------------------------------
    def _target(self):
        if self.host:
            return "root@" + self.host, "22"
        return "root@127.0.0.1", str(self.port)

    def _start_iproxy(self):
        if self.host:
            return  # talking to the device directly over the network
        cmd = [self.IPROXY, str(self.port), "22"]
        if self.udid:
            cmd += ["-u", self.udid]
        Log.section()
        Log.info("Forwarding local port " + str(self.port) + " to device :22 via iproxy")
        try:
            self.iproxy = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except FileNotFoundError:
            raise SystemExit("error: iproxy not found — 'brew install libimobiledevice', or pass --host <ip> to go over the network.")
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

    def _common_opts(self):
        return ["-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=10"]

    def _ssh_base(self):
        target, port = self._target()
        return ["ssh", "-p", port, "-i", os.path.expanduser(self.key), *self._common_opts(), target]

    def _scp_base(self):
        target, port = self._target()
        return ["scp", "-P", port, "-i", os.path.expanduser(self.key), *self._common_opts()], target

    def _ssh(self, remote_cmd, capture=False):
        full = self._ssh_base() + [remote_cmd]
        if capture:
            return subprocess.run(full, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
        return subprocess.run(full, check=False)

    def _scp(self, local, remote):
        scp_cmd, target = self._scp_base()
        return subprocess.run(scp_cmd + [str(local), target + ":" + remote], check=False)

    # -- install ------------------------------------------------------------
    def install(self, deb):
        if not deb or not Path(deb).is_file():
            Log.error("No rootless .deb to install over SSH.")
            return 1
        self._start_iproxy()
        try:
            remote = self.REMOTE_TMP + "/" + Path(deb).name
            Log.section()
            Log.info("Uploading " + Path(deb).name + " to device " + remote)
            if self._scp(deb, remote).returncode != 0:
                Log.error("scp upload failed — check the device is reachable, unlocked, and the SSH key is right.")
                return 1

            Log.section()
            Log.info("Installing package with dpkg")
            res = self._ssh("dpkg -i " + remote + "; rm -f " + remote, capture=True)
            if res.stdout:
                print(res.stdout.strip())
            if res.returncode != 0:
                Log.error("dpkg -i failed with exit code " + str(res.returncode))
                return 1

            check = self._ssh("for d in " + " ".join(self.DYLIB_DIRS) + "; do ls -la \"$d\"/ 2>/dev/null | grep -iE 'fbplus|facebook'; done", capture=True)
            out = (check.stdout or "").strip()
            if out:
                Log.info("Active tweak files:")
                print(out)
            else:
                Log.warn("No Facebook Plus files found under MobileSubstrate — the install may not have taken.")

            if not self.no_restart:
                Log.section()
                Log.info("Restarting Facebook")
                self._ssh("killall -9 Facebook 2>/dev/null")
                Log.info("Facebook restarted — Facebook Plus is active.")
            return 0
        finally:
            self._stop_iproxy()


class FacebookPlus:
    def __init__(self):
        self.paths = Paths()
        self.control = Control(self.paths)

    def usage(self):
        version = self.control.version
        print("Facebook Plus Build Script")
        print("Usage: build.py [OPTIONS]")
        Log.blank()
        print("Options:")
        print("  --rootless    Build rootless package only")
        print("  --rootfull    Build rootfull package only")
        print("  --roothide    Build roothide package only (rootless layout, arm64e arch)")
        print("  --trollfools  Build the TrollFools zip only (dylib + bundle)")
        print("  --all         Build every variant: rootless, rootfull, roothide and TrollFools (default)")
        print("  --debug       Build with FBP_DIAG=1 (the [FBPDIAG] os_log trace); v" + version + ", names unchanged")
        print("  --ipa         Inject the rootless .deb into test/com.facebook.Facebook.ipa with cyan")
        print("  --no-ipa      Build the .deb package(s) only (skip IPA injection)")
        print("  --install     Sign + install over USB (devicectl, then ideviceinstaller).")
        print("                Given ALONE it skips the build and installs the existing")
        print("                packages/ IPA. Multiple devices: asks which one.")
        print("  --ssh         With --install: dpkg the rootless .deb onto a jailbroken")
        print("                device over SSH instead of sideloading the IPA.")
        print("  --host IP     SSH to this device directly over the network (skips iproxy)")
        print("  --port N      Local iproxy port forwarded to device :22 (default 2222)")
        print("  --key PATH    SSH private key (default ~/.ssh/id_ed25519)")
        print("  --no-restart  Don't restart Facebook after an SSH install")
        print("  --drop-nse    Sign/install without the notification service extension")
        print("                (for a certificate that carries no App Group)")
        print("  -u, --udid    Target device UDID (devicectl prompt, or iproxy -u for --ssh)")
        print("  --clean       Clean build artifacts and packages directory")
        print("  -h, --help    Show this help message")
        Log.blank()
        print("Signing certificates (test/certificate/):")
        print("  Named by device UDID: <UDID>.p12 + <UDID>.mobileprovision.")
        print("  The IPA is signed with the cert matching the chosen device, then installed on it.")
        Log.blank()
        print("Environment variables:")
        print("  BUNDLE_ID            Override CFBundleIdentifier for the injected IPA")
        print("  NSE_BRIDGE           Set 0 to build the IPA without the NSE session bridge")
        print("  FBP_CERT_PASSWORD    Password for the signing .p12 (else test/certificate/password.txt, default '1')")
        print("  SSH_HOST             Default device IP for --ssh (same as --host)")
        print("  SSH_KEY              Default SSH private key for --ssh (same as --key)")
        print("  JAILBROKEN_UUID      Default device for an SSH install when -u is omitted")
        print("  SIDELOAD_UUID        Default device for a USB/IPA install when -u is omitted")
        print()
        print("  These are read from a .env file in the project root automatically")
        print("  (copy .env.example to .env), so the flags above can be left off.")

    def clean(self):
        env = self.paths.make_env()
        subprocess.run(["make", "clean"], cwd=str(self.paths.root), env=env, check=False, stdout=subprocess.DEVNULL)
        if self.paths.packages.is_dir():
            for pattern in ("*.deb", "*.dylib", "*.ipa"):
                for stale in self.paths.packages.glob(pattern):
                    stale.unlink()
        Log.info("Cleaned packages and build artifacts.")

    def run(self, argv):
        build_rootless = False
        build_rootfull = False
        build_roothide = False
        build_trollfools = False
        skip_ipa = False
        force_ipa = False
        debug = False
        do_install = False
        device_sel = ""
        use_ssh = False
        ssh_host = ""
        ssh_port = 2222
        ssh_key = ""
        ssh_no_restart = False
        drop_nse = False

        args = list(argv)
        index = 0
        while index < len(args):
            arg = args[index]
            if arg == "--rootless":
                build_rootless = True
            elif arg in ("--rootfull", "--rootful"):
                build_rootfull = True
            elif arg == "--roothide":
                build_roothide = True
            elif arg == "--trollfools":
                build_trollfools = True
            elif arg == "--all":
                build_rootless = True
                build_rootfull = True
                build_roothide = True
                build_trollfools = True
            elif arg == "--no-ipa":
                skip_ipa = True
            elif arg == "--ipa":
                force_ipa = True
                if index + 1 < len(args) and args[index + 1] == "rootless":
                    index += 1
            elif arg == "--install":
                do_install = True
            elif arg == "--ssh":
                use_ssh = True
            elif arg == "--host":
                if index + 1 >= len(args):
                    Log.error("--host requires an IP address.")
                    return 1
                ssh_host = args[index + 1]
                index += 1
            elif arg == "--port":
                if index + 1 >= len(args) or not args[index + 1].isdigit():
                    Log.error("--port requires a port number.")
                    return 1
                ssh_port = int(args[index + 1])
                index += 1
            elif arg == "--key":
                if index + 1 >= len(args):
                    Log.error("--key requires a path to an SSH private key.")
                    return 1
                ssh_key = args[index + 1]
                index += 1
            elif arg == "--no-restart":
                ssh_no_restart = True
            elif arg == "--drop-nse":
                drop_nse = True
            elif arg in ("-u", "--udid"):
                if index + 1 >= len(args):
                    Log.error(arg + " requires a device UDID.")
                    return 1
                device_sel = args[index + 1]
                index += 1
            elif arg == "--debug":
                debug = True
            elif arg == "--clean":
                self.clean()
                return 0
            elif arg in ("-h", "--help"):
                self.usage()
                return 0
            else:
                Log.error("unknown argument '" + arg + "'")
                print("Run 'build.py --help' for usage.", file=sys.stderr)
                return 1
            index += 1

        # Fall back to the UUID in .env when none was given: the jailbroken
        # device for an SSH install, the sideload device for a USB install.
        if not device_sel:
            device_sel = os.environ.get(
                "JAILBROKEN_UUID" if use_ssh else "SIDELOAD_UUID", "")

        ssh = SSHInstaller(self.paths, self.control, host=ssh_host, port=ssh_port, key=ssh_key, udid=device_sel, no_restart=ssh_no_restart) if use_ssh else None

        # --install given ALONE (no build/ipa/debug flag): don't build — just
        # install what is already sitting in packages/.
        if do_install and not (build_rootless or build_rootfull or build_roothide
                               or build_trollfools or force_ipa or debug):
            if ssh:
                return self.install_existing_ssh(ssh)
            return self.install_existing_usb(device_sel, drop_nse)

        # Nothing chosen → build the full release set (all three .deb schemes and
        # the TrollFools zip), the same set a release ships.
        if not (build_rootless or build_rootfull or build_roothide or build_trollfools):
            build_rootless = build_rootfull = build_roothide = build_trollfools = True
        # Injection and a USB install both need the rootless build.
        if (force_ipa or (do_install and not use_ssh)) and not build_rootless:
            build_rootless = True

        labels = []
        if build_rootless:
            labels.append("rootless")
        if build_rootfull:
            labels.append("rootfull")
        if build_roothide:
            labels.append("roothide")
        # The TrollFools zip is cut from the compiled .theos/obj a scheme leaves
        # behind; if it is the only thing asked for, build rootless to produce it.
        if build_trollfools and not labels:
            labels.append("rootless")

        builder = TweakBuilder(self.paths, self.control, debug)
        builder.build(labels)
        if build_trollfools:
            builder.build_trollfools()

        injected = None
        # SSH installs the raw .deb, so the sideload IPA step is skipped for it
        # unless --ipa was asked for explicitly.
        if not skip_ipa and (not use_ssh or force_ipa):
            rootless_deb = builder.output_deb("rootless") if build_rootless else None
            injected = IpaInjector(self.paths, self.control, debug).inject(rootless_deb)

        if do_install:
            if ssh:
                ssh.install(builder.output_deb("rootless"))
            else:
                installer = DeviceInstaller(self.paths)
                udid = installer.select_udid(device_sel)
                self._purge_signed()
                signed = Signer(self.paths).sign(injected, udid, drop_nse=drop_nse)
                if installer.install(signed or injected, udid) and signed:
                    self._delete_signed(signed)

        return 0

    @staticmethod
    def _delete_signed(signed):
        # A signed IPA is bound to one device and large; once it is installed it
        # is spent, so it is removed. The unsigned injected IPA stays in packages/.
        try:
            path = Path(signed)
            if path.is_file():
                path.unlink()
                Log.info("Removed the signed IPA after install: " + str(path))
        except OSError as exc:
            Log.warn("Could not remove the signed IPA: " + str(exc))

    def _packages_ipa(self):
        # Prefer the unsigned injected build: a signed IPA is bound to one device,
        # so it is re-signed for the chosen one rather than reused.
        pkgs = self.paths.packages
        if not pkgs.is_dir():
            return None
        unsigned = sorted((p for p in pkgs.glob("*.ipa") if not p.name.endswith("-signed.ipa")),
                          key=lambda p: p.stat().st_mtime, reverse=True)
        if unsigned:
            return unsigned[0]
        signed = sorted(pkgs.glob("*-signed.ipa"), key=lambda p: p.stat().st_mtime, reverse=True)
        return signed[0] if signed else None

    def _purge_signed(self, keep=None):
        # A signed IPA is bound to a single device; leaving an old one around is
        # what lets the wrong-device build get installed by mistake.
        pkgs = self.paths.packages
        if not pkgs.is_dir():
            return
        keep_resolved = Path(keep).resolve() if keep else None
        for stale in pkgs.glob("*-signed.ipa"):
            if keep_resolved and stale.resolve() == keep_resolved:
                continue
            stale.unlink()
            Log.info("Removed existing signed IPA: " + str(stale))

    def _packages_deb(self, scheme="rootless"):
        pkgs = self.paths.packages
        if not pkgs.is_dir():
            return None
        debs = sorted(pkgs.glob("Facebook-Plus-*" + scheme + "*.deb"), key=lambda p: p.stat().st_mtime, reverse=True)
        if not debs:
            debs = sorted(pkgs.glob("*" + scheme + "*.deb"), key=lambda p: p.stat().st_mtime, reverse=True)
        return debs[0] if debs else None

    def install_existing_ssh(self, ssh):
        deb = self._packages_deb("rootless")
        if not deb:
            Log.error("No rootless .deb found in packages/ to install — build one first (e.g. build.py --rootless --no-ipa).")
            return 1
        Log.section()
        Log.info("Installing existing package over SSH: " + str(deb))
        return ssh.install(deb)

    def install_existing_usb(self, device_sel, drop_nse):
        ipa = self._packages_ipa()
        if not ipa:
            Log.error("No IPA found in packages/ to install — build one first (e.g. build.py --ipa).")
            return 1
        Log.section()
        Log.info("Installing existing package: " + str(ipa))
        installer = DeviceInstaller(self.paths)
        udid = installer.select_udid(device_sel)
        self._purge_signed(keep=ipa)
        signed = Signer(self.paths).sign(ipa, udid, drop_nse=drop_nse)
        if not signed:
            Log.error("Could not sign for device " + udid + " — not installing.")
            return 1
        if installer.install(signed, udid):
            self._delete_signed(signed)
        return 0


if __name__ == "__main__":
    load_dotenv(os.path.join(ROOT, ".env"))
    sys.exit(FacebookPlus().run(sys.argv[1:]))
