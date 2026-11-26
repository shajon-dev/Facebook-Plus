// Definitions of the shared constants declared in FBPlus.h: notification
// names, preference keys, and Facebook accessibility identifiers.

#import "FBPlus.h"
#import "FBPPrefs.h"

#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <math.h>

// Shared latch: a confirmation is on screen. Both confirmation paths read and
// set this so a second prompt never stacks on the first.
static BOOL gFBPConfirmPromptVisible = NO;
BOOL FBPConfirmPromptVisible(void) { return gFBPConfirmPromptVisible; }
void FBPSetConfirmPromptVisible(BOOL visible) { gFBPConfirmPromptVisible = visible; }

// Font-replacement self-exclusion guard (see FBPlus.h). Thread-local so building
// a replacement font on one thread never disables replacement on another.
static _Thread_local BOOL gFBPFontScopeActive = NO;
BOOL FBPFontScopeActive(void) { return gFBPFontScopeActive; }
void FBPSetFontScopeActive(BOOL active) { gFBPFontScopeActive = active; }

NSNotificationName const FBPSettingsDidChangeNotification =
    @"FBPlusSettingsDidChangeNotification";
NSNotificationName const FBPVideoButtonsDidChangeNotification =
    @"FBPlusVideoButtonsDidChangeNotification";
NSNotificationName const FBPTabBarVisibilityDidChangeNotification =
    @"FBPlusTabBarVisibilityDidChangeNotification";
NSString *const FBPTabBarFractionKey = @"fraction";
NSString *const FBPKeyNoAds            = @"noAds";
NSString *const FBPKeyNoRecs           = @"noRecs";
NSString *const FBPKeyNoPYMK           = @"noPYMK";
NSString *const FBPKeyNoReels          = @"noReels";
NSString *const FBPKeyNoStories        = @"noStories";
NSString *const FBPKeyNoMainStories    = @"noMainStories";
NSString *const FBPKeyNoStoryPYMK      = @"noStoryPYMK";
NSString *const FBPKeyNoThreads        = @"noThreads";
NSString *const FBPKeyNoGroupSuggestions = @"noGroupSuggestions";
NSString *const FBPKeyNoSuggestedPages = @"noSuggestedPages";
NSString *const FBPKeyNoSurveys        = @"noSurveys";
NSString *const FBPKeyNoCommentProductBanner = @"noCommentProductBanner";
NSString *const FBPKeyNoCommentEmojiBar = @"noCommentEmojiBar";
NSString *const FBPKeyNoReelsRecommended = @"noReelsRecommended";
NSString *const FBPKeyConfirmComment   = @"confirmComment";
NSString *const FBPKeyConfirmFriend    = @"confirmFriend";
NSString *const FBPKeyConfirmShare     = @"confirmShare";
NSString *const FBPKeyConfirmFollow    = @"confirmFollow";
NSString *const FBPKeyConfirmPost      = @"confirmPost";
NSString *const FBPKeyReelsDownloaderEnabled = @"reelsDownloaderEnabled";
NSString *const FBPKeyStoryDownloaderEnabled = @"storyDownloaderEnabled";
NSString *const FBPKeyDownloadQualityPicker = @"downloadQualityPicker";
NSString *const FBPKeyReelsHideOverlay = @"reelsHideOverlay";
NSString *const FBPKeyVideoButtonsOpacity     = @"videoButtonsOpacity";
NSString *const FBPKeyVideoButtonsAutoDim     = @"videoButtonsAutoDim";
NSString *const FBPKeyVideoButtonsIdleOpacity = @"videoButtonsIdleOpacity";
NSString *const FBPKeyVideoDownloadPosition   = @"videoDownloadPosition";
NSString *const FBPKeyVideoEyePosition        = @"videoEyePosition";
NSString *const FBPKeyStoryDownloadPosition   = @"storyDownloadPosition";
NSString *const FBPKeyStoryEyePosition        = @"storyEyePosition";
NSString *const FBPKeyAnonymousStories = @"anonymousStories";
NSString *const FBPKeyNoAutoNext       = @"noAutoNext";
NSString *const FBPKeyFeedLike         = @"feedLike";
NSString *const FBPKeyOLED             = @"oledMode";
NSString *const FBPKeyOLEDDividers     = @"oledDividers";
NSString *const FBPKeyHideSidebarUpgrades     = @"hideSidebarUpgrades";
NSString *const FBPKeyHideSidebarAlsoFromMeta = @"hideSidebarAlsoFromMeta";
NSString *const FBPKeyDisableHDR       = @"disableHDR";
NSString *const FBPKeyFont             = @"uiFont";
NSString *const FBPKeyFontScale        = @"uiFontScale";
NSString *const FBPKeyMetaPlus         = @"metaFacebookPlus";
NSString *const FBPKeyMetaPlusMode     = @"metaFacebookPlusMode";
NSString *const FBPKeyLinksInSafari    = @"linksInSafari";
NSString *const FBPKeyLogsKeep         = @"logsKeep";
NSString *const FBPKeyKeychainRebind   = @"keychainRebind";
NSString *const FBPKeyNotifClientSync  = @"notifClientSync";
NSString *const FBPKeyNotifyUpdates    = @"notifyUpdates";
NSString *const FBPKeyAutoClearCache   = @"autoClearCache";
NSString *const FBPKeyCacheSchedule    = @"cacheSchedule";
NSString *const FBPKeyLanguage         = @"uiLanguage";
NSString *const FBPKeyIntroduced       = @"introduced";
NSString *const FBPKeyLastNotifiedVersion = @"lastNotifiedVersion";
NSString *const FBPKeyResolvedGitHubOwner = @"resolvedGitHubOwner";
NSString *const FBPKeyLastCacheSweep   = @"lastCacheSweep";
NSString *const FBPAXFeedLikeButton    = @"cell-ufi-like-button";
NSString *const FBPAXReelsLikeButton   = @"shorts-like-top-button";
NSString *const FBPAXNavSettingsButton = @"nav-settings-button";

