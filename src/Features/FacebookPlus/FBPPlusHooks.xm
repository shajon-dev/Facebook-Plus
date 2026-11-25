// Preview the paid Facebook Plus subscriber features in the UI.
//
// Most perks funnel through one Swift benefit checker,
// FBSubsBenefitStatusChecker, whose -isBenefitActive: answers every "is this
// perk unlocked?" question. Forcing it to YES unlocks the *client* gate only;
// the servers still validate on use, and acting on such a perk can flag the
// account, so the settings toggle confirms before switching on. Three gates do
// NOT consult the checker and are hooked separately below: the story
// super-reaction controller, the composer's reveal gate, the story-extend
// helper.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPTrace.h"

#import <objc/runtime.h>

/// Cached, refreshed on the settings-changed notification: the checker fires
/// constantly during layout and must not touch NSUserDefaults.
static BOOL gPlusEnabled = NO;
static BOOL gPlusTrial   = NO;   // unlock mode: NO = "direct" (force gates), YES = "trial"

static void FBPRefreshPlus(void) {
    gPlusEnabled = FBPEnabled(FBPKeyMetaPlus);
    gPlusTrial   = [[FBPPrefs.shared stringForKey:FBPKeyMetaPlusMode] isEqualToString:@"trial"];
}

// Swift class, so it is hooked under a placeholder bound in %init below.
%group FBPMetaPlus

%hook FBPSubsBenefitStatusChecker

- (BOOL)isBenefitActiveWithBenefitType:(NSInteger)benefitType {
    if (gPlusEnabled) return YES;
    return %orig;
}

- (BOOL)isBenefitActive:(NSInteger)benefitType {
    if (gPlusEnabled) return YES;
    return %orig;
}

%end

%end // FBPMetaPlus

#pragma mark - Story super-reaction (diamond / heart) access gate

// The story diamond / heart reaction has its own server-backed entitlement
// object rather than the benefit checker, which is why forcing the checker
// alone never revealed it. Plain ObjC, hooked by name.
%group FBPSuperReaction

%hook FBSnacksSuperReactionFeatureAccessController

- (BOOL)hasFeatureAccess {
    if (gPlusEnabled) return YES;
    return %orig;
}

// NO, or the reaction becomes a "start free trial" upsell card.
- (BOOL)isTrialOfferEligible {
    if (gPlusEnabled) return NO;
    return %orig;
}

// TRIAL mode: OR'd into -hasFeatureAccess at every branch, so forcing it
// reveals the reaction through the app's own mid-trial path.
- (BOOL)_hasValidConfirmedTrialAccess {
    if (gPlusEnabled && gPlusTrial) return YES;
    return %orig;
}

%end

%end // FBPSuperReaction

#pragma mark - Story super-reaction reveal gate (DIRECT mode)

// The master reveal gate: benefitActive OR ((hasFeatureAccess OR
// bucketPreview) AND gatekeeper), where the gatekeeper is a MobileConfig flag
// that can be OFF, so forcing hasFeatureAccess alone is not enough. DIRECT
// mode forces this; TRIAL mode drives the controller's trial state instead.
%group FBPSuperReactionReveal

%hook FBSnacksComposerController

- (BOOL)_isSuperReactionAvailableForCurrentThreadWithBucketPreview:(id)preview {
    if (gPlusEnabled && !gPlusTrial) return YES;
    return %orig;
}

%end

%end // FBPSuperReactionReveal

#pragma mark - Story super-reaction teaser (DIRECT mode)

%group FBPSuperReactionTeaser

%hook FBSnacksSuperReactionTeaserState

- (BOOL)shouldRevealSuperReaction {
    if (gPlusEnabled && !gPlusTrial) return YES;
    return %orig;
}

%end

%end // FBPSuperReactionTeaser

#pragma mark - Story extend / viewer-sheet diamond

// Story-viewer-sheet diamond and story extend, which also bypass the benefit
// checker. Class methods, and the placeholder binds in %init below.
%group FBPStoryExtend

%hook FBPStoryExtendHelper

+ (BOOL)isBenefitActiveWithSession:(id)session {
    if (gPlusEnabled) return YES;
    return %orig;
}

