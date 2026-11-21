<div align="center">
  <img src="resources/logo.png" width="90" alt="Facebook Plus logo">
  <h1>Facebook Plus</h1>

  <p>
    <strong>The ultimate privacy and enhancement tweak for the Facebook iOS app.</strong><br>
    <em>Quieten your feed, watch stories anonymously, download Reels & Stories, block incoming calls, confirm interactions, and customize the app's appearance and font.</em>
  </p>

  <p>
    <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/License-GPLv3-blue.svg?style=flat-square"></a>
    <img alt="Platform" src="https://img.shields.io/badge/Platform-iOS%2015.1%2B-lightgrey.svg?style=flat-square">
    <a href="https://github.com/shajon-dev/Facebook-Plus/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/shajon-dev/Facebook-Plus?style=flat-square&label=Version&color=success"></a>
  </p>
</div>

---

## ✨ Features

<table>
  <thead>
    <tr>
      <th align="center">Category</th>
      <th align="center">Features</th>
    </tr>
  </thead>
  <tbody>
    <tr><td nowrap rowspan="4">🎨 <b>Appearance</b></td><td>OLED dark mode (true black) that follows your iOS Light / Dark setting, with an option to hide post dividers for a fully black feed</td></tr>
    <tr><td>Disable HDR: force SDR rendering across all EDR paths, tone-mapping video layers to SDR and disabling HDR image views</td></tr>
    <tr><td>Alternate app icons</td></tr>
    <tr><td>Custom fonts from a bundled or imported <code>.ttf</code>/<code>.otf</code>, with adjustable size</td></tr>
    <tr><td nowrap>🧹 <b>Cache</b></td><td>Scheduled automatic cache cleanup (every 12h, 24h, or off) running safely at startup without breaking feed pagination or deleting user sessions</td></tr>
    <tr><td nowrap>📞 <b>Calls</b></td><td>Silently block incoming VoIP and Messenger calls</td></tr>
    <tr><td nowrap rowspan="2">✅ <b>Confirmations</b></td><td>Opt-in prompts that catch accidental taps, with Cancel to stop the action</td></tr>
    <tr><td>Covers Like, Comment, Share, Post, Friend request and Follow / Join</td></tr>
    <tr><td nowrap rowspan="2">🩺 <b>Diagnostics</b></td><td>Exportable in-app activity log for bug reports: kept across launches, cleared daily</td></tr>
    <tr><td>About card with Facebook Plus, Facebook, iOS and device details</td></tr>
    <tr><td nowrap rowspan="5">⬇️ <b>Downloads</b></td><td>Choose a quality before saving: every rung the video actually offers, not just HD/SD</td></tr>
    <tr><td>Lossless merge of Facebook's separate video and audio streams</td></tr>
    <tr><td>AV1 and VP9 qualities re-encoded on-device so Photos accepts them (no shipped FFmpeg)</td></tr>
    <tr><td>Save with add-only Photos access, without full-library permission (iOS 17+)</td></tr>
    <tr><td>Download manager with progress, cancel and retry</td></tr>
    <tr><td nowrap>👑 <b>Facebook Plus</b></td><td>Preview Meta's paid subscriber features without subscribing (including the Story diamond/heart reaction); Direct or Trial unlock, off by default with a warning</td></tr>
    <tr><td nowrap rowspan="5">📰 <b>Feed</b></td><td>Remove ads &amp; sponsored posts across feed, video, Stories and Marketplace</td></tr>
    <tr><td>Hide "People you may know", Group and Page suggestions</td></tr>
    <tr><td>Hide Reels in the feed, Top Stories tray, Threads promo</td></tr>
    <tr><td>Remove survey prompts ("Are you interested in this post?")</td></tr>
    <tr><td>Remove the affiliate / product banner: under a video post, in the comment sheet and on the Reel itself</td></tr>
    <tr><td nowrap rowspan="2">🧭 <b>Links</b></td><td>Open external links in your default browser</td></tr>
    <tr><td>"Open in Facebook" Safari extension: reopens facebook.com links in the app, at the exact destination</td></tr>
    <tr><td nowrap rowspan="3">🎬 <b>Reels</b></td><td>Cinema mode: one tap hides the overlay and the tab bar</td></tr>
    <tr><td>Hide the full-screen "Recommended" card shown between Reels</td></tr>
    <tr><td>Save Reels to Photos</td></tr>
    <tr><td nowrap rowspan="2">🗂️ <b>Sidebar</b></td><td>Clean up the left menu by hiding "Upgrades" and "Also from Meta"</td></tr>
    <tr><td>Quick-access Facebook Plus shortcut row directly in the left navigation drawer</td></tr>
    <tr><td nowrap rowspan="4">📖 <b>Stories</b></td><td>Remove the top Stories carousel tray cleanly without leaving empty gaps or stalling feed pagination</td></tr>
    <tr><td>Ghost Mode: watch without being seen</td></tr>
    <tr><td>Disable auto-advance and hide Story suggestions</td></tr>
    <tr><td>Save Stories, video or photo, to Photos</td></tr>
    <tr><td nowrap>🔔 <b>Updates</b></td><td>In-app update checker with changelog and one-tap download</td></tr>
  </tbody>