#pragma mark - Floating video controls (opacity & drag positioning)

static const void *kFBPDragInstalledKey   = &kFBPDragInstalledKey;
static const void *kFBPDragPrefKeyKey     = &kFBPDragPrefKeyKey;
static const void *kFBPDragActiveKey      = &kFBPDragActiveKey;
static const void *kFBPDragStartCenterKey = &kFBPDragStartCenterKey;
static const void *kFBPDragEndTimeKey     = &kFBPDragEndTimeKey;

static const CGFloat kFBPVideoButtonMinAlpha = 0.15;
static const CGFloat kFBPVideoButtonMaxAlpha = 1.00;
static const CGFloat kFBPVideoButtonMinIdleRatio = 0.01;
// UIKit -[UIView hitTest:withEvent:] ignores views whose alpha <= 0.01, so the
// rendered layer floor stays at 0.015 (visually indistinguishable from 1%) so
// the button never becomes untouchable or undraggable at minimum opacity.
static const CGFloat kFBPVideoButtonHitTestableAlphaFloor = 0.015;
static const CFTimeInterval kFBPVideoButtonIdleDelay = 2.0;

static CFTimeInterval gFBPLastButtonInteractionTime = 0.0;
static uint64_t gFBPIdleTimerGeneration = 0;
static NSInteger gFBPActiveDragCount = 0;

// The button opacity, idle opacity and saved positions are read from the Reels
// display link, so once or twice per frame per button. A stored read is an
// NSUserDefaults lookup and a position is a parsed string, so they are mirrored
// and re-read only when something moves them.
static uint64_t gFBPButtonPrefGen = 1;
static uint64_t gFBPButtonMirrorGen = 0;
static CGFloat gFBPMirrorAlpha = 1.0;
static CGFloat gFBPMirrorIdleAlpha = 0.05;
static BOOL gFBPMirrorAutoDim = NO;
static NSMutableDictionary<NSString *, NSValue *> *gFBPMirrorPositions;

static void FBPInvalidateVideoButtonPrefs(void) { gFBPButtonPrefGen++; }

static void FBPRefreshButtonPrefMirror(void) {
    // Both notifications already exist: settings commits and the live slider.
    FBP_ONCE(gFBPButtonPrefWatch) {
        for (NSNotificationName name in @[ FBPSettingsDidChangeNotification,
                                           FBPVideoButtonsDidChangeNotification ]) {
            [NSNotificationCenter.defaultCenter
                addObserverForName:name object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(__unused NSNotification *note) {
                FBPInvalidateVideoButtonPrefs();
            }];
        }
    }
    if (gFBPButtonMirrorGen == gFBPButtonPrefGen) return;

    double raw = [FBPPrefs.shared doubleForKey:FBPKeyVideoButtonsOpacity];
    if (raw <= 0.001) raw = 1.0;
    raw = MIN(MAX(raw, kFBPVideoButtonMinAlpha), kFBPVideoButtonMaxAlpha);
    gFBPMirrorAlpha = (CGFloat)raw;

    double idle = [FBPPrefs.shared doubleForKey:FBPKeyVideoButtonsIdleOpacity];
    if (idle <= 0.0001) idle = 0.05;
    idle = MIN(MAX(idle, kFBPVideoButtonMinIdleRatio), kFBPVideoButtonMaxAlpha);
    gFBPMirrorIdleAlpha = (CGFloat)idle;

    gFBPMirrorAutoDim = FBPEnabled(FBPKeyVideoButtonsAutoDim);
    [gFBPMirrorPositions removeAllObjects];
    gFBPButtonMirrorGen = gFBPButtonPrefGen;
}

