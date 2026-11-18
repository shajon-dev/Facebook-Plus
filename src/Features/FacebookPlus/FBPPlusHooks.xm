// Meta Facebook Plus: preview the paid subscriber features in the UI without
// subscribing.
//
// Facebook gates its "Facebook Plus" subscriber perks — story previews, story
// extend / rewatch, superlikes, "who viewed my story" search, custom app icons
// and themes, branded threads, and the Meta AI quotas (image generation,
// Imagine video, think-harder) — behind one benefit checker,
// FBSubsBenefitStatusChecker. It is a Swift class living in FBSharedFramework;
// every "is this perk unlocked?" call in the app funnels through its
// -isBenefitActiveWithBenefitType: (Swift `isBenefitActive(benefitType:)`),
// which takes a SUBSXFBNMESubscriptionApplicationBenefitTypeEnum and returns a
// BOOL. Forcing that to YES makes the whole Plus UI appear as though the perk
// were active — a single-gate override.
//
// This only unlocks the *client* gate, so it previews the interface: Facebook's
// servers still validate on use, so anything that round-trips (an actual AI
// generation, a server-persisted benefit) will not be granted by this alone.
// It is off by default and cached on the hot path like the other toggles.
//
// RISK / WHY IT IS A DELIBERATE OPT-IN
// ------------------------------------------------------------------------
// Because this tampers with subscription entitlements, acting on an unlocked
// perk that round-trips to the server — most visibly using a diamond / superlike
// reaction on a story — can flag the account. The settings toggle therefore
// shows a confirmation the first time it is switched on (see
// FBPSettingsController fbpToggleSwitch:); the hook itself stays a pure
// client-side gate override.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPTrace.h"

#import <objc/runtime.h>

/// Cached toggle, refreshed on the settings-changed notification so the checker
/// (called very frequently while laying out feed / stories / profile) never
/// touches NSUserDefaults.
static BOOL gPlusEnabled = NO;
static BOOL gPlusTrial   = NO;   // unlock mode: NO = "direct" (force gates), YES = "trial"

static void FBPRefreshPlus(void) {
    gPlusEnabled = FBPEnabled(FBPKeyMetaPlus);
    gPlusTrial   = [[FBPPrefs.shared stringForKey:FBPKeyMetaPlusMode] isEqualToString:@"trial"];
}

// FBSubsBenefitStatusChecker is a Swift class, so it is hooked under a
// placeholder name that is bound to the resolved runtime class in %init below.
%group FBPMetaPlus

%hook FBPSubsBenefitStatusChecker

// The one gate every Plus feature consults. The argument is the benefit-type
// enum (an NSInteger under the hood); every type is granted while the toggle is
// on, which is exactly "preview all Facebook Plus features".
- (BOOL)isBenefitActiveWithBenefitType:(NSInteger)benefitType {
    if (gPlusEnabled) return YES;
    return %orig;
}

// A second entry point present on the class in some builds; hooked defensively.
// If a build does not implement it, Logos simply does not install this one.
- (BOOL)isBenefitActive:(NSInteger)benefitType {
    if (gPlusEnabled) return YES;
    return %orig;
}

%end

%end // FBPMetaPlus

#pragma mark - Story super-reaction (diamond / heart) access gate

// The diamond / heart "super reaction" on stories does NOT read
// FBSubsBenefitStatusChecker. It has its own server-backed entitlement object,
// FBSnacksSuperReactionFeatureAccessController, whose -hasFeatureAccess the
// composer / teaser consults before revealing the reaction — which is why
// forcing the benefit checker alone never showed it. Plain ObjC class, hooked
// by name; -hasFeatureAccess returns a BOOL the app already produces for a
// subscriber, so forcing it is crash-safe.
%group FBPSuperReaction

%hook FBSnacksSuperReactionFeatureAccessController

- (BOOL)hasFeatureAccess {
    if (gPlusEnabled) return YES;
    return %orig;
}

// With access granted this is no longer a trial offer; answering NO keeps the
// real reaction from being replaced by a "start free trial" upsell card.
- (BOOL)isTrialOfferEligible {
    if (gPlusEnabled) return NO;
    return %orig;
}

// TRIAL mode: report an active, confirmed trial. This BOOL is OR'd into
// -hasFeatureAccess (the w20 term) at every branch, so forcing it makes the
// controller report access through its own trial path — the app then treats the
// account as mid-trial and reveals the reaction via its normal logic rather than
// a forced gate. Plain BOOL, crash-safe.
- (BOOL)_hasValidConfirmedTrialAccess {
    if (gPlusEnabled && gPlusTrial) return YES;
    return %orig;
}

%end

%end // FBPSuperReaction

#pragma mark - Story super-reaction reveal gate (DIRECT mode)

// The master reveal gate. Its real logic is roughly
//     reveal = subscriptionBenefitActive
//              OR ((hasFeatureAccess OR bucketPreview) AND gatekeeper)
// where the gatekeeper is a MobileConfig flag that can be OFF on a given build —
// so forcing hasFeatureAccess alone is not enough when that flag is off. DIRECT
// mode forces this one BOOL to YES, revealing the reaction regardless of the
// gatekeeper. Plain ObjC, plain BOOL the app already returns, so crash-safe.
// TRIAL mode leaves it to %orig and instead drives the controller's trial state,
// so the reveal happens through the app's own path.
%group FBPSuperReactionReveal

%hook FBSnacksComposerController

