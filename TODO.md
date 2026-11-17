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

**Notifications**
- [x] **Detailed push notifications on sideloaded builds** — session bridge into `NotificationServiceExtension`

**Navigation**
- [ ] Option to hide the **Reels / Video tab** from the bottom tab bar
- [ ] Remove the **"Also from Meta"** section from the left sidebar

> [!NOTE]
> This list tracks intended work; items are unchecked until shipped in a release.
