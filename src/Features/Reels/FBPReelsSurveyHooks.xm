// Survey-prompt suppression for Reels. The tab and the full-screen viewer share
// one injection manager, so two classes cover both: returning early from
// FBShortsInlineSurveyInjectionManager's -maybeAddInlineSurveyComponents:
// leaves no empty cell, and the Swift FBShortsInlineSurveyHelper's class-method
// gates stop the survey loading at all. Each group installs only when its class
// and selector exist, so a rename degrades one surface rather than the tweak.
// Standalone survey feed units never reach this manager; they are dropped at
// the feed-model chokepoint in FBPFeedHooks.xm.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPHeaders.h"
#import "FBPTrace.h"

#import <objc/runtime.h>

#pragma mark - Injection point

%group FBPReelsSurveyInjection

%hook FBShortsInlineSurveyInjectionManager

- (void)maybeAddInlineSurveyComponents:(id)arg1 {
    FBPTraceFire("reels.FBShortsInlineSurveyInjectionManager.maybeAddInlineSurveyComponents");
    if (FBPEnabled(FBPKeyNoSurveys)) return;
    %orig;
}

%end

%end // FBPReelsSurveyInjection

#pragma mark - Load gates

%group FBPReelsSurveyGates

%hook _TtC27FBShortsInlineSurveyHelpers26FBShortsInlineSurveyHelper

+ (BOOL)inlineSurveyLoadInjectionManagerEnabledWithSession:(id)session {
    FBPTraceFire("reels.FBShortsInlineSurveyHelper.inlineSurveyLoadInjectionManagerEnabled");
    if (FBPEnabled(FBPKeyNoSurveys)) return NO;
    return %orig;
}

+ (BOOL)inlineSurveyLoadEnabledWithSession:(id)session {
    FBPTraceFire("reels.FBShortsInlineSurveyHelper.inlineSurveyLoadEnabled");
    if (FBPEnabled(FBPKeyNoSurveys)) return NO;
    return %orig;
}

%end

%end // FBPReelsSurveyGates

#pragma mark - Init

void FBPInitReelsSurveyHooks(void) {
    // FBShortsKit is lazily dlopen'd, so this is re-run from the dyld
    // image-load callback until the classes appear; FBP_ONCE keeps it to one.
    Class manager = objc_getClass("FBShortsInlineSurveyInjectionManager");
    if (manager &&
        [manager instancesRespondToSelector:@selector(maybeAddInlineSurveyComponents:)]) {
        FBP_ONCE(gReelsSurveyInjection) { %init(FBPReelsSurveyInjection); }
    }

    // Class methods, so the metaclass must respond.
    Class helper = objc_getClass("_TtC27FBShortsInlineSurveyHelpers26FBShortsInlineSurveyHelper");
    if (helper &&
        [helper respondsToSelector:@selector(inlineSurveyLoadEnabledWithSession:)] &&
        [helper respondsToSelector:@selector(inlineSurveyLoadInjectionManagerEnabledWithSession:)]) {
        FBP_ONCE(gReelsSurveyGates) { %init(FBPReelsSurveyGates); }
    }
}