- (BOOL)_isSuperReactionAvailableForCurrentThreadWithBucketPreview:(id)preview {
    if (gPlusEnabled && !gPlusTrial) return YES;
    return %orig;
}

%end

%end // FBPSuperReactionReveal

#pragma mark - Story super-reaction teaser (DIRECT mode)

// Drives the animated teaser reveal — a plain BOOL backed by a single ivar. In
// DIRECT mode it is forced YES so the reveal animation plays alongside the gate
// override above.
%group FBPSuperReactionTeaser

%hook FBSnacksSuperReactionTeaserState

- (BOOL)shouldRevealSuperReaction {
    if (gPlusEnabled && !gPlusTrial) return YES;
    return %orig;
}

%end

%end // FBPSuperReactionTeaser

#pragma mark - Story extend / viewer-sheet diamond

// FBStoryExtendHelper is a separate Swift gate for the story-viewer-sheet
// diamond and the "extend a story beyond 24h" benefit; it also does not consult
// the benefit checker. These are class (+) methods, so the placeholder is bound
// to the resolved Swift class in %init below. Each returns a BOOL the app
// already handles.
%group FBPStoryExtend

%hook FBPStoryExtendHelper

+ (BOOL)isBenefitActiveWithSession:(id)session {
    if (gPlusEnabled) return YES;
    return %orig;
}

// Keep the decision client-side: were the app to re-check eligibility against
// the server, a server "no" would override the forced YES above.
+ (BOOL)useServerDiamondEligibilityWithSession:(id)session {
    if (gPlusEnabled) return NO;
    return %orig;
}

// Access is granted, so suppress the upsell nag rather than showing it.
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

    // Swift runtime name is _TtC<n><module><n><class>, and for this class the
    // module and class names are identical. `NSClassFromString` also accepts the
    // demangled Module.Class form; a plain ObjC class is tried last in case a
    // future build renames it.
    Class checker =
        NSClassFromString(@"_TtC26FBSubsBenefitStatusChecker26FBSubsBenefitStatusChecker")
        ?: NSClassFromString(@"FBSubsBenefitStatusChecker.FBSubsBenefitStatusChecker")
        ?: objc_getClass("FBSubsBenefitStatusChecker");

    // Guard on -isBenefitActive:, the method actually present on this Swift class.
    // -isBenefitActiveWithBenefitType: is a SUBSBenefitDataProvider protocol
    // witness that tail-calls -isBenefitActive:, so it is NOT listed as a direct
    // instance method — guarding on it made this whole group silently never
    // install (hooking -isBenefitActive: already covers both entry points).
    if (checker &&
        [checker instancesRespondToSelector:@selector(isBenefitActive:)]) {
        FBP_ONCE(gMetaPlus) { %init(FBPMetaPlus, FBPSubsBenefitStatusChecker = checker); }
        FBPLog(@"plus: subscription benefit gate installed on %@", NSStringFromClass(checker));
    } else {
        FBPLog(@"plus: FBSubsBenefitStatusChecker not found — "
               @"subscription unlock inactive");
    }

    // Story super-reaction (diamond / heart) — plain ObjC, hooked by name. This
    // is the gate that actually governs the reaction; the benefit checker above
    // does not.
    Class superReaction = objc_getClass("FBSnacksSuperReactionFeatureAccessController");
    if (superReaction &&
        [superReaction instancesRespondToSelector:@selector(hasFeatureAccess)]) {
        FBP_ONCE(gSuperReaction) { %init(FBPSuperReaction); }
        FBPLog(@"plus: story super-reaction access gate installed");
    } else {
        FBPLog(@"plus: FBSnacksSuperReactionFeatureAccessController not found");
    }

    // DIRECT-mode master reveal gate on the composer.
    Class composer = objc_getClass("FBSnacksComposerController");
    if (composer && [composer instancesRespondToSelector:
            @selector(_isSuperReactionAvailableForCurrentThreadWithBucketPreview:)]) {
        FBP_ONCE(gSRReveal) { %init(FBPSuperReactionReveal); }
        FBPLog(@"plus: super-reaction reveal gate installed");
    } else {
        FBPLog(@"plus: FBSnacksComposerController reveal gate not found");
    }

    // DIRECT-mode teaser (reveal animation).
    Class teaser = objc_getClass("FBSnacksSuperReactionTeaserState");
    if (teaser && [teaser instancesRespondToSelector:@selector(shouldRevealSuperReaction)]) {
        FBP_ONCE(gSRTeaser) { %init(FBPSuperReactionTeaser); }
    }

    // Story-extend / viewer-sheet diamond — Swift class, resolved and bound here
    // the same way as the benefit checker. respondsToSelector on the class object
    // checks the class (+) method.
    Class storyExtend =
        NSClassFromString(@"_TtC19FBStoryExtendHelper19FBStoryExtendHelper")
        ?: NSClassFromString(@"FBStoryExtendHelper.FBStoryExtendHelper")
        ?: objc_getClass("FBStoryExtendHelper");
    if (storyExtend &&
        [storyExtend respondsToSelector:@selector(isBenefitActiveWithSession:)]) {
        FBP_ONCE(gStoryExtend) { %init(FBPStoryExtend, FBPStoryExtendHelper = storyExtend); }
        FBPLog(@"plus: story-extend diamond gate installed on %@", NSStringFromClass(storyExtend));
    } else {
        FBPLog(@"plus: FBStoryExtendHelper not found");
    }
}
