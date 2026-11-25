// Removes the affiliate / product-link banner that Facebook pins to the bottom
// of the comment sheet (https://github.com/shajon-dev/Facebook-Plus/issues/3).
//
// When a post's author attaches an affiliate / product link (e.g. a Shopee
// product), Facebook shows a floating CTA — product thumbnail, title, store
// name and an "X" — pinned above the comment composer. It sits in the comment
// stream's *sticky footer*, a region separate from the composer and the comment
// list, and it also appears in the comment sheet opened from Reels. The feed /
// Marketplace ad hooks never touch it: its class names
// (FBCommentStreamOrganicAffiliateFloatingCtaHandlerFragment,
// FBCommentsBFAffiliateLinkComponent) carry no "Ad"/"Sponsored" token, so
// "Remove Ads" leaves it on screen.
//
// FBCommentStreamRootComponentModel drives the sheet. It carries the sticky
// footer as two read-only properties — stickyFooterController and
// stickyFooterStory — set from the matching arguments of its long
// -initWith…stickyFooterController:stickyFooterStory:stickyFooterDelegate:… .
// The root component spec reads those to decide whether to build the
// FBCommentStreamStickyFooterContainerComponent at all; a post with no attached
// link leaves them nil, and the spec already renders that case with no footer
// bar and no reserved gap. Returning nil from both getters therefore puts the
// sheet into a state Facebook's own code produces for an ordinary post, which
// is exactly the issue's suggested direction ("nil out the sticky footer
// controller/story for the comment stream").
//
// The composer (the comment input box) is a different thing entirely — a
// separate composerConfiguration / isComposerHidden pair, with its own
// stickyFooterRequestHide/UnhideCommentComposer callbacks — so it is untouched;
// only the CTA bar goes away.
//
// All of the above was read out of the Objective-C metadata of Facebook
// 587.0.0 (FBCommentStreamRootComponentModel in FBSharedFramework, which is
// linked at launch), not guessed. The group installs only when the class and
// both getters are present, so a rename in a future build leaves this one
// surface unaffected instead of taking the comment sheet down.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPHeaders.h"
#import "FBPTrace.h"

#import <objc/runtime.h>

#pragma mark - Comment composer quick reaction emoji bar

// Facebook mounts a 52pt static emoji strip (❤️ 🙌 🔥 👏 😢 😍 😮 😂,
// accessibilityIdentifier = "static-emoji-banner") directly above the comment
// input row via FBStaticEmojiBannerController in FBSharedFramework. Merely
// setting static-emoji-banner.hidden = YES leaves a 52pt blank dark slot
// because FBCommentComposerWithDrawersComponentView sizes its background container
// to 104.3pt while a bannerProvidingBlock is active.
//
// Preventing FBStaticEmojiBannerController from publishing its banner block (and
// invoking -hideBannerDueToPrimaryBanner, which clears the block on
// FBCommentComposerBannerHostingAnnouncer) makes ComponentKit collapse the
// composer container cleanly from 104.3pt to 52pt with zero empty gap while
// keeping the top hairline border, text box, media button, and '+' button intact.

@protocol FBPStaticEmojiBannerControllerMethods <NSObject>
- (void)hideBannerDueToPrimaryBanner;
- (void)commentComposerComponentDidMount;
@end

static NSHashTable<id> *gEmojiBannerControllers = nil;

static NSObject *FBPEmojiBannerSyncToken(void) {
    static NSObject *token = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ token = [[NSObject alloc] init]; });
    return token;
}

static void FBPTrackEmojiBannerController(id ctrl) {
    if (!ctrl) return;
    @synchronized (FBPEmojiBannerSyncToken()) {
        if (!gEmojiBannerControllers) {
            gEmojiBannerControllers = [NSHashTable weakObjectsHashTable];
        }
        [gEmojiBannerControllers addObject:ctrl];
    }
}

static void FBPApplyEmojiBannerPreferenceLive(void) {
    NSArray *live = nil;
    @synchronized (FBPEmojiBannerSyncToken()) {
        live = gEmojiBannerControllers.allObjects;
    }
    BOOL blockBar = FBPEnabled(FBPKeyNoCommentEmojiBar);
    for (id<FBPStaticEmojiBannerControllerMethods> ctrl in live) {
        if (blockBar) {
            if ([ctrl respondsToSelector:@selector(hideBannerDueToPrimaryBanner)]) {
                [ctrl hideBannerDueToPrimaryBanner];
            }
        } else {
            if ([ctrl respondsToSelector:@selector(commentComposerComponentDidMount)]) {
                [ctrl commentComposerComponentDidMount];
            }
        }
    }
}

