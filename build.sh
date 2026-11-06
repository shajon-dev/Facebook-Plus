#!/usr/bin/env bash
#
# Builds Facebook Plus for every packaging scheme and writes one versioned .deb
# per scheme to packages/:
#
#   packages/Facebook-Plus-v<version>-rootless.deb
#   packages/Facebook-Plus-v<version>-rootfull.deb
#
# If a decrypted Facebook IPA is present at test/com.facebook.Facebook.ipa, the
# rootless build is then injected into it with cyan and written as
# packages/Facebook-Plus-v<facebook-version>-rootless.ipa, where the version is
# read from the IPA's own Info.plist. Any custom app-icon logos under
# resources/logo/ (fbplus_*.png) are injected in the same cyan run: their files go
# to the .app root and their CFBundleAlternateIcons entries are merged into the
# app's Info.plist (Facebook's own icons preserved).
#
# Usage:
#   ./build.sh                          # build every scheme
#   SCHEMES="rootless" ./build.sh       # build a subset
#
# Requires: theos ($THEOS, defaults to ~/theos). cyan is needed only for the
#   optional IPA injection step.

set -euo pipefail

# Always run from the repository root, wherever the script is invoked from.
cd "$(dirname "$0")"

: "${THEOS:=$HOME/theos}"
export THEOS

VERSION="$(awk -F': ' '/^Version:/{print $2; exit}' control)"
PKG_ID="$(awk -F': ' '/^Package:/{print $2; exit}' control)"

# Map a scheme label (the filename suffix) to the THEOS_PACKAGE_SCHEME value it
# builds with; rootful is theos's empty scheme. Prints the value (empty for
# rootfull) and returns non-zero for an unknown label. A function rather than an
# associative array so this runs on macOS's stock bash 3.2 as well as bash 4+.
scheme_value() {
	case "$1" in
		rootless) printf '%s' "rootless" ;;
		rootfull) printf '%s' "" ;;
		*)        return 1 ;;
	esac
}

# Schemes to build (space-separated labels). Narrow with SCHEMES, e.g.
# SCHEMES="rootless" ./build.sh
SCHEMES="${SCHEMES:-rootless rootfull}"

IPA_IN="test/com.facebook.Facebook.ipa"

mkdir -p packages

# Every run starts from an empty packages/: the previous .deb, .dylib and .ipa
# are deleted up front and without asking. They are all reproducible from this
# source tree, and a stale artifact sitting next to a fresh one is exactly how
# the wrong file ends up signed and shipped — a version bump, for instance,
# renames the .deb and would otherwise leave the old one behind.
#
# Scoped to packages/ on purpose. The input IPA lives in test/ ($IPA_IN) and is
# never touched: it is not a build product and cannot be regenerated here.
rm -f packages/*.deb packages/*.dylib packages/*.ipa

# Scratch paths the IPA post-processing steps create. One trap removes whatever
# exists, so a later step cannot drop an earlier step's cleanup by installing its
# own EXIT handler.
ICON_MERGE=""
NSE_WORK=""
cleanup() {
	[ -n "$ICON_MERGE" ] && rm -f "$ICON_MERGE"
	[ -n "$NSE_WORK" ] && rm -rf "$NSE_WORK" "$NSE_WORK.ipa"
	return 0
}
trap cleanup EXIT

# --- NSE session bridge ------------------------------------------------------
#
# Facebook's NotificationServiceExtension.appex (the NSE) is what turns a push
# into real notification text, and it only does so when it can resolve the
# logged-in session. On a re-signed build it cannot: the session lives in
# group.com.facebook.* App Groups and the T84QZS65DQ keychain group, neither of
# which a third-party signer can claim. FBPNotifyBridge.dylib applies the same
# container/keychain redirects the main app already gets (src/PluginsInject/)
# inside the extension. See FBPNotifyBridge/README.md.
#
# Users sideload the released IPA with their own signer (Feather, AltStore,
# SideStore, …), which will not inject anything, so the shipped IPA has to carry
# the bridge already. Set NSE_BRIDGE=0 to build an IPA without it.
NSE_BRIDGE="${NSE_BRIDGE:-1}"
BRIDGE_DIR="FBPNotifyBridge/src"
# Where theos drops it, and where we publish it. The dylib lands in packages/
# alongside the .deb and .ipa so every build product is in one place — and
# because packages/ is git-ignored, the binary is never committed: the repository
# carries only FBPNotifyBridge/src and the IPA build compiles it from source.
BRIDGE_BUILT="$BRIDGE_DIR/.theos/obj/FBPNotifyBridge.dylib"
BRIDGE_DYLIB="packages/FBPNotifyBridge.dylib"

# Locate cyan's bundled insert_dylib. cyan ships its own per-platform Mach-O
# tools (insert_dylib, ldid, otool, …) inside its Python package; neither
# insert_dylib nor optool is on PATH here. The location is a pipx-venv detail, so
# it is resolved from the cyan entry point at runtime instead of hardcoded.
cyan_insert_dylib() {
	local bin real venv_py pkg="" tool candidate
	bin="$(command -v cyan 2>/dev/null || true)"
	[ -n "$bin" ] || return 1
	real="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$bin" 2>/dev/null || true)"
	[ -n "$real" ] || return 1

	# cyan.__file__ is None (namespace package), so ask for __path__ instead.
	venv_py="$(dirname "$real")/python3"
	if [ -x "$venv_py" ]; then
		pkg="$("$venv_py" -c 'import cyan; print(list(cyan.__path__)[0])' 2>/dev/null || true)"
	fi
	if [ -z "$pkg" ]; then
		for candidate in "$(dirname "$(dirname "$real")")"/lib/python*/site-packages/cyan; do
			if [ -d "$candidate" ]; then pkg="$candidate"; break; fi
		done
	fi
	[ -n "$pkg" ] || return 1

	tool="$pkg/tools/$(uname)/$(uname -m)/insert_dylib"
	[ -x "$tool" ] || return 1
	printf '%s' "$tool"
}

