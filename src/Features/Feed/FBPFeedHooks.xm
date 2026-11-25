// Feed cleanup. Every News Feed unit is materialised through FBMemModelObject,
// and returning nil from the initialiser drops it before the data source sees
// it, so no blank cell is left behind — which is why this is done at the model
// layer rather than by hiding views.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPHeaders.h"
#import "FBPTrace.h"

#import <objc/message.h>
#import <os/log.h>
#import <os/lock.h>
#import <stdatomic.h>

/// Feed category token -> the preference that suppresses it. Built once:
/// -initWithFBPandoTree: is on the hot path for every item in the feed.
static NSDictionary<NSString *, NSString *> *FBPCategoryMap(void) {
    static NSDictionary *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // "SPONSORED" belongs to FBPModelIsBlockedAd in FBPAdsHooks.xm.
        map = @{
            @"ENGAGEMENT"    : FBPKeyNoRecs,
            @"ENGAGEMENT_QP" : FBPKeyNoRecs,
            @"FB_SHORTS"     : FBPKeyNoReels,
            // Gone from v585, where the tray is removed at its section
            // component instead; mapped for builds that still serve it.
            @"MULTI_FB_STORIES_TRAY" : FBPKeyNoMainStories,
            @"PYMK_STORY"    : FBPKeyNoStoryPYMK,
            // Renamed from the bare "PYMK", which is gone from v585 and is why
            // the filter silently stopped matching; both stay mapped.
            @"PYMK_FEED"     : FBPKeyNoPYMK,
            @"PYMK"          : FBPKeyNoPYMK,
        };
    });
    return map;
}

/// The Threads cross-app promotion unit, and deliberately only that one: the
/// binary has a whole `*_IN_FEED_UNIT` family, and blocking all of them emptied
/// the feed — they evidently carry pagination the feed depends on.
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

/// Field keys that might carry the unit's type. The concrete model classes
/// declare no ObjC methods at all (fields resolve off the Pando tree), so the
/// accessor name cannot be read out of the binary; KVC resolves either shape,
/// so both spellings are tried.
static NSArray<NSString *> *FBPUnitTypeKeys(void) {
    static NSArray *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
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
        // Typed send, only for a declared object-returning accessor: some of
        // these are scalar ('Q'), and messaging that result as an id is
        // undefined behaviour.
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

        // KVC reaches a Pando field whose accessor is not materialised yet, so
        // -respondsToSelector: is NO at -initWithFBPandoTree: time and a
        // selector-only check misses it. An absent key throws, absorbed below.
        @try {
            id value = [model valueForKey:key];
            if (FBPValueIsThreadsToken(value)) return YES;
        } @catch (__unused NSException *exception) {}
    }
    return NO;
}

#pragma mark - Feed-unit token diagnostic

// Every entry in FBPCategoryMap() is a token Facebook can rename, and when it
// does the toggle silently stops biting. Several mapped tokens are no longer
// strings anywhere in the bundle, and part of the enum has gone numeric, so
// replacements cannot be found statically. This logs what the device serves,
// which is the ground truth to map in FBPCategoryMap().

static os_log_t FBPFeedUnitLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.shajon.fbplus", "FeedUnits");
    });
    return log;
}

/// FBPShouldFilterModel runs for every object the Pando tree materialises, so
/// the disabled diagnostic must cost one relaxed load and nothing more; an
/// NSUserDefaults lookup per model would be scroll jank.
static atomic_bool gFBPLogFeedUnits = false;

static void FBPRefreshFeedUnitLogging(void) {
    // Diagnostic builds only: the cost would jank scrolling in a shipped one.
#if FBP_DIAG
    atomic_store_explicit(&gFBPLogFeedUnits, true, memory_order_relaxed);
#else
    atomic_store_explicit(&gFBPLogFeedUnits, false, memory_order_relaxed);
#endif
}

/// `category` is what FBPCategoryMap() matches; the rest are neighbouring
/// accessors plus the raw snake_case Pando keys.
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

/// One line per distinct finding: FBMemModelObject is the base of every Pando
/// object, so a scroll materialises tens of thousands of them.
static BOOL FBPClaimDiagnosticLine(NSString *line) {
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static NSMutableSet<NSString *> *seen;

    os_unfair_lock_lock(&lock);
    if (!seen) seen = [NSMutableSet set];
    BOOL fresh = ![seen containsObject:line];
    if (fresh) {
        if (seen.count >= 4096) [seen removeAllObjects];
        [seen addObject:line];
    }
    os_unfair_lock_unlock(&lock);
    return fresh;
}

