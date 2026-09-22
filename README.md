<div align="center">
  <img src="resources/logo.png" width="90" alt="Facebook Plus logo">
  <h1>Facebook Plus</h1>

  <p>
    <strong>The ultimate privacy and enhancement tweak for the Facebook iOS app.</strong><br>
    <em>Quieten your feed, watch stories anonymously, download Reels & Stories, confirm interactions, and customize the app's appearance.</em>
  </p>

  <p>
    <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/License-GPLv3-blue.svg?style=flat-square"></a>
    <img alt="Platform" src="https://img.shields.io/badge/Platform-iOS%2017.0%2B-lightgrey.svg?style=flat-square">
    <img alt="Version" src="https://img.shields.io/badge/Version-1.0.1-success.svg?style=flat-square">
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
      <td>Remove Ads & Sponsored Posts<br>Hide "People you may know", Group & Page suggestions<br>Remove Reels carousel & Threads promo<br><b>Confirm before liking</b> (prevents accidental likes)</td>
    </tr>
    <tr>
      <td nowrap>🎬 <b>Reels</b></td>
      <td><b>Confirm before liking</b><br>Save <b>Reels</b> to Photos</td>
    </tr>
    <tr>
      <td nowrap>📖 <b>Stories</b></td>
      <td>Watch stories anonymously (Ghost Mode)<br>Disable auto-advance<br>Hide Story Suggestions<br> Save <b>Stories</b> (video & photo) to Photos</td>
    </tr>
    <tr>
      <td nowrap>🧭 <b>Links</b></td>
      <td>Open external links in your <b>default browser</b> instead of the in-app browser<br><b>Open in Facebook</b> Safari extension — reopens facebook.com links from Safari in the app</td>
    </tr>
    <tr>
      <td nowrap>🎨 <b>Appearance</b></td>
      <td><b>OLED Dark Mode</b> (True black)<br>Custom App-Icon Picker</td>
    </tr>
    <tr>
      <td nowrap>🔔 <b>Updates</b></td>
      <td>Built-in <b>update checker</b> — notified in-app when a new version ships, with the changelog and one-tap download from GitHub or Telegram<br>Manual re-check from <b>Settings → Check for Update</b></td>
    </tr>
  </tbody>
</table>

💡 **Settings:** Long-press any **tab bar item** (classic or the new iOS 26 liquid-glass bar) or the **native Facebook settings button**.

---

## 🗺️ Roadmap

Planned features and fixes for upcoming releases. Contributions and suggestions
are welcome — open an issue or a pull request.

**Feed & Content**
- [ ] Hide the **Reels overlay** (comment/like/share controls layered over Reels)
- [ ] Hide **Stories** row from the main feed
- [ ] Hide **ads on Facebook Marketplace**

**Downloads**
- [ ] **Multiple-quality** download picker for Reels & videos (choose resolution before saving)

**Appearance**
- [ ] Enhance **OLED Mode** — restore the missing **post divider** (separators not shown between posts in OLED mode)
- [ ] Fix the **unwanted box** rendered beside the app-icon image

**Navigation**
- [ ] Remove the **"Also from Meta"** section from the left sidebar

> [!NOTE]
> This list tracks intended work; items are unchecked until shipped in a release.

---

## 🚀 Installation