CGFloat FBPVideoButtonsAlpha(void) {
    FBPRefreshButtonPrefMirror();
    return gFBPMirrorAlpha;
}

CGFloat FBPVideoButtonsConfiguredIdleOpacity(void) {
    FBPRefreshButtonPrefMirror();
    return gFBPMirrorIdleAlpha;
}

CGFloat FBPVideoButtonsIdleAlpha(void) {
    CGFloat configured = FBPVideoButtonsConfiguredIdleOpacity();
    return MAX(kFBPVideoButtonHitTestableAlphaFloor, configured);
}

static void FBPScheduleIdleFadeCheck(void) {
    uint64_t expectedGen = ++gFBPIdleTimerGeneration;
    int64_t delayNs = (int64_t)((kFBPVideoButtonIdleDelay + 0.03) * (double)NSEC_PER_SEC);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delayNs), dispatch_get_main_queue(), ^{
        if (expectedGen != gFBPIdleTimerGeneration) return;
        [NSNotificationCenter.defaultCenter
            postNotificationName:FBPVideoButtonsDidChangeNotification
                          object:nil];
    });
}

void FBPNoteVideoButtonsInteraction(void) {
    void (^work)(void) = ^{
        gFBPLastButtonInteractionTime = CACurrentMediaTime();
        FBPScheduleIdleFadeCheck();
        [NSNotificationCenter.defaultCenter
            postNotificationName:FBPVideoButtonsDidChangeNotification
                          object:nil];
    };
    if (NSThread.isMainThread) {
        work();
    } else {
        dispatch_async(dispatch_get_main_queue(), work);
    }
}

BOOL FBPVideoButtonsAreIdle(void) {
    FBPRefreshButtonPrefMirror();
    if (!gFBPMirrorAutoDim) return NO;
    if (gFBPActiveDragCount > 0) return NO;
    CFTimeInterval now = CACurrentMediaTime();
    if (gFBPLastButtonInteractionTime <= 0.0) {
        gFBPLastButtonInteractionTime = now;
        if (NSThread.isMainThread) {
            FBPScheduleIdleFadeCheck();
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{ FBPScheduleIdleFadeCheck(); });
        }
        return NO;
    }
    return (now - gFBPLastButtonInteractionTime) >= kFBPVideoButtonIdleDelay;
}

CGFloat FBPVideoButtonsEffectiveAlpha(void) {
    CGFloat active = FBPVideoButtonsAlpha();
    if (!FBPVideoButtonsAreIdle()) return active;
    return MIN(active, FBPVideoButtonsIdleAlpha());
}

static CGPoint FBPClampButtonCenter(CGPoint desired, CGSize buttonSize, UIView *container) {
    if (!container) return desired;
    CGRect bounds = container.bounds;
    if (bounds.size.width <= 1.0 || bounds.size.height <= 1.0) return desired;

    UIEdgeInsets safe = container.safeAreaInsets;
    UIWindow *win = [container isKindOfClass:UIWindow.class]
        ? (UIWindow *)container
        : container.window;
    CGFloat hwTop = win ? win.safeAreaInsets.top : safe.top;
    CGFloat hwBottom = win ? win.safeAreaInsets.bottom : safe.bottom;

    CGFloat edgePadX = MAX(18.0, buttonSize.width * 0.42);
    CGFloat edgePadY = MAX(20.0, buttonSize.height * 0.45);

    CGFloat minX = safe.left + edgePadX;
    CGFloat maxX = bounds.size.width - safe.right - edgePadX;

    // Allow moving freely all the way up into Facebook's top header row (where
    // the Back "<" and Magnifying Glass search buttons sit at centerY ~ 76..85pt
    // right below the status bar / Dynamic Island), instead of trapping buttons
    // below safe.top + halfH + margin (~90pt).
    CGFloat topCeilingInWin = MAX(edgePadY, hwTop - 28.0);
    CGFloat minY = topCeilingInWin;
    if (win && container != win) {
        CGPoint convertedTop = [win convertPoint:CGPointMake(0.0, topCeilingInWin)
                                          toView:container];
        minY = MAX(edgePadY, convertedTop.y);
    }
    CGFloat maxY = bounds.size.height - MAX(edgePadY, hwBottom + 14.0);

    if (maxX < minX) minX = maxX = CGRectGetMidX(bounds);
    if (maxY < minY) minY = maxY = CGRectGetMidY(bounds);

    CGFloat x = MIN(MAX(desired.x, minX), maxX);
    CGFloat y = MIN(MAX(desired.y, minY), maxY);
    return CGPointMake(x, y);
}