// Keep it client-side, or a server "no" overrides the forced YES above.
+ (BOOL)useServerDiamondEligibilityWithSession:(id)session {
    if (gPlusEnabled) return NO;
    return %orig;
}

+ (BOOL)isUpsellEnabledWithSession:(id)session isServerEligible:(BOOL)eligible {
    if (gPlusEnabled) return NO;
    return %orig;
}

%end

%end // FBPStoryExtend

void FBPInitPlusHooks(void) {
    FBPRefreshPlus();

    [NSNotificationCenter.defaultCenter
        addObserverForName:FBPSettingsDidChangeNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) { FBPRefreshPlus(); }];

    // Mangled Swift name, then the demangled form, then a plain ObjC class.
    Class checker =
        NSClassFromString(@"_TtC26FBSubsBenefitStatusChecker26FBSubsBenefitStatusChecker")
        ?: NSClassFromString(@"FBSubsBenefitStatusChecker.FBSubsBenefitStatusChecker")
        ?: objc_getClass("FBSubsBenefitStatusChecker");

    // Guard on -isBenefitActive:, not -isBenefitActiveWithBenefitType:: the
    // latter is a protocol witness that tail-calls it and is not a direct
    // instance method, so guarding on it installs nothing at all.
    if (checker &&
        [checker instancesRespondToSelector:@selector(isBenefitActive:)]) {
        FBP_ONCE(gMetaPlus) { %init(FBPMetaPlus, FBPSubsBenefitStatusChecker = checker); }
        // Every gate here installs whatever the preference says, because the
        // preference is live and must take effect without a relaunch; each one
        // consults gPlusEnabled when it fires.
        FBPLogOnce(@"plus: subscription benefit gate installed on %@ (toggle=%d)",
                   NSStringFromClass(checker), gPlusEnabled);
    } else {
        FBPLogOnce(@"plus: FBSubsBenefitStatusChecker not found — "
               @"subscription unlock inactive");
    }

    Class superReaction = objc_getClass("FBSnacksSuperReactionFeatureAccessController");
    if (superReaction &&
        [superReaction instancesRespondToSelector:@selector(hasFeatureAccess)]) {
        FBP_ONCE(gSuperReaction) { %init(FBPSuperReaction); }
        FBPLogOnce(@"plus: story super-reaction access gate installed (toggle=%d)", gPlusEnabled);
    } else {
        FBPLogOnce(@"plus: FBSnacksSuperReactionFeatureAccessController not found");
    }

    Class composer = objc_getClass("FBSnacksComposerController");
    if (composer && [composer instancesRespondToSelector:
            @selector(_isSuperReactionAvailableForCurrentThreadWithBucketPreview:)]) {
        FBP_ONCE(gSRReveal) { %init(FBPSuperReactionReveal); }
        FBPLogOnce(@"plus: super-reaction reveal gate installed (toggle=%d)", gPlusEnabled);
    } else {
        FBPLogOnce(@"plus: FBSnacksComposerController reveal gate not found");
    }

    Class teaser = objc_getClass("FBSnacksSuperReactionTeaserState");
    if (teaser && [teaser instancesRespondToSelector:@selector(shouldRevealSuperReaction)]) {
        FBP_ONCE(gSRTeaser) { %init(FBPSuperReactionTeaser); }
    }

    Class storyExtend =
        NSClassFromString(@"_TtC19FBStoryExtendHelper19FBStoryExtendHelper")
        ?: NSClassFromString(@"FBStoryExtendHelper.FBStoryExtendHelper")
        ?: objc_getClass("FBStoryExtendHelper");
    if (storyExtend &&
        [storyExtend respondsToSelector:@selector(isBenefitActiveWithSession:)]) {
        FBP_ONCE(gStoryExtend) { %init(FBPStoryExtend, FBPStoryExtendHelper = storyExtend); }
        FBPLogOnce(@"plus: story-extend diamond gate installed on %@ (toggle=%d)",
                   NSStringFromClass(storyExtend), gPlusEnabled);
    } else {
        FBPLogOnce(@"plus: FBStoryExtendHelper not found");
    }
}
