// Feed cleanup.
//
// Every News Feed unit is materialised through FBMemModelObject. Returning nil
// from the initialiser drops the unit before it reaches the data source, so no
// blank cell is left behind — which is why this is done at the model layer
// rather than by hiding views.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPHeaders.h"

#import <objc/message.h>
#import <os/log.h>
#import <os/lock.h>
#import <stdatomic.h>

/// Feed category token -> the preference that suppresses it.
///
/// Built once. -initWithFBPandoTree: is on the hot path for every item in the
/// feed, so per-call string work would show up as scroll jank.
static NSDictionary<NSString *, NSString *> *FBPCategoryMap(void) {
    static NSDictionary *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Ads are handled separately by FBPModelIsBlockedAd (FBPAdsHooks.xm), so
        // "SPONSORED" is deliberately not mapped here.
        map = @{
            @"ENGAGEMENT"    : FBPKeyNoRecs,
            @"ENGAGEMENT_QP" : FBPKeyNoRecs,
            @"FB_SHORTS"     : FBPKeyNoReels,
            @"MULTI_FB_STORIES_TRAY" : FBPKeyNoStories,
            @"PYMK_STORY"    : FBPKeyNoStoryPYMK,
            // The feed-level bucket was renamed PYMK_FEED somewhere before
            // v585 — the bare "PYMK" token is gone from that build's binary,
            // which is why the filter silently stopped matching. The old token
            // stays mapped so older Facebook versions keep working.
            @"PYMK_FEED"     : FBPKeyNoPYMK,
            @"PYMK"          : FBPKeyNoPYMK,
        };
    });
    return map;
}

/// The Threads cross-app promotion unit ("<name>, discover new threads").
///
/// Deliberately only Threads. The binary has a whole `*_IN_FEED_UNIT` family
/// (Notes, Highlights, "creators you may follow", follow-back, MEMU…) and
/// blocking all of them emptied the feed — Facebook stopped serving pages and
/// fell back to "feed not available at this moment". Those units evidently
/// carry pagination the feed depends on, so they stay.
static NSSet<NSString *> *FBPThreadsUnits(void) {
    static NSSet *units;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        units = [NSSet setWithArray:@[
            @"THREADS_IN_FEED_UNIT",
            @"THREADS_IN_STORY_UNIT_MID_CARD",
        ]];
    });
    return units;
}

/// Field keys that might carry the unit's type.
///
/// FBMemModelObject resolves its fields dynamically off the Pando tree — the
/// concrete model classes declare no ObjC methods or properties at all, so the
/// real accessor name cannot be read out of the binary. In v578 the app serves
/// the Threads card ("<name>, discover new threads") through a generic Pando
/// feed unit whose type lives in `feed_unit_type` (== "THREADS_IN_FEED_UNIT").
///
/// Both camelCase and the raw snake_case Pando key are tried, because KVC (see
/// FBPIsThreadsUnit) resolves either shape.
static NSArray<NSString *> *FBPUnitTypeKeys(void) {
    static NSArray *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Grounded in the strings actually present in FBSharedFramework v578:
        // `unitType`, `feed_unit_type` and `FeedUnitType`. camelCase covers a
        // materialised accessor; the raw snake key covers KVC lookups that hit
        // the Pando tree directly.
        keys = @[@"feedUnitType", @"feed_unit_type", @"unitType", @"inlineUnitType"];
    });
    return keys;
}

static BOOL FBPValueIsThreadsToken(id value) {
    return [value isKindOfClass:NSString.class] &&
           [FBPThreadsUnits() containsObject:value];
}

static BOOL FBPIsThreadsUnit(id model) {
    for (NSString *key in FBPUnitTypeKeys()) {
        // 1) Typed selector send — only when the model genuinely declares an
        //    object-returning accessor. The return-type guard avoids the scalar
        //    case (-[FBShortsViewerRichMediaModel storyUnitType] is 'Q', an
        //    NSUInteger); messaging its result as an id is undefined behaviour
        //    and previously destabilised the feed.
        SEL selector = NSSelectorFromString(key);
        if ([model respondsToSelector:selector]) {
            NSMethodSignature *signature = [model methodSignatureForSelector:selector];
            const char *returnType = signature.methodReturnType;
            if (returnType && returnType[0] == _C_ID) {
                @try {
                    id value = ((id (*)(id, SEL))objc_msgSend)(model, selector);
                    if (FBPValueIsThreadsToken(value)) return YES;
                } @catch (__unused NSException *exception) {}
            }
        }

        // 2) KVC. Pando fields are reachable through -valueForKey: even when the
        //    matching accessor has not been lazily materialised yet, so
        //    -respondsToSelector: for it is NO at -initWithFBPandoTree: time.
        //    That gap is why the selector-only check missed the Threads card.
        //    -valueForKey: on an absent key throws NSUndefinedKeyException, which
        //    the @try absorbs; a scalar-backed field returns an NSNumber that
        //    FBPValueIsThreadsToken rejects.
        @try {
            id value = [model valueForKey:key];
            if (FBPValueIsThreadsToken(value)) return YES;
        } @catch (__unused NSException *exception) {}
    }
    return NO;
}