</table>

💡 **Dedicated Settings Page:** Access the full-screen tweak settings anytime by long-pressing any **tab bar item** (classic or modern liquid-glass bar), long-pressing the **"facebook" wordmark**, via the **left sidebar menu**, or through the **native Facebook settings entry**. Row titles automatically adjust font size and wrap cleanly across all screen sizes and Display Zoom levels.

---

## 🚀 Installation

> [!IMPORTANT]
> **This repository publishes no `.ipa`.** An injected IPA contains Facebook's own
> application, which is not ours to distribute. Our releases carry only the `.deb`
> packages, which hold nothing but this project's own code. See
> [RELEASE-POLICY.md](.github/RELEASE-POLICY.md).

Pick whichever matches your device:

- **Jailbroken** - install the `.deb` for your packaging scheme (`rootless`,
  `rootfull` or `roothide`) from the **[Releases](../../releases)** section with
  Sileo, Zebra or `dpkg -i`. Nothing else is needed.
- **TrollStore** - grab the **TrollFools** zip from Releases (the tweak dylib and
  its resource bundle, with no Facebook code) and inject it into your own installed
  Facebook with TrollFools.
- **Sideloading (Feather, Ksing, AltStore, SideStore, ...)** - build an injected
  IPA with the GitHub Actions workflow below using a direct download link to your
  own decrypted Facebook IPA. It takes about fifteen minutes and needs no Mac.
