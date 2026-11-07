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

`FBPNotifyBridge.dylib` — a second, deliberately tiny dylib that `build.sh`
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
consulted. The probe-and-pin pair is what makes it succeed, and it is the same
shared code the app uses, so the two processes converge on the same group.

**Known concern:** the rebind is blanket — it forces `kSecAttrAccessGroup` on
*every* `SecItem*` call in the process. Project notes record a suspicion that
this aggravates crashes elsewhere in the app. In an NSE a crash costs a
notification, so this is the riskiest part of the bridge and the first thing to
remove if the extension starts dying.

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

- **Messenger messages.** Those are end-to-end encrypted, with device-bound keys
  in `group.com.facebook.family`. A redirected container starts out empty, so
  there are no keys to decrypt with, and no amount of path rewriting produces
  them. The target here is **Facebook** notifications — likes, comments, tags,
  friend requests — which the NSE resolves with an auth-token GraphQL fetch.
- **TrollStore installs.** They already work today, and this changes nothing for
  them: TrollStore preserves the original entitlements, so Facebook's real App
  Groups and keychain group are intact and no redirect is needed.

## Build and injection

Built separately from the root tweak, the same way the Safari web extension is:

```bash
make -C FBPNotifyBridge/src FINALPACKAGE=1
# -> FBPNotifyBridge/src/.theos/obj/FBPNotifyBridge.dylib
```

`build.sh` copies that to **`packages/FBPNotifyBridge.dylib`** and injects from
there, so every build product sits in `packages/` together. That directory is
git-ignored, so the compiled dylib is never committed — the repository carries
only the sources in this folder and each build compiles them again.

It is **deliberately not a target of the root `Makefile`.** A second target there
would be packaged into the `.deb`, and `cyan` would then inject this dylib into
the *main* binary as well — installing the `NSFileManager` / `NSUserDefaults`
redirects twice.

`build.sh` builds it, and after the `cyan` run unpacks the output IPA, copies the
dylib into the appex, adds a weak load command with `cyan`'s own bundled
`insert_dylib` (resolved at runtime from the `cyan` entry point — it is not on
`PATH`) at `@executable_path/FBPNotifyBridge.dylib`, re-fakesigns the appex binary
with `ldid` **preserving its original entitlements** (TrollStore depends on them)
plus the dylib, and repacks. Every failure in that step is a warning: the IPA is
left as `cyan` produced it rather than failing the build. Skip the whole step
with `NSE_BRIDGE=0 ./build.sh`.

`test/sign-and-install.py` additionally passes `-l … -w -P` to `zsign`, so the
local device test exercises the extension-injection path too.

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
4. Notification text becomes specific. ✅

### Still unverified

- Whether the `SecItem*` rebind is comfortable inside an NSE's memory and time
  budget. It has since been narrowed so it no longer rewrites system access
  groups, and **Settings → General → Keychain Compatibility** turns it off
  entirely, which is the first thing to try if the extension starts misbehaving.
- Behaviour on a certificate whose profile grants a *different* set of App
  Groups, or more than one. The resolver sorts and picks the first that actually
  resolves, so both processes converge, but only one certificate has been tested.
- Messenger messages remain out of scope by design, not by omission: they are
  end-to-end encrypted with device-bound keys in `group.com.facebook.family`, and
  a redirected container is empty.
