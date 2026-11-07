// Single constructor. Each hook group installs itself only after checking that
// its target class and selector actually exist in this build of Facebook, so a
// missing target degrades that one feature instead of taking the tweak down.

#import "FBPlus.h"
#import "FBPPrefs.h"

#import <mach-o/dyld.h>

extern void FBPInitFeedHooks(void);
extern void FBPInitFeedSurveyHooks(void);
extern void FBPInitAdsHooks(void);
extern void FBPInitReelsSurveyHooks(void);
extern void FBPInitStoryHooks(void);
extern void FBPInitConfirmHooks(void);
extern void FBPInitActionConfirm(void);
extern void FBPInitChromeHooks(void);
extern void FBPInitOLEDHooks(void);
extern void FBPInitFontHooks(void);
extern void FBPInitReelsDownloader(void);
extern void FBPInitLinkHooks(void);
extern void FBPInitLinkBridge(void);
extern void FBPInitCallBlocker(void);

/// Not a hook installer: it settles, off the main thread, whether this device
/// can decode AV1 — which decides whether the download picker may offer AV1
/// quality rungs at all. Declared here rather than by importing
/// FBPMediaConverter.h, which would pull AVFoundation and VideoToolbox into this
/// constructor for one call. Asked for now because the first caller would
/// otherwise be the DASH reader on the main thread during a download tap, and
/// the answer costs ~46 ms to work out once.
///
/// `extern "C"` unlike the installers above, and that difference is the point:
/// logos compiles this file as Objective-C++, so a bare `extern` would look for
/// a C++-mangled symbol. The installers get away with it because every one of
/// them is defined in another .xm and so is mangled the same way; this one lives
/// in a plain .m and is not.
extern "C" void FBPMediaConversionPrewarm(void);

/// Runs every installer. Each group latches itself with FBP_ONCE, so calling
/// this repeatedly installs each hook exactly once.
static void FBPInstallHooks(void) {
    FBPInitFeedHooks();
    FBPInitFeedSurveyHooks();
    FBPInitAdsHooks();
    FBPInitReelsSurveyHooks();
    FBPInitStoryHooks();
    FBPInitConfirmHooks();
    FBPInitActionConfirm();
    FBPInitChromeHooks();
    FBPInitOLEDHooks();
    FBPInitFontHooks();
    FBPInitReelsDownloader();
    FBPInitLinkHooks();
    FBPInitLinkBridge();
    FBPInitCallBlocker();
}

/// dyld calls this for every image already loaded, then again for each new one.
///
/// This is why the deferred-install pattern is needed at all: Facebook links only
/// FBSharedFramework at launch and dlopens the rest on demand, so a one-shot %ctor
/// observes only a fraction of the app's classes.
static void FBPImageDidLoad(const struct mach_header *header, intptr_t slide) {
    FBPInstallHooks();
}

%ctor {
    @autoreleasepool {
        // The tweak is bound to the app it ships in, not to a fixed bundle id:
        // the Filter plist scopes the substrate build to Facebook, and an
        // IPA-embedded build only ever loads inside the app cyan injected it into.
        // We therefore do not hardcode a bundle id here — that lets a re-signed
        // IPA use a custom identifier (to run alongside the stock app) and still
        // activate.

        // Registers defaults before any hook can read a preference.
        (void)FBPPrefs.shared;

        // Installs what is available now, and again as each framework arrives.
        FBPInstallHooks();
        _dyld_register_func_for_add_image(&FBPImageDidLoad);

        // Returns immediately; the work happens on a utility queue. Outside
        // FBPInstallHooks because it is not a hook and must not be repeated for
        // every image dyld reports.
        FBPMediaConversionPrewarm();

        // Inlined (not a local) so the release build, where FBPLog is a no-op,
        // does not trip -Werror=unused-variable.
        FBPLog(@"loaded into %@", NSBundle.mainBundle.bundleIdentifier);
    }
}
