// App chrome: settings entry points, tab-bar tracking, launch bootstrap.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPDiagnostics.h"
#import "FBPHeaders.h"
#import "FBPResources.h"
#import "FBPSettingsController.h"
#import "FBPWelcomeController.h"
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
    %orig;
    FBPAttachSettingsGesture(self);
}

%end

%hook FBTabBarItemDefaultView

- (void)layoutSubviews {
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
    %orig;
    FBPAttachSettingsGesture(self);
}

%end

%hook FBNativeTabBar

- (void)layoutSubviews {
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

#pragma mark - Launch bootstrap

%group FBPAppDelegate

%hook FBBaseAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)options {
    BOOL result = %orig;

    if (FBPEnabled(FBPKeyAutoClearCache)) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSString *cachePath = NSSearchPathForDirectoriesInDomains(
                NSCachesDirectory, NSUserDomainMask, YES).firstObject;
            NSArray<NSString *> *contents =
                [NSFileManager.defaultManager contentsOfDirectoryAtPath:cachePath error:NULL];
            for (NSString *item in contents) {
                [NSFileManager.defaultManager
                    removeItemAtPath:[cachePath stringByAppendingPathComponent:item]
                               error:NULL];
            }
        });
    }

    [FBPWelcomeController presentIfNeeded];

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
        [FBPDiagnostics.shared recordGroup:@"FBPTabBar" installed:YES detail:nil];
    }

    // iOS 26+ liquid-glass tab bars (present alongside or instead of the classic
    // ones depending on the OS version).
    if (objc_getClass("FBFloatingTabBar") || objc_getClass("FBNativeTabBar")) {
        FBP_ONCE(gLiquidTabBar) { %init(FBPLiquidTabBar); }
        [FBPDiagnostics.shared recordGroup:@"FBPLiquidTabBar" installed:YES detail:nil];
    }


    // The offset selector lives on the container controller, not FBTabBar.
    if (objc_getClass("FBTabBarAndContentViewController")) {
        FBP_ONCE(gTabBarOffset) { %init(FBPTabBarOffset); }
        [FBPDiagnostics.shared recordGroup:@"FBPTabBarOffset" installed:YES detail:nil];
    }

    if (objc_getClass("FBBaseAppDelegate")) {
        FBP_ONCE(gAppDelegate) { %init(FBPAppDelegate); }
        [FBPDiagnostics.shared recordGroup:@"FBPAppDelegate" installed:YES detail:nil];
    }
}
