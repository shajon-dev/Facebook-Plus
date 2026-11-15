# 📜 Third-Party Notices

Provenance and attributions for third-party ideas, code, and binaries used in
Facebook Plus. Planned work lives separately in **[TODO.md](TODO.md)**.

- **Story & Reels Downloader:** Versions **v1.0 – v1.0.4** used the media download system from **[ttlongdl](https://github.com/ttlongdl/Facebook-Plus)**'s GPLv3 fork (enhanced by **@SHAJON-404**), attributed as the license requires. From **v1.0.5** onward the download system (`src/Features/Downloads/`) is an entirely new implementation, written from scratch A-to-Z by **@SHAJON-404** (backup **@shajon-dev**), carrying over no third-party code.
- **"Open in Facebook" Safari Extension:** The bundled Safari web extension (`OpenInFacebookSafariExtension/`, built from source into the IPA) is our own, independently written implementation — its own `NSExtension` host, manifest and link-routing scripts, with no third-party binary or source bundled. See `OpenInFacebookSafariExtension/README.md` for details.
- **Marketplace Ad Removal:** The idea of removing Facebook Marketplace ads at the React Native / GraphQL layer, and the core of that logic in `src/Features/Ads/FBPAdsHooks.xm` — intercepting `-[RCTNetworking handlerForRequest:]` to fail dedicated ad queries and to buffer-and-filter blended ad stories out of feed/search responses — are adapted from **[MarketplaceAdBlock](https://github.com/adamsardo/MarketplaceAdBlock)** by adamsardo, restyled into this tweak's conventions and gated behind the existing **Remove Ads** toggle.
- **Compatibility Layer:** The sideloading compatibility layer (`src/PluginsInject/`) is copied and derived directly from **[zxPluginsInject](https://github.com/asdfzxcvbn/zxPluginsInject)**.
- **Keychain Session Patch:** The prebuilt keychain access-group patch injected into the sideloaded IPA (`vendor/blatantsPatch/blatantsPatch.dylib`), which keeps a re-signed login from being dropped after a few hours, is the work of **blatants** — Telegram channel **[t.me/blatants](https://t.me/blatants)**. It is bundled as-is (no source available) and credited to its owner.
- **Symbol Rebinding:** Uses **[fishhook](https://github.com/facebook/fishhook)** for dynamic symbol rebinding.

This project is distributed under the **[GNU General Public License v3.0](LICENSE)**; see the `LICENSE` file for details.