#pragma mark - Feed-unit token diagnostic

// Why this exists.
//
// Every entry in FBPCategoryMap() is a bucket token Facebook can rename at any
// release, and when it does the toggle keeps its switch and silently stops
// biting — exactly how the bare "PYMK" token died. Against Facebook
// 585.0.0.64.71, "FB_SHORTS", "ENGAGEMENT", "ENGAGEMENT_QP" and
// "MULTI_FB_STORIES_TRAY" are absent as standalone strings from all nineteen
// Mach-O images in the app bundle, from the Pando flatbuffer blob
// (lightblue-app-ios_pando_flatbuffer_data.bin), from react_native_routes.json
// and prepackaged_bloks_config.json, and from main.hbcbundle. Their
// replacements could not be identified statically: the only surviving
// category-shaped family is the feed_top_story_min_gap_type cluster (SPONSORED,
// MP_NETFLIX_PROMOTION, HIGH_VALUE_PROMOTION, FB_STORIES_ENGAGEMENT,
// FIXED_POSITION, FB_STORIES, SHOWCASE, END_OF_FEED_CONTENT), which has no
// Reels entry at all, and parts of the enum have evidently gone numeric — the
// bundled ranking config expresses "is_organic" as `category=1`, the client
// logs dist_to_min_gap_type_4/5/10, and several classes declare `category` with
// an integer encoding (Ti / Tq / TQ) rather than T@"NSString".
//
// So rather than guess, this logs what the device actually serves. Turn
// "Log Feed Unit Tokens" on in Settings, scroll the feed once, and read it back
// in Console.app filtered on subsystem com.shajon.fbplus — the token set that
// comes out is the ground truth to map in FBPCategoryMap().

static os_log_t FBPFeedUnitLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.shajon.fbplus", "FeedUnits");
    });
    return log;
}

/// Cached mirror of FBPKeyLogFeedUnits.
///
/// FBPShouldFilterModel runs for every object the Pando tree materialises, so
/// when the toggle is off the diagnostic has to cost one relaxed load of this
/// flag and nothing else — an NSUserDefaults lookup per model would be scroll
/// jank. The mirror is refreshed from the notification the settings panel posts
/// on commit, so the switch takes effect without a relaunch and without a
/// rebuild.
static atomic_bool gFBPLogFeedUnits = false;

static void FBPRefreshFeedUnitLogging(void) {
    atomic_store_explicit(&gFBPLogFeedUnits,
                          FBPEnabled(FBPKeyLogFeedUnits) ? true : false,
                          memory_order_relaxed);
}

/// Field keys the diagnostic probes.
///
/// `category` is what FBPCategoryMap() is matched against. The rest are the
/// neighbouring accessors v585 actually declares — `feedUnitCategory` (a new
/// T@"NSString",R,C,N property), `storyCategory`, `storyUnitType` — plus the raw
/// snake_case Pando keys, because KVC resolves either shape and the Threads
/// matcher depends on that (see FBPUnitTypeKeys above).
static NSArray<NSString *> *FBPDiagnosticKeys(void) {
    static NSArray *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[
            @"category", @"feedUnitCategory", @"feed_unit_category",
            @"storyCategory", @"story_category",
            @"storyBucketType", @"story_bucket_type",
            @"feedUnitType", @"feed_unit_type",
            @"unitType", @"unit_type", @"inlineUnitType", @"storyUnitType",
        ];
    });
    return keys;
}