%group FBPCommentEmojiBanner

%hook FBStaticEmojiBannerController

- (id)initWithBannerDelegate:(id)bannerDelegate
               guideDelegate:(id)guideDelegate
       navigationCoordinator:(id)navigationCoordinator
                     session:(id)session
                   sessionId:(id)sessionId
                      logger:(id)logger {
    id instance = %orig;
    if (instance) {
        FBPTrackEmojiBannerController(instance);
    }
    return instance;
}

- (void)commentComposerComponentDidMount {
    FBPTrackEmojiBannerController(self);
    if (FBPEnabled(FBPKeyNoCommentEmojiBar)) {
        FBPTraceFire("comments.FBStaticEmojiBannerController.didMount.suppressed");
        if ([self respondsToSelector:@selector(hideBannerDueToPrimaryBanner)]) {
            [(id<FBPStaticEmojiBannerControllerMethods>)self hideBannerDueToPrimaryBanner];
        }
        return;
    }
    %orig;
}

- (void)showBannerIfValidWithComposerState:(id)state {
    FBPTrackEmojiBannerController(self);
    if (FBPEnabled(FBPKeyNoCommentEmojiBar)) {
        FBPTraceFire("comments.FBStaticEmojiBannerController.showBanner.suppressed");
        if ([self respondsToSelector:@selector(hideBannerDueToPrimaryBanner)]) {
            [(id<FBPStaticEmojiBannerControllerMethods>)self hideBannerDueToPrimaryBanner];
        }
        return;
    }
    %orig;
}

- (BOOL)shouldHideComposerViewTopBorder {
    if (FBPEnabled(FBPKeyNoCommentEmojiBar)) {
        return NO;
    }
    return %orig;
}

- (id)_bannerProvidingBlock {
    if (FBPEnabled(FBPKeyNoCommentEmojiBar)) {
        return nil;
    }
    return %orig;
}

%end

%end // FBPCommentEmojiBanner

#pragma mark - Comment-stream sticky footer (affiliate / product banner)

%group FBPCommentProductBanner

%hook FBCommentStreamRootComponentModel

- (id)stickyFooterController {
    FBPTraceFire("comments.FBCommentStreamRootComponentModel.stickyFooterController");
    // nil is the "no footer for this post" value Facebook already sets for a post
    // with no attached link, so the sheet renders exactly as it does there.
    if (FBPEnabled(FBPKeyNoCommentProductBanner)) return nil;
    return %orig;
}

- (id)stickyFooterStory {
    FBPTraceFire("comments.FBCommentStreamRootComponentModel.stickyFooterStory");
    if (FBPEnabled(FBPKeyNoCommentProductBanner)) return nil;
    return %orig;
}

%end

%end // FBPCommentProductBanner

#pragma mark - Reels creator-storefront product tag

// The same affiliate CTA also appears as an in-video product card ON a Reel (a
// creator-storefront product tag: thumbnail, title, store name, "commission
// eligible") — a surface separate from the comment sheet above, so the comment
// hook never touched it. It is built from a Swift class,
// FBShortsCreatorStorefrontProductTagResolver, whose @objc gate
// +hasAnyPayloadWithFragment: answers whether a Reel carries a tag. Answering NO
// is the state the app already renders for every untagged Reel, so the card is
// never built — no empty slot, no reserved gap. Bound to the resolved Swift
// runtime class in %init. Gated on the same toggle as the comment banner, since
// to the user both are "the product/affiliate banner".
%group FBPReelsProductTag

%hook FBPShortsProductTagResolver

+ (BOOL)hasAnyPayloadWithFragment:(id)fragment {
    if (FBPEnabled(FBPKeyNoCommentProductBanner)) {
        FBPTraceFire("reels.CreatorStorefrontProductTag.hasAnyPayload.suppressed");
        return NO;
    }
    return %orig;
}

%end

%end // FBPReelsProductTag

#pragma mark - Page video post affiliate / product banner (Issue #13)

