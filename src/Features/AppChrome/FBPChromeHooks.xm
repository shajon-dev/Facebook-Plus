// App chrome: settings entry points, tab-bar tracking, launch bootstrap.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPHeaders.h"
#import "FBPTrace.h"
#import "FBPResources.h"
#import "FBPSettingsController.h"
#import "FBPWelcomeController.h"
#import "FBPUpdateChecker.h"
#import "FBPCacheCleaner.h"
#import "FBPSheet.h"
#import "FBPToast.h"

#import <objc/runtime.h>

#pragma mark - Settings gesture

@interface FBPSettingsGesture : UILongPressGestureRecognizer
@end
@implementation FBPSettingsGesture
@end

@interface FBPSettingsTarget : NSObject
@end

@implementation FBPSettingsTarget

+ (instancetype)shared {
    static FBPSettingsTarget *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [[self alloc] init]; });
    return shared;
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) return;

    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback impactOccurred];

    [FBPSettingsController presentFromViewController:
        recognizer.view._viewControllerForAncestor];
}

@end

/// Long press on any tab opens settings — the tweak has no home screen icon, so
/// this is the only always-available entry point.
static void FBPAttachSettingsGesture(UIView *view) {
    if (!view) return;
    for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
        if ([recognizer isKindOfClass:FBPSettingsGesture.class]) return;
    }
    FBPSettingsGesture *gesture =
        [[FBPSettingsGesture alloc] initWithTarget:FBPSettingsTarget.shared
                                            action:@selector(handleLongPress:)];
    gesture.minimumPressDuration = 0.5;
    gesture.cancelsTouchesInView = NO;
    [view addGestureRecognizer:gesture];
}

#pragma mark - Tab bar

%group FBPTabBar

%hook FBTabBarContainerView

- (void)layoutSubviews {
    FBPTraceFire("chrome.FBTabBarContainerView.layoutSubviews");
    %orig;
    FBPAttachSettingsGesture(self);
}

%end

%hook FBTabBarItemDefaultView

- (void)layoutSubviews {
    FBPTraceFire("chrome.FBTabBarItemDefaultView.layoutSubviews");
    %orig;
    FBPAttachSettingsGesture(self);
}

%end

%end // FBPTabBar

// iOS 26+ liquid-glass tab bars. The classic FBTabBarContainerView /
// FBTabBarItemDefaultView hooks above still fire on older builds; these cover the
// new floating-pill and native-glass bars that replaced them, so long-press keeps
// working across iOS versions.
%group FBPLiquidTabBar

%hook FBFloatingTabBar

- (void)layoutSubviews {
    FBPTraceFire("chrome.FBFloatingTabBar.layoutSubviews");
    %orig;
    FBPAttachSettingsGesture(self);
}

%end

%hook FBNativeTabBar

- (void)layoutSubviews {
    FBPTraceFire("chrome.FBNativeTabBar.layoutSubviews");
    %orig;
    FBPAttachSettingsGesture(self);
}

%end

%end // FBPLiquidTabBar

// The tab bar slides away as the user scrolls; the toast stack follows it so a
// progress pill never sits over content or floats in empty space.
%group FBPTabBarOffset

%hook FBTabBarAndContentViewController

- (void)setTabBarViewOffsetFraction:(double)fraction animationKind:(NSUInteger)kind {
    FBPTraceFire("chrome.FBTabBarAndContentViewController.setTabBarViewOffsetFraction");
    %orig;
    [NSNotificationCenter.defaultCenter
        postNotificationName:FBPTabBarVisibilityDidChangeNotification
                      object:nil
                    userInfo:@{FBPTabBarFractionKey : @(fraction)}];
}

%end

%end // FBPTabBarOffset

#pragma mark - Facebook settings button

/// Facebook's own settings button also offers Facebook Plus settings, so the tweak is
/// reachable from where a user would look for settings anyway.
static void FBPInterceptSettingsButton(UIView *root) {
    UIView *button = nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSInteger visited = 0;
    while (queue.count && visited < 400) {
        UIView *candidate = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited += 1;
        if ([candidate.accessibilityIdentifier isEqualToString:FBPAXNavSettingsButton]) {
            button = candidate;
            break;
        }
        [queue addObjectsFromArray:candidate.subviews];
    }
    if (button) FBPAttachSettingsGesture(button);
}

#pragma mark - Top "facebook" wordmark

/// Breadth-first search under @c root for the first view the block accepts,
/// bounded so a layout pass never walks an unbounded tree.
static UIView *FBPFirstViewWhere(UIView *root, BOOL (^test)(UIView *candidate)) {
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSInteger visited = 0;
    while (queue.count && visited < 600) {
        UIView *candidate = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited += 1;
        if (test(candidate)) return candidate;
        [queue addObjectsFromArray:candidate.subviews];
    }
    return nil;
}

