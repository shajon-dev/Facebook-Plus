# Safari Web Extensions

Each subdirectory here is a theos project that builds a Safari web extension
(`.appex`). `build.sh` builds every `OpenInFacebookSafariExtension/*/Makefile`, then injects the
resulting bundle into the app's `PlugIns/` (via `cyan -f`) and fakesigns it, so
the extension ships inside the produced IPA. Nothing prebuilt is committed — the
`.appex` is compiled from source on each build.

## src — "Open in Facebook"

A Safari web extension that reopens `facebook.com` (and `fb.com`, `fb.watch`,
`fb.me`, `fb.gg`) links from Safari in the sideloaded Facebook app through its
`fb://` URL scheme, so links don't get stranded on the web when universal links
are unavailable to a sideloaded build. It also rewrites Facebook links in Google
search results so they route straight into the app.

- Bundle id: `com.facebook.Facebook.OpenInFacebookSafariExtension`
- Principal class: `FBPSafariWebExtensionHandler` (our own minimal
  `NSExtensionRequestHandling` host — all routing is done in JavaScript)
- After installing, enable it in **Settings → Safari → Extensions → Open in
  Facebook** and set it to **Allow**.

### Layout

```
src/
  Makefile                       # theos appex target (APPEX_NAME)
  SafariWebExtensionHandler.h/.m # native host
  Resources/                     # copied to the .appex root by theos
    Info.plist                   # NSExtension (com.apple.Safari.web-extension)
    manifest.json
    content.js                   # facebook.com → fb:// routing
    google.js                    # unwrap Google result links → fb://
    background.js
    popup.html / popup.css
    _locales/en/messages.json
    images/                      # icons generated from resources/logo.png
```

