# FBPNotifyBridge — the notification-service session bridge

**Status: shipped and confirmed working on a device (2026-11-07).** Detailed
notifications arrive on the lock screen on a re-signed build. The one hard
requirement is that the signing certificate carries at least one registered App
Group — see [Your signing certificate has to cooperate](#your-signing-certificate-has-to-cooperate)
— without which the bridge has nowhere to redirect to and notifications stay
generic.

Tracks issues **#12** and **#13** ("You have a new notification").

## The problem

Facebook does not put the notification text in the push payload. The payload is a
stub, and `NotificationServiceExtension.appex` (the **NSE**) is what expands it:
it resolves the logged-in session, fetches the real content, and rewrites the
notification before iOS shows it. If the NSE cannot find a session, iOS shows the
stub — *"You have a new notification"*.

On a re-signed (sideloaded) build the NSE cannot find the session, because the
session does not live anywhere a third-party signer can reach:

| What Facebook uses | Why a re-signed build loses it |
|---|---|
| App Groups `group.com.facebook.Facebook`, `group.com.facebook.family`, `group.com.facebook.msysstorage` | Apple will not authorize another team's group id. A third-party certificate can never claim `group.com.facebook.*`. |
| Keychain group `T84QZS65DQ.platformFamily` (the NSE's own `Info.plist` names it as `FBKeychainAccessGroup`) | Same — it is Meta's team prefix. |

The **main app** already works around both (`src/PluginsInject/`): App-Group and
group-suite `NSUserDefaults` containers are redirected into a container the
signer *does* own, and every `SecItem*` call is pinned to the keychain access
group the app actually got. The NSE never saw any of that, because
`FacebookPlus.dylib` is injected into the main binary only
(`INSTALL_TARGET_PROCESSES = Facebook`, and the filter plist scopes the
Substrate build to `com.facebook.Facebook`).

## What this is

`FBPNotifyBridge.dylib` — a second, deliberately tiny dylib that `build.py`
injects into `NotificationServiceExtension.appex`, so the extension applies the
*same* redirects the app already does.

It contains only:

- `FBPNotifyBridge.mm` — swizzles
  `-[NSFileManager containerURLForSecurityApplicationGroupIdentifier:]` and
  `-[NSUserDefaults _initWithSuiteName:container:]`;
- `src/PluginsInject/Paths.mm` — resolves the signer's real App-Group container
  from the live entitlements (shared with the main tweak);
- `src/PluginsInject/PluginsInject.mm`, `SecRebinds.xm`, `fishhook/fishhook.c` —
  the keychain access-group probe and the `SecItem*` rebinds (shared).

It links **Foundation, Security and MobileCoreServices only**: no UIKit, no
settings / toast / font / feature code, no Cydia Substrate. About **70 KB**.

### Why it is not just the whole tweak

`FacebookPlus.dylib`'s `%ctor` has no bundle-id gate — it registers preferences
and installs every feature hook unconditionally, and it links UIKit. An NSE runs
under a hard **~24 MB** memory limit and a short execution window. Getting killed
there makes notifications *worse*, not better: iOS falls back to the stub
payload. Hence a separate, slim dylib.

### Why the mapping has to be identical in both processes

Both the app and the extension build their redirected containers as
`<signer's App-Group container>/<requested group id>`. That is a single shared
directory *only* if both processes pick the same App-Group container, so
`Paths.mm` filters out Meta-owned ids, sorts the remainder with a
locale-independent comparison, and takes the first one that actually resolves —
rather than trusting `firstObject` and whatever order the entitlement array
happens to arrive in. The path construction in `FBPNotifyBridge.mm` is a
line-for-line match of `src/PluginsInject/SideloadFix.xm`, including the `group`
prefix check and the `Documents/<group id>` fallback. **Change one, change the
other.**

### Why the keychain rebinds are included

The container redirect alone cannot surface a session: Facebook's NSE asks the
keychain for access group `T84QZS65DQ.platformFamily`, which a re-signed
extension can never be granted, so the request fails before any container is
consulted. Rewriting that group is what makes it succeed, and it is the same
shared code the app uses, so the two processes converge on the same group.

**This is the half that was broken, and it is why the bridge only ever half
worked.** The rebind used to force `kSecAttrAccessGroup` on *every* `SecItem*`
call in the process; it was then narrowed for issue #13, and the narrowing
passed `kSecUseDataProtectionKeychain` queries through untouched — which in this
binary is precisely Meta's own Swift keychain stores asking for
`T84QZS65DQ.platformFamily`. The extension got a null token, so likes, comments
and friend requests stayed generic while Messenger messages (container-backed)
kept working. Fixed 2026-11-08; the reasoning and the disassembly that shows it
are in
[`.agent/notification-extension.md`](../.agent/notification-extension.md#root-cause-of-the-half-working-state-found-2026-11-08).

**Known concern that remains:** fishhook rebinds the symbol process-wide, so
these shims see every framework's keychain traffic, and in an NSE a crash costs
a notification. `com.apple.*` groups are left alone for that reason. If the
extension starts dying, this is still the first thing to suspect.

## Your signing certificate has to cooperate

The bridge is **inert** unless the certificate you sign with has at least one
**registered App Group**, because there is then no signer-owned container to
redirect into. (The extension's own `Documents/` is not a usable fallback: an app
extension gets its own data container, separate from the host app's.)

Two profiles were tested during development, and the difference between them is
the whole requirement:

| Profile | App Groups | Bridge works? |
|---|---|---|
| Paid certificate, several registered groups | `group.<yourTeam>.…` × 5 | **Yes.** There is a container to redirect into. |
| Paid certificate, none registered | `com.apple.security.application-groups` is an empty array | **No.** The bridge loads and does nothing. |

The user-facing way to check is
[**Check App Groups Support**](https://github.com/SHAJON-404/Facebook-Plus/wiki/Check-App-Groups-Support)
in the wiki — sign and open a small checker app, which answers it outright. To
read the profile directly instead, decode it and look at that key:

```bash
security cms -D -i YourCertificate.mobileprovision > profile.plist
/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.security.application-groups" profile.plist
```

One or more `group.…` identifiers means the bridge has somewhere to work. An
empty array means it does not, and no change to this tweak can alter that — the
group has to be registered on the Apple Developer account the certificate
belongs to.

### Optional: Feather's "Merge Entitlements"

Facebook's notification extension also reads part of the session from the
**keychain**, under a group named after Meta's team. Keychain groups, unlike App
Groups, *can* legitimately be re-issued under another team: a provisioning
profile grants `<yourTeam>.*` as a wildcard, so `T84QZS65DQ.platformFamily` can
be rewritten to `<yourTeam>.platformFamily`. Feather's **Merge Entitlements**
option performs that rewrite.

**It is not required.** Detailed notifications have been confirmed working
without it, on a certificate that carries App Groups. Treat it as belt-and-braces
rather than a prerequisite: if your build of Feather offers the switch, turning
it on costs nothing; if it does not, a certificate with an App Group is enough.

Two practical notes:

- The option is **not in any released build** of Feather as of v2.9.0. It exists
  only on the project's `main` branch, under **Settings → Features → Signing
  Options**, in its own section below "Delete After Signing".
- Where it does appear, it is disabled while a custom entitlements file is
  loaded — Feather will not merge on top of one you supplied yourself.

"Inject into app extensions" is **not** needed either: the released IPA already
carries the bridge inside the appex. Enabling it is harmless.

## What it does *not* fix

- ~~**Messenger messages.**~~ **Corrected 2026-11-08: Messenger messages and
  calls are the ones that *do* work.** They come out of the Msys store in the
  redirected app-group container, so the container half already serves them. The
  half that needed fixing was the **keychain**, which is what Facebook
  notifications — likes, comments, tags, friend requests — depend on for the
  client-sync token behind their GraphQL fetch.
- **TrollStore installs.** They already work today, and this changes nothing for
  them: TrollStore preserves the original entitlements, so Facebook's real App
  Groups and keychain group are intact and no redirect is needed.

## Build and injection

Built separately from the root tweak, the same way the Safari web extension is:

```bash
make -C FBPNotifyBridge/src FINALPACKAGE=1
# -> FBPNotifyBridge/src/.theos/obj/FBPNotifyBridge.dylib
```

`build.py` copies that to **`packages/FBPNotifyBridge.dylib`** and injects from
there, so every build product sits in `packages/` together. That directory is
git-ignored, so the compiled dylib is never committed — the repository carries
only the sources in this folder and each build compiles them again.

It is **deliberately not a target of the root `Makefile`.** A second target there
would be packaged into the `.deb`, and `cyan` would then inject this dylib into
the *main* binary as well — installing the `NSFileManager` / `NSUserDefaults`
redirects twice.

`build.py` builds it, and after the `cyan` run unpacks the output IPA, copies the
dylib into the appex, adds a weak load command with `cyan`'s own bundled
`insert_dylib` (resolved at runtime from the `cyan` entry point — it is not on
`PATH`) at `@executable_path/FBPNotifyBridge.dylib`, re-fakesigns the appex binary
with `ldid` **preserving its original entitlements** (TrollStore depends on them)
plus the dylib, and repacks. Every failure in that step is a warning: the IPA is
left as `cyan` produced it rather than failing the build. Skip the whole step
with `NSE_BRIDGE=0 python3 build.py`.

`build.py`'s signer (`python3 build.py --install`) additionally passes
`-l … -w -P` to `zsign`, so the local device test exercises the
extension-injection path too.

## Explicit App IDs and whether the NSE launches — settled

Both certificates tested use an **explicit** App ID rather than a wildcard. An
app extension normally needs its own `application-identifier`
(`<team>.<host bundle id>.NotificationServiceExtension`), which an explicit App
ID does not cover — and `zsign` cannot help: it writes the provisioning
profile's `Entitlements` dictionary verbatim into every binary, nested `.appex`
bundles included, so the extension inherits the main bundle's identifier and
there is no way to give it a profile of its own.

That looked fatal while it was theory. It is not. Sideloading tools ship exactly
this behaviour and it works for their users; their own source notes that
per-extension provisioning is not something `zsign` can express, and registering
only the main bundle is accepted as sufficient.

The device run then settled it outright: the extension launches on a re-signed
build and produces real notification text. An earlier note recording
`nse_seen:0`, read at the time as the extension never starting, turned out to be
an artefact of how it was traced rather than a finding.

### Settled by the 2026-11-07 device run

1. The NSE launches on a re-signed install. ✅
2. No wildcard profile and no per-extension App IDs are needed. ✅
3. The redirected App-Group container carries what the NSE needs. ✅
4. Notification text becomes specific — **for Messenger messages and calls
   only.** Read as "the bridge works" at the time; the keychain half was in fact
   still broken, and Facebook notifications stayed generic. Corrected
   2026-11-08.

### Tracing it on a device

`FBP_DIAG=1` compiles an `os_log` trace into both this dylib and the main tweak
— the access group each process resolved and *how*, every container redirect, and
every `SecItem*` call with its requested group, the decision taken and the
`OSStatus`, plus the notification request and the content finally handed back:

```bash
make FBP_DIAG=1
make -C FBPNotifyBridge/src FBP_DIAG=1 FINALPACKAGE=1
FBP_DIAG=1 python3 build.py --install
idevicesyslog | grep FBPDIAG     # or Console.app, subsystem com.shajon.fbplus
```

A diagnostic build is ~90 KB instead of 70 KB. **Keep it out of releases** — the
lines name keychain services and container paths.

### Still unverified

- Whether the `SecItem*` rebind is comfortable inside an NSE's memory and time
  budget. **Settings → General → Keychain Compatibility** turns it off, but only
  for the main app: an appex has its own preferences domain, so the read there
  finds nothing and falls back to on.
- Behaviour on a certificate whose profile grants a *different* set of App
  Groups, or more than one. The resolver sorts and picks the first that actually
  resolves, so both processes converge, but only one certificate has been tested.
- Whether Facebook sends this build HPKE-encrypted payloads at all. The NSE has
  the machinery (`MetaPushEncryptionKeyStore`, `is_encrypted`), and its keychain
  queries were broken by the same rule and fixed by the same change, but nothing
  has shown it is on the path in practice.