Download the pre-built `.ipa` file from the **[Releases](../../releases)** section and install it on your device using **Feather**, **Ksing**, or any other sideloading tool of your choice.

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
     `.ipa` to a file host (e.g. [filebin.net](https://filebin.net),
     [filemail.com](https://filemail.com), or Dropbox) and paste the
     **direct download link**. A link to a *web page* instead of the file itself
     will fail validation.
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
     - fakesigns every injected binary for sideloading.


<details>
<summary><b>Code Editor Setup</b></summary>

Theos does not emit a compilation database by default, causing editors to fail at finding the iOS SDK. You can generate one using [`bear`](https://github.com/rizsotto/Bear):

```bash
make compile-commands
```

This generates `compile_commands.json`. Re-run this after adding new source files. Note: Logos `.xm` files cannot be fully parsed by clang, so `.clangd` suppresses false diagnostics while ensuring they compile correctly.

</details>

---

## 🏗️ Project Architecture

```text
├── Localizations       # Translations (ar, bn, de, es, fr, hi, id, it, ja, ko, etc.)
├── OpenInFacebookSafariExtension  # Safari web extension built into PlugIns ("Open in Facebook")
├── resources           # Assets (App icons, SVGs, and asset bundles)
│   ├── bundle          # Compiled UI images and tweak resources
│   ├── logo            # Custom app-icons drop folder for build.sh injection
│   └── svg             # Source vector graphics
├── scripts             # Python utility scripts (e.g., icon merging, svg rendering)
├── src                 # Tweak source code
│   ├── Core            # Constructor, preferences, resources, and diagnostics
│   ├── Features        # All the hooks for modifying the Facebook app:
│   │   ├── AppChrome   # UI settings gesture (TabBar & Settings Button)
│   │   ├── AppIcons    # Custom app-icon picker logic
│   │   ├── Diagnostics # Diagnostics and logging controllers
│   │   ├── Downloads   # Reel & Story media downloaders (save to Photos)
│   │   ├── Feed        # Feed-related hooks (ads, suggestions, Reels)
│   │   ├── Language    # UI language override hooks
│   │   ├── LikeConfirmation # Confirm before liking logic
│   │   ├── Links       # Open external links in the default browser (not the IAB)
│   │   ├── Menu        # Diagnostics for blocking server-driven menu sections
│   │   ├── OLED        # True dark mode implementation
│   │   ├── Onboarding  # Welcome screen controller
│   │   ├── Stories     # Story-related hooks (Ghost mode, auto-advance block)
│   │   └── Update      # In-app update checker + update screen (GitHub Releases)
│   ├── PluginsInject   # Sideload compatibility layer (Keychain / App-Group / CloudKit)
│   ├── Settings        # The Facebook Plus in-app settings UI
│   └── UI              # Shared UI components
│       ├── Sheet       # Bottom sheet controllers
│       └── Toast       # HUD / Progress pills
└── test                # Input IPA directory and test scripts
```

**Resilient Hooking:** Each hook dynamically verifies that its target class and selector exist before installation. If a Facebook update changes a specific class, only that single feature degrades safely without crashing the entire tweak. The settings gesture, for example, hooks both the classic tab bar and the new iOS 26 liquid-glass bars so long-press keeps working across iOS versions.

## 📜 Provenance & Credits

- **Idea & Inspiration:** The core concept of this tweak was inspired by the closed-source Facebook tweak **[Glow](https://github.com/dayanch96/Glow)**. This project is a clean reimplementation based on its behavioral analysis.
- **Story & Reels Downloader:** The media download feature (`src/Features/Downloads/`) was contributed by **[ttlongdl](https://github.com/ttlongdl/Facebook-Plus)** via their GPLv3 fork, and is integrated here with attribution as required by the license.
- **"Open in Facebook" Safari Extension:** The bundled Safari web extension (`OpenInFacebookSafariExtension/`, built from source into the IPA) is our own, independently written implementation — its own `NSExtension` host, manifest and link-routing scripts, with no third-party binary or source bundled. See `OpenInFacebookSafariExtension/README.md` for details.
- **Compatibility Layer:** The sideloading compatibility layer (`src/PluginsInject/`) is copied and derived directly from **[zxPluginsInject](https://github.com/asdfzxcvbn/zxPluginsInject)**.
- **Symbol Rebinding:** Uses **[fishhook](https://github.com/facebook/fishhook)** for dynamic symbol rebinding.

## ⚖️ License

This project is open-source and distributed under the terms of the **[GNU General Public License v3.0 (GPL-3.0)](LICENSE)**.
Please refer to the `LICENSE` file for more details.

---
<p align="center">
  <b>Copyright &copy; 2026 S. SHAJON</b>
</p>
