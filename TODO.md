# 🗺️ TODO & Roadmap

Planned work for Facebook Plus. Contributions and suggestions are welcome — open
an issue or a pull request. Third-party attributions and credits live separately
in **[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)**.

**Feed & Content**
- [x] Hide **ads on Facebook Marketplace**
- [x] Hide **survey prompts** in the **feed** — the "Are you interested in this post?" card
- [ ] Hide the same **survey card on Reels** — no longer possible on build 587
  <details><summary>why</summary>

  In 587 the Reels card is a pure C++ ComponentKit component (`FBShortsModernizedSMSLComponent`) built from a GraphQL sub-fragment of the Reel — no Objective-C class, factory or accessor to hook, and the old injection-manager / helper-gate path is dormant. The only chokepoint is the C++ build function via `MSHookFunction`, which crashes on a sideloaded build (see the note at the bottom). The feed card is still removed.
  </details>
- [ ] Hide the **"Suggested for you"** groups/pages rail in the **Marketplace** tab
  <details><summary>why</summary>

  It is a React Native / Relay surface (Hermes `MARKETPLACE_*_GYSJ_MODULE`), not a native feed unit — the native feed filter never sees it and there is no class or gate to hook. A fix would need a JS/Relay-layer patch, out of scope for a native tweak.
  </details>

**Downloads**
- [x] **Multiple-quality** download picker for Reels & videos (choose resolution before saving)
- [x] **Download manager** — per-download progress, cancel and retry, surviving the sheet being dismissed
- [x] **VP9** rungs — the same Photos limitation as AV1, but decoded by Facebook's own bundled libavcodec (borrowed by `dlsym`, since VideoToolbox has no VP9 decoder) and re-encoded to HEVC/H.264 before the save
- [ ] **Live videos** (`MPD@type="dynamic"`), which are segment-templated rather than single-file

**Notifications** — *"You have a new notification"* on sideloaded builds
- [x] **Messenger messages and calls** — carried end to end by
      **[`FBPNotifyBridge`](FBPNotifyBridge/README.md)**, the session bridge
      injected into `NotificationServiceExtension.appex`
- [x] **Jailbroken / TrollStore installs** — the sideload compatibility layer
      no longer runs where Facebook's own entitlements are intact. It used to
      redirect the real App-Group container into `Documents/`, which broke
      notifications on an App Store Facebook purely by installing the `.deb`
- [ ] **Likes, comments, replies, tags, mentions, friend requests** — still
      generic, or no banner at all, **on a re-signed (sideloaded) build**. The
      bridge is not what is failing here

Facebook expands a push along two different paths. Messenger's carries real
alert text, so iOS launches the extension and the bridge serves it. The rest
arrive with no alert and no `mutable-content`, so iOS never starts the extension
at all — it wakes the app in the background instead, and the app is suspended
before Facebook's own fetch can finish.

**Full write-up — the evidence, what has been ruled out, and what is being tried
next — is in [`FBPNotifyBridge/README.md`](FBPNotifyBridge/README.md).**

**Navigation**
- [ ] Option to hide the **Reels / Video tab** from the bottom tab bar
- [ ] Remove the **"Also from Meta"** section from the left sidebar

**Localization**
- [ ] Fix Facebook's **"… wasn't downloaded"** language wall on sideloaded builds
  <details><summary>why</summary>

  Facebook resolves UI strings from a *downloaded* language pack while `FBCoreLocaleIsDownloadableLanguagePackEnabled()` is on, with no fall-through to the bundled `languages.lgpk` (which already carries every locale). Forcing that C gate off needs `MSHookFunction`, which crashes on sideload; `fishhook` is safe but misses the intra-framework caller. Works on a jailbroken install, not a plain sideload.
  </details>

> [!IMPORTANT]
> On a **sideloaded (non-jailbroken)** build, inline C/C++ function hooking (`MSHookFunction`) is not possible — it patches code-signed pages, so the kernel kills the app (`CODESIGNING` / "Invalid Page"). Only Objective-C `%hook` and `fishhook` are safe; a fix whose only chokepoint is a C/C++ function (the two above) can't be shipped for sideload.

> [!NOTE]
> This list tracks intended work; items are unchecked until shipped in a release.
