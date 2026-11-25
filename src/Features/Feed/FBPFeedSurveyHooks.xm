// Suppress the inline survey card under the media of an ordinary feed post.
//
// FBFeedInlineSurveyComponent is a ComponentKit component of the host story,
// not a feed unit, so dropping it at the feed-model chokepoint used for
// standalone survey units would delete the whole post. Its two short factories
// tail-call the long one through an __objc_stubs stub, so hooking the long
// builder catches all three. Its layout is left alone: the class declares no
// layout method, and the inherited CK entry point would need a
// CKComponentLayout / CKSizeRange ABI this tweak does not declare.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPHeaders.h"
#import "FBPTrace.h"

#import <objc/runtime.h>

#pragma mark - Inline survey card

%group FBPFeedInlineSurvey

%hook FBFeedInlineSurveyComponent

+ (id)newWithActionLink:(id)actionLink
               tracking:(id)tracking
      externalVariables:(id)externalVariables
dismissalExternalVariableName:(id)dismissalName
                toolbox:(id)toolbox {
    FBPTraceFire("feed.FBFeedInlineSurveyComponent.newWithActionLink");
    // nil is what the factory already returns for an ineligible story.
    if (FBPEnabled(FBPKeyNoSurveys)) return nil;
    return %orig;
}

%end

%end // FBPFeedInlineSurvey

#pragma mark - Init

void FBPInitFeedSurveyHooks(void) {
    Class component = objc_getClass("FBFeedInlineSurveyComponent");

    if (component &&
        [component respondsToSelector:@selector(newWithActionLink:tracking:externalVariables:dismissalExternalVariableName:toolbox:)]) {
        FBP_ONCE(gFeedInlineSurvey) { %init(FBPFeedInlineSurvey); }
    } else {
        FBPLogOnce(@"FBFeedInlineSurveyComponent factory not found — in-post survey cards not suppressed");
    }
}
