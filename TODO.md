# 🗺️ TODO & Roadmap

Planned work for Facebook Plus. Contributions and suggestions are welcome — open
an issue or a pull request. Third-party attributions and credits live separately
in **[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)**.

**Feed & Content**
- [x] Hide **ads on Facebook Marketplace**
- [x] Hide **survey prompts** — the "Are you interested in this post / Reel?" cards, in the feed and on both Reels surfaces

**Downloads**
- [x] **Multiple-quality** download picker for Reels & videos (choose resolution before saving)
- [x] **Download manager** — per-download progress, cancel and retry, surviving the sheet being dismissed
- [x] **VP9** rungs — the same Photos limitation as AV1, but decoded by Facebook's own bundled libavcodec (borrowed by `dlsym`, since VideoToolbox has no VP9 decoder) and re-encoded to HEVC/H.264 before the save
- [ ] **Live videos** (`MPD@type="dynamic"`), which are segment-templated rather than single-file

**Notifications** — *"You have a new notification"* on sideloaded builds
- [x] **Messenger messages and calls** — carried end to end by
      **[`FBPNotifyBridge`](FBPNotifyBridge/README.md)**, the session bridge
      injected into `NotificationServiceExtension.appex`
- [ ] **Likes, comments, replies, tags, mentions, friend requests** — still
      generic, or no banner at all. The bridge is not what is failing here

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

> [!NOTE]
> This list tracks intended work; items are unchecked until shipped in a release.