// Video posts on Pages marked "Commission eligible" show a product banner directly
// under the video (thumbnail + title + store name, e.g. Shopee). Tapping it opens
// the Shopee app through an affiliate tracking link (https://github.com/shajon-dev/Facebook-Plus/issues/13).
//
// 1. View level: An FDSTouchStateComponentView whose accessibilityLabel or
//    accessibilityIdentifier is "fig-card-content-landscape-attachment" and has a
//    video sibling (FBVideoPlaybackContainerView / FBVideoPlayerComponentStatefulView)
//    is hidden and tagged (0x424B4E52L). Subsequent calls to setHidden:NO are dropped
//    while tagged, preventing ComponentKit from un-hiding it after mounting.
// 2. Layout level: FDSTouchStateComponent receives an override of
//    -computeLayoutThatFits:restrictedToSize:relativeToParentSize: via class_addMethod.
//    An arm64 trampoline preserves the struct-return register (x8), calls the superclass
//    layout IMP, and zeroes size.height (offset 16) if the component/layout tree contains
//    a "Bloks" component and no video/media/photo/image/player component, collapsing the 56pt gap.

#define FBP_BANNER_LABEL "fig-card-content-landscape-attachment"
#define FBP_BANNER_TAG_MAGIC ((NSInteger)0x424B4E52L)

static BOOL FBPHasClass(id view, const char *name, int depth) {
    if (!view || depth > 16) return NO;
    if (strcmp(object_getClassName(view), name) == 0) return YES;
    if ([view respondsToSelector:@selector(subviews)]) {
        for (id sub in [view subviews]) {
            if (FBPHasClass(sub, name, depth + 1)) return YES;
        }
    }
    return NO;
}

static BOOL FBPIsVideoFooter(UIView *view) {
    UIView *sup = view.superview;
    if (!sup) return NO;
    for (UIView *sv in sup.subviews) {
        if (sv == view) continue;
        if (FBPHasClass(sv, "FBVideoPlaybackContainerView", 0) ||
            FBPHasClass(sv, "FBVideoPlayerComponentStatefulView", 0)) {
            return YES;
        }
    }
    return NO;
}

static void FBPProcessVideoBannerView(UIView *view) {
    if (!FBPEnabled(FBPKeyNoCommentProductBanner)) return;
    if (strcmp(object_getClassName(view), "FDSTouchStateComponentView") != 0) return;

    NSString *al = view.accessibilityLabel;
    NSString *ai = view.accessibilityIdentifier;
    BOOL isTarget = (al && [al isEqualToString:@FBP_BANNER_LABEL]) ||
                    (ai && [ai isEqualToString:@FBP_BANNER_LABEL]);
    BOOL want = isTarget && FBPIsVideoFooter(view);
    NSInteger tag = view.tag;

    if (want) {
        if (!view.isHidden) {
            view.hidden = YES;
            FBPTraceFire("comments.videoProductBanner.view.suppressed");
        }
        if (tag != FBP_BANNER_TAG_MAGIC) {
            view.tag = FBP_BANNER_TAG_MAGIC;
        }
    } else if (tag == FBP_BANNER_TAG_MAGIC) {
        view.tag = 0;
        view.hidden = NO;
    }
}

%group FBPVideoProductBanner

%hook FDSTouchStateComponentView

- (void)didMoveToWindow {
    %orig;
    FBPProcessVideoBannerView(self);
}

- (void)didMoveToSuperview {
    %orig;
    FBPProcessVideoBannerView(self);
}

- (void)layoutSubviews {
    %orig;
    FBPProcessVideoBannerView(self);
}

- (void)setHidden:(BOOL)hidden {
    if (!hidden && [(UIView *)self tag] == FBP_BANNER_TAG_MAGIC && FBPEnabled(FBPKeyNoCommentProductBanner)) {
        return;
    }
    %orig(hidden);
}

%end

%end // FBPVideoProductBanner

static int gFBPWalkFlags = 0;

static BOOL FBPContainsCaseInsensitive(const char *s, const char *pat) {
    if (!s || !pat) return NO;
    for (; *s; s++) {
        const char *a = s, *b = pat;
        while (*a && *b && ((*a | 32) == (*b | 32))) { a++; b++; }
        if (!*b) return YES;
    }
    return NO;
}

