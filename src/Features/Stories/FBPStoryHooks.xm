// Stories: incognito viewing, manual mark-as-seen, no auto-advance.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPDiagnostics.h"
#import "FBPHeaders.h"
#import "FBPResources.h"
#import "FBPToast.h"
#import "FBPSheet.h"

#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// The seen-receipt selector gained a parameter; v570/v574 ship only the
// 5-argument form. Both are hooked, each in its own group, and only
// the one that exists is installed.
static SEL FBPMarkSeenModernSelector(void) {
    return NSSelectorFromString(
        @"_markThreadAsSeen:bucket:session:shouldMarkThreadSeenStateUpdates:"
        @"skipSeenMutationForLastUnseenThread:");
}

static SEL FBPMarkSeenLegacySelector(void) {
    return NSSelectorFromString(
        @"_markThreadAsSeen:bucket:session:shouldMarkThreadSeenStateUpdates:");
}

/// Set while the user explicitly asks to be marked as seen, so the suppression
/// below lets that one call through.
static BOOL gAllowSeenPassthrough = NO;

#pragma mark - Incognito

%group FBPStorySeenModern

%hook FBSnacksBucketsSeenStateManager

- (void)_markThreadAsSeen:(id)thread
                   bucket:(id)bucket
                  session:(id)session
shouldMarkThreadSeenStateUpdates:(BOOL)shouldUpdate
skipSeenMutationForLastUnseenThread:(BOOL)skipMutation {
    if (FBPEnabled(FBPKeyAnonymousStories) && !gAllowSeenPassthrough) return;
    %orig;
}

%end

%end // FBPStorySeenModern

%group FBPStorySeenLegacy

%hook FBSnacksBucketsSeenStateManager

- (void)_markThreadAsSeen:(id)thread
                   bucket:(id)bucket
                  session:(id)session
shouldMarkThreadSeenStateUpdates:(BOOL)shouldUpdate {
    if (FBPEnabled(FBPKeyAnonymousStories) && !gAllowSeenPassthrough) return;
    %orig;
}

%end

%end // FBPStorySeenLegacy

#pragma mark - Auto-advance

%group FBPStoryAdvance

%hook FBSnacksThreadSwitcherViewController

/// Stops the viewer rolling into the next author's stories. Manual swipes use a
/// different navigation action and are unaffected.
- (void)_advanceToNextItemWithNavigationAction:(NSUInteger)action {
    if (FBPEnabled(FBPKeyNoAutoNext)) return;
    %orig;
}

%end

%end // FBPStoryAdvance

#pragma mark - Story menu

@interface FBPStoryMenuTarget : NSObject
@property (nonatomic, weak) UIViewController *controller;
@end

@implementation FBPStoryMenuTarget

/// Reaches the seen-state manager the viewer already owns and drives the
/// original implementation for the current thread.
- (void)markCurrentThreadAsSeen {
    UIViewController *controller = self.controller;
    id manager = [controller valueForKey:@"_bucketsSeenStateManager"];
    if (!manager) {
        [FBPToastManager.shared showMessage:@"Something went wrong" success:NO];
        return;
    }

    id thread = nil;
    id bucket = nil;
    id session = nil;
    @try {
        thread  = [controller valueForKey:@"currentThread"];
        bucket  = [controller valueForKey:@"bucket"];
        session = [controller valueForKey:@"session"];
    } @catch (NSException *exception) {
        FBPLog(@"could not read thread/bucket/session: %@", exception.reason);
    }

    SEL modern = FBPMarkSeenModernSelector();
    SEL legacy = FBPMarkSeenLegacySelector();
    SEL selector = [manager respondsToSelector:modern] ? modern
                 : ([manager respondsToSelector:legacy] ? legacy : NULL);
    if (!selector) {
        [FBPToastManager.shared showMessage:@"Something went wrong" success:NO];
        return;
    }

    NSMethodSignature *signature = [manager methodSignatureForSelector:selector];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = manager;
    invocation.selector = selector;
    [invocation setArgument:&thread atIndex:2];
    [invocation setArgument:&bucket atIndex:3];
    [invocation setArgument:&session atIndex:4];
    BOOL yes = YES;
    BOOL no = NO;
    [invocation setArgument:&yes atIndex:5];
    if (signature.numberOfArguments > 6) [invocation setArgument:&no atIndex:6];

    gAllowSeenPassthrough = YES;
    [invocation invoke];
    gAllowSeenPassthrough = NO;

    [FBPToastManager.shared showMessage:@"Marked as seen" success:YES];
}