# Add FBPNotifyBridge.dylib to the NSE inside an already-built IPA. Every failure
# mode here is a warning, never an error: an IPA without the bridge is still a
# perfectly valid build of everything else.
inject_nse_bridge() {
	local ipa="$1" dylib="$2"
	local appex_rel="Payload/Facebook.app/PlugIns/NotificationServiceExtension.appex"
	local tool ipa_abs appex exe ents

	if [ ! -f "$dylib" ]; then
		echo "warning: $dylib not built — IPA ships without the NSE session bridge." >&2
		return 0
	fi
	if ! command -v ldid >/dev/null 2>&1; then
		echo "warning: ldid not found — IPA ships without the NSE session bridge." >&2
		return 0
	fi
	tool="$(cyan_insert_dylib || true)"
	if [ -z "$tool" ]; then
		echo "warning: cyan's bundled insert_dylib not found (looked for" >&2
		echo "         <cyan package>/tools/$(uname)/$(uname -m)/insert_dylib) —" >&2
		echo "         IPA ships without the NSE session bridge." >&2
		return 0
	fi

	ipa_abs="$(cd "$(dirname "$ipa")" && pwd)/$(basename "$ipa")"
	NSE_WORK="$(mktemp -d)"

	# ${ipa} is braced because macOS's bash 3.2 mis-tokenizes a bare $ipa when the
	# "…" follows it directly: in a UTF-8 locale it reads the multi-byte U+2026 as
	# part of the variable name, so `set -u` aborts the build with
	# "ipa<junk>: unbound variable". Verified on bash 3.2.57: it fails under
	# LANG=en_US.UTF-8 (what the build-ipa workflow sets, and what an interactive
	# macOS shell normally has) and only happens to survive under LANG=C. Brace
	# every variable that is followed immediately by a non-ASCII character.
	echo "==> Injecting the NSE session bridge into ${ipa}…"
	unzip -q "$ipa_abs" -d "$NSE_WORK"

	appex="$NSE_WORK/$appex_rel"
	exe="$appex/NotificationServiceExtension"
	if [ ! -f "$exe" ]; then
		echo "warning: $appex_rel/NotificationServiceExtension not in the IPA —" >&2
		echo "         skipping the NSE session bridge (IPA left as cyan produced it)." >&2
		rm -rf "$NSE_WORK"; NSE_WORK=""
		return 0
	fi

	# Capture the appex's entitlements before insert_dylib strips the signature:
	# they are Facebook's originals, and preserving them is what makes the
	# extension work under TrollStore (which honours them as-is).
	ents="$NSE_WORK/nse.entitlements"
	ldid -e "$exe" > "$ents" 2>/dev/null || true

	cp "$dylib" "$appex/FBPNotifyBridge.dylib"
	# Load path relative to the appex executable, which is where the dylib sits.
	"$tool" --weak --inplace --all-yes "@executable_path/FBPNotifyBridge.dylib" "$exe" >/dev/null

	# Match cyan's -s treatment of everything else: fakesign both the rewritten
	# appex binary and the dylib we just added.
	ldid -S "$appex/FBPNotifyBridge.dylib"
	if [ -s "$ents" ]; then
		ldid -S"$ents" "$exe"
	else
		ldid -S "$exe"
	fi
	rm -f "$ents"

	# -y keeps symlinks as symlinks; the app bundle contains some.
	( cd "$NSE_WORK" && zip -qry "$NSE_WORK.ipa" Payload )
	mv -f "$NSE_WORK.ipa" "$ipa_abs"
	rm -rf "$NSE_WORK"; NSE_WORK=""
	echo "==> NSE session bridge injected (@executable_path/FBPNotifyBridge.dylib)."
}

