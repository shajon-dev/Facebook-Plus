<div align="center">
  <img src="resources/logo.png" width="90" alt="Facebook Plus logo">
  <h1>Facebook Plus</h1>

  <p>
    <strong>The ultimate privacy and enhancement tweak for the Facebook iOS app.</strong><br>
    <em>Quieten your feed, watch stories anonymously, confirm interactions, and customize the app's appearance.</em>
  </p>

  <p>
    <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/License-GPLv3-blue.svg?style=flat-square"></a>
    <img alt="Platform" src="https://img.shields.io/badge/Platform-iOS%2015.1%2B-lightgrey.svg?style=flat-square">
    <img alt="Version" src="https://img.shields.io/badge/Version-1.0.0-success.svg?style=flat-square">
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
      <td>Remove Ads & Sponsored Posts<br>Hide "People you may know" & Group suggestions<br>Remove Reels carousel & Threads promo<br><b>Confirm before liking</b> (prevents accidental likes)</td>
    </tr>
    <tr>
      <td nowrap>🎬 <b>Reels</b></td>
      <td><b>Confirm before liking</b></td>
    </tr>
    <tr>
      <td nowrap>📖 <b>Stories</b></td>
      <td>Watch stories anonymously (Ghost Mode)<br>Disable auto-advance<br>Remove "People you may know"</td>
    </tr>
    <tr>
      <td nowrap>🎨 <b>Appearance</b></td>
      <td><b>OLED Dark Mode</b> (True black)<br>Custom App-Icon Picker (Seamless integration with <code>CFBundleAlternateIcons</code>)</td>
    </tr>
  </tbody>
</table>

💡 **Settings:** Long-press any **tab bar item** or the **native Facebook settings button**.

---

## 🚀 Installation

Download the pre-built `.ipa` file from the **[Releases](../../releases)** section and install it on your device using **Feather**, **Ksing**, or any other sideloading tool of your choice.

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
     `cyan`, merging any custom app icons (`fbplus_*.png` in `resources/logo/`)
     into `CFBundleAlternateIcons` via `scripts/icon_plist.py` — Facebook's native
     icons preserved — and writes `packages/com.facebook.Facebook-injected.ipa`.


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
│   │   ├── Feed        # Feed-related hooks (ads, suggestions, Reels)
│   │   ├── Language    # UI language override hooks
│   │   ├── LikeConfirmation # Confirm before liking logic
│   │   ├── Menu        # Diagnostics for blocking server-driven menu sections
│   │   ├── OLED        # True dark mode implementation
│   │   ├── Onboarding  # Welcome screen controller
│   │   └── Stories     # Story-related hooks (Ghost mode, auto-advance block)
│   ├── PluginsInject   # Sideload compatibility layer (Keychain / App-Group / CloudKit)
│   ├── Settings        # The Facebook Plus in-app settings UI
│   └── UI              # Shared UI components
│       ├── Sheet       # Bottom sheet controllers
│       └── Toast       # HUD / Progress pills
└── test                # Input IPA directory and test scripts
```

**Resilient Hooking:** Each hook dynamically verifies that its target class and selector exist before installation. If a Facebook update changes a specific class, only that single feature degrades safely without crashing the entire tweak.

## 📝 To-Do

- [ ] Add Download Stories and Reels feature

## 📜 Provenance & Credits

- **Idea & Inspiration:** The core concept of this tweak was inspired by the closed-source Facebook tweak **[Glow](https://github.com/dayanch96/Glow)**. This project is a clean reimplementation based on its behavioral analysis.
- **Compatibility Layer:** The sideloading compatibility layer (`src/PluginsInject/`) is copied and derived directly from **[zxPluginsInject](https://github.com/asdfzxcvbn/zxPluginsInject)**.
- **Symbol Rebinding:** Uses **[fishhook](https://github.com/facebook/fishhook)** for dynamic symbol rebinding.

## ⚖️ License

This project is open-source and distributed under the terms of the **[GNU General Public License v3.0 (GPL-3.0)](LICENSE)**.
Please refer to the `LICENSE` file for more details.

---
<p align="center">
  <b>Copyright &copy; 2026 S. SHAJON</b>
</p>
