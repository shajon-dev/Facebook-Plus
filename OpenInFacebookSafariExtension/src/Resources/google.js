// "Open in Facebook" — Google results helper.
//
// On google.com, a tapped Facebook result often lands on a bare story.php page
// that no longer identifies its post. Catch the click here, unwrap Google's
// /url?q= redirect, and carry the clean Facebook URL over in the fragment so the
// facebook.com content script can hand it to the app.

(() => {
  "use strict";

  const FB_HOSTS = ["facebook.com", "fb.com", "fb.watch", "fb.me", "fb.gg"];

  function isFacebookHost(host) {
    host = host.toLowerCase();
    return FB_HOSTS.some(h => host === h || host.endsWith("." + h));
  }

  function facebookURL(value) {
    if (!value) return null;
    let candidate;
    try {
      candidate = new URL(value, window.location.href);
    } catch {
      return null;
    }

    // Unwrap Google's redirector: https://www.google.com/url?q=<real url>
    if (candidate.hostname.toLowerCase().endsWith("google.com") &&
        candidate.pathname === "/url") {
      const wrapped = candidate.searchParams.get("q") ||
                      candidate.searchParams.get("url");
      if (!wrapped) return null;
      try {
        candidate = new URL(wrapped);
      } catch {
        return null;
      }
    }

    return isFacebookHost(candidate.hostname) ? candidate : null;
  }

  document.addEventListener("click", event => {
    if (event.defaultPrevented || event.button !== 0) return;

    const path = event.composedPath?.() || [event.target];
    let destination = null;
    for (const node of path) {
      if (!(node instanceof Element)) continue;
      const values = [
        node instanceof HTMLAnchorElement ? node.href : null,
        node.getAttribute("data-href"),
        node.getAttribute("data-url")
      ];
      destination = values.map(facebookURL).find(Boolean) || null;
      if (destination) break;
    }
    if (!destination) return;

    event.preventDefault();
    event.stopImmediatePropagation();

    // Preserve the clean destination for facebook.com's content script.
    destination.hash = `open-in-facebook=${encodeURIComponent(destination.href)}`;
    window.location.assign(destination.href);
  }, true);
})();
