// Survey-prompt suppression for the Reels surfaces.
//
// Facebook's inline survey card ("Are you interested in this Reel?", with
// "Interested" / "Not interested" buttons) reaches the Reels tab and the
// full-screen Reels viewer through a single class — the surfaces look separate
// but share one injection manager:
//
//   * FBShortsInlineSurveyInjectionManager (FBSharedFramework / FBShortsKit)
//     builds the survey components and splices them into the section being
//     assembled. -maybeAddInlineSurveyComponents: is the injection entry point,
//     so returning before %orig means the component is never constructed and no
//     empty cell or layout gap is left behind.
//   * FBShortsInlineSurveyHelper gates whether the survey is loaded at all. It
//     is a Swift class, so its Objective-C runtime name is the mangled
//     _TtC27FBShortsInlineSurveyHelpers26FBShortsInlineSurveyHelper, and its two
//     gates are class methods. Answering NO stops the survey being fetched in
//     the first place, which is cheaper than dropping it at injection time; the
//     injection hook above stays as the backstop.
//
// Signatures were read out of the Objective-C metadata of Facebook
// 585.0.0.64.71, not guessed: -maybeAddInlineSurveyComponents: is
// `v24@0:8@16` (void, one object), and both gates are `B24@0:8@16`
// (BOOL, one object). Each group still installs only when its class and
// selector are actually present, so a rename degrades that one surface instead
// of taking the tweak down.
//
// The standalone survey *feed units* are dropped at the feed-model chokepoint
// instead (see FBPFeedHooks.xm) — they never reach this manager.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPHeaders.h"

#import <objc/runtime.h>

#pragma mark - Injection point

%group FBPReelsSurveyInjection

%hook FBShortsInlineSurveyInjectionManager

- (void)maybeAddInlineSurveyComponents:(id)arg1 {
    if (FBPEnabled(FBPKeyNoSurveys)) return;
    %orig;
}

%end

%end // FBPReelsSurveyInjection

#pragma mark - Load gates

%group FBPReelsSurveyGates

// Logos runs before the C preprocessor, so the mangled Swift name has to be
// spelled out here rather than hidden behind a #define.
%hook _TtC27FBShortsInlineSurveyHelpers26FBShortsInlineSurveyHelper

+ (BOOL)inlineSurveyLoadInjectionManagerEnabledWithSession:(id)session {
    if (FBPEnabled(FBPKeyNoSurveys)) return NO;
    return %orig;
}

+ (BOOL)inlineSurveyLoadEnabledWithSession:(id)session {
    if (FBPEnabled(FBPKeyNoSurveys)) return NO;
    return %orig;
}

%end

%end // FBPReelsSurveyGates

#pragma mark - Init

void FBPInitReelsSurveyHooks(void) {
    // FBShortsKit arrives with a lazily dlopen'd framework, so this installer is
    // re-run from the dyld image-load callback until the classes show up; each
    // group latches with FBP_ONCE so it still installs exactly once.
    Class manager = objc_getClass("FBShortsInlineSurveyInjectionManager");
    if (manager &&
        [manager instancesRespondToSelector:@selector(maybeAddInlineSurveyComponents:)]) {
        FBP_ONCE(gReelsSurveyInjection) { %init(FBPReelsSurveyInjection); }
    }

    // Class methods, so the metaclass is what has to respond.
    Class helper = objc_getClass("_TtC27FBShortsInlineSurveyHelpers26FBShortsInlineSurveyHelper");
    if (helper &&
        [helper respondsToSelector:@selector(inlineSurveyLoadEnabledWithSession:)] &&
        [helper respondsToSelector:@selector(inlineSurveyLoadInjectionManagerEnabledWithSession:)]) {
        FBP_ONCE(gReelsSurveyGates) { %init(FBPReelsSurveyGates); }
    }
}