static BOOL FBPParseNormalizedPoint(NSString *raw, CGPoint *outRatio) {
    if (!raw.length) return NO;
    NSArray<NSString *> *parts = [raw componentsSeparatedByString:@","];
    if (parts.count != 2) return NO;

    NSScanner *sx = [NSScanner scannerWithString:parts[0]];
    NSScanner *sy = [NSScanner scannerWithString:parts[1]];
    double rx = 0.0, ry = 0.0;
    if (![sx scanDouble:&rx] || !sx.isAtEnd) return NO;
    if (![sy scanDouble:&ry] || !sy.isAtEnd) return NO;
    if (!isfinite(rx) || !isfinite(ry)) return NO;
    if (rx < 0.0 || rx > 1.0 || ry < 0.0 || ry > 1.0) return NO;

    if (outRatio) *outRatio = CGPointMake((CGFloat)rx, (CGFloat)ry);
    return YES;
}

CGPoint FBPResolvedButtonCenter(NSString *prefKey, CGPoint defaultCenter,
                                CGSize buttonSize, UIView *container) {
    if (!prefKey.length || !container) return defaultCenter;
    CGRect bounds = container.bounds;
    if (bounds.size.width <= 1.0 || bounds.size.height <= 1.0) return defaultCenter;

    FBPRefreshButtonPrefMirror();
    if (!gFBPMirrorPositions) gFBPMirrorPositions = [NSMutableDictionary dictionary];
    NSValue *held = gFBPMirrorPositions[prefKey];
    CGPoint ratio = CGPointZero;
    if (held) {
        ratio = held.CGPointValue;
        if (ratio.x < 0.0) return defaultCenter;
    } else {
        NSString *saved = [FBPPrefs.shared stringForKey:prefKey];
        BOOL ok = FBPParseNormalizedPoint(saved, &ratio);
        // A miss is worth remembering too: nothing saved is the common case.
        gFBPMirrorPositions[prefKey] =
            [NSValue valueWithCGPoint:ok ? ratio : CGPointMake(-1.0, -1.0)];
        if (!ok) return defaultCenter;
    }

    CGPoint desired = CGPointMake(ratio.x * bounds.size.width,
                                  ratio.y * bounds.size.height);
    return FBPClampButtonCenter(desired, buttonSize, container);
}

BOOL FBPIsButtonDragging(UIButton *button) {
    if (!button) return NO;
    return [objc_getAssociatedObject(button, kFBPDragActiveKey) boolValue];
}

BOOL FBPShouldSuppressTapAfterDrag(UIButton *button) {
    if (!button) return NO;
    if (FBPIsButtonDragging(button)) return YES;
    NSNumber *endTime = objc_getAssociatedObject(button, kFBPDragEndTimeKey);
    if (!endTime) return NO;
    return (CACurrentMediaTime() - endTime.doubleValue) < 0.22;
}

@interface FBPDraggableButtonCoordinator : NSObject
+ (instancetype)shared;
- (void)handlePan:(UIPanGestureRecognizer *)pan;
@end

@implementation FBPDraggableButtonCoordinator