- **On a Mac, from source** - see [Building from Source](#️-building-from-source--automated-injection).
  `python3 build.py` writes the injected IPA straight to `packages/`.

## ⚡ Build your own IPA with GitHub Actions

No Mac required. The **Build Facebook Plus (.ipa)** workflow builds the tweak from
source and injects it into a decrypted Facebook IPA from a direct download link you provide, then
publishes the result as a **draft** release on your fork. A draft is visible only
to you, which is the point: the IPA it holds is your own copy of Facebook, so keep
it that way and do not publish it.

> [!IMPORTANT]
> You must supply a direct download URL to your own **decrypted** Facebook `.ipa`. We cannot distribute one
> for legal reasons.

**First time only:**

1. **Fork** this repository (top-right **Fork** button).
2. On your fork, open the **Actions** tab and click **I understand my workflows, go ahead and enable them**.

**To build:**

1. If your fork is behind, click **Sync fork -> Update branch**.
2. Go to **Actions -> Build Facebook Plus (.ipa)**.
3. Click **Run workflow** on the right.
4. In the **Direct download URL to the decrypted Facebook IPA** field, paste the **direct download link** to your decrypted `.ipa` file (for example, upload your file to [**filebin.net**](https://filebin.net) or any direct file host and copy the direct file link). A link to a *web page* instead of the direct file URL will fail validation.
5. Click **Run workflow** and wait for it to finish (about 10-15 min).
6. Download the IPA from your fork's **Releases** section. The release is created as
   a **draft**, so only you can see it: open it and download the assets. (If you
   don't see Releases, append `/releases` to your fork's URL, e.g.
   `github.com/<you>/Facebook-Plus/releases`.) Leave it as a draft; publishing an
   IPA is what this project does not do, and why.

The workflow reuses [`build.py`](build.py) in the cloud to inject the tweak, custom
app-icons, and the bundled **Open in Facebook** Safari extension, all fakesigned for sideloading.

## 🛠️ Building from Source & Automated Injection

This project requires [Theos](https://theos.dev) to build. Ensure you have it installed and configured.

1. **Clone the repository** (including submodules):
   ```bash
   git clone --recursive https://github.com/shajon-dev/Facebook-Plus.git
   cd Facebook-Plus
   ```

2. **Set up Python Environment**:
   Create a virtual environment and install the required tools:
   ```bash
   python3 -m venv venv && source venv/bin/activate && pip install -r requirements.txt && pipx install --force https://github.com/asdfzxcvbn/pyzule-rw/archive/main.zip && pipx inject --force cyan lief
   ```

3. **Automated Pipeline (`build.py`)**:
   - Run `python3 build.py` to build **every variant**, or narrow it with
     `--rootless` / `--rootfull` / `--roothide` / `--trollfools`. See
     `python3 build.py --help` for the full set of flags (`--ipa`, `--install`,
     `--ssh`, `--clean`, ...).
   - To also produce an injected `.ipa`, place a decrypted Facebook `.ipa` at
     `test/com.facebook.Facebook.ipa` before running (optional: set `BUNDLE_ID=com.example.id`
     to install alongside the stock app; the tweak is bundle-id-agnostic).

   **What `build.py` does:**
   - Builds each variant into `packages/`:

     | Variant | Output |
     |---|---|
     | `rootless` | `Facebook-Plus-v<version>-rootless.deb` |
     | `rootfull` | `Facebook-Plus-v<version>-rootfull.deb` |
     | `roothide` | `Facebook-Plus-v<version>-roothide.deb` (rootless layout, arm64e) |
     | `trollfools` | `Facebook-Plus-v<version>-TrollFools.zip` (dylib + bundle) |

   - If a decrypted `.ipa` is present, injects the **rootless** build into it with
     `cyan` and writes `packages/Facebook-Plus-v<facebook-version>-rootless.ipa`.
     The same `cyan` run also:
     - builds every Safari web extension under `OpenInFacebookSafariExtension/`
       from source and injects the resulting `.appex` into the app's `PlugIns/`;
     - merges any custom app icons (`fbplus_*.png` in `resources/logo/`) into
       `CFBundleAlternateIcons`, preserving Facebook's native icons;
     - fakesigns every injected binary for sideloading;
     - builds `FBPNotifyBridge/src` and adds the resulting dylib to the app's
       `NotificationServiceExtension.appex` (see
       [below](#-notifications-on-sideloaded-builds));
       skip it with `NSE_BRIDGE=0 python3 build.py`.


<details>
<summary><b>Code Editor Setup</b></summary>

Theos does not emit a compilation database by default, causing editors to fail at finding the iOS SDK. Generate one with [`bear`](https://github.com/rizsotto/Bear):

```bash
make compile-commands
```

This writes a per-machine `.clangd` (with your theos path and SDK baked in) and a `compile_commands.json`. The database is produced with `bear parse-sh` from theos's own dry-run (`make -n`) rather than by intercepting the build, because macOS strips the interception mechanism (`DYLD_INSERT_LIBRARIES`) from the Xcode toolchain's Apple-signed clang, leaving a plain `bear -- make` empty. Re-run it after adding new source files. Note: Logos `.xm` files cannot be fully parsed by clang, so `.clangd` suppresses false diagnostics while ensuring they compile correctly.

</details>

---

## 🔔 Notifications on sideloaded builds

Whether a sideloaded build delivers real notifications or just
*"You have a new notification"* depends on your signing certificate. The full
explanation of how it works, what is confirmed today, and what to check on your
certificate lives in **[`FBPNotifyBridge/README.md`](FBPNotifyBridge/README.md)**.

---

## 🏗️ Project Architecture

```text
├── FBPNotifyBridge     # Slim dylib injected into NotificationServiceExtension.appex (session bridge)
├── Localizations       # Translations (ar, bn, de, es, fr, hi, id, it, ja, ko, pl, pt-BR, ru, tr, vi, zh-Hans, zh-Hant)
├── OpenInFacebookSafariExtension  # Safari web extension built into PlugIns ("Open in Facebook")
├── resources           # Assets (App icons, SVGs, and asset bundles)
│   ├── bundle          # Compiled UI images and tweak resources
│   ├── fonts           # Bundled custom fonts offered by the Fonts picker
│   ├── logo            # Custom app-icons drop folder for build.py injection
│   └── svg             # Source vector graphics
├── scripts             # doctor.py: typecheck, link, prefs, strings, lint, and hook checks
├── src                 # Tweak source code
│   ├── Core            # Constructor, preferences, logging/diagnostics, fishhook submodule
│   ├── Features        # All hooks & feature implementations:
│   │   ├── Ads         # Feed, video, story & Marketplace ad removal (feed chokepoint + RN/GraphQL)
│   │   ├── AppChrome   # UI settings gesture (TabBar, Wordmark long-press & Settings Button)
│   │   ├── AppIcons    # Custom app-icon picker logic
│   │   ├── Cache       # Scheduled automatic cache cleaner and manual cache sweep
│   │   ├── Calls       # Incoming Call Blocker (PushKit & CallKit interceptors)
│   │   ├── Comments    # Remove the affiliate/product banner in the comment sheet
│   │   ├── Confirmation # Opt-in confirmations for like/share/follow/friend (CK forwarder) & comment/post (swizzle)
│   │   ├── Downloads   # Quality picker, DASH manifest reader, two-stream fetch, lossless
│   │   │               # mux, AV1/VP9->HEVC conversion, add-only Photos save, download manager
│   │   ├── FacebookPlus # Preview paid subscriber benefits (client-side gate override)
│   │   ├── Feed        # Feed-related hooks (suggestions, Reels, Stories removal)
│   │   ├── Fonts       # Custom UI font replacement (Core Text registration + picker)
│   │   ├── HDR         # Force SDR rendering app-wide (comprehensive EDR and headroom clamp)
│   │   ├── Language    # UI language override hooks
│   │   ├── Links       # Open external links in default browser & inbound link bridge
│   │   ├── Notifications # Client-sync bridge for detailed push on sideloaded builds
│   │   ├── OLED        # True black dark mode that follows the iOS system appearance
│   │   ├── Onboarding  # Welcome screen controller
│   │   ├── Reels       # Cinema mode (hide overlay/tab bar), hide Recommended card & Reels download
│   │   ├── Sidebar     # Left menu cleaner (hide Upgrades / Also from Meta, add tweak entry)
│   │   ├── Stories     # Story-related hooks (Ghost mode, auto-advance block, remove top stories tray)
│   │   └── Update      # In-app update checker + update screen (GitHub Releases)
│   ├── PluginsInject   # Sideload compatibility layer (Keychain / App-Group / CloudKit)
│   ├── Settings        # Dedicated full-screen Facebook Plus settings UI
│   └── UI              # Shared UI components
│       ├── Sheet       # Detent & Presentation controllers
│       └── Toast       # HUD / Progress pills (app-logo toast)
└── test                # Decrypted input IPA and signing certificates
```

**Resilient Hooking:** Each hook dynamically verifies that its target class and selector exist before installation. If a Facebook update changes a specific class, only that single feature degrades safely without crashing the entire tweak. The settings gesture, for example, hooks both the classic tab bar and the new iOS 26 liquid-glass bars so long-press keeps working across iOS versions.

---

## 🗺️ Roadmap & Credits

Planned features and fixes are tracked in **[TODO.md](TODO.md)**. The project's
provenance, third-party attributions, and credits are documented in
**[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)**. Contributions and
suggestions are welcome: open an issue or a pull request.

## 🔒 Security & Disclaimer

Please read **[SECURITY.md](SECURITY.md)** for our security policy, account safety guidelines, and disclaimer of warranty/liability. Use Facebook Plus at your own risk.

## ⚖️ License

This project is open-source and distributed under the terms of the **[GNU General Public License v3.0 (GPL-3.0)](LICENSE)**.
Please refer to the `LICENSE` file for more details.

---
<p align="center">
  <b>Copyright &copy; 2026 S. SHAJON</b>
</p>
