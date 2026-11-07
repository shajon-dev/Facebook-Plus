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
    <img alt="Version" src="https://img.shields.io/badge/Version-1.0.4-success.svg?style=flat-square">
  </p>
</div>

---

## ✨ Features

<table>
  <thead>
    <tr>
      <th>Category</th>
      <th>Features</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td nowrap>📰 <b>Feed</b></td>
      <td>Remove ads &amp; sponsored posts — feed, video, Stories and Marketplace<br>Hide "People you may know", Group and Page suggestions<br>Hide the Reels carousel, Threads promo and Stories tray<br>Remove survey prompts ("Are you interested in this post?")</td>
    </tr>
    <tr>
      <td nowrap>⬇️ <b>Downloads</b></td>
      <td>Choose a quality before saving — every rung the video actually offers, not just HD/SD<br>Lossless merge of Facebook's separate video and audio streams<br>Download manager with progress, cancel and retry</td>
    </tr>
    <tr>
      <td nowrap>✅ <b>Confirmations</b></td>
      <td>Opt-in prompts that catch accidental taps, with Cancel to stop the action<br>Covers Like, Comment, Share, Post, Friend request and Follow / Join</td>
    </tr>
    <tr>
      <td nowrap>🎬 <b>Reels</b></td>
      <td>Cinema mode — one tap hides the overlay and the tab bar<br>Save Reels to Photos</td>
    </tr>
    <tr>
      <td nowrap>📖 <b>Stories</b></td>
      <td>Ghost Mode — watch without being seen<br>Disable auto-advance and hide Story suggestions<br>Save Stories, video or photo, to Photos</td>
    </tr>
    <tr>
      <td nowrap>📞 <b>Calls</b></td>
      <td>Silently block incoming VoIP and Messenger calls</td>
    </tr>
    <tr>
      <td nowrap>🧭 <b>Links</b></td>
      <td>Open external links in your default browser<br>"Open in Facebook" Safari extension — reopens facebook.com links in the app, at the exact destination</td>
    </tr>
    <tr>
      <td nowrap>🎨 <b>Appearance</b></td>
      <td>OLED dark mode (true black)<br>Alternate app icons<br>Custom fonts from a bundled or imported <code>.ttf</code>/<code>.otf</code>, with adjustable size</td>
    </tr>
    <tr>
      <td nowrap>🔔 <b>Updates</b></td>
      <td>In-app update checker with changelog and one-tap download</td>
    </tr>
  </tbody>
</table>

💡 **Dedicated Settings Page:** Access the dedicated full-screen tweak settings anytime by long-pressing any **tab bar item** (classic or modern liquid-glass bar), long-pressing the **"facebook" wordmark**, or via the **native Facebook settings entry**.

---

## 🚀 Installation

Download the pre-built `.ipa` file from the **[Releases](../../releases)** section and install it on your device using **Feather**, **Ksing**, **AltStore**, **TrollStore**, or any other sideloading tool of your choice.

## ⚡ Build your own IPA with GitHub Actions

No Mac required. The **Build Facebook Plus (.ipa)** workflow builds the tweak from
source and injects it into a decrypted Facebook IPA that **you** provide, then
publishes the result as a draft release on your fork.

> [!IMPORTANT]
> You must supply your own **decrypted** Facebook `.ipa`. We cannot distribute one
> for legal reasons.

**First time only:**

1. **Fork** this repository (top-right **Fork** button).
2. On your fork, open the **Actions** tab and click **I understand my workflows, go ahead and enable them**.

**To build:**

