# FBPNotifyBridge — the notification-service session bridge

**Status: shipped, and half the job is done (last device capture 2026-11-08).**

| | On a re-signed build |
|---|---|
| Messenger messages and calls | **Detailed.** Confirmed on device — content mutated and delivered in 165 ms. |
| Likes, comments, replies, tags, mentions, friend requests | **Still generic, or no banner at all.** |

> [!IMPORTANT]
> **It comes down to your signing certificate.** If your developer certificate
> supports push notifications — i.e. it grants at least one App Group — the
> bridge has somewhere to work and you can receive notifications. If it does
> not, you will not get them: the app only shows *"You have a new
> notification"*.

Everything this component was built to do, it does: the extension launches, the
bridge loads into it, and it resolves the *same* App-Group container and the
*same* keychain access group as the main app. The remaining failure is not in
this dylib — see [What is still missing](#what-is-still-missing).

A signing certificate carrying at least one registered App Group is **necessary
but not sufficient**: without one the bridge has nowhere to redirect and is inert
(see [Your signing certificate has to cooperate](#your-signing-certificate-has-to-cooperate)),
but a certificate that has five of them was used for the capture above and
Facebook notifications stayed broken anyway.

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
call in the process; it was then narrowed to stop breaking system and auth
frameworks, and the narrowing passed `kSecUseDataProtectionKeychain` queries
through untouched — which in this binary is precisely Meta's own Swift keychain
stores asking for `T84QZS65DQ.platformFamily`. The extension got a null token, so
likes, comments and friend requests stayed generic while Messenger messages
(container-backed) kept working.

The evidence, from the 586.0.0 extension binary: `kSecAttrAccessControl` is not
imported at all, so half that rule was dead code; `kSecUseDataProtectionKeychain`
has exactly two load sites, both Swift global-accessor thunks, and at each of
their four call sites the `kSecAttrAccessGroup` thunk is called four
instructions earlier — i.e. both keys go into the same dictionary. That code
region is `MetaPushEncryptionKeyStore` / `MetaHPKEManager` and the push-notif
token store behind client sync.

Fixed 2026-11-08: `SecRebinds.xm` now decides per query with three outcomes
(`leave`, `pin`, `strip`) under one rule — *never leave a query asking for an
access group this process cannot possibly hold, and never move a query that
already asks for one it can.* `com.apple.*` groups stay untouched.

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

**It is not required.** Messenger notifications have been confirmed detailed
without it, on a certificate that carries App Groups. Treat it as belt-and-braces
rather than a prerequisite: if your build of Feather offers the switch, turning
it on costs nothing; if it does not, a certificate with an App Group is enough
for everything this dylib can reach.

Two practical notes:

- The option is **not in any released build** of Feather as of v2.9.0. It exists
  only on the project's `main` branch, under **Settings → Features → Signing
  Options**, in its own section below "Delete After Signing".
- Where it does appear, it is disabled while a custom entitlements file is
  loaded — Feather will not merge on top of one you supplied yourself.

"Inject into app extensions" is **not** needed either: the released IPA already
carries the bridge inside the appex. Enabling it is harmless.

## What is still missing

Facebook expands a push along **two different paths**, and they fail for
different reasons. This is the whole of the remaining problem.

**Messenger messages and calls — these work.** The push carries real alert text
plus `mutable-content: 1`, which is exactly what iOS requires before it will
launch a notification service extension. The NSE then reads its content out of
the Msys store in `group.com.facebook.msysstorage`, which the container redirect
supplies.

**Likes, comments, replies, tags, mentions, friend requests — these do not.**
The push carries `content-available: 1`, a badge and a sound, but **no alert and
no `mutable-content`**. iOS answers

```
Saving notification … NO [ hasAlertContent: NO, shouldPresentAlert: YES ]
Error saving notification … "Repository could not save notification.
                             No content that needs to alert."
NOT delivering user visible push notification
```

and **never starts the extension at all**. It sets the badge and hands the push
to DUET, which wakes the app in the background instead. The app does wake, and
does read its keychain successfully — but it is suspended within about two
seconds, before Facebook's own client-sync fetch can finish, so nothing is ever
posted.

So for this half, no change inside this dylib can help: the code never runs.
Two things are being pursued instead, and neither belongs here —

1. **`com.apple.developer.usernotifications.filtering`.** The extension's
   original entitlements carry it; it is Apple-restricted (granted only by
   request, and Apple's own rejection wording limits the categories to
   messaging, emergency, education and healthcare), so no third-party profile
   will ever have it, and re-signing replaces the whole entitlement dictionary.
   It is the only plausible mechanism by which Meta's contentless pushes reach
   the extension on an App Store build. Not yet confirmed on device.
2. **Finishing the fetch in the main app.** The app is already awake and
   Facebook's own machinery is already in that process —
   `FBPushNotifClientSyncManager`, `FBPushNotifClientSyncGraphQLNetworker`,
   `addNotificationRequest:withCompletionHandler:`, and a notification source
   label named `DEFAULT__FROM_SILENT_PUSH_FALLBACK`. Holding a background task
   assertion across `application:didReceiveRemoteNotification:fetchCompletionHandler:`
   so the fetch can complete needs no entitlement and no server. That work lives
   in the main tweak, not in this dylib.

One thing worth stating plainly, because it is asked often: **a push server of
our own is not an option.** APNs routes by `apns-topic`, which is the app's
bundle identifier `com.facebook.Facebook`; pushing to that topic requires an
APNs key belonging to the team that owns that App ID. A signing `.p12` is not an
APNs credential, and `NEAppPushProvider` needs an `app-push-provider`
entitlement that sideloading profiles do not grant.

**TrollStore installs are unaffected by any of this.** They keep the original
entitlements, so Facebook's real App Groups, its keychain group *and* the
filtering entitlement are all intact, and notifications work with no bridge
involvement.

## What has already been ruled out

Each of these was a live theory at some point, and each is closed with evidence
rather than reasoning. Worth reading before proposing any of them again.

| Suspect | Why it is not the cause |
|---|---|
| **The signing certificate** | `test/certificates/00008140-…` grants five App Groups, and that is the certificate the 2026-11-08 capture ran on (`from 5 candidates`, `resolved access group Y8BF277F4X.*`). The App-Group requirement is **met and still insufficient**. |
| **The container redirect, the keychain rebind, the access-group resolution** | All three resolved correctly in that capture, and *identically* in both processes. Every Facebook keychain service came back `OSStatus 0` in both. |
| **Extensions stripped at build time** | `build.py` passes cyan `-g` (`--remove-encrypted`), never `-e` (`--remove-extensions`), and the decrypted input IPA is `cryptid 0` throughout. The shipped IPA carries the appex with `FBPNotifyBridge.dylib` weak-linked — verified in the release artifact. |
| **Notifications being switched off** | The same capture read back `authorization=authorized alert=on lockScreen=on notificationCenter=on badge=on sound=on`. |
| **Running a push server of our own** | APNs routes by `apns-topic`, which is `com.facebook.Facebook`; pushing there needs an APNs key from the team owning that App ID. A signing `.p12` is not an APNs credential, and `NEAppPushProvider` needs an `app-push-provider` entitlement sideloading profiles do not grant. |
| **Explicit (non-wildcard) App IDs, and whether the extension launches at all** | Settled on device — see [below](#explicit-app-ids-and-whether-the-nse-launches--settled). |

One finding worth keeping in view, because it contradicts an earlier reading of
the capture: the string *"You have a new notification"* is **nowhere in the app
bundle** — a byte search in ASCII and UTF-16 across every binary, every
`.lproj` and `Localizable.json` finds nothing. It is therefore server-supplied
inside an `alert`, which means a push carrying it is *not* the contentless push
the capture analysed. Both shapes are in play.

## What happens next

In order, because the first one decides the rest.

1. **Capture, before anything else.** An `FBP_DIAG=1` build, recording per push:
   `hasAlertContent` / `hasMutableContent` / `pushType`, the payload, whether the
   extension launched, whether Facebook called `addNotificationRequest:`, and the
   access group each process resolved. Trigger a like, a comment, a friend
   request, a tag and a Messenger message deliberately. A push carrying
   `mutable-content` means the extension runs and loses, which is a session
   problem; one without means it never runs, which is not.
2. **Finish the fetch in the main app.** Hook
   `application:didReceiveRemoteNotification:fetchCompletionHandler:`, hold a
   `beginBackgroundTaskWithExpirationHandler:` assertion, let Facebook's own
   `FBPushNotifClientSyncManager` complete, then call the completion handler.
   Force `FBMobileConfigSilentPushFallbackTable` if it turns out to gate the
   fallback. This is main-tweak work, not bridge work.
3. **Probe the filtering entitlement.** Add the key to the appex before signing
   and see whether `installd` accepts it. Either answer is worth having — a
   refusal closes the route for good and leaves TrollStore as the only one.
   `build.py` already captures and re-applies the appex's original entitlements,
   so this is a few lines.
4. **Run one keychain implementation in both processes** — see the last entry
   under [Still unverified](#still-unverified).
5. **Wrap the content handler.** A once-only, exception- and expiry-safe wrapper
   around `didReceiveNotificationRequest:withContentHandler:` that always calls
   the handler exactly once, falling back to the original content. This does not
   make notifications detailed; it removes the separate failure class where a
   banner arrives ~30 s late or not at all.

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
  Groups. The resolver sorts and picks the first that actually resolves, so both
  processes converge, but only one certificate has been tested — one granting
  five groups, on which the container and the access group resolved identically
  in both processes.
- **Whether the app and the extension converge on a device.** They at least run
  the same code now: the released IPA used to inject a vendored closed-source
  keychain patch into the **main app**, where this project's own `SecRebinds`
  stood down, so the two processes ran *different* keychain implementations.
  That dylib was reversed, found to do nothing for Facebook's own keychain
  traffic that `SecRebinds` does not, and removed — both processes share one
  implementation again. The convergence itself still wants a device run.
- Whether Facebook sends this build HPKE-encrypted payloads at all. The NSE has
  the machinery (`MetaPushEncryptionKeyStore`, `is_encrypted`), and its keychain
  queries were broken by the same rule and fixed by the same change, but nothing
  has shown it is on the path in practice.