/// One line per distinct finding, not per model.
///
/// FBMemModelObject is the base of every Pando object, so a single scroll
/// materialises tens of thousands of them and logging each one would bury the
/// answer. Deduping keeps the output to the token set itself, which is the whole
/// point of the capture.
static BOOL FBPClaimDiagnosticLine(NSString *line) {
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static NSMutableSet<NSString *> *seen;

    os_unfair_lock_lock(&lock);
    if (!seen) seen = [NSMutableSet set];
    BOOL fresh = ![seen containsObject:line];
    if (fresh) {
        // Values can be unbounded (ids, tracking strings), so cap the set
        // rather than let a long session grow it without limit.
        if (seen.count >= 4096) [seen removeAllObjects];
        [seen addObject:line];
    }
    os_unfair_lock_unlock(&lock);
    return fresh;
}

/// A printable description of @c key on @c model, or nil when there is no such
/// field. The leading tag says which path produced it — @c sel for a declared
/// accessor, @c kvc for a Pando field resolved through -valueForKey:.
static NSString *FBPDiagnosticDescription(id model, NSString *key) {
    SEL selector = NSSelectorFromString(key);
    if ([model respondsToSelector:selector]) {
        NSMethodSignature *signature = [model methodSignatureForSelector:selector];
        const char *returnType = signature.methodReturnType;
        if (returnType && returnType[0] != _C_ID) {
            // The accessor exists but does not return an object. Reported rather
            // than read: messaging a scalar result as an id is the undefined
            // behaviour that previously destabilised the feed, and the encoding
            // alone is the answer worth having — a scalar-backed field is
            // precisely what makes an NSString comparison in FBPCategoryMap()
            // stop matching with no other symptom.
            return [NSString stringWithFormat:@"sel <scalar '%c'>", returnType[0]];
        }
        if (returnType) {
            @try {
                id value = ((id (*)(id, SEL))objc_msgSend)(model, selector);
                if (value) {
                    return [NSString stringWithFormat:@"sel %@ <%@>",
                            value, NSStringFromClass([value class])];
                }
            } @catch (__unused NSException *exception) {}
        }
    }
    @try {
        id value = [model valueForKey:key];
        if (value) {
            return [NSString stringWithFormat:@"kvc %@ <%@>",
                    value, NSStringFromClass([value class])];
        }
    } @catch (__unused NSException *exception) {}
    return nil;
}

/// Kept out of line so the disabled path in FBPShouldFilterModel stays a flag
/// test and a not-taken branch.
__attribute__((noinline))
static void FBPLogFeedUnit(id model) {
    NSString *className = NSStringFromClass([model class]);
    BOOL reported = NO;

    for (NSString *key in FBPDiagnosticKeys()) {
        NSString *description = FBPDiagnosticDescription(model, key);
        if (!description) continue;
        // A whole nested model can come back as the value; the token is at the
        // front, so a bounded prefix is enough and keeps the log readable.
        if (description.length > 160) {
            description = [[description substringToIndex:160] stringByAppendingString:@"…"];
        }
        NSString *line = [NSString stringWithFormat:@"%@ · %@ = %@",
                          className, key, description];
        if (FBPClaimDiagnosticLine(line)) {
            os_log(FBPFeedUnitLog(), "token %{public}@", line);
        }
        reported = YES;
    }

    if (!reported && [className containsString:@"FeedUnit"]) {
        // No probed field resolved, but the class name says this is a feed unit
        // — the inventory of those is worth having too, once per class, since a
        // class-name match is the fallback the other filters already use.
        NSString *line = [NSString stringWithFormat:@"%@ · no token", className];
        if (FBPClaimDiagnosticLine(line)) {
            os_log(FBPFeedUnitLog(), "unit  %{public}@", line);
        }
    }
}