/// Asks first, then marks seen. Mark-as-seen is the eye button's only action, so
/// it is wired straight to a confirmation prompt — matching the like confirmation
/// — rather than an intermediate one-item menu.
- (void)confirmAndMarkAsSeen {
    UIViewController *host = self.controller;
    if (!host) return;
    while (host.presentedViewController) host = host.presentedViewController;

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Mark as seen"
                                            message:@"Send the read receipt for this story now?"
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    __weak typeof(self) weakSelf = self;
    UIAlertAction *confirm =
        [UIAlertAction actionWithTitle:@"Mark as seen"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *action) {
            [weakSelf markCurrentThreadAsSeen];
        }];
    [alert addAction:confirm];
    alert.preferredAction = confirm;

    alert.view.tintColor = FBPTintColor();
    [host presentViewController:alert animated:YES completion:nil];
}

@end

static const void *kStoryTargetKey = &kStoryTargetKey;

/// The story viewer on screen right now, or nil.
///
/// Used to tell "this action sheet belongs to a story" from every other sheet in
/// the app, since FIGActionSheetController is Facebook's generic design-system
/// sheet and is used everywhere.
static UIViewController *FBPCurrentStoryViewer(void) {
    Class bucketClass = objc_getClass("FBSnacksBucketViewController");
    if (!bucketClass) return nil;

    UIViewController *node = [FBPToastWindow appKeyWindow].rootViewController;
    while (node) {
        if ([node isKindOfClass:bucketClass]) return node;
        for (UIViewController *child in node.childViewControllers) {
            if ([child isKindOfClass:bucketClass]) return child;
        }
        if (node.presentedViewController) { node = node.presentedViewController; continue; }
        // Walk into the visible branch of the common containers.
        if ([node isKindOfClass:UINavigationController.class]) {
            node = ((UINavigationController *)node).topViewController;
        } else if ([node isKindOfClass:UITabBarController.class]) {
            node = ((UITabBarController *)node).selectedViewController;
        } else {
            break;
        }
    }

    // Containers vary; fall back to a search of the whole controller tree.
    __block UIViewController *found = nil;
    void (^__block walk)(UIViewController *) = nil;
    void (^walkImpl)(UIViewController *) = ^(UIViewController *controller) {
        if (found || !controller) return;
        if ([controller isKindOfClass:bucketClass]) { found = controller; return; }
        for (UIViewController *child in controller.childViewControllers) walk(child);
        if (controller.presentedViewController) walk(controller.presentedViewController);
    };
    walk = walkImpl;
    walk([FBPToastWindow appKeyWindow].rootViewController);
    return found;
}

#pragma mark - Appending a row to Facebook's own story menu

// How the story "..." sheet is actually built (traced by disassembly):
//
//   -[FBSnacksHeaderDefaultComponent didTapMore]
//     -> -[FBSnacksSharedActionHelpers showBottomSheetWithIntentHandler:...]
//     -> -[FBSnacksSettingsBottomSheetActionHandlerV2
//          showSettingsBottomSheetWithBucket:whenClosed:source:...]
//     -> builds a std::vector<FDSControl> -> FDSControlsMenu -> intent
//
// The rows are C++ structs, not Objective-C objects, so there is no array to
// append to from here. There is, however, a set of builder methods each gated by
// a boolean on FBSnacksTrayTileMenuConfiguration — and one of them,
// `shouldShowInlineSnacksDebugOverlay`, is an internal debug flag that is off in
// every production build. Forcing that flag on and replacing its builder yields
// one real row in Facebook's own menu, in Facebook's own styling, without
// touching the underlying C++ vector.
//
// FDSControl is 216 bytes and returned by value (sret). It is never inspected
// here — it is produced by Facebook's own exported converter and passed straight
// back — so an opaque buffer of the right size is enough.
typedef struct { char opaque[216]; } FBPFDSControl;

/// Facebook's exported bridge from an ObjC-constructible object to an FDSControl.
static FBPFDSControl (*FBPControlFromBridge(void))(id) {
    static FBPFDSControl (*converter)(id);
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        converter = (FBPFDSControl (*)(id))dlsym(
            RTLD_DEFAULT, "_Z25FDSControlFromSwiftBridgeP22FDSControl_SwiftBridge");
        if (!converter) FBPLog(@"FDSControlFromSwiftBridge not found");
    });
    return converter;
}

