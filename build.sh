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

	# cyan refuses to overwrite an existing output, so clear a previous run first.
	if [ -f "$IPA_OUT" ]; then
		echo "==> Removing existing $IPA_OUT"
		rm -f "$IPA_OUT"
	fi

	# Custom app-icon logos (shipped in resources/logo/). cyan drops the PNGs at
	# the .app root via -f; their alternate-icon plist entries are merged via -l,
	# built from the target's real CFBundleIcons so Facebook's own icons survive.
	shopt -s nullglob
	LOGOS=(resources/logo/fbplus_*.png)
	shopt -u nullglob

	ICON_MERGE=""
	if [ ${#LOGOS[@]} -gt 0 ]; then
		ICON_MERGE="$(mktemp)"
		trap 'rm -f "$ICON_MERGE"' EXIT
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
		echo "==> Building Safari web extension in $ext_dir…"
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

	echo "==> Injecting $DEB_INJECT (+ icons${PLUGINS:+ + ${#PLUGINS[@]} extension(s)}) into $IPA_IN with cyan…"
	cyan -i "$IPA_IN" -o "$IPA_OUT" -f "$DEB_INJECT" "${LOGOS[@]}" "${PLUGINS[@]}" "${MERGE_ARGS[@]}" "${RENAME_ARGS[@]}" -uwsgq

	echo "==> Done. Injected IPA: $IPA_OUT"
else
	echo "==> $IPA_IN not found — built the .deb package(s) only (skipped injection)."
	echo "    Drop a decrypted Facebook IPA there and re-run to produce an injected IPA."
fi