/// YES when this model should be dropped.
static BOOL FBPShouldFilterModel(id model) {
    if (!model) return NO;

    if (atomic_load_explicit(&gFBPLogFeedUnits, memory_order_relaxed)) {
        FBPLogFeedUnit(model);
    }

    // Ads (sponsored units and sponsoredData-backed units) are detected in one
    // place — FBPModelIsBlockedAd in FBPAdsHooks.xm — so every ad rule lives
    // beside the other ad hooks. This single model hook stays the only thing that
    // touches FBMemModelObject.
    if (FBPModelIsBlockedAd(model)) return YES;

    // Most models have no category at all; bail out before doing any work.
    if ([model respondsToSelector:@selector(category)]) {
        NSString *category = [model category];
        if ([category isKindOfClass:NSString.class]) {
            NSString *key = FBPCategoryMap()[category];
            if (key && FBPEnabled(key)) return YES;
        }
    }

    if (FBPEnabled(FBPKeyNoThreads) && FBPIsThreadsUnit(model)) {
        return YES;
    }

    // "Groups you should join" / "Suggested for you" group units. These arrive as
    // their own FBMem* model class rather than under a shared category token, so
    // they are matched by class name. The generated model does not override
    // -initWithFBPandoTree:, so the instance still reaches this base hook.
    if (FBPEnabled(FBPKeyNoGroupSuggestions)) {
        NSString *className = NSStringFromClass([model class]);
        if ([className containsString:@"GroupsYouShouldJoin"]) return YES;
    }

    // "Suggested Pages for you" — the pages-you-may-like unit. Like the group
    // suggestions above it arrives as its own FBMem* model class (the plain,
    // Paginated and Creative variants all share the "PagesYouMayLike" infix) and
    // does not override -initWithFBPandoTree:, so it reaches this base hook.
    if (FBPEnabled(FBPKeyNoSuggestedPages)) {
        NSString *className = NSStringFromClass([model class]);
        if ([className containsString:@"PagesYouMayLike"]) return YES;
    }

    // Standalone survey feed units — the "Are you interested in this post?"
    // card when it arrives as a unit of its own (FBMemXFBPositionalFeedSurvey,
    // FBMemStoryGallerySurveyFeedUnit). The two infixes are matched rather than
    // a bare "Survey" or "InlineSurvey": the latter would also catch
    // FBMemInlineSurveyStoryActionLink / …SubmitResponsePayload, which belong to
    // a host post that may dereference them, so dropping those risks a crash.
    //
    // The inline card attached to an ordinary post is a component, not a unit —
    // see FBPFeedSurveyHooks.xm; the Reels surfaces are in FBPReelsSurveyHooks.xm.
    if (FBPEnabled(FBPKeyNoSurveys)) {
        NSString *className = NSStringFromClass([model class]);
        if ([className containsString:@"PositionalFeedSurvey"] ||
            [className containsString:@"SurveyFeedUnit"]) {
            return YES;
        }
    }

    // A single ephemeral story shown inline in the feed (its own card, distinct
    // from the horizontal tray). It arrives as FBMemStoriesSingleBucketInline
    // ViewerFeedUnit under an ORGANIC edge, so it is matched by class name rather
    // than category. Gated by the same Stories toggle as the tray.
    if (FBPEnabled(FBPKeyNoStories)) {
        NSString *className = NSStringFromClass([model class]);
        if ([className containsString:@"SingleBucketInlineViewer"]) return YES;
    }

    // The story-tray PYMK bucket is distinct from the feed-level one.
    if (FBPEnabled(FBPKeyNoStoryPYMK) &&
        [model respondsToSelector:@selector(storyBucketType)]) {
        NSString *bucket = [model storyBucketType];
        if ([bucket isKindOfClass:NSString.class] &&
            [bucket isEqualToString:@"PYMK_STORY"]) {
            return YES;
        }
    }

    return NO;
}

%group FBPFeed

%hook FBMemModelObject

// The current path in FB v570/v574.
- (id)initWithFBPandoTree:(void *)tree {
    id model = %orig;
    return FBPShouldFilterModel(model) ? nil : model;
}

%end

%end // FBPFeed

// Legacy GraphQL tree path. Absent from v570 and v574, so it is
// installed only when the selector actually exists — hooking a missing selector
// would fail silently and mask a real problem later.
%group FBPFeedLegacy

%hook FBMemModelObject

- (id)initWithFBTree:(void *)tree {
    id model = %orig;
    return FBPShouldFilterModel(model) ? nil : model;
}

%end

%end // FBPFeedLegacy

void FBPInitFeedHooks(void) {
    Class model = objc_getClass("FBMemModelObject");
    if (!model) {
        FBPLog(@"FBMemModelObject not found — feed filtering disabled");
        return;
    }

    // Seed the diagnostic flag and keep it in step with the settings panel. The
    // installer is re-run on every dyld image load, so this needs its own latch.
    FBP_ONCE(gFeedUnitLogging) {
        FBPRefreshFeedUnitLogging();
        [NSNotificationCenter.defaultCenter
            addObserverForName:FBPSettingsDidChangeNotification
                        object:nil
                         queue:nil
                    usingBlock:^(__unused NSNotification *note) {
            FBPRefreshFeedUnitLogging();
        }];
    }

    if ([model instancesRespondToSelector:@selector(initWithFBPandoTree:)]) {
        FBP_ONCE(gFeed) { %init(FBPFeed); }
    }
    if ([model instancesRespondToSelector:@selector(initWithFBTree:)]) {
        FBP_ONCE(gFeedLegacy) { %init(FBPFeedLegacy); }
    }
}
