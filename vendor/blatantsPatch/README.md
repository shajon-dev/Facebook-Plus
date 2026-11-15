# blatantsPatch.dylib (vendored, prebuilt)

A third-party, **closed-source** Substrate-style dylib that rebinds the
`SecItem*` keychain functions (`SecItemAdd` / `SecItemCopyMatching` /
`SecItemUpdate` / `SecItemDelete`) and rewrites `kSecAttrAccessGroup` to an
access group a re-signed app actually holds — the same class of
access-group fix as `src/PluginsInject/SecRebinds.xm`, in its original blanket
form.

## Why it is here

On **sideloaded** (re-signed) builds, Facebook's session was being dropped after
a few hours and the user was forced to log in and re-verify (GitHub issue #2).
Injecting this dylib into the patched IPA keeps the session persistent. We have
no source for it, so it is vendored as a prebuilt binary and injected into the
**IPA only** (never the `.deb`).

## Scope

- Injected into the patched IPA by `build.py` (an extra `cyan -f`), only when a
  Facebook IPA is present to inject into, so the `.deb` (jailbreak / TrollStore)
  never carries it — those installs keep their entitlements and do not have the
  logout problem.
- Because it owns the main app's keychain access-group rewrite, the tweak's own
  `SecRebinds.xm` is left **off by default in the main app**
  (`FBPKeyKeychainRebind` defaults to `NO`) so the two do not fight over the
  same `SecItem*` rebind. The notification extension is a separate process that
  this dylib is not injected into, so its own `SecRebinds.xm` stays active and
  issue #12 notifications are unaffected.

## Provenance

- Owner / distributor: **blatants** — Telegram channel `https://t.me/blatants`.
- Architecture: `arm64`, Mach-O dynamic library.
- Original install name: `/Library/MobileSubstrate/DynamicLibraries/blatantsPatch.dylib`
  (cyan rewrites the load path on injection).
- SHA-256: `a8fd612fb190a8cb2f1156d3d23af910c8fd166fd1657c6fb4679b88ee81e70b`

Credited in `THIRD_PARTY_NOTICES.md`.