static void FBPClassify(const char *cn) {
    if (!cn) return;
    if (FBPContainsCaseInsensitive(cn, "bloks")) gFBPWalkFlags |= 1;
    if (FBPContainsCaseInsensitive(cn, "video") ||
        FBPContainsCaseInsensitive(cn, "media") ||
        FBPContainsCaseInsensitive(cn, "photo") ||
        FBPContainsCaseInsensitive(cn, "image") ||
        FBPContainsCaseInsensitive(cn, "player")) {
        gFBPWalkFlags |= 2;
    }
}

static void FBPWalkComponents(id c, int depth) {
    if (!c || depth > 9) return;
    FBPClassify(object_getClassName(c));
    SEL selCount = @selector(numberOfChildren);
    SEL selChild = @selector(childAtIndex:);
    if (![c respondsToSelector:selCount] || ![c respondsToSelector:selChild]) return;

    typedef unsigned long (*FBPCountFn)(id, SEL);
    typedef id (*FBPChildFn)(id, SEL, unsigned long);

    FBPCountFn countFn = (FBPCountFn)[c methodForSelector:selCount];
    unsigned long n = countFn ? countFn(c, selCount) : 0;
    if (n > 8) n = 8;
    FBPChildFn childFn = (FBPChildFn)[c methodForSelector:selChild];
    if (childFn) {
        for (unsigned long i = 0; i < n; i++) {
            FBPWalkComponents(childFn(c, selChild, i), depth + 1);
        }
    }
}

static inline BOOL FBPPlausiblePtr(void *p) {
    uintptr_t u = (uintptr_t)p;
    return u > 0x100000000ULL && u < 0x800000000000ULL && !(u & 7);
}

static void FBPWalkLayout(char *l, int depth) {
    if (!l || depth > 10) return;
    void *compPtr = *(void **)l;
    if (FBPPlausiblePtr(compPtr)) {
        id comp = (__bridge id)compPtr;
        FBPClassify(object_getClassName(comp));
    }
    void *vec = *(void **)(l + 24);
    if (!FBPPlausiblePtr(vec)) return;
    char *b = *(char **)vec;
    char *e = *(char **)((char *)vec + 8);
    if (!FBPPlausiblePtr(b) || !FBPPlausiblePtr(e) || e < b) return;
    uintptr_t bytes = (uintptr_t)(e - b);
    if (bytes % 64 || bytes / 64 > 64) return;
    for (uintptr_t i = 0; i < bytes / 64; i++) {
        FBPWalkLayout(b + i * 64 + 16, depth + 1);
    }
}

#if defined(__arm64__) || defined(__aarch64__)
void *gFBPSuperLayoutIMP __attribute__((used)) = NULL;

// extern "C" is load-bearing, not decoration. Logos compiles every .xm as
// Objective-C++, so without it this gets a C++-mangled symbol while the
// assembly below calls plain `_FBPFdsDecide`, and the link fails with
// "Undefined symbols: _FBPFdsDecide, referenced from _FBPLayoutTrampoline".
// gFBPSuperLayoutIMP needs no such thing: C++ leaves a file-scope variable's
// symbol unmangled, which is why the linker names only the two functions.
extern "C" __attribute__((used)) int FBPFdsDecide(id self, char *sret) {
    if (!FBPEnabled(FBPKeyNoCommentProductBanner)) return 0;
    int f;
    gFBPWalkFlags = 0; FBPWalkComponents(self, 0); f = gFBPWalkFlags;
    gFBPWalkFlags = 0; FBPWalkLayout(sret, 0);     f |= gFBPWalkFlags;
    int shouldCollapse = (f & 1) && !(f & 2);
    if (shouldCollapse) {
        FBPTraceFire("comments.videoProductBanner.layout.collapsed");
    }
    return shouldCollapse;
}

__asm__(
    ".text\n.align 2\n.globl _FBPLayoutTrampoline\n_FBPLayoutTrampoline:\n"
    "stp x29,x30,[sp,#-32]!\n"
    "stp x19,x20,[sp,#16]\n"
    "mov x29,sp\n"
    "mov x19,x8\n"
    "mov x20,x0\n"
    "adrp x9,_gFBPSuperLayoutIMP@PAGE\n"
    "ldr x9,[x9,_gFBPSuperLayoutIMP@PAGEOFF]\n"
    "blr x9\n"
    "mov x0,x20\n"
    "mov x1,x19\n"
    "bl _FBPFdsDecide\n"
    "cbz w0,1f\n"
    "str xzr,[x19,#16]\n"
    "1:\n"
    "ldp x19,x20,[sp,#16]\n"
    "ldp x29,x30,[sp],#32\n"
    "ret\n"
);
// Same reason as FBPFdsDecide above: the symbol the assembly defines is
// `_FBPLayoutTrampoline`, so the declaration that takes its address has to ask
// for C linkage or it looks for a mangled name that nothing defines.
extern "C" void FBPLayoutTrampoline(void);
#endif