/// A printable description of @c key on @c model, or nil. The leading tag is
/// @c sel for a declared accessor, @c kvc for a -valueForKey: resolution.
static NSString *FBPDiagnosticDescription(id model, NSString *key) {
    SEL selector = NSSelectorFromString(key);
    if ([model respondsToSelector:selector]) {
        NSMethodSignature *signature = [model methodSignatureForSelector:selector];
        const char *returnType = signature.methodReturnType;
        if (returnType && returnType[0] != _C_ID) {
            // Reported, not read: messaging a scalar result as an id is
            // undefined behaviour. A scalar-backed field is exactly what makes
            // an NSString comparison in FBPCategoryMap() stop matching.
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

/// Out of line, so the disabled path stays a flag test and an untaken branch.
__attribute__((noinline))
static void FBPLogFeedUnit(id model) {
    NSString *className = NSStringFromClass([model class]);
    BOOL reported = NO;

    for (NSString *key in FBPDiagnosticKeys()) {
        NSString *description = FBPDiagnosticDescription(model, key);
        if (!description) continue;
        if (description.length > 160) {
            description = [[description substringToIndex:160] stringByAppendingString:@"…"];
        }
        NSString *line = [NSString stringWithFormat:@"%@ · %@ = %@",
                          className, key, description];
        if (FBPClaimDiagnosticLine(line)) {
            os_log(FBPFeedUnitLog(), "token %{public}@", line);
            FBPDiag(@"feedunit", @"%@", line);
        }
        reported = YES;
    }

    if (!reported && [className containsString:@"FeedUnit"]) {
        // No field resolved, but the class name says feed unit: inventory it.
        NSString *line = [NSString stringWithFormat:@"%@ · no token", className];
        if (FBPClaimDiagnosticLine(line)) {
            os_log(FBPFeedUnitLog(), "unit  %{public}@", line);
            FBPDiag(@"feedunit", @"%@", line);
        }
    }
}

static BOOL FBPShouldFilterModel(id model) {
    if (!model) return NO;

    if (atomic_load_explicit(&gFBPLogFeedUnits, memory_order_relaxed)) {
        FBPLogFeedUnit(model);
    }

    // Ad rules live beside the other ad hooks, so this stays the only hook.
    if (FBPModelIsBlockedAd(model)) return YES;

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

    // Group suggestions arrive as their own FBMem* class, not under a category
    // token, so they match by name; the generated model does not override
    // -initWithFBPandoTree:, so it still reaches this base hook.
    if (FBPEnabled(FBPKeyNoGroupSuggestions)) {
        NSString *className = NSStringFromClass([model class]);
        if ([className containsString:@"GroupsYouShouldJoin"]) return YES;
    }

    // "Suggested Pages for you", likewise by class name: the plain, Paginated
    // and Creative variants all share the "PagesYouMayLike" infix.
    if (FBPEnabled(FBPKeyNoSuggestedPages)) {
        NSString *className = NSStringFromClass([model class]);
        if ([className containsString:@"PagesYouMayLike"]) return YES;
    }

    // Survey cards that arrive as a unit of their own. These two infixes, not a
    // bare "Survey", which would also catch the action-link and payload objects
    // a host post may dereference. The inline card is in FBPFeedSurveyHooks.xm.
    if (FBPEnabled(FBPKeyNoSurveys)) {
        NSString *className = NSStringFromClass([model class]);
        if ([className containsString:@"PositionalFeedSurvey"] ||
            [className containsString:@"SurveyFeedUnit"]) {
            return YES;
        }
    }

    // A single story inline in the feed, distinct from the horizontal tray. It
    // arrives under an ORGANIC edge, so it is matched by class name.
    if (FBPEnabled(FBPKeyNoStories)) {
        NSString *className = NSStringFromClass([model class]);
        if ([className containsString:@"SingleBucketInlineViewer"] ||
            [className containsString:@"StoriesSingleBucketFeedUnit"]) {
            return YES;
        }
    }

    // The story-tray PYMK bucket, distinct from the feed-level one. Its type is
    // a Pando field, not an ObjC getter, so it must be read by KVC:
    // respondsToSelector:@selector(storyBucketType) is always NO here.
    // FBMemPymkStoryData is the leaf of such a bucket and is never dropped,
    // since removing a leaf risks a parent dereference.
    if (FBPEnabled(FBPKeyNoStoryPYMK) &&
        ![NSStringFromClass([model class]) containsString:@"PymkStoryData"]) {
        @try {
            id raw = [model valueForKey:@"storyBucketType"];
            NSString *bucket = [raw isKindOfClass:NSString.class] ? raw : nil;
            if (bucket && ([bucket isEqualToString:@"PYMK_STORY"] ||
                           [bucket hasPrefix:@"PYMK_STORY_TRAY"])) {
                FBPTraceFire("feed.storyBucket.suggestionDropped");
                return YES;
            }
        } @catch (__unused NSException *e) {
            // No storyBucketType field, so not a tray bucket.
        }
    }

    return NO;
}

%group FBPFeed

%hook FBMemModelObject

- (id)initWithFBPandoTree:(void *)tree {
    FBPTraceFire("feed.FBMemModelObject.initWithFBPandoTree");
    id model = %orig;
    return FBPShouldFilterModel(model) ? nil : model;
}

%end

%end // FBPFeed

// Legacy GraphQL tree path, absent from current builds, so it is installed
// only when the selector exists: hooking a missing one creates it.
%group FBPFeedLegacy

%hook FBMemModelObject

- (id)initWithFBTree:(void *)tree {
    FBPTraceFire("feed.FBMemModelObject.initWithFBTree");
    id model = %orig;
    return FBPShouldFilterModel(model) ? nil : model;
}

%end

%end // FBPFeedLegacy

void FBPInitFeedHooks(void) {
    Class model = objc_getClass("FBMemModelObject");
    if (!model) {
        FBPLogOnce(@"FBMemModelObject not found — feed filtering disabled");
        return;
    }

    // The installer re-runs on every dyld image load, so this needs a latch.
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
