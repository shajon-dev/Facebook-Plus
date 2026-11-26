// Suppress the two cards that ask a post's reader whether the post interests
// them: the inline survey under the media, and the bumper a story hangs below
// its footer, a second renderer the survey hook cannot reach and which comes
// in a persistent and a triggered flavour, hence one group for each.
//
// FBFeedInlineSurveyComponent is a component of the host story, not a feed
// unit, so dropping it at the feed-model chokepoint used for standalone survey
// units would delete the whole post. Its two short factories tail-call the long
// one through an __objc_stubs stub, so hooking the long builder catches all
// three. Its layout is left alone: the class declares no layout method, and the
// inherited CK entry point would need a CKComponentLayout / CKSizeRange ABI
// this tweak does not declare.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPHeaders.h"
#import "FBPTrace.h"

#import <objc/message.h>
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

#pragma mark - Story bumper

/// Nil for a bumper this feature has no business removing, a shop incentive or
/// a restyle call to action among them, so those keep their card.
static BOOL FBPStoryCarriesPreferenceSignal(id story) {
    SEL accessor = @selector(asFBPreferenceSignalsBumperTypeGraphQL);
    if (![story respondsToSelector:accessor]) {
        FBPTraceFire("feed.storyBumper.signalAccessorMissing");
        return NO;
    }
    // A scalar messaged as an object is undefined, and siblings here are scalar.
    const char *returnType =
        [story methodSignatureForSelector:accessor].methodReturnType;
    if (!returnType || returnType[0] != _C_ID) return NO;
    return ((id (*)(id, SEL))objc_msgSend)(story, accessor) != nil;
}

// `options` is a pointer the factory dereferences, not an object: typing it
// id would put it in reach of ARC.
%group FBPFeedPersistentBumper

%hook FBFeedStoryStandardPersistentBumperComponent

+ (id)newWithStory:(id)story options:(void *)options toolbox:(id)toolbox {
    FBPTraceFire("feed.FBFeedStoryStandardPersistentBumperComponent.newWithStory");
    if (FBPEnabled(FBPKeyNoSurveys) && FBPStoryCarriesPreferenceSignal(story)) {
        FBPTraceFire("feed.storyBumper.persistentDropped");
        // The factory returns nil of its own accord when the card it wraps is
        // absent, so the row collapses rather than reserving height.
        return nil;
    }
    return %orig;
}

%end

%end // FBPFeedPersistentBumper

%group FBPFeedTriggeredBumper

%hook FBFeedStoryStandardTriggeredBumperComponent

+ (id)newWithStory:(id)story options:(void *)options toolbox:(id)toolbox {
    FBPTraceFire("feed.FBFeedStoryStandardTriggeredBumperComponent.newWithStory");
    if (FBPEnabled(FBPKeyNoSurveys) && FBPStoryCarriesPreferenceSignal(story)) {
        FBPTraceFire("feed.storyBumper.triggeredDropped");
        return nil;
    }
    return %orig;
}

%end

%end // FBPFeedTriggeredBumper

#pragma mark - Init

void FBPInitFeedSurveyHooks(void) {
    Class component = objc_getClass("FBFeedInlineSurveyComponent");

    if (component &&
        [component respondsToSelector:@selector(newWithActionLink:tracking:externalVariables:dismissalExternalVariableName:toolbox:)]) {
        FBP_ONCE(gFeedInlineSurvey) { %init(FBPFeedInlineSurvey); }
    } else {
        FBPLogOnce(@"FBFeedInlineSurveyComponent factory not found — in-post survey cards not suppressed");
    }

    SEL factory = @selector(newWithStory:options:toolbox:);

    Class persistent = objc_getClass("FBFeedStoryStandardPersistentBumperComponent");
    if (persistent && [persistent respondsToSelector:factory]) {
        FBP_ONCE(gFeedPersistentBumper) { %init(FBPFeedPersistentBumper); }
    } else {
        FBPLogOnce(@"FBFeedStoryStandardPersistentBumperComponent factory not found — persistent interest prompts not suppressed");
    }

    Class triggered = objc_getClass("FBFeedStoryStandardTriggeredBumperComponent");
    if (triggered && [triggered respondsToSelector:factory]) {
        FBP_ONCE(gFeedTriggeredBumper) { %init(FBPFeedTriggeredBumper); }
    } else {
        FBPLogOnce(@"FBFeedStoryStandardTriggeredBumperComponent factory not found — triggered interest prompts not suppressed");
    }
}
