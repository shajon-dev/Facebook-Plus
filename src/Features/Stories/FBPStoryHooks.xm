// Stories: incognito viewing, manual mark-as-seen, no auto-advance, and
// removal of the tray at the top of News Feed.

#import "FBPlus.h"
#import "FBPAlert.h"
#import "FBPPrefs.h"
#import "FBPHeaders.h"
#import "FBPTrace.h"
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
    FBPTraceFire("story.FBSnacksBucketsSeenStateManager.markThreadAsSeen.modern");
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
    FBPTraceFire("story.FBSnacksBucketsSeenStateManager.markThreadAsSeen.legacy");
    if (FBPEnabled(FBPKeyAnonymousStories) && !gAllowSeenPassthrough) return;
    %orig;
}

%end

%end // FBPStorySeenLegacy

#pragma mark - Incognito (server receipt)

// The receipt that tells the author "you viewed this" is sent by
// FBSnacksUnifiedSeenStateMutator, which the impression tracker can drive
// directly: blocking only the seen-state manager still let views register, so
// the mutator's two public send entry points are blocked here too, so
// no receipt leaves the device whichever path triggered it.
//
// Both are fire-and-forget void methods, so returning early leaves nothing
// dangling. The manual "mark as seen" sets gAllowSeenPassthrough and the
// manager forwards on the same stack, so that one receipt still flows.

%group FBPStorySeenMutator

%hook FBSnacksUnifiedSeenStateMutator

- (void)markUnifiedThreadsAsSeenForBucket:(id)threads
                                   bucket:(id)bucket
                         idempotenceToken:(id)token {
    FBPTraceFire("story.FBSnacksUnifiedSeenStateMutator.markForBucket");
    if (FBPEnabled(FBPKeyAnonymousStories) && !gAllowSeenPassthrough) return;
    %orig;
}

- (void)markUnifiedThreadsAsSeenForViewerSession:(id)session
                                idempotenceToken:(id)token
                      bucketToStoryCardIdFilters:(id)filters {
    FBPTraceFire("story.FBSnacksUnifiedSeenStateMutator.markForViewerSession");
    if (FBPEnabled(FBPKeyAnonymousStories) && !gAllowSeenPassthrough) return;
    %orig;
}

%end

%end // FBPStorySeenMutator

#pragma mark - Auto-advance

%group FBPStoryAdvance

%hook FBSnacksBucketViewController

/// The media view's completion delegate is what advances a story, so no-oping
/// it stops every automatic advance and leaves manual navigation alone: a tap
/// goes through navigateToNextItem and a swipe through the bucket displayer's
/// own scroll. The app already no-ops this delegate on several paths of its
/// own, so holding on the last frame is a state it is built to handle.
///
/// FBSnacksThreadSwitcherViewController does not implement it, so hooking that
/// class only added a dead method and auto-advance kept running.
- (void)mediaViewDidPlayToEnd:(id)mediaView {
    FBPTraceFire("story.FBSnacksBucketViewController.mediaViewDidPlayToEnd");
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
    __weak typeof(self) weakSelf = self;
    [FBPAlert showWithTitle:@"Mark as seen"
                    message:@"Send the read receipt for this story now?"
                cancelTitle:FBPL(@"common.cancel")
               confirmTitle:@"Mark as seen"
                destructive:NO
                  onConfirm:^{ [weakSelf markCurrentThreadAsSeen]; }
                   onCancel:nil];
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

// The sheet's rows are C++ structs built into a std::vector<FDSControl>, so
// there is no array to append to. Each builder is gated by a boolean on
// FBSnacksTrayTileMenuConfiguration, and shouldShowInlineSnacksDebugOverlay is
// an internal debug flag off in every production build: forcing it on and
// replacing its builder yields a real row in Facebook's own styling.
//
// FDSControl is 216 bytes, returned by value and never inspected here, so an
// opaque buffer of the right size is enough.
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
    FBPTraceFire("story.FBSnacksTrayTileMenuConfiguration.shouldShowInlineSnacksDebugOverlay");
    if (FBPStoryRowWanted() && FBPCanBuildStoryRow()) return YES;
    return %orig;
}