/// Long press on the top "facebook" wordmark opens Facebook Plus settings.
///
/// Ground truth from the live app (observed with Frida on device):
///   * The wordmark is a @c UIImageView whose @c accessibilityIdentifier is
///     "facebook-wordmark" — a developer string Facebook does not translate — and
///     whose @c accessibilityLabel is just "Facebook". It is NOT the "…view
///     selector" element older versions searched for; that label does not exist
///     on current builds, which is why matching it failed on every phone.
///   * It is decorative: it has no tap action and sits userInteractionEnabled =
///     NO, inside a ComponentKit top bar (CKComponentHostingView) under
///     FBNavigationBar, wrapped by a plain UIView that does carry interaction.
///
/// So match the image view by its identifier and attach the gesture to its
/// wrapping superview, which is already interactive and sized to the wordmark.
/// ComponentKit re-mounts that subtree, so the search runs on every
/// FBNavigationBar layout; FBPAttachSettingsGesture skips a view that already
/// carries the gesture, and re-attaches to the fresh view after a re-mount.
static void FBPAttachWordmarkGesture(UIView *bar) {
    UIView *logo = FBPFirstViewWhere(bar, ^BOOL(UIView *candidate) {
        return [candidate isKindOfClass:UIImageView.class] &&
               [candidate.accessibilityIdentifier.lowercaseString
                   containsString:@"wordmark"];
    });
    if (!logo) return;
    // The image view is non-interactive; its wrapper carries touches and is sized
    // to the wordmark. Fall back to the image view itself if it has no superview.
    UIView *target = logo.superview ?: logo;
    target.userInteractionEnabled = YES;
    FBPAttachSettingsGesture(target);
    static BOOL logged = NO;
    if (!logged) {
        logged = YES;
        FBPTraceLine(@"wordmark attached · %@ · id=%@",
                     NSStringFromClass(target.class),
                     logo.accessibilityIdentifier ?: @"(nil)");
    }
}

%group FBPNavLogo

%hook FBNavigationBar

- (void)layoutSubviews {
    FBPTraceFire("chrome.FBNavigationBar.layoutSubviews");
    %orig;
    // FBNavigationBar is not declared as a UIView subclass in the tweak's
    // headers, so cast to reach the view-tree helpers. The hook also runs for the
    // KVO subclass (NSKVONotifying_FBNavigationBar), the live instance on device.
    FBPAttachWordmarkGesture((UIView *)self);
}

%end

%end // FBPNavLogo

#pragma mark - Launch bootstrap

%group FBPAppDelegate

%hook FBBaseAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)options {
    FBPTraceFire("chrome.FBBaseAppDelegate.application");

    // Before %orig, not after: the sweep has to finish before Facebook opens
    // its feed and session stores, or it deletes what they are already reading
    // and the feed fails a page or two in. It stages rather than unlinks, so
    // the wait here is a handful of renames, and it decides for itself whether
    // the user's schedule has one owed.
    [FBPCacheCleaner clearCachesAtLaunchIfDue];

    BOOL result = %orig;

    [FBPWelcomeController presentIfNeeded];

    // Check GitHub for a newer release a few seconds in, once the UI has settled
    // (silent unless a newer version the user hasn't seen is available).
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [FBPUpdateChecker checkOnLaunch];
    });

    // Facebook's chrome is not up yet at this point; give it a moment before
    // looking for the settings button.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIWindow *window = [FBPToastWindow appKeyWindow];
        if (window) FBPInterceptSettingsButton(window);
    });

    return result;
}

%end

%end // FBPAppDelegate

#pragma mark - Init

void FBPInitChromeHooks(void) {
    if (objc_getClass("FBTabBarContainerView") ||
        objc_getClass("FBTabBarItemDefaultView")) {
        FBP_ONCE(gTabBar) { %init(FBPTabBar); }
    }

    // iOS 26+ liquid-glass tab bars (present alongside or instead of the classic
    // ones depending on the OS version).
    if (objc_getClass("FBFloatingTabBar") || objc_getClass("FBNativeTabBar")) {
        FBP_ONCE(gLiquidTabBar) { %init(FBPLiquidTabBar); }
    }


    // The offset selector lives on the container controller, not FBTabBar.
    if (objc_getClass("FBTabBarAndContentViewController")) {
        FBP_ONCE(gTabBarOffset) { %init(FBPTabBarOffset); }
    }

    if (objc_getClass("FBBaseAppDelegate")) {
        FBP_ONCE(gAppDelegate) { %init(FBPAppDelegate); }
    }

    // Long-press the top "facebook" wordmark to open Facebook Plus settings. The
    // wordmark is a ComponentKit image view inside FBNavigationBar, so re-scan on
    // that bar's layout (it also fires for the NSKVONotifying_ KVO subclass).
    if (objc_getClass("FBNavigationBar")) {
        FBP_ONCE(gNavLogo) { %init(FBPNavLogo); }
    }
}
