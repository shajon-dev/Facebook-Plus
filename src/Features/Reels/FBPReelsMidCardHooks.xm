// Hide the "Recommended" (おすすめ) mid-card interstitial in Reels (https://github.com/shajon-dev/Facebook-Plus/issues/1).
//
// Facebook interleaves a full-screen "mid-card" between reels. One of them is the
// algorithm-transparency / recommended card — a page that shows only a title
// ("Recommended" / おすすめ) with a "See my algorithm" button. A user who has
// suppressed survey cards is left looking at that near-empty page until they
// swipe past it.
//
// WHERE THIS HOOKS, AND WHY HERE
// ------------------------------------------------------------------------
// Read out of the Objective-C / Swift metadata of Facebook 587 (FBSharedFramework),
// not guessed. The mid-card is a Shorts feed unit (FBMemFBShortsMidCardFeedUnit)
// carrying a FBShortsMidCardRecommendationContext, injected as an edge into the
// Reels paginable list by one of several managers (FBShortsInVideoHomeCSR…,
// …AdsMidCardSurvey…, …AEMidcard…). None of those is a clean "build this card"
// chokepoint — they each process a whole fetch response, so no-oping one would
// break the Reels fetch itself.
//
// The clean chokepoint is the feature gate the app reads before the card is ever
// requested: FBRADLConfigHelper (a Swift class, runtime name
// _TtC18FBRADLConfigHelper18FBRADLConfigHelper) answers
// +isTYAMidcardEnabled: and +isTYAMidcardSeeMyAlgorithmButtonEnabled:
// ("TYA" = the transparency / "see my algorithm" card). Answering NO is a path
// Facebook's own code already takes when the mobileconfig flag is off, so the
// card is simply never built — no empty shell, no reserved slot, no layout gap,
// and the next reel plays straight through.
//
// FALLBACK / SAFETY
// ------------------------------------------------------------------------
// This can only ever make a gate return NO — a value the app is built to handle —
// so it cannot crash the host whatever happens. The group installs only when the
// class and both class methods are actually present, so a future Facebook build
// that renames or drops either one leaves the feature quietly inert (logged)
// rather than taking Reels, or the tweak, down. If a later build moves the
// recommended card off this gate, the toggle simply stops hiding it until the new
// chokepoint is taught here — never a failure the user sees as a crash.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPHeaders.h"
#import "FBPTrace.h"

#import <objc/runtime.h>

#pragma mark - Recommended mid-card gate

%group FBPReelsMidCardGate

// Logos runs before the C preprocessor, so the mangled Swift runtime name is
// spelled out here rather than hidden behind a #define — the same arrangement
// FBPReelsSurveyHooks uses for FBShortsInlineSurveyHelper.
%hook _TtC18FBRADLConfigHelper18FBRADLConfigHelper

+ (BOOL)isTYAMidcardEnabled:(id)arg1 {
    FBPTraceFire("reels.FBRADLConfigHelper.isTYAMidcardEnabled");
    if (FBPEnabled(FBPKeyNoReelsRecommended)) return NO;
    return %orig;
}

+ (BOOL)isTYAMidcardSeeMyAlgorithmButtonEnabled:(id)arg1 {
    FBPTraceFire("reels.FBRADLConfigHelper.isTYAMidcardSeeMyAlgorithmButtonEnabled");
    if (FBPEnabled(FBPKeyNoReelsRecommended)) return NO;
    return %orig;
}

%end

%end // FBPReelsMidCardGate

#pragma mark - Init

void FBPInitReelsMidCardHooks(void) {
    // Class methods, so the metaclass is what has to respond. Installs only when
    // the class and both gates exist; otherwise it logs and stays inert, so a
    // renamed gate is a no-op, never a crash.
    Class config = objc_getClass("_TtC18FBRADLConfigHelper18FBRADLConfigHelper");
    if (config &&
        [config respondsToSelector:@selector(isTYAMidcardEnabled:)] &&
        [config respondsToSelector:@selector(isTYAMidcardSeeMyAlgorithmButtonEnabled:)]) {
        FBP_ONCE(gReelsMidCardGate) { %init(FBPReelsMidCardGate); }
    } else {
        FBPLog(@"FBRADLConfigHelper TYA mid-card gates not found — "
               @"Reels recommended-card hiding inactive");
    }
}
