// Survey-prompt suppression for the inline card attached to an ordinary feed post.
//
// This is the third and last survey surface. The other two are handled elsewhere:
//
//   * the Reels tab and the full-screen Reels viewer — FBPReelsSurveyHooks.xm;
//   * standalone survey *feed units* (…PositionalFeedSurvey, …SurveyFeedUnit) —
//     dropped at the feed-model chokepoint in FBPFeedHooks.xm.
//
// The one handled here is the card that hangs *under the media of a normal post*
// ("Are you interested in this post?" / この投稿に興味がありますか?, with
// 興味あり / 興味なし). It is FBFeedInlineSurveyComponent — a ComponentKit
// component belonging to a host story rather than a feed unit of its own, so it
// cannot be dropped at the feed-model chokepoint: doing that would delete the
// whole post along with it.
//
// Instead the component is never built. All of this was read out of the
// Objective-C metadata and the arm64 text of Facebook 585.0.0.64.71
// (FBSharedFramework), not guessed:
//
//   * FBFeedInlineSurveyComponent declares exactly three factories, and the two
//     short ones are four-instruction thunks that tail-call the long one through
//     an __objc_stubs selector stub (so they dispatch through objc_msgSend and
//     this hook catches them too):
//
//       +newWithActionLink:tracking:toolbox:                  @ 0x132db38
//           mov x6, x4 / mov x4, #0 / mov x5, #0 / b <stub>
//       +newWithActionLink:tracking:externalVariables:toolbox: @ 0x1f3f80c
//           mov x6, x5 / mov x5, #0 / b <stub>
//
//     Both funnel into the one real builder, which is what is hooked below:
//
//       +newWithActionLink:tracking:externalVariables:
//            dismissalExternalVariableName:toolbox:           @ 0x13c81c0
//            type encoding @56@0:8@16@24@32@40@48
//            (returns an object; self, _cmd, then five object arguments)
//
//   * Returning nil is a path Facebook's own code already takes. In that builder
//     the action-link argument is tested immediately — `ldr x8, [sp, #0x130]` /
//     `cbz x8, 0x13c860c` — and the branch target is `mov x19, #0x0`, falling
//     into the shared epilogue that does `mov x0, x19` and returns. So the
//     factory already answers nil for an ineligible story, before it even
//     constructs its CKComponentScope. Every call site therefore has to tolerate
//     nil already, and ComponentKit treats a nil child as absent — the card is
//     not built and no empty cell or layout gap is reserved.
//
// This is why the component's *layout* is deliberately left alone. In v585 the
// class declares no layout method of its own (only the answer/dismiss callbacks,
// -boundsAnimationFromPreviousComponent:, -tracking and -toolbox), so suppressing
// it that way would mean overriding an inherited CK entry point — and
// CKComponentLayout / CKSizeRange are not declared anywhere in this tweak, so the
// struct ABI could not be matched safely. Refusing to build the component avoids
// the question entirely.
//
// The group installs only when the class and that exact class method are both
// present, so a rename in a future Facebook build leaves this one surface
// unsuppressed instead of taking the tweak — or the feed — down.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPHeaders.h"

#import <objc/runtime.h>

#pragma mark - Inline survey card

%group FBPFeedInlineSurvey

%hook FBFeedInlineSurveyComponent

+ (id)newWithActionLink:(id)actionLink
               tracking:(id)tracking
      externalVariables:(id)externalVariables
dismissalExternalVariableName:(id)dismissalName
                toolbox:(id)toolbox {
    // nil is the "no card for this story" answer the factory already gives when
    // the action link is missing, so the host post renders exactly as it does
    // for a story that was never eligible for a survey.
    if (FBPEnabled(FBPKeyNoSurveys)) return nil;
    return %orig;
}

%end

%end // FBPFeedInlineSurvey

#pragma mark - Init

void FBPInitFeedSurveyHooks(void) {
    // FBSharedFramework is linked at launch, so this normally latches on the
    // first pass; the installer is still re-run from the dyld image-load
    // callback (see FBPEntry.xm) and FBP_ONCE keeps it to a single install.
    Class component = objc_getClass("FBFeedInlineSurveyComponent");

    // A class method, so the metaclass is what has to respond.
    if (component &&
        [component respondsToSelector:@selector(newWithActionLink:tracking:externalVariables:dismissalExternalVariableName:toolbox:)]) {
        FBP_ONCE(gFeedInlineSurvey) { %init(FBPFeedInlineSurvey); }
    } else {
        FBPLog(@"FBFeedInlineSurveyComponent factory not found — in-post survey cards not suppressed");
    }
}