+ (instancetype)shared {
    static FBPDraggableButtonCoordinator *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[FBPDraggableButtonCoordinator alloc] init];
    });
    return shared;
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if (![pan.view isKindOfClass:UIButton.class]) return;
    UIButton *button = (UIButton *)pan.view;
    UIView *container = button.superview;
    if (!container) return;

    CGSize buttonSize = button.bounds.size;
    if (buttonSize.width <= 1.0 || buttonSize.height <= 1.0) {
        buttonSize = CGSizeMake(44.0, 44.0);
    }

    switch (pan.state) {
        case UIGestureRecognizerStateBegan: {
            if (![objc_getAssociatedObject(button, kFBPDragActiveKey) boolValue]) {
                gFBPActiveDragCount += 1;
            }
            objc_setAssociatedObject(button, kFBPDragActiveKey, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(button, kFBPDragStartCenterKey,
                                     [NSValue valueWithCGPoint:button.center],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            FBPNoteVideoButtonsInteraction();
            [container bringSubviewToFront:button];
            button.alpha = MAX(0.30, FBPVideoButtonsAlpha());
            UIImpactFeedbackGenerator *feedback =
                [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [feedback impactOccurred];
            break;
        }
        case UIGestureRecognizerStateChanged: {
            gFBPLastButtonInteractionTime = CACurrentMediaTime();
            NSValue *startVal = objc_getAssociatedObject(button, kFBPDragStartCenterKey);
            CGPoint start = startVal ? startVal.CGPointValue : button.center;
            CGPoint delta = [pan translationInView:container];
            CGPoint desired = CGPointMake(start.x + delta.x, start.y + delta.y);
            CGPoint clamped = FBPClampButtonCenter(desired, buttonSize, container);
            button.frame = CGRectMake(round(clamped.x - buttonSize.width * 0.5),
                                      round(clamped.y - buttonSize.height * 0.5),
                                      buttonSize.width, buttonSize.height);
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            CGPoint clamped = FBPClampButtonCenter(button.center, buttonSize, container);
            button.frame = CGRectMake(round(clamped.x - buttonSize.width * 0.5),
                                      round(clamped.y - buttonSize.height * 0.5),
                                      buttonSize.width, buttonSize.height);

            NSString *prefKey = objc_getAssociatedObject(button, kFBPDragPrefKeyKey);
            CGRect bounds = container.bounds;
            if (prefKey.length && bounds.size.width > 1.0 && bounds.size.height > 1.0 &&
                (pan.state == UIGestureRecognizerStateEnded ||
                 pan.state == UIGestureRecognizerStateCancelled)) {
                double rx = MIN(MAX(button.center.x / bounds.size.width, 0.0), 1.0);
                double ry = MIN(MAX(button.center.y / bounds.size.height, 0.0), 1.0);
                NSString *encoded = [NSString stringWithFormat:@"%.6f,%.6f", rx, ry];
                [FBPPrefs.shared setString:encoded forKey:prefKey];
                FBPInvalidateVideoButtonPrefs();
            }

            objc_setAssociatedObject(button, kFBPDragEndTimeKey,
                                     @(CACurrentMediaTime()),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if ([objc_getAssociatedObject(button, kFBPDragActiveKey) boolValue]) {
                gFBPActiveDragCount = MAX(0, gFBPActiveDragCount - 1);
            }
            objc_setAssociatedObject(button, kFBPDragActiveKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            CGFloat baseAlpha = FBPVideoButtonsAlpha();
            button.alpha = button.enabled ? baseAlpha : MAX(0.12, baseAlpha * 0.45);
            FBPNoteVideoButtonsInteraction();
            break;
        }
        default:
            break;
    }
}

@end

void FBPAttachDraggableBehavior(UIButton *button, NSString *prefKey) {
    if (!button || !prefKey.length) return;
    objc_setAssociatedObject(button, kFBPDragPrefKeyKey, prefKey,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    if ([objc_getAssociatedObject(button, kFBPDragInstalledKey) boolValue]) return;

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:FBPDraggableButtonCoordinator.shared
                action:@selector(handlePan:)];
    pan.cancelsTouchesInView = YES;
    pan.delaysTouchesBegan = NO;
    pan.delaysTouchesEnded = NO;
    pan.maximumNumberOfTouches = 1;
    [button addGestureRecognizer:pan];
    objc_setAssociatedObject(button, kFBPDragInstalledKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void FBPResetVideoButtonPositions(void) {
    FBPInvalidateVideoButtonPrefs();
    [FBPPrefs.shared setString:nil forKey:FBPKeyVideoDownloadPosition];
    [FBPPrefs.shared setString:nil forKey:FBPKeyVideoEyePosition];
    [FBPPrefs.shared setString:nil forKey:FBPKeyStoryDownloadPosition];
    [FBPPrefs.shared setString:nil forKey:FBPKeyStoryEyePosition];
    [FBPPrefs.shared commit];
    FBPNoteVideoButtonsInteraction();
}