%end

%hook FBSnacksSettingsBottomSheetActionHandlerV2

- (FBPFDSControl)_inlineSnacksDebugOverlayItem {
    FBPTraceFire("story.FBSnacksSettingsBottomSheetActionHandlerV2.inlineSnacksDebugOverlayItem");
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

    // A second row, directly under the close button: beside "..." it crowded a
    // row Facebook already fills and collided with the author's name on a
    // narrow screen. Measured on a 390pt screen with a 47pt safe-area top, the
    // header row is centred 41pt below it with the glyph 24pt in from the right.
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
    FBPTraceFire("story.FBSnacksBucketViewController.viewDidLayoutSubviews");
    %orig;
    FBPInstallStoryFallbackButton(self);
}

%end

%end // FBPStoryFallback

#pragma mark - Stories tray (News Feed)

// The News Feed story tray is a ComponentKit *section* of the feed's own data
// source, not a feed unit and not a view that can be hidden.
// FBInlineSnacksSectionComponent is the factory that builds it, and refusing to
// build it is what removes it. Sizing its cell to zero instead keeps the
// section in the data source and lies to the layout about an item it has
// already measured, which is how the feed gets wedged.
//
// Which of the feed's story modules runs is decided per session, so one
// refusal is not enough: the story section is refused outright, while the
// shared top-of-feed section carries other modules and only loses its tray.

%group FBPStoryTray

%hook FBInlineSnacksSectionComponent

+ (id)newWithSession:(id)session
    inlineSnacksController:(id)controller
              initialModel:(id)model {
    FBPTraceFire("story.FBInlineSnacksSectionComponent.newWithSession");
    if (FBPEnabled(FBPKeyNoMainStories)) return nil;
    return %orig;
}

%end

%end // FBPStoryTray

%group FBPStoryTrayRender

%hook FBInlineSnacksRenderSectionComponent

/// The newer wrapper around the section above. Its whole body is a send of that
/// factory, so refusing here is the same refusal one step earlier, and the row
/// survives the older half being retired.
- (id)render:(id)state {
    FBPTraceFire("story.FBInlineSnacksRenderSectionComponent.render");
    if (FBPEnabled(FBPKeyNoMainStories)) return nil;
    return %orig;
}

%end

%end // FBPStoryTrayRender

#pragma mark - Stories tray (shared top-of-feed section)

/// Non-zero while this thread is inside the shared top-of-feed section's build.
static __thread NSUInteger gTopOfFeedDepth = 0;

%group FBPStoryTrayTopOfFeed

%hook FBUnifiedTofuSection_Spec

- (id)render:(id)state {
    FBPTraceFire("story.FBUnifiedTofuSection_Spec.render");
    if (!FBPEnabled(FBPKeyNoMainStories)) return %orig;
    gTopOfFeedDepth++;
    // A depth left raised would refuse trays on surfaces this row does not cover.
    @try {
        return %orig;
    } @finally {
        gTopOfFeedDepth--;
    }
}

%end

%hook FBSnacksTrayCollectionComponent

/// Every snacks surface draws its tray with this one component, the Reels tab
/// among them, so the refusal is armed only for the section above: ComponentKit
/// builds a section's children inside that section's own -render:, on the
/// calling thread. @c options is a C++ struct pointer and is only forwarded.
+ (id)newWithModel:(id)model
           options:(const void *)options
           toolbox:(id)toolbox
thumbnailImageProvider:(id)provider {
    FBPTraceFire("story.FBSnacksTrayCollectionComponent.newWithModel");
    if (gTopOfFeedDepth > 0 && FBPEnabled(FBPKeyNoMainStories)) {
        FBPTraceFire("story.FBSnacksTrayCollectionComponent.refused");
        return nil;
    }
    return %orig;
}

%end

%end // FBPStoryTrayTopOfFeed

#pragma mark - Init

