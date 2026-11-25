// Hide the near-empty "Recommended" mid-card interstitial between reels.
//
// The card is a Shorts feed unit injected by several fetch-response managers,
// so no-oping one of those would break the Reels fetch itself. The chokepoint
// is the gate read before the card is requested: the Swift FBRADLConfigHelper
// answers the two +isTYAMidcard… gates, and NO is a path Facebook already
// takes when its server flag is off.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPHeaders.h"
#import "FBPTrace.h"

#import <objc/runtime.h>

#pragma mark - Recommended mid-card gate

%group FBPReelsMidCardGate

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
    // Class methods, so the metaclass must respond; inert if a gate is renamed.
    Class config = objc_getClass("_TtC18FBRADLConfigHelper18FBRADLConfigHelper");
    if (config &&
        [config respondsToSelector:@selector(isTYAMidcardEnabled:)] &&
        [config respondsToSelector:@selector(isTYAMidcardSeeMyAlgorithmButtonEnabled:)]) {
        FBP_ONCE(gReelsMidCardGate) { %init(FBPReelsMidCardGate); }
    } else {
        FBPLogOnce(@"FBRADLConfigHelper TYA mid-card gates not found — "
               @"Reels recommended-card hiding inactive");
    }
}