1. If your fork is behind, click **Sync fork → Update branch**.
2. Go to **Actions → Build Facebook Plus (.ipa)**.
3. Click **Run workflow** on the right.
4. Fill in the inputs:
   - **Direct download URL to the decrypted Facebook IPA** — upload your decrypted
     `.ipa` to [**filebin.net**](https://filebin.net) and paste the **direct
     download link** to the file. filebin is the recommended host and the one this
     workflow has been tested with. A link to a *web page* instead of the file
     itself will fail validation.
   - **Bundle identifier** *(optional)* — leave blank to keep `com.facebook.Facebook`.
     Set a custom id to install alongside the stock app. The tweak is
     bundle-id-agnostic, so it activates under whatever id you choose — no other
     change needed.
5. Click **Run workflow** and wait for it to finish (≈10–15 min).
6. Download the IPA from your fork's **Releases** section. The release is created as
   a **draft** — open it, review, and publish. (If you don't see Releases, append
   `/releases` to your fork's URL, e.g. `github.com/<you>/Facebook-Plus/releases`.)

The workflow reuses [`build.sh`](build.sh), so your IPA gets the exact same
injection as a local build — the tweak, the custom app-icons, and the bundled
**Open in Facebook** Safari extension, all fakesigned for sideloading.

## 🛠️ Building from Source & Automated Injection

This project requires [Theos](https://theos.dev) to build. Ensure you have it installed and configured.

1. **Clone the repository** (including submodules):
   ```bash
   git clone --recursive https://github.com/SHAJON-404/Facebook-Plus.git
   cd Facebook-Plus
   ```

2. **Set up Python Environment**:
   Create a virtual environment and install the required tools:
   ```bash
   python3 -m venv venv && source venv/bin/activate && pip install -r requirements.txt && pipx install --force https://github.com/asdfzxcvbn/pyzule-rw/archive/main.zip && pipx inject --force cyan lief
   ```

3. **Automated Pipeline (`build.sh`)**:
   - Run `./build.sh` to build **every packaging scheme**, or narrow it with the
     `SCHEMES` variable (e.g. `SCHEMES="rootless rootfull" ./build.sh`).
   - To also produce an injected `.ipa`, place a decrypted Facebook `.ipa` at
     `test/com.facebook.Facebook.ipa` before running.

   **What `build.sh` does:**
   - Builds one versioned `.deb` per scheme into `packages/`:

     | Scheme | Output |
     |---|---|
     | `rootless` | `Facebook-Plus-v<version>-rootless.deb` |
     | `rootfull` | `Facebook-Plus-v<version>-rootfull.deb` |

   - If a decrypted `.ipa` is present, injects the **rootless** build into it with
     `cyan` and writes `packages/Facebook-Plus-v<facebook-version>-rootless.ipa`.
     The same `cyan` run also:
     - builds every Safari web extension under `OpenInFacebookSafariExtension/`
       from source and injects the resulting `.appex` into the app's `PlugIns/`;
     - merges any custom app icons (`fbplus_*.png` in `resources/logo/`) into
     `CFBundleAlternateIcons` via `scripts/icon_plist.py`, preserving
     Facebook's native icons;
     - fakesigns every injected binary for sideloading;
     - builds `FBPNotifyBridge/src` and adds the resulting dylib to the app's
       `NotificationServiceExtension.appex` (see
       [below](#-notifications-on-sideloaded-builds));
       skip it with `NSE_BRIDGE=0 ./build.sh`.


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

Sideloaded builds show *"You have a new notification"* instead of the real text
(issues [#12](../../issues/12), [#13](../../issues/13)). Facebook sends a stub
payload and lets `NotificationServiceExtension.appex` expand it — but that
extension can only do so if it can find your session, and on a re-signed build it
cannot: the session lives in Meta's App Groups (`group.com.facebook.*`) and
keychain group (`T84QZS65DQ.platformFamily`), and Apple will never authorize
another team's identifiers for your certificate.

The released IPA carries **`FBPNotifyBridge.dylib`** inside that extension: a
~70 KB dylib that applies the same container and keychain redirects the main app
already uses, so both processes read and write the same place. **Confirmed
working on a device**, with detailed notifications on the lock screen. Full
write-up in **[`FBPNotifyBridge/README.md`](FBPNotifyBridge/README.md)**.

What this means for you:

- **Your certificate needs at least one registered App Group.** Without one
  there is no container to redirect into and the bridge does nothing.
  **[Check your certificate in a minute](../../wiki/Check-App-Groups-Support)**
  — sign and open a small checker app and it tells you outright, before you
  sign anything else.
- **Feather's "Merge Entitlements" is optional.** Notifications are confirmed
  working without it, and as of Feather v2.9.0 the switch is not in any released
  build. Enable it if your build offers it; otherwise a certificate with an App
  Group is enough. "Inject into app extensions" is not needed either — the
  bridge already ships inside the IPA.
- **Messenger messages are out of scope**, being end-to-end encrypted with
  device-bound keys the bridge cannot reach. The target is **Facebook**
  notifications: likes, comments, tags, friend requests.
- **TrollStore users need none of this** — it preserves the original
  entitlements, so notifications already work.

---

## 🏗️ Project Architecture

```text
├── FBPNotifyBridge     # Slim dylib injected into NotificationServiceExtension.appex (session bridge)
├── Localizations       # Translations (ar, bn, de, es, fr, hi, id, it, ja, ko, pl, pt-BR, ru, tr, vi, zh-Hans, zh-Hant)
├── OpenInFacebookSafariExtension  # Safari web extension built into PlugIns ("Open in Facebook")
├── resources           # Assets (App icons, SVGs, and asset bundles)
│   ├── bundle          # Compiled UI images and tweak resources
│   ├── fonts           # Bundled custom fonts offered by the Fonts picker
│   ├── logo            # Custom app-icons drop folder for build.sh injection
│   └── svg             # Source vector graphics
├── scripts             # Python utility scripts (e.g., icon merging, svg rendering)
├── src                 # Tweak source code
│   ├── Core            # Constructor, preferences, and resources
│   ├── Features        # All hooks & feature implementations:
│   │   ├── Ads         # Feed, video, story & Marketplace ad removal (feed chokepoint + RN/GraphQL)
│   │   ├── AppChrome   # UI settings gesture (TabBar, Wordmark long-press & Settings Button)
│   │   ├── AppIcons    # Custom app-icon picker logic
│   │   ├── Calls       # Incoming Call Blocker (PushKit & CallKit interceptors)
│   │   ├── Confirmations # Opt-in commit-level confirmations (comment, share, post, friend, follow)
│   │   ├── Downloads   # Quality picker, DASH manifest reader, two-stream fetch,
│   │   │               # lossless mux, AV1→HEVC conversion, download manager
│   │   ├── Feed        # Feed-related hooks (suggestions, Reels, Stories removal)
│   │   ├── Fonts       # Custom UI font replacement (Core Text registration + picker)
│   │   ├── Language    # UI language override hooks
│   │   ├── LikeConfirmation # Confirm likes via the ComponentKit forwarder (feed & Reels)
│   │   ├── Links       # Open external links in default browser & inbound link bridge
│   │   ├── OLED        # True black dark mode implementation
│   │   ├── Onboarding  # Welcome screen controller
│   │   ├── Stories     # Story-related hooks (Ghost mode, auto-advance block)
│   │   └── Update      # In-app update checker + update screen (GitHub Releases)
│   ├── PluginsInject   # Sideload compatibility layer (Keychain / App-Group / CloudKit)
│   ├── Settings        # Dedicated full-screen Facebook Plus settings UI
│   └── UI              # Shared UI components
│       ├── Sheet       # Detent & Presentation controllers
│       └── Toast       # HUD / Progress pills
└── test                # Input IPA directory and test scripts
```

**Resilient Hooking:** Each hook dynamically verifies that its target class and selector exist before installation. If a Facebook update changes a specific class, only that single feature degrades safely without crashing the entire tweak. The settings gesture, for example, hooks both the classic tab bar and the new iOS 26 liquid-glass bars so long-press keeps working across iOS versions.

---

## 🗺️ Roadmap & Credits

Planned features and fixes, together with the project's provenance, third-party
attributions, and credits, are documented in **[ROADMAP_AND_CREDITS.md](ROADMAP_AND_CREDITS.md)**.
Contributions and suggestions are welcome — open an issue or a pull request.

## 🔒 Security & Disclaimer

Please read **[SECURITY.md](SECURITY.md)** for our security policy, account safety guidelines, and disclaimer of warranty/liability. Use Facebook Plus at your own risk.

## ⚖️ License

This project is open-source and distributed under the terms of the **[GNU General Public License v3.0 (GPL-3.0)](LICENSE)**.
Please refer to the `LICENSE` file for more details.

---
<p align="center">
  <b>Copyright &copy; 2026 S. SHAJON</b>
</p>