/// YES when everything needed to build a row is available.
static BOOL FBPCanBuildStoryRow(void) {
    BOOL haveClass = objc_getClass("FDSControl_SwiftBridge") != nil;
    BOOL haveConverter = FBPControlFromBridge() != NULL;
    static BOOL reported = NO;
    if (!reported && !(haveClass && haveConverter)) {
        reported = YES;
        [FBPDiagnostics.shared recordEvent:
            @"story: cannot build row (bridge class %@, converter %@)",
            haveClass ? @"yes" : @"NO", haveConverter ? @"yes" : @"NO"];
    }
    return haveClass && haveConverter;
}

/// Whether the mark-as-seen row should be offered in the story menu.
static BOOL FBPStoryRowWanted(void) {
    return FBPEnabled(FBPKeyAnonymousStories);
}

/// Set once the row is actually built, so the fallback button stays out of the way.
static BOOL gStoryRowInstalled = NO;

%group FBPStoryMenu

%hook FBSnacksTrayTileMenuConfiguration

/// Internal debug flag, off in production. Repurposed as the row's slot.
- (BOOL)shouldShowInlineSnacksDebugOverlay {
    if (FBPStoryRowWanted() && FBPCanBuildStoryRow()) return YES;
    return %orig;
}

%end

%hook FBSnacksSettingsBottomSheetActionHandlerV2