#pragma mark - Init

void FBPInitCommentHooks(void) {
    // FBSharedFramework is linked at launch, so this normally latches on the
    // first pass; the installer is still re-run from the dyld image-load
    // callback (see FBPEntry.xm) and FBP_ONCE keeps it to a single install.
    Class model = objc_getClass("FBCommentStreamRootComponentModel");
    if (model &&
        [model instancesRespondToSelector:@selector(stickyFooterController)] &&
        [model instancesRespondToSelector:@selector(stickyFooterStory)]) {
        FBP_ONCE(gCommentProductBanner) { %init(FBPCommentProductBanner); }
    } else {
        FBPLogOnce(@"FBCommentStreamRootComponentModel sticky-footer getters not found — comment product banner not hidden");
    }

    // The same affiliate card ON a Reel is a separate, Swift-backed surface.
    Class resolver =
        NSClassFromString(@"_TtC43FBShortsCreatorStorefrontProductTagResolver43FBShortsCreatorStorefrontProductTagResolver")
        ?: objc_getClass("FBShortsCreatorStorefrontProductTagResolver");
    if (resolver && [resolver respondsToSelector:@selector(hasAnyPayloadWithFragment:)]) {
        FBP_ONCE(gReelsProductTag) { %init(FBPReelsProductTag, FBPShortsProductTagResolver = resolver); }
        FBPLogOnce(@"reels: creator-storefront product-tag gate installed");
    } else {
        FBPLog(@"reels: FBShortsCreatorStorefrontProductTagResolver not found");
    }

    // Video post affiliate/product banner layout collapse (Issue #13).
#if defined(__arm64__) || defined(__aarch64__)
    static BOOL gVideoProductLayoutInstalled = NO;
    if (!gVideoProductLayoutInstalled) {
        Class comp = objc_getClass("FDSTouchStateComponent");
        if (comp) {
            Class sup = class_getSuperclass(comp);
            SEL ls = @selector(computeLayoutThatFits:restrictedToSize:relativeToParentSize:);
            Method sm = sup ? class_getInstanceMethod(sup, ls) : NULL;
            if (sm) {
                gFBPSuperLayoutIMP = (void *)method_getImplementation(sm);
                if (class_addMethod(comp, ls, (IMP)FBPLayoutTrampoline, "v@:")) {
                    gVideoProductLayoutInstalled = YES;
                    FBPLogOnce(@"comments: FDSTouchStateComponent layout collapse installed");
                }
            }
        }
    }
#endif

    // Video post affiliate/product banner view hiding (Issue #13).
    Class touchView = objc_getClass("FDSTouchStateComponentView");
    if (touchView) {
        FBP_ONCE(gVideoProductBanner) {
            %init(FBPVideoProductBanner, FDSTouchStateComponentView = touchView);
            FBPLogOnce(@"comments: FDSTouchStateComponentView banner killer installed");
        }
    }

    // Comment composer quick-reaction emoji bar suppression.
    Class emojiCtrl = objc_getClass("FBStaticEmojiBannerController");
    if (emojiCtrl &&
        [emojiCtrl instancesRespondToSelector:@selector(showBannerIfValidWithComposerState:)] &&
        [emojiCtrl instancesRespondToSelector:@selector(hideBannerDueToPrimaryBanner)]) {
        FBP_ONCE(gCommentEmojiBanner) {
            %init(FBPCommentEmojiBanner);
            [NSNotificationCenter.defaultCenter
                addObserverForName:FBPSettingsDidChangeNotification
                            object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(__unused NSNotification *note) {
                FBPApplyEmojiBannerPreferenceLive();
            }];
            FBPLogOnce(@"comments: FBStaticEmojiBannerController quick-emoji blocker installed");
        }
    } else {
        FBPLogOnce(@"comments: FBStaticEmojiBannerController not found — quick emoji bar not hidden");
    }
}
