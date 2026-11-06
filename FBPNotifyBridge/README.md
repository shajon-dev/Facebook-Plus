# FBPNotifyBridge — the notification-service session bridge

**Status: implemented, builds, and is shipped in the IPA — but UNVERIFIED on a
device.** Nobody has yet confirmed that it turns a generic push into real text.
Read the whole page before assuming it fixes anything.

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

Of the two profiles this repo was developed against:

| Profile | App Groups | Bridge works? |
|---|---|---|
| `<udid-device-a>` (team `<TEAM-A>`) | `group.<TEAM-A>.{g1,g2,g3,g4,g5}` | Has something to redirect into. |
| `<udid-device-b>` (team `<TEAM-B>`) | `com.apple.security.application-groups` is an **empty array** | **No.** Nothing to redirect into — the bridge loads and does nothing. |

### If you sideload with Feather

Feather can supply the other half of the fix, and **both of its relevant options
default to off**:

- **Enable "Merge entitlements".** Facebook's keychain groups are read out of the
  original binary and re-written with *your* team id (`T84QZS65DQ.platformFamily`
  → `<yourTeam>.platformFamily`), which works because a developer profile grants
  `<yourTeam>.*` as a wildcard. Without this, the app and the extension have no
  keychain group in common and the session cannot cross between them. Note that
  app *groups* are deliberately **not** merged this way — `group.com.facebook.*`
  can never be authorized — which is exactly the gap this bridge fills.
- **"Inject into app extensions" is not required.** The released IPA already
  carries the bridge inside the appex, so you do not need it. Turning it on is
  harmless.

You still need a certificate with a registered App Group.

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

## Open risk: explicit App IDs and whether the NSE launches at all

Both profiles on hand use an **explicit** App ID (`<TEAM-B>.<app-id-b>`,
`<TEAM-A>.<app-id-a>`), not a wildcard. An app extension normally needs
its own `application-identifier` (`<team>.<host bundle id>.NotificationServiceExtension`),
which an explicit App ID does not cover — and `zsign` cannot help: it writes the
provisioning profile's `Entitlements` dictionary **verbatim into every binary**,
nested `.appex` bundles included, so the extension inherits the main bundle's
`application-identifier` and there is no way to give it a profile of its own.

That sounds fatal, but it is not established that it is:

- The sideloading tools people actually use ship exactly this behaviour and it
  works in practice for them; their own source notes that per-extension
  provisioning is simply not something `zsign` can express, and registering only
  the main bundle is accepted as good enough.
- So an explicit App ID is **not a demonstrated blocker** — but nothing here
  proves the NSE launches either.

Project notes record an on-device observation of `nse_seen:0`, i.e. the extension
may not have been running at all on a re-signed build. If that holds, no
app-group or keychain fix can help until the signing identity is sorted out, and
the first diagnostic should be "does the NSE process start?", not "does it find a
session?".

### Unverified, in order of importance

1. Whether the NSE launches at all on a re-signed install (`nse_seen:0`).
2. Whether a wildcard profile, or per-extension explicit App IDs, is required for
   it to launch.
3. Whether the redirected App-Group container actually carries what the NSE needs
   once it does launch.
4. Whether the blanket `SecItem*` rebind is safe inside an NSE's memory and time
   budget.
5. Whether notification text actually becomes specific. No device run has
   happened.