void FBPInitStoryHooks(void) {
    Class seenManager = objc_getClass("FBSnacksBucketsSeenStateManager");
    if (seenManager) {
        if ([seenManager instancesRespondToSelector:FBPMarkSeenModernSelector()]) {
            FBP_ONCE(gSeenModern) { %init(FBPStorySeenModern); }
        } else if ([seenManager instancesRespondToSelector:FBPMarkSeenLegacySelector()]) {
            FBP_ONCE(gSeenLegacy) { %init(FBPStorySeenLegacy); }
        } else {
            FBPLogOnce(@"no known _markThreadAsSeen: variant — incognito disabled");
        }
    }

    // The actual server-receipt chokepoint. Installed alongside the manager hook,
    // not instead of it: the manager still gates the manual "mark as seen", while
    // this closes the tracker-driven path that left views registering anyway.
    Class seenMutator = objc_getClass("FBSnacksUnifiedSeenStateMutator");
    if (seenMutator &&
        [seenMutator instancesRespondToSelector:
            @selector(markUnifiedThreadsAsSeenForBucket:bucket:idempotenceToken:)]) {
        FBP_ONCE(gSeenMutator) { %init(FBPStorySeenMutator); }
    } else {
        FBPLogOnce(@"FBSnacksUnifiedSeenStateMutator send methods not found — "
               @"story seen receipt may not be fully suppressed");
    }

    Class bucketVC = objc_getClass("FBSnacksBucketViewController");
    if (bucketVC && [bucketVC instancesRespondToSelector:@selector(mediaViewDidPlayToEnd:)]) {
        FBP_ONCE(gAdvance) { %init(FBPStoryAdvance); }
    } else {
        FBPLogOnce(@"story: FBSnacksBucketViewController mediaViewDidPlayToEnd: not found — "
               @"auto-advance block inactive");
    }
    if (objc_getClass("FBSnacksTrayTileMenuConfiguration") &&
        objc_getClass("FBSnacksSettingsBottomSheetActionHandlerV2") &&
        objc_getClass("FBSnacksBucketViewController")) {
        FBP_ONCE(gStoryMenu) { %init(FBPStoryMenu); }
    } else {
        FBPLogOnce(@"story bottom-sheet classes not found — story menu disabled");
    }

    if (objc_getClass("FBSnacksBucketViewController")) {
        FBP_ONCE(gStoryFallback) { %init(FBPStoryFallback); }
    }

    // The section components only exist once the feed stack is up, so these are
    // latched like the others. Each factory is checked as well as its class:
    // hooking a selector a class has lost adds an override nothing calls.
    Class snacksSection = objc_getClass("FBInlineSnacksSectionComponent");
    SEL sectionFactory =
        NSSelectorFromString(@"newWithSession:inlineSnacksController:initialModel:");
    if (snacksSection && [snacksSection respondsToSelector:sectionFactory]) {
        FBP_ONCE(gStoryTray) { %init(FBPStoryTray); }
    } else {
        FBPLogOnce(@"FBInlineSnacksSectionComponent factory not found — "
               @"stories tray stays");
    }

    Class renderSection = objc_getClass("FBInlineSnacksRenderSectionComponent");
    if (renderSection && [renderSection instancesRespondToSelector:@selector(render:)]) {
        FBP_ONCE(gStoryTrayRender) { %init(FBPStoryTrayRender); }
    } else {
        FBPLogOnce(@"FBInlineSnacksRenderSectionComponent render: not found — "
               @"the story section is refused at its factory only");
    }

    Class topOfFeedSection = objc_getClass("FBUnifiedTofuSection_Spec");
    Class trayComponent = objc_getClass("FBSnacksTrayCollectionComponent");
    SEL trayFactory =
        NSSelectorFromString(@"newWithModel:options:toolbox:thumbnailImageProvider:");
    if (topOfFeedSection &&
        [topOfFeedSection instancesRespondToSelector:@selector(render:)] &&
        trayComponent && [trayComponent respondsToSelector:trayFactory]) {
        FBP_ONCE(gStoryTrayTopOfFeed) { %init(FBPStoryTrayTopOfFeed); }
    } else {
        FBPLogOnce(@"top-of-feed tray classes not found — the tray in the "
               @"shared section stays");
    }
}
