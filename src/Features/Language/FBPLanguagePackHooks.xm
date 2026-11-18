// Make Facebook's own UI language work on a re-signed / sideloaded build.
//
// Facebook resolves its interface strings from a DOWNLOADED language pack
// whenever FBCoreLocaleIsDownloadableLanguagePackEnabled() is true (its default).
// On a sideloaded build that download never completes, and the resolver has no
// fall-through to the bundled pack — so the app shows a full-screen
// "<language> wasn't downloaded — try clearing space" wall and no language ever
// loads (only the "Use Facebook in English" escape works).
//
// But the app already ships every bundled locale — en-GB included — inside
// languages.lgpk, and carries a complete offline reader (FBBundledLanguagePackLoader
// via FBLanguagePackArchive) that the resolver uses whenever that gate is OFF.
// So force the gate off: every string then resolves from the bundle, with no
// network, and the download wall is never reached. The strings are the app's own
// shipped translations, so this only changes WHERE they come from, not what they
// say (a string present only in a newer downloaded pack falls back to English,
// exactly as it would before the pack downloaded).
//
// The gate is a plain C function in FBSharedFramework, called intra-framework by
// a direct branch, so a symbol rebind (fishhook, as used elsewhere) would miss
// its internal callers. It is patched at the prologue with MSHookFunction, which
// catches every caller. A second, defensive hook stops the startup loader state
// from stalling until its timeout waiting for a download that will never arrive.

#import "FBPlus.h"
#import "FBPPrefs.h"

#import <substrate.h>
#import <dlfcn.h>
#import <objc/runtime.h>

/// The downloadable-pack gate. Forcing NO routes all string resolution through
/// the bundled languages.lgpk. Returns a value the app already produces whenever
/// downloadable packs are gated off, so the bundled branch is a first-class path.
static BOOL fbp_IsDownloadableLanguagePackEnabled(void) {
    return NO;
}

#pragma mark - Startup wait

%group FBPLangPackState

%hook FBLanguagePackLoaderState

// App init blocks here waiting for the download to signal done. With the bundled
// path there is nothing to download, so report done at once instead of stalling
// until LanguagePackWaitTimeOutForLoaderToFinish.
- (BOOL)waitForDone:(double)timeout {
    return YES;
}

%end

%end // FBPLangPackState

#pragma mark - Init

void FBPInitLanguagePackHooks(void) {
    // The C gate lives in FBSharedFramework, which Facebook links at launch.
    // Latched: resolve and patch it once, retried on each image-load pass until
    // the framework is present.
    static BOOL gateHooked = NO;
    if (!gateHooked) {
        void *sym = dlsym(RTLD_DEFAULT, "FBCoreLocaleIsDownloadableLanguagePackEnabled");
        if (sym) {
            MSHookFunction(sym, (void *)fbp_IsDownloadableLanguagePackEnabled, NULL);
            gateHooked = YES;
            FBPLog(@"i18n: forced the bundled language pack (download gate off)");
        }
    }

    // Defensive: never let startup block on a download that will not arrive.
    Class state = objc_getClass("FBLanguagePackLoaderState");
    if (state && [state instancesRespondToSelector:@selector(waitForDone:)]) {
        FBP_ONCE(gLangPackState) { %init(FBPLangPackState); }
    }
}