- (FBPFDSControl)_inlineSnacksDebugOverlayItem {
    if (!FBPStoryRowWanted() || !FBPCanBuildStoryRow()) return %orig;

    UIViewController *viewer = FBPCurrentStoryViewer();
    if (!viewer) return %orig;

    FBPStoryMenuTarget *target = [[FBPStoryMenuTarget alloc] init];
    target.controller = viewer;
    // The row's block outlives this call, so the target is kept alive by the
    // viewer it acts on.
    objc_setAssociatedObject(viewer, kStoryTargetKey, target,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSString *title  = @"Mark as seen";
    NSString *detail = @"Send the read receipt for this story now.";

    id bridge = [objc_getClass("FDSControl_SwiftBridge") alloc];
    SEL initSel = NSSelectorFromString(
        @"initWithType:headlineText:bodyText:action:onVisibleAction:");
    if (![bridge respondsToSelector:initSel]) return %orig;

    id (*build)(id, SEL, NSUInteger, id, id, id, id) =
        (id (*)(id, SEL, NSUInteger, id, id, id, id))objc_msgSend;
    bridge = build(bridge, initSel, 0, title, detail,
                   ^{ [target markCurrentThreadAsSeen]; },
                   nil);
    if (!bridge) return %orig;

    gStoryRowInstalled = YES;
    [FBPDiagnostics.shared recordEvent:@"story: menu row built"];
    return FBPControlFromBridge()(bridge);
}

%end

%end // FBPStoryMenu

#pragma mark - Fallback button

// If the row above never materialises — the debug slot is gated in a way that is
// not observable here, or FBSharedDynamicFramework never loads — there still has
// to be some way to mark a story as seen. This is that fallback, and it removes
// itself the moment the menu row is confirmed to work.
//
// Position: level with Facebook's own header controls, immediately left of the
// "..." button, where a user already looks for story actions.

static const void *kStoryButtonTargetKey = &kStoryButtonTargetKey;

static void FBPInstallStoryFallbackButton(UIViewController *controller) {
    if (gStoryRowInstalled) return;
    if (!FBPEnabled(FBPKeyAnonymousStories)) return;
    if (!controller.isViewLoaded) return;

    UIView *host = controller.view;
    if (!host || [host viewWithTag:FBPViewTagStoryButton]) return;

    FBPStoryMenuTarget *target = [[FBPStoryMenuTarget alloc] init];
    target.controller = controller;
    objc_setAssociatedObject(controller, kStoryButtonTargetKey, target,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = FBPViewTagStoryButton;
    button.tintColor = UIColor.whiteColor;
    // The tweak's own eye glyph (resources/svg/eye.svg, template-rendered). A plain
    // glyph, not a circled one: Facebook's own "⌄ ⋯ ✕" in this header are bare white
    // symbols, and a filled circle among them would read as out of place.
    [button setImage:[UIImage fbp_imageNamed:@"eye"] forState:UIControlStateNormal];
    button.imageView.contentMode = UIViewContentModeScaleAspectFit;
    // Keep the 38pt tap target but shrink the glyph to match Facebook's own
    // header controls (the "⌄ ⋯ ✕" symbols above it).
    button.contentEdgeInsets = UIEdgeInsetsMake(8, 8, 8, 8);
    // A single dedicated action: tap the eye, confirm, done — no intermediate
    // one-item menu.
    [button addTarget:target
               action:@selector(confirmAndMarkAsSeen)
     forControlEvents:UIControlEventTouchUpInside];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.5;
    button.layer.shadowOffset = CGSizeMake(0, 1);
    button.layer.shadowRadius = 3.0;
    [host addSubview:button];
    [host bringSubviewToFront:button];
    [FBPDiagnostics.shared recordEvent:@"story: fallback button installed"];

    // A second row rather than a fourth slot in the first.
    //
    //     ⌄   ⋯   ✕
    //             ⬇      <- this button, directly under the close button
    //
    // Placing it beside "⋯" crowded a row Facebook already fills, and on a narrow
    // screen it collided with the author's name. Sitting under ✕ keeps it on the
    // same right-hand axis, clear of the other controls, and visually distinct.
    //
    // Measured from a device screenshot (iPhone 13, 390pt wide, 47pt safe-area
    // top): the "⌄ ⋯ ✕" row is centred 41pt below the safe-area top, with ✕
    // centred 24pt in from the right edge.
    static const CGFloat kHeaderRowCentre = 41.0;
    static const CGFloat kCloseCentreFromRight = 24.0;
    static const CGFloat kRowGap = 44.0;
    static const CGFloat kButtonBox = 38.0;

    [NSLayoutConstraint activateConstraints:@[
        [button.centerXAnchor
            constraintEqualToAnchor:host.safeAreaLayoutGuide.trailingAnchor
                           constant:-kCloseCentreFromRight],
        [button.centerYAnchor
            constraintEqualToAnchor:host.safeAreaLayoutGuide.topAnchor
                           constant:kHeaderRowCentre + kRowGap],
        [button.widthAnchor constraintEqualToConstant:kButtonBox],
        [button.heightAnchor constraintEqualToConstant:kButtonBox],
    ]];
}

%group FBPStoryFallback

%hook FBSnacksBucketViewController

- (void)viewDidLayoutSubviews {
    %orig;
    FBPInstallStoryFallbackButton(self);
    [FBPDiagnostics.shared dumpViewTreeOnce:self.view label:@"story viewer"];
}

%end

%end // FBPStoryFallback

#pragma mark - Init

void FBPInitStoryHooks(void) {
    Class seenManager = objc_getClass("FBSnacksBucketsSeenStateManager");
    if (seenManager) {
        if ([seenManager instancesRespondToSelector:FBPMarkSeenModernSelector()]) {
            FBP_ONCE(gSeenModern) { %init(FBPStorySeenModern); }
        [FBPDiagnostics.shared recordGroup:@"FBPStorySeenModern" installed:YES detail:nil];
        } else if ([seenManager instancesRespondToSelector:FBPMarkSeenLegacySelector()]) {
            FBP_ONCE(gSeenLegacy) { %init(FBPStorySeenLegacy); }
        [FBPDiagnostics.shared recordGroup:@"FBPStorySeenLegacy" installed:YES detail:nil];
        } else {
            FBPLog(@"no known _markThreadAsSeen: variant — incognito disabled");
        }
    }

    if (objc_getClass("FBSnacksThreadSwitcherViewController")) {
        FBP_ONCE(gAdvance) { %init(FBPStoryAdvance); }
        [FBPDiagnostics.shared recordGroup:@"FBPStoryAdvance" installed:YES detail:nil];
    }
    if (objc_getClass("FBSnacksTrayTileMenuConfiguration") &&
        objc_getClass("FBSnacksSettingsBottomSheetActionHandlerV2") &&
        objc_getClass("FBSnacksBucketViewController")) {
        FBP_ONCE(gStoryMenu) { %init(FBPStoryMenu); }
        [FBPDiagnostics.shared recordGroup:@"FBPStoryMenu" installed:YES detail:nil];
    } else {
        FBPLog(@"story bottom-sheet classes not found — story menu disabled");
    }

    if (objc_getClass("FBSnacksBucketViewController")) {
        FBP_ONCE(gStoryFallback) { %init(FBPStoryFallback); }
        [FBPDiagnostics.shared recordGroup:@"FBPStoryFallback" installed:YES detail:nil];
    }
}