# Build one scheme and rename its .deb to the versioned, labelled name.
build_scheme() {
	local label="$1"
	local scheme
	scheme="$(scheme_value "$label")"
	local out="packages/Facebook-Plus-v${VERSION}-${label}.deb"

	echo "==> Building ${label} (THEOS_PACKAGE_SCHEME='${scheme}')…"
	make clean >/dev/null
	# Clear any previous raw theos output so the freshest build is unambiguous.
	rm -f packages/${PKG_ID}_*.deb
	make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME="${scheme}"

	local built
	built="$(ls -t packages/${PKG_ID}_*.deb 2>/dev/null | head -1 || true)"
	if [ -z "${built}" ]; then
		echo "error: no .deb was produced for the ${label} scheme" >&2
		return 1
	fi

	mv -f "${built}" "${out}"
	echo "==> ${label}: ${out}"
}

for label in ${SCHEMES}; do
	if ! scheme_value "$label" >/dev/null 2>&1; then
		echo "error: unknown scheme '${label}' (valid: rootless rootfull)" >&2
		exit 1
	fi
	build_scheme "${label}"
done

echo "==> Built package(s):"
ls -1 packages/Facebook-Plus-v${VERSION}-*.deb

# Inject into the IPA only when one is provided. The rootless build is used for
# sideloading, since cyan re-signs and rewrites the dylib's load path anyway.
DEB_INJECT="packages/Facebook-Plus-v${VERSION}-rootless.deb"
if [ -f "$IPA_IN" ]; then
	if [ ! -f "$DEB_INJECT" ]; then
		echo "==> $DEB_INJECT not built (rootless not in SCHEMES) — skipping injection."
		exit 0
	fi
	if ! command -v cyan >/dev/null 2>&1; then
		echo "error: cyan not found — install it with 'pip install --user cyan' (pyzule-rw)." >&2
		echo "       The .deb packages are ready; run the cyan command yourself once installed." >&2
		exit 1
	fi

	# Name the injected IPA after the Facebook build it targets, read from the
	# IPA's own Info.plist (the rootless build is what cyan injects).
	FB_VERSION="$(python3 scripts/ipa_version.py "$IPA_IN")"
	IPA_OUT="packages/Facebook-Plus-v${FB_VERSION}-rootless.ipa"

	# packages/ was emptied at the start of the run, so this output should not
	# exist. Clear it anyway and pass --overwrite below: left to itself cyan stops
	# on an existing output with an interactive "overwrite it? [Y/n]" prompt,
	# which would hang a CI run or a build left unattended.
	rm -f "$IPA_OUT"

	# Custom app-icon logos (shipped in resources/logo/). cyan drops the PNGs at
	# the .app root via -f; their alternate-icon plist entries are merged via -l,
	# built from the target's real CFBundleIcons so Facebook's own icons survive.
	shopt -s nullglob
	LOGOS=(resources/logo/fbplus_*.png)
	shopt -u nullglob

	if [ ${#LOGOS[@]} -gt 0 ]; then
		ICON_MERGE="$(mktemp)"
		echo "==> Building custom app-icon plist (${#LOGOS[@]} file(s))…"
		python3 scripts/icon_plist.py "$IPA_IN" "$ICON_MERGE"
	fi

	MERGE_ARGS=()
	if [ -n "$ICON_MERGE" ]; then MERGE_ARGS=(-l "$ICON_MERGE"); fi

	# Optional bundle-id override. When BUNDLE_ID is set (e.g. by the build-ipa
	# GitHub Action), cyan rewrites the app's CFBundleIdentifier. The tweak is
	# bundle-id-agnostic (see FBPEntry.xm), so it still activates under the new id.
	# Left empty, the IPA keeps Facebook's own bundle id.
	RENAME_ARGS=()
	if [ -n "${BUNDLE_ID:-}" ]; then RENAME_ARGS+=(-b "$BUNDLE_ID"); fi

	# Safari web extensions bundled into the app's PlugIns (e.g. "Open in
	# Facebook", which reopens facebook.com links from Safari in the app). Each
	# is built from source under OpenInFacebookSafariExtension/*/Makefile; cyan
	# then places the resulting .appex under PlugIns and fakesigns it (-s below).
	PLUGINS=()
	shopt -s nullglob
	for ext_mk in OpenInFacebookSafariExtension/*/Makefile; do
		ext_dir="$(dirname "$ext_mk")"
		echo "==> Building Safari web extension in ${ext_dir}…"
		make -C "$ext_dir" FINALPACKAGE=1 >/dev/null
		# Only the final bundle at .theos/obj/*.appex carries the resources and
		# Info.plist; the per-arch intermediates under obj/<arch>/ hold just the
		# binary, so restrict to maxdepth 1 and require a readable Info.plist.
		appex=""
		for candidate in "$ext_dir"/.theos/obj/*.appex; do
			if [ -f "$candidate/Info.plist" ]; then appex="$candidate"; break; fi
		done
		if [ -n "$appex" ]; then
			PLUGINS+=("$appex")
		else
			echo "warning: no complete .appex produced in $ext_dir — skipping." >&2
		fi
	done
	shopt -u nullglob

	# The NSE session bridge is built here but injected after cyan (below): it is
	# deliberately not a target of the root Makefile, because a second target
	# would be packaged into the .deb and cyan would then also inject it into the
	# main binary, installing its container redirects a second time.
	if [ "$NSE_BRIDGE" != "0" ]; then
		echo "==> Building the NSE session bridge in ${BRIDGE_DIR}…"
		# Drop any dylib an earlier run left behind, in the theos output and in
		# packages/: if this build fails we want the injection step to find
		# nothing and say so, rather than quietly shipping a stale bridge built
		# from older sources.
		rm -f "$BRIDGE_BUILT" "$BRIDGE_DYLIB"
		if ! make -C "$BRIDGE_DIR" FINALPACKAGE=1 >/dev/null; then
			echo "warning: the NSE session bridge failed to build — continuing without it." >&2
		elif ! cp "$BRIDGE_BUILT" "$BRIDGE_DYLIB" 2>/dev/null; then
			echo "warning: the NSE session bridge built but could not be copied to" >&2
			echo "         ${BRIDGE_DYLIB} — continuing without it." >&2
		else
			echo "==> NSE session bridge: ${BRIDGE_DYLIB}"
		fi
		# This subproject compiles two shared sources through ../../, and theos
		# mirrors those relative paths into stamp directories *next to* the
		# subproject: FBPNotifyBridge/src/src/PluginsInject and
		# FBPNotifyBridge/src/fishhook. They hold nothing but an empty .stamp
		# marker — the real objects go under .theos/ — so they are removed to keep
		# the working tree clean. theos recreates them on the next build, and
		# .gitignore still lists them for anyone running `make -C` by hand.
		rm -rf "$BRIDGE_DIR/src" "$BRIDGE_DIR/fishhook"
	fi

	echo "==> Injecting $DEB_INJECT (+ icons${PLUGINS:+ + ${#PLUGINS[@]} extension(s)}) into $IPA_IN with cyan…"
	# The "${arr[@]+"${arr[@]}"}" form expands to nothing when the array is empty,
	# instead of tripping `set -u` on bash < 4.4 (the macOS runner's bash), where a
	# plain "${arr[@]}" on an empty array is treated as an unbound variable.
	cyan -i "$IPA_IN" -o "$IPA_OUT" -f "$DEB_INJECT" \
		"${LOGOS[@]+"${LOGOS[@]}"}" \
		"${PLUGINS[@]+"${PLUGINS[@]}"}" \
		"${MERGE_ARGS[@]+"${MERGE_ARGS[@]}"}" \
		"${RENAME_ARGS[@]+"${RENAME_ARGS[@]}"}" \
		--overwrite -uwsgq

	if [ "$NSE_BRIDGE" = "0" ]; then
		echo "==> NSE_BRIDGE=0 — skipped the notification-service bridge."
	else
		inject_nse_bridge "$IPA_OUT" "$BRIDGE_DYLIB"
	fi

	echo "==> Done. Injected IPA: $IPA_OUT"
else
	echo "==> $IPA_IN not found — built the .deb package(s) only (skipped injection)."
	echo "    Drop a decrypted Facebook IPA there and re-run to produce an injected IPA."
fi
