#import "FBPlus.h"
#import "FBPHeaders.h"
#import "FBPPrefs.h"
#import "FBPResources.h"
#import "FBPDownloadVariants.h"
#import "FBPDashDownload.h"
#import "FBPDownloadStore.h"
#import "FBPDownloadManagerController.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <stdint.h>
#import <string.h>
#import <math.h>

#pragma mark - Globals

static void (*gOriginalDidStartPlayback)(
    id, SEL, id, int64_t, id, id
) = NULL;

static void (*gOriginalSidebarDidMoveToWindow)(
    id, SEL
) = NULL;

static void (*gOriginalPlayerViewWillAppear)(
    id, SEL, BOOL
) = NULL;

static void (*gOriginalPlayerViewDidDisappear)(
    id, SEL, BOOL
) = NULL;

// Every rendition the current video can be saved in, best first — not a single
// chosen URL. The choice is the user's, and it is made at tap time, because
// these are short-lived signed CDN URLs (an `oe=` hex expiry) and a picker sheet
// can sit open while the user deliberates. See -downloadButtonPressed:.
static NSArray<FBPDownloadVariant *> *gCurrentVariants = nil;
static NSString *gCurrentVideoID = nil;

// The same video's id as read off the playback *item* (-videoID), kept beside
// gCurrentVideoID — which prefers the id the didStartPlayback hook was handed,
// and is what names the saved file. Tap-time re-resolution compares its live
// read against this one so both sides of the comparison come from the same
// accessor; comparing against the hook argument would risk a format mismatch
// that silently rejected every refresh.
static NSString *gCurrentItemVideoID = nil;

static void (*gOriginalHitTestLayoutSubviews)(
    id, SEL
) = NULL;

static BOOL gPlayerHookInstalled = NO;
static BOOL gSidebarHookInstalled = NO;
static BOOL gLifecycleHooksInstalled = NO;
static BOOL gHitTestHookInstalled = NO;

static __weak id gMediaOwnerPlayerVC = nil;

static const NSInteger kFBPDownloadButtonTag =
    0x46425044;

static const NSInteger kFBPHideOverlayButtonTag =
    0x46425048;

// Vertical gap between the download button and the hide-overlay toggle stacked
// above it.
static const CGFloat kFBPButtonGap = 10.0;

static NSHashTable<UIView *> *gSidebars = nil;

#pragma mark - Hide-overlay state

// Session-only "cinema mode": while YES, every Reel's chrome (gradients,
// caption, author, and the whole like/comment/share/save/more sidebar) is
// hidden, leaving only the video plus our own download + toggle buttons. The
// user turns it on/off with the eye toggle; it persists across reel swipes
// until they untoggle, and resets to shown on relaunch.
static BOOL gOverlayHidden = NO;

// The overlay container views we have hidden, held weakly so recycled
// ComponentKit views don't keep us alive. Used to restore them on untoggle.
static NSHashTable<UIView *> *gHiddenOverlays = nil;

// Marks a view as hidden by us (not by Facebook) so the sidebar-visibility
// check can tell "the reel left the screen" apart from "we stripped its chrome".
static const void *kFBPHiddenByUsKey = &kFBPHiddenByUsKey;

static BOOL FBPViewHiddenByUs(UIView *view) {
    return [objc_getAssociatedObject(view, kFBPHiddenByUsKey) boolValue];
}

static void FBPSetViewHiddenByUs(UIView *view, BOOL hidden) {
    objc_setAssociatedObject(
        view,
        kFBPHiddenByUsKey,
        hidden ? @YES : nil,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );
}

// Walk up from a sidebar to the Shorts overlay container that holds every chrome
// element. Matched by class-name substring because it is a Swift class whose
// mangled ObjC name is not stable to hardcode. The video is rendered by an
// ancestor OUTSIDE this view, so hiding it never touches the video.
static UIView *FBPOverlayForSidebar(UIView *sidebar) {
    UIView *view = sidebar;
    while (view) {
        if ([NSStringFromClass([view class])
                containsString:@"ShortsViewerOverlay"]) {
            return view;
        }
        view = view.superview;
    }
    return nil;
}

// Hide the overlay container of every Reel currently laid out in this window.
// Re-run each frame so a reel swiped in while hide-mode is on is stripped too.
static void FBPHideOverlaysForWindow(UIWindow *window) {
    if (!window || !gSidebars)
        return;

    if (!gHiddenOverlays)
        gHiddenOverlays = [NSHashTable weakObjectsHashTable];

    for (UIView *sidebar in gSidebars.allObjects) {
        if (sidebar.window != window)
            continue;

        UIView *overlay = FBPOverlayForSidebar(sidebar);
        if (!overlay)
            continue;

        if (!overlay.hidden)
            overlay.hidden = YES;

        FBPSetViewHiddenByUs(overlay, YES);
        [gHiddenOverlays addObject:overlay];
    }
}

// Hide the Shorts overlay component(s) parented by a given container (the
// hit-test view). Used from the synchronous layout hook so a reel swiped in is
// stripped in the same layout pass Facebook re-shows it — no one-frame flash.
static void FBPHideOverlayChildrenOf(UIView *container) {
    if (!container)
        return;

    if (!gHiddenOverlays)
        gHiddenOverlays = [NSHashTable weakObjectsHashTable];

    for (UIView *sub in container.subviews) {
        if (![NSStringFromClass([sub class])
                containsString:@"ShortsViewerOverlay"])
            continue;

        if (!sub.hidden)
            sub.hidden = YES;

        FBPSetViewHiddenByUs(sub, YES);
        [gHiddenOverlays addObject:sub];
    }
}

// Restore every overlay we hid and forget them.
static void FBPUnhideAllOverlays(void) {
    if (!gHiddenOverlays)
        return;

    for (UIView *overlay in gHiddenOverlays.allObjects) {
        if (!overlay)
            continue;
        FBPSetViewHiddenByUs(overlay, NO);
        overlay.hidden = NO;
    }

    [gHiddenOverlays removeAllObjects];
}

#pragma mark - Tab bar (cinema mode)

// While cinema mode is on, the bottom tab bar is faded out along with the rest of
// the Reels chrome, then restored on untoggle or on leaving Reels. Held strongly
// only while hidden so we can always restore their alpha; cleared on restore.
static NSMutableSet<UIView *> *gHiddenTabBars = nil;

// Every view that makes up the bottom tab bar's chrome — the icon rows AND the
// separate background/material/safe-area fills behind them — matched by exact
// class so content is never touched. Hiding only the icon row left the glass
// background (FBFloatingTabBarContainerMaterial) as a visible placeholder, so the
// whole set is listed. "…AndContentView" is deliberately absent: it wraps the
// entire screen, not just the bar. Covers the classic bar and the iOS 26
// liquid-glass bars (floating / native).
static BOOL FBPIsTabBarContainer(UIView *view) {
    static NSSet<NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = [NSSet setWithArray:@[
            @"FBTabBarContainerView", @"FBTabBarFloatableContainerView",
            @"FBTabBarSafeAreaProtectionView", @"FBTabBarVideoSamplingView",
            @"FBTabBarVideoSamplingBlurView", @"FBTabBarTransitionView", @"FBTabBar",
            @"FBFloatingTabBar", @"FBFloatingTabBarContainerMaterial",
            @"FBFloatingTabBarItemView", @"FBNativeTabBar",
        ]];
    });
    return [names containsObject:NSStringFromClass(view.class)];
}

// Walk the whole window tree, collecting every tab-bar chrome view (icons and
// backgrounds may be siblings, so we don't stop at the first match).
static void FBPCollectTabBars(UIView *root, NSMutableArray<UIView *> *out, NSInteger depth) {
    if (!root || depth > 80) return;
    if (FBPIsTabBarContainer(root)) [out addObject:root];
    for (UIView *sub in root.subviews) FBPCollectTabBars(sub, out, depth + 1);
}

// Fade the window's tab bar(s) out and remember them.
static void FBPHideTabBars(UIWindow *window) {
    if (!window) return;
    if (!gHiddenTabBars) gHiddenTabBars = [NSMutableSet set];
    NSMutableArray<UIView *> *bars = [NSMutableArray array];
    FBPCollectTabBars(window, bars, 0);
    for (UIView *bar in bars) {
        [gHiddenTabBars addObject:bar];
        bar.userInteractionEnabled = NO;
        bar.alpha = 0.0;
    }
}

// Cheap per-frame top-up: keep already-found bars faded without re-walking the
// tree (Facebook's own scroll-driven offset animations don't touch alpha, so one
// search per enter is enough, but this guards against a stray reset).
static void FBPReassertHiddenTabBars(void) {
    if (!gHiddenTabBars) return;
    for (UIView *bar in gHiddenTabBars) {
        if (bar.window && bar.alpha > 0.01) bar.alpha = 0.0;
    }
}

// Restore every tab bar we faded and forget them.
static void FBPShowTabBars(void) {
    if (!gHiddenTabBars || gHiddenTabBars.count == 0) return;
    for (UIView *bar in gHiddenTabBars) {
        bar.alpha = 1.0;
        bar.userInteractionEnabled = YES;
    }
    [gHiddenTabBars removeAllObjects];
}

#pragma mark - Runtime helpers

// The guarded zero-argument object getter this file has always used, now shared
// with the Stories downloader and the variant resolver — one implementation, so
// the two surfaces cannot drift apart in how defensively they read Facebook's
// objects. See FBPDownloadVariants.m for the body.
static inline id FBPSafeObjectGetter(
    id object,
    NSString *getterName
) {
    return FBPDownloadSafeObjectGetter(object, getterName);
}

// Capture no longer collapses the renditions to `hdURL ?: sdURL`: the whole
// ordered variant list is kept, and the pick happens at tap time.
// FBPDownloadVariantsForItem (FBPDownloadVariants.m) is now the one place that
// knows how to read an FBVideoPlaybackItem.

static UIViewController *FBPFindControllerOfClass(UIViewController *vc, Class targetClass) {
    if (!vc || !targetClass) return nil;
    if ([vc isKindOfClass:targetClass]) return vc;

    UIViewController *found = FBPFindControllerOfClass(vc.presentedViewController, targetClass);
    if (found) return found;

    for (UIViewController *child in vc.childViewControllers) {
        found = FBPFindControllerOfClass(child, targetClass);
        if (found) return found;
    }

    return nil;
}

#pragma mark - Top VC

static UIViewController *
FBPTopViewController(void) {

    UIWindow *keyWindow = nil;

    for (UIScene *scene in
         [UIApplication sharedApplication]
             .connectedScenes) {

        if (scene.activationState !=
            UISceneActivationStateForegroundActive)
            continue;

        if (![scene
            isKindOfClass:
                [UIWindowScene class]])
            continue;

        UIWindowScene *windowScene =
            (UIWindowScene *)scene;

        for (UIWindow *window
             in windowScene.windows) {

            if (window.isKeyWindow) {

                keyWindow = window;
                break;
            }
        }

        if (keyWindow)
            break;
    }

    if (!keyWindow)
        return nil;

    UIViewController *vc =
        keyWindow.rootViewController;

    while (YES) {

        if (vc.presentedViewController) {

            vc =
                vc.presentedViewController;

            continue;
        }

        if ([vc
            isKindOfClass:
                [UINavigationController class]]) {

            UIViewController *next =
                [(UINavigationController *)vc
                    visibleViewController];

            if (next) {

                vc = next;
                continue;
            }
        }

        if ([vc
            isKindOfClass:
                [UITabBarController class]]) {

            UIViewController *next =
                [(UITabBarController *)vc
                    selectedViewController];

            if (next) {

                vc = next;
                continue;
            }
        }

        break;
    }

    return vc;
}

#pragma mark - Alert

static void FBPShowMessage(
    NSString *title,
    NSString *message
) {
    dispatch_async(
        dispatch_get_main_queue(), ^{

        UIViewController *vc =
            FBPTopViewController();

        if (!vc)
            return;

        UIAlertController *alert =
            [UIAlertController
                alertControllerWithTitle:title
                message:message
                preferredStyle:
                    UIAlertControllerStyleAlert];

        [alert addAction:
            [UIAlertAction
                actionWithTitle:FBPL(@"common.ok")
                style:
                    UIAlertActionStyleDefault
                handler:nil]];

        [vc
            presentViewController:alert
                         animated:YES
                       completion:nil];
    });
}

#pragma mark - Download tasks

// One object per download, so several can run at once.
//
// What used to be here: a singleton holding one NSURLSession, one task, one
// `downloading` flag and the UIAlertController that showed the percentage. That
// shape had two problems the download manager exists to fix. A second tap while
// something was downloading was answered with "A Reel is already downloading."
// even though nothing in the flow required that — FBPDashDownload has always
// supported more than one in flight. And the alert *was* the download's state:
// dismissing it left the transfer running with nothing left pointing at it.
//
// Now each tap makes one of these, each owns its own session or two-stream
// flow, and all any of them reports to is FBPDownloadStore. The HUD pill and the
// manager list are both drawn from the store, so dismissing either of them is
// not an operation on the download at all.

@interface FBPReelDownloadTask : NSObject <NSURLSessionDownloadDelegate>

@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionDownloadTask *task;

// The two-stream flow for a DASH rung, nil on the single-URL path.
@property(nonatomic, strong) FBPDashDownload *dashDownload;

@property(nonatomic, strong) FBPDownloadJob *job;
@property(nonatomic, strong) FBPDownloadVariant *variant;
@property(nonatomic, copy) NSString *videoID;

/// Register a download and start it.
+ (void)startWithVariant:(FBPDownloadVariant *)variant
                 videoID:(NSString *)videoID
                   title:(NSString *)title
            thumbnailURL:(NSURL *)thumbnailURL;

@end

// Every task with work still outstanding. A task is held here from the moment it
// starts until its completion has run — the same reason FBPDashDownload holds
// itself alive — so neither surface has to park it anywhere.
//
// Guarded, because the two ends of a task's life are on different queues now
// that several can run at once: it is added from the main queue (the pick) and
// dropped from whichever queue reported the end — an NSURLSession delegate
// queue, or Photos' completion handler.
static NSMutableSet<FBPReelDownloadTask *> *gLiveDownloadTasks = nil;

static void FBPReelTrackTask(FBPReelDownloadTask *task, BOOL live) {
    if (!task) return;
    @synchronized ([FBPReelDownloadTask class]) {
        if (!gLiveDownloadTasks) gLiveDownloadTasks = [NSMutableSet set];
        if (live) {
            [gLiveDownloadTasks addObject:task];
        } else {
            [gLiveDownloadTasks removeObject:task];
        }
    }
}

/// An error whose localizedDescription is already the sentence to show.
///
/// The single-URL path has its own wording for every way it can fail, tested on
/// device, and those strings are kept rather than re-derived: packing them into
/// an NSError is only how they travel to the store, which reads
/// -localizedDescription for anything outside FBPDashDownload's own domain.
static NSError *FBPReelError(NSString *message) {
    return [NSError errorWithDomain:@"com.shajon.fbplus.downloads"
                               code:1
                           userInfo:@{
        NSLocalizedDescriptionKey : message ?: FBPL(@"download.reel.failed"),
    }];
}

@implementation FBPReelDownloadTask

#pragma mark Lifecycle

+ (void)startWithVariant:(FBPDownloadVariant *)variant
                 videoID:(NSString *)videoID
                   title:(NSString *)title
            thumbnailURL:(NSURL *)thumbnailURL {

    if (!variant.url) return;

    FBPDownloadStore *store = FBPDownloadStore.shared;

    FBPDownloadJob *job =
        [store addJobWithSurface:FBPDownloadJobSurfaceReel
                           title:title
                         quality:variant.title
                    thumbnailURL:thumbnailURL
                        needsMux:variant.needsMux
                   expectedBytes:variant.byteSize];

    // Retry deliberately captures nothing but the two values it needs, so the
    // block the job holds for the rest of the session does not keep a finished
    // task — and its session, and its temporary files — alive with it.
    //
    // It re-runs from the same variant, which is the honest thing to offer: by
    // the time the user reaches for Retry the signed URL may well have expired,
    // and the failure it then reports is the expired-link message that tells
    // them to tap download again on the Reel itself. Re-resolving is not
    // possible from here — the reel it came from is long gone from the screen.
    NSString *retryID = [videoID copy];
    FBPDownloadVariant *retryVariant = variant;
    [store setRetryWork:^(FBPDownloadJob *retried) {
        [FBPReelDownloadTask runJob:retried variant:retryVariant videoID:retryID];
    } forJob:job];

    [self runJob:job variant:variant videoID:videoID];
}

/// Attach a fresh task to a job and start it. Also the retry path.
+ (void)runJob:(FBPDownloadJob *)job
       variant:(FBPDownloadVariant *)variant
       videoID:(NSString *)videoID {

    FBPReelDownloadTask *download = [[FBPReelDownloadTask alloc] init];
    download.job = job;
    download.variant = variant;
    download.videoID = videoID.length ? videoID : @"unknown";

    FBPReelTrackTask(download, YES);

    // Installed before anything is in flight, so the HUD pill — which is raised
    // from the store's change notification, one turn of the run loop later —
    // already knows whether this job has a stop to offer.
    [FBPDownloadStore.shared setCancelWork:^(__unused FBPDownloadJob *cancelled) {
        [download cancel];
    } forJob:job];

    [download begin];
}

- (void)begin {
    // A variant with no separate audio is a complete MP4 — one GET, one file,
    // audio already in it. That is the progressive tier, confirmed working on
    // device, and it goes down exactly the path it always has.
    if (self.variant.needsMux) {
        [self beginTwoStream];
    } else {
        [self beginSingleFile];
    }
}

/// Stop whichever flow is running. Safe at any point, including after the
/// download has already finished.
- (void)cancel {
    [self.dashDownload cancel];
    [self.task cancel];
}

/// Let go of the session and drop out of the live set. Called on every terminal
/// path, so nothing outlives its download.
- (void)finish {
    [self.session finishTasksAndInvalidate];
    self.session = nil;
    self.task = nil;
    self.dashDownload = nil;

    // Clearing the cancel work breaks the job -> block -> task reference, so a
    // finished task is released as soon as the live set lets go of it.
    [FBPDownloadStore.shared setCancelWork:nil forJob:self.job];
    FBPReelTrackTask(self, NO);
}

- (void)failWithMessage:(NSString *)message {
    [FBPDownloadStore.shared job:self.job didFailWithError:FBPReelError(message)];
    [self finish];
}

#pragma mark Destination

/// The same name, in the same directory, as this file has always used — so the
/// asset Photos ends up with is indistinguishable from one saved before any of
/// this existed, right down to its originalFilename.
///
/// The job identifier is mixed in because several downloads can now be in
/// flight: two taps on the same Reel would otherwise race for one path, and the
/// second would delete the first's file out from under it.
- (NSURL *)outputURL {
    NSString *filename =
        [NSString stringWithFormat:@"FBP-Reel-%@-%@.mp4",
                                   self.videoID ?: @"unknown",
                                   self.job.identifier ?: NSUUID.UUID.UUIDString];

    return [NSURL fileURLWithPath:
        [NSTemporaryDirectory() stringByAppendingPathComponent:filename]];
}

#pragma mark Photos

- (void)saveVideo:(NSURL *)fileURL {
    [FBPDownloadStore.shared job:self.job didEnterStage:FBPDownloadJobStageSaving];

    // Kept so the manager's row can offer "View in Photos" afterwards. The
    // placeholder's localIdentifier is the created asset's, and it is only valid
    // to read once the change block has been handed over.
    __block NSString *assetIdentifier = nil;

    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        PHAssetChangeRequest *request =
            [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:fileURL];
        assetIdentifier = request.placeholderForCreatedAsset.localIdentifier;

    } completionHandler:^(BOOL success, NSError *error) {
        [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];

        if (success) {
            [FBPDownloadStore.shared job:self.job
                didFinishWithAssetIdentifier:assetIdentifier];
            [self finish];
            return;
        }

        [self failWithMessage:
            [NSString stringWithFormat:FBPL(@"download.reel.saveFailed"),
                                       error.localizedDescription
                                           ?: FBPL(@"download.error.unknown")]];
    }];
}

#pragma mark Single-file path

- (void)beginSingleFile {
    [FBPDownloadStore.shared job:self.job didEnterStage:FBPDownloadJobStageFetching];

    NSURLSessionConfiguration *config =
        [NSURLSessionConfiguration defaultSessionConfiguration];
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    config.timeoutIntervalForRequest = 60.0;
    config.timeoutIntervalForResource = 180.0;

    NSOperationQueue *queue = [[NSOperationQueue alloc] init];
    queue.maxConcurrentOperationCount = 1;

    self.session = [NSURLSession sessionWithConfiguration:config
                                                delegate:self
                                           delegateQueue:queue];

    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:self.variant.url
                               cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                           timeoutInterval:60.0];
    request.HTTPMethod = @"GET";

    self.task = [self.session downloadTaskWithRequest:request];
    [self.task resume];
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {

    FBPDownloadStore *store = FBPDownloadStore.shared;

    // A real Content-Length beats the picker's size; a CDN that sent none leaves
    // the picker's exact -atomSize standing as the total.
    [store job:self.job
        didReceiveBytes:totalBytesWritten
               expected:(totalBytesExpectedToWrite > 0) ? totalBytesExpectedToWrite : 0];

    if (totalBytesExpectedToWrite <= 0) return;

    [store job:self.job
        didProgress:(float)totalBytesWritten / (float)totalBytesExpectedToWrite];
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {

    NSHTTPURLResponse *response =
        [downloadTask.response isKindOfClass:[NSHTTPURLResponse class]]
        ? (NSHTTPURLResponse *)downloadTask.response
        : nil;

    NSInteger status = response ? response.statusCode : 0;

    if (status < 200 || status >= 300) {
        // 403 is the one failure the user can fix: Facebook's playback URLs are
        // signed and carry a short `oe=` expiry, so a link that sat around — a
        // picker sheet left open, a reel paused for a while — is simply past it.
        // Tapping download again re-resolves it.
        NSString *message =
            (status == 403)
            ? FBPL(@"download.reel.expired")
            : [NSString stringWithFormat:FBPL(@"download.reel.httpError"), (long)status];

        [self failWithMessage:message];
        return;
    }

    NSURL *destination = [self outputURL];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtURL:destination error:nil];

    if (![fm moveItemAtURL:location toURL:destination error:NULL]) {
        [self failWithMessage:FBPL(@"download.reel.tmpFailed")];
        return;
    }

    [FBPDownloadStore.shared job:self.job didProgress:1.0f];
    [self saveVideo:destination];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {

    if (!error) return;

    // A cancelled transfer is the user's own stop arriving back. The store knows
    // it was asked for and records the job as cancelled rather than failed, so
    // the message built here is never shown for one.
    [self failWithMessage:
        [NSString stringWithFormat:FBPL(@"download.reel.failedDetail"),
                                   error.localizedDescription
                                       ?: FBPL(@"download.error.unknown")]];
}

#pragma mark Two-stream path

- (void)beginTwoStream {
    FBPDownloadStore *store = FBPDownloadStore.shared;
    [store job:self.job didEnterStage:FBPDownloadJobStageFetching];

    __weak __typeof__(self) weakSelf = self;

    self.dashDownload =
        [FBPDashDownload startWithVideoURL:self.variant.url
                                 audioURL:self.variant.audioURL
                                outputURL:[self outputURL]
                                 progress:^(FBPDashDownloadStage stage, float fraction) {

            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf) return;

            FBPDownloadStore *inner = FBPDownloadStore.shared;
            [inner job:strongSelf.job didProgress:fraction];
            [inner job:strongSelf.job
                didEnterStage:(stage == FBPDashDownloadStageMerging)
                                  ? FBPDownloadJobStageMerging
                                  : FBPDownloadJobStageFetching];

        } completion:^(NSURL *merged, NSError *error) {

            __typeof__(self) strongSelf = weakSelf;
            if (!strongSelf) return;

            strongSelf.dashDownload = nil;

            if (merged) {
                [FBPDownloadStore.shared job:strongSelf.job didProgress:1.0f];
                // Straight into the single-URL path's own save step: same
                // PHAssetChangeRequest, same album behaviour, and it deletes the
                // file afterwards either way.
                [strongSelf saveVideo:merged];
                return;
            }

            // The flow's own errors go through untouched, in its own domain, so
            // the store's message builder can keep folding a 403 on either
            // stream into the expired-link wording. A cancellation reports no
            // message at all, and the store has already recorded why.
            [FBPDownloadStore.shared job:strongSelf.job didFailWithError:error];
            [strongSelf finish];
        }];

    if (!self.dashDownload) {
        // Only a nil completion block makes +start… refuse, which cannot happen
        // here — but a job that silently never moved would be worse than one
        // that says it failed.
        [self failWithMessage:FBPL(@"download.reel.failed")];
    }
}

@end

#pragma mark - Active playback fallback

static id FBPObjectIvar(id object, const char *name) {
    if (!object || !name) return nil;

    for (Class cls = object_getClass(object);
         cls;
         cls = class_getSuperclass(cls)) {

        Ivar ivar = class_getInstanceVariable(cls, name);
        if (!ivar) continue;

        const char *type = ivar_getTypeEncoding(ivar);
        if (!type || type[0] != '@') return nil;

        @try {
            return object_getIvar(object, ivar);
        } @catch (__unused NSException *e) {
            return nil;
        }
    }

    return nil;
}

/// Walk from the tapped button to Facebook's live playback controller and
/// resolve it, writing nothing global.
///
/// Called on every download tap, not just as a fallback: the playback URLs are
/// signed and short-lived, so the list captured when the reel started playing
/// may already be stale by the time the user taps. @c ownerOut is the player
/// view controller the media belongs to, used to keep the owner latch in step.
static FBPDownloadSource *
FBPResolveActivePlayback(UIButton *sender, UIViewController **ownerOut) {
    if (ownerOut) *ownerOut = nil;

    UIWindow *window = sender.window;
    if (!window) return nil;

    Class playerClass =
        NSClassFromString(@"FBVideoHomeUnifiedPlayerViewController");
    if (!playerClass) return nil;

    UIViewController *playerVC =
        FBPFindControllerOfClass(
            window.rootViewController,
            playerClass
        );
    if (!playerVC) return nil;

    id feedVC =
        FBPObjectIvar(playerVC, "_feedViewController");

    id autoAdvance =
        FBPObjectIvar(feedVC, "_feedAutoAdvanceController");

    id monitor =
        FBPObjectIvar(autoAdvance, "_currentVideoMonitor");

    id playbackController =
        FBPSafeObjectGetter(
            monitor,
            @"activePlaybackController"
        );
    if (!playbackController) return nil;

    FBPDownloadSource *source =
        FBPDownloadSourceFromPlaybackController(playbackController);
    if (source.variants.count == 0) return nil;

    if (ownerOut) *ownerOut = playerVC;

    return source;
}

#pragma mark - Button handler

@interface FBPReelDownloadHandler :
    NSObject

+ (instancetype)shared;

- (void)downloadTouchDown:
    (UIButton *)sender;

- (void)downloadTouchFinished:
    (UIButton *)sender;

- (void)downloadButtonPressed:
    (UIButton *)sender;

- (void)hideOverlayButtonPressed:
    (UIButton *)sender;

@end

// Forward declaration — defined with the window-button helpers below.
static void FBPUpdateHideOverlayButtonIcon(UIButton *button);

@implementation FBPReelDownloadHandler

+ (instancetype)shared {

    static FBPReelDownloadHandler *handler =
        nil;

    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{

        handler =
            [[FBPReelDownloadHandler alloc]
                init];
    });

    return handler;
}

- (void)downloadTouchDown:
    (UIButton *)sender {

    sender.alpha =
        0.45;
}

- (void)downloadTouchFinished:
    (UIButton *)sender {

    sender.alpha =
        1.0;
}

- (void)downloadButtonPressed:
    (UIButton *)sender {

    sender.alpha = 1.0;

    NSArray<FBPDownloadVariant *> *variants = nil;
    NSString *videoID = nil;
    NSString *itemVideoID = nil;

    @synchronized([NSFileManager class]) {
        variants = gCurrentVariants;
        videoID = [gCurrentVideoID copy];
        itemVideoID = [gCurrentItemVideoID copy];
    }

    /*
     * Re-resolve now, at tap time, rather than trusting what was captured when
     * the reel started playing.
     *
     * Two reasons, and the second is the important one:
     *
     *  - Reels/swipe normally arrive through didStartPlayback, but the first
     *    video opened from Home can already be playing before that callback
     *    reaches this controller, so there may be nothing captured at all.
     *
     *  - These are signed CDN URLs carrying a short `oe=` expiry. A captured
     *    list goes stale on its own, and the picker sheet below can sit open for
     *    as long as the user takes to decide, so the freshest list we can get is
     *    the one read at the moment of the tap.
     *
     * The live read wins only when it describes the same video (or when nothing
     * was captured): the walk finds whatever playback controller is active, and
     * a mismatch means it found a different video, not a fresher copy of this
     * one. Anything else falls back to the captured list, which is still better
     * than refusing to download.
     */
    UIViewController *owner = nil;
    FBPDownloadSource *live = FBPResolveActivePlayback(sender, &owner);

    if (live &&
        (!itemVideoID || !live.videoID ||
         [live.videoID isEqualToString:itemVideoID])) {

        variants = live.variants;
        videoID = videoID ?: live.videoID;

        @synchronized([NSFileManager class]) {
            gCurrentVariants = live.variants;
            gCurrentVideoID = [videoID copy];
            gCurrentItemVideoID = [live.videoID copy];
            if (owner) gMediaOwnerPlayerVC = owner;
        }
    }

    if (variants.count == 0) {
        FBPShowMessage(
            FBPL(@"download.appName"),
            FBPL(@"download.reel.noLink")
        );
        return;
    }

    // Diagnostic (off by default): record what Facebook is really serving for
    // this video, so the maintainer's device run can answer whether a DASH
    // quality tier is worth building. Free when the switch is off.
    FBPDownloadLogQualities(live.item, live.playbackController, variants);

    NSString *downloadID = [videoID copy];

    // Carried into the job so the download manager's row can show the video's
    // own title and poster frame instead of a bare "Reel". Both are nil on
    // plenty of real content, and nil is fine — the row falls back.
    NSString *mediaTitle = [live.mediaTitle copy];
    NSURL *thumbnailURL = [live.thumbnailURL copy];

    // Re-resolve on the pick, not just on the tap: the sheet can sit open while
    // the user decides, and these URLs carry an oe= expiry. Same identity guard
    // as above — a walk that lands on a different video must not swap the URL
    // out from under this download.
    __weak UIButton *weakSender = sender;
    NSString *expectedItemID = [itemVideoID copy];

    FBPDownloadPresentPicker(
        variants,
        FBPTopViewController(),
        sender,
        ^NSArray<FBPDownloadVariant *> *{
            FBPDownloadSource *again =
                FBPResolveActivePlayback(weakSender, NULL);
            if (!again) return nil;
            if (expectedItemID && again.videoID &&
                ![again.videoID isEqualToString:expectedItemID]) {
                return nil;
            }
            return again.variants;
        },
        ^(FBPDownloadVariant *variant) {
            [FBPReelDownloadTask startWithVariant:variant
                                         videoID:downloadID
                                           title:mediaTitle
                                    thumbnailURL:thumbnailURL];
        }
    );
}

- (void)hideOverlayButtonPressed:
    (UIButton *)sender {

    sender.alpha = 1.0;

    gOverlayHidden = !gOverlayHidden;

    UIWindow *window = sender.window;
    if (gOverlayHidden) {
        // Strip the current reel immediately so the tap feels instant; the
        // display-link tracker keeps newly-swiped reels stripped from here on.
        FBPHideOverlaysForWindow(window);
        // The bottom tab bar is chrome too, so it fades away with the rest.
        [UIView animateWithDuration:0.2 animations:^{ FBPHideTabBars(window); }];
    } else {
        FBPUnhideAllOverlays();
        [UIView animateWithDuration:0.2 animations:^{ FBPShowTabBars(); }];
    }

    FBPUpdateHideOverlayButtonIcon(sender);
}

@end

#pragma mark - Sidebar geometry

static NSArray<UIView *> *
FBPExistingSidebarControls(
    UIView *sidebar
) {
    NSMutableArray *result =
        [NSMutableArray array];

    for (UIView *view
         in sidebar.subviews) {

        if (view.hidden ||
            view.alpha < 0.05)
            continue;

        CGRect frame =
            [sidebar
                convertRect:view.bounds
                fromView:view];

        if (CGRectIsEmpty(frame))
            continue;

        if (frame.size.width < 20.0 ||
            frame.size.height < 20.0)
            continue;

        if (frame.size.width > 100.0 ||
            frame.size.height > 120.0)
            continue;

        [result addObject:view];
    }

    return result;
}

static CGFloat
FBPDetectedSpacing(
    UIView *sidebar,
    NSArray<UIView *> *controls
) {
    if (controls.count < 2)
        return 12.0;

    NSMutableArray<NSNumber *> *centers =
        [NSMutableArray array];

    for (UIView *view in controls) {

        CGRect frame =
            [sidebar
                convertRect:view.bounds
                fromView:view];

        [centers
            addObject:
                @(CGRectGetMidY(frame))];
    }

    [centers
        sortUsingSelector:
            @selector(compare:)];

    CGFloat best =
        CGFLOAT_MAX;

    for (NSUInteger i = 1;
         i < centers.count;
         i++) {

        CGFloat gap =
            centers[i].doubleValue -
            centers[i - 1].doubleValue;

        if (gap >= 35.0 &&
            gap <= 100.0 &&
            gap < best) {

            best =
                gap;
        }
    }

    if (best ==
        CGFLOAT_MAX)
        return 12.0;

    return MAX(
        8.0,
        MIN(
            best - 46.0,
            30.0
        )
    );
}

static BOOL
FBPFrameForSidebar(
    UIView *sidebar,
    UIWindow *window,
    CGRect *outputFrame
) {
    if (!sidebar ||
        !window ||
        sidebar.window != window ||
        sidebar.hidden ||
        sidebar.alpha < 0.05)
        return NO;

    NSArray<UIView *> *controls =
        FBPExistingSidebarControls(
            sidebar
        );

    UIView *topControl =
        nil;

    CGFloat topY =
        CGFLOAT_MAX;

    CGRect topFrame =
        CGRectZero;

    for (UIView *view
         in controls) {

        CGRect frame =
            [sidebar
                convertRect:view.bounds
                fromView:view];

        if (CGRectGetMinY(frame)
            < topY) {

            topY =
                CGRectGetMinY(frame);

            topControl =
                view;

            topFrame =
                frame;
        }
    }

    if (!topControl)
        return NO;

    CGFloat spacing =
        FBPDetectedSpacing(
            sidebar,
            controls
        );

    CGRect desired =
        CGRectMake(
            CGRectGetMidX(
                sidebar.bounds) - 24.0,

            CGRectGetMinY(topFrame)
                - spacing
                - 48.0,

            48.0,
            48.0
        );

    CGRect frame =
        [sidebar
            convertRect:desired
            toView:window];

    if (outputFrame)
        *outputFrame =
            frame;

    return YES;
}

#pragma mark - Window button

static UIButton *
FBPGetOrCreateWindowButton(
    UIWindow *window
) {
    if (!window)
        return nil;

    UIButton *button =
        (UIButton *)
            [window
                viewWithTag:
                    kFBPDownloadButtonTag];

    if (button) {
        return button;
    }

    button =
        [UIButton
            buttonWithType:
                UIButtonTypeCustom];

    button.tag =
        kFBPDownloadButtonTag;

    button.userInteractionEnabled =
        YES;

    button.exclusiveTouch =
        YES;

    button.backgroundColor =
        [UIColor clearColor];

    UIImage *image =
        [UIImage fbp_imageNamed:@"download"];

    [button
        setImage:image
        forState:UIControlStateNormal];

    button.imageView.contentMode =
        UIViewContentModeScaleAspectFit;

    button.contentEdgeInsets =
        UIEdgeInsetsMake(9, 9, 9, 9);

    button.tintColor =
        [UIColor whiteColor];

    button.accessibilityLabel =
        FBPL(@"download.reel.a11y");

    FBPReelDownloadHandler *handler =
        [FBPReelDownloadHandler shared];

    [button
        addTarget:handler
        action:
            @selector(downloadTouchDown:)
        forControlEvents:
            UIControlEventTouchDown];

    [button
        addTarget:handler
        action:
            @selector(downloadTouchFinished:)
        forControlEvents:
            UIControlEventTouchCancel |
            UIControlEventTouchDragExit |
            UIControlEventTouchUpOutside];

    [button
        addTarget:handler
        action:
            @selector(downloadButtonPressed:)
        forControlEvents:
            UIControlEventTouchUpInside];

    [window addSubview:button];

    return button;
}

#pragma mark - Hide-overlay toggle button

// The glyph reflects the action the tap performs: an open eye while chrome is
// visible (tap to hide), a slashed eye while it is hidden (tap to reveal).
static void FBPUpdateHideOverlayButtonIcon(UIButton *button) {
    if (!button)
        return;

    NSString *symbol =
        gOverlayHidden ? @"eye.slash.fill" : @"eye.fill";

    UIImage *image =
        [UIImage fbp_symbolNamed:symbol
                            size:21.0
                          weight:UIImageSymbolWeightSemibold];

    [button setImage:image forState:UIControlStateNormal];
}

static UIButton *
FBPGetOrCreateHideOverlayButton(
    UIWindow *window
) {
    if (!window)
        return nil;

    UIButton *button =
        (UIButton *)
            [window
                viewWithTag:
                    kFBPHideOverlayButtonTag];

    if (button) {
        return button;
    }

    button =
        [UIButton
            buttonWithType:
                UIButtonTypeCustom];

    button.tag =
        kFBPHideOverlayButtonTag;

    button.userInteractionEnabled =
        YES;

    button.exclusiveTouch =
        YES;

    button.backgroundColor =
        [UIColor clearColor];

    // Set the image BEFORE touching -imageView so the image view is realized on
    // the main thread with its content already in place. Otherwise an
    // accessibility query of -accessibilityLabel (which internally calls
    // -imageView) can lazily build the image view on a background thread and
    // trip UIKit's main-queue assertion. This mirrors the download button.
    FBPUpdateHideOverlayButtonIcon(button);

    button.imageView.contentMode =
        UIViewContentModeScaleAspectFit;

    button.contentEdgeInsets =
        UIEdgeInsetsMake(10, 10, 10, 10);

    button.tintColor =
        [UIColor whiteColor];

    button.accessibilityLabel =
        FBPL(@"reels.hideOverlay.a11y");

    FBPReelDownloadHandler *handler =
        [FBPReelDownloadHandler shared];

    [button
        addTarget:handler
        action:
            @selector(downloadTouchDown:)
        forControlEvents:
            UIControlEventTouchDown];

    [button
        addTarget:handler
        action:
            @selector(downloadTouchFinished:)
        forControlEvents:
            UIControlEventTouchCancel |
            UIControlEventTouchDragExit |
            UIControlEventTouchUpOutside];

    [button
        addTarget:handler
        action:
            @selector(hideOverlayButtonPressed:)
        forControlEvents:
            UIControlEventTouchUpInside];

    [window addSubview:button];

    return button;
}

#pragma mark - Display-link tracker

@interface FBPReelButtonTracker : NSObject
@property(nonatomic, strong) CADisplayLink *displayLink;
@property(nonatomic, weak) UIView *lastSidebar;
@property(nonatomic, assign) CGRect lastCandidateFrame;
@property(nonatomic, assign) BOOL hasLastCandidateFrame;
@property(nonatomic, assign) NSInteger stableFrames;
+ (instancetype)shared;
- (void)start;
- (void)registerSidebar:(UIView *)sidebar;
- (void)tick:(CADisplayLink *)link;
@end

@implementation FBPReelButtonTracker

+ (instancetype)shared {
    static FBPReelButtonTracker *tracker = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tracker = [[FBPReelButtonTracker alloc] init];
    });
    return tracker;
}

- (void)start {
    if (self.displayLink) return;
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)registerSidebar:(UIView *)sidebar {
    if (!sidebar) return;
    if (!gSidebars) gSidebars = [NSHashTable weakObjectsHashTable];
    [gSidebars addObject:sidebar];
    [self start];
}

// Per-button show/hide. Dedupe is read off the button's own state rather than a
// shared flag, so the download button and the hide-overlay toggle can be driven
// independently.
- (void)setButton:(UIButton *)button visible:(BOOL)visible {
    if (!button) return;

    if (visible) {
        if (!button.hidden && button.alpha > 0.99 &&
            button.userInteractionEnabled) return;
        button.hidden = NO;
        button.userInteractionEnabled = YES;
        [UIView animateWithDuration:0.10
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionAllowUserInteraction |
                                    UIViewAnimationOptionCurveEaseOut
                         animations:^{ button.alpha = 1.0; }
                         completion:nil];
    } else {
        if (button.hidden || button.alpha < 0.01) return;
        button.userInteractionEnabled = NO;
        [UIView animateWithDuration:0.05
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionCurveEaseOut
                         animations:^{ button.alpha = 0.0; }
                         completion:^(BOOL finished) {
            if (finished && button.alpha < 0.01) button.hidden = YES;
        }];
    }
}

// Hide both overlay buttons at once (used on every "not on a reel" path).
- (void)hideButton:(UIButton *)download andToggle:(UIButton *)toggle {
    if (download) [self setButton:download visible:NO];
    if (toggle)   [self setButton:toggle   visible:NO];
}

/*
 * Find the UIScrollView that contains the sidebar. Facebook may wrap the sidebar
 * in several containers, so walk the entire superview chain rather than guessing
 * a specific class.
 */
- (UIScrollView *)scrollViewForSidebar:(UIView *)sidebar {
    UIView *view = sidebar;
    while (view) {
        if ([view isKindOfClass:[UIScrollView class]])
            return (UIScrollView *)view;
        view = view.superview;
    }
    return nil;
}

- (BOOL)userIsDraggingSidebar:(UIView *)sidebar {
    UIScrollView *scrollView = [self scrollViewForSidebar:sidebar];
    if (!scrollView) return NO;

    UIGestureRecognizerState state = scrollView.panGestureRecognizer.state;

    return scrollView.dragging ||
           state == UIGestureRecognizerStateBegan ||
           state == UIGestureRecognizerStateChanged;
}

/*
 * The sidebar can still have a window after the user has switched to another
 * tab, so sidebar.window != nil is NOT enough to conclude that Reels is on
 * screen. Check the full ancestor chain up to the UIWindow: if any one of them
 * is hidden or has a low alpha, the sidebar is no longer the active UI.
 */
- (BOOL)sidebarHierarchyIsVisible:(UIView *)sidebar inWindow:(UIWindow *)window {
    if (!sidebar || !window || sidebar.window != window) return NO;

    UIView *view = sidebar;
    while (view && view != window) {
        if (view.hidden || view.alpha < 0.05) {
            // In hide-overlay mode we deliberately hide the Shorts overlay
            // container (an ancestor of the sidebar). That must NOT read as the
            // reel having left the screen — the reel is still there, just
            // stripped — otherwise our own buttons would vanish with it.
            if (FBPViewHiddenByUs(view)) {
                view = view.superview;
                continue;
            }
            return NO;
        }
        view = view.superview;
    }
    if (view != window) return NO;

    // A modal presented over the Reel (comment sheet, share sheet, the "..." menu,
    // or Facebook Plus settings) does not hide the sidebar in the view tree — it
    // just sits on top of it. Facebook hides its own like/comment/share controls
    // in that state, so the download button should hide too. Detect it: if the
    // window's top-most presented controller is a modal that does not contain the
    // sidebar, the Reel is covered.
    UIViewController *top = window.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if (top && top != window.rootViewController &&
        ![sidebar isDescendantOfView:top.view]) {
        return NO;
    }

    return YES;
}

static BOOL FBPViewControllerTreeContainsClass(UIViewController *vc, Class targetClass) {
    if (!vc || !targetClass) return NO;
    if ([vc isKindOfClass:targetClass]) return YES;
    if (vc.presentedViewController &&
        FBPViewControllerTreeContainsClass(vc.presentedViewController, targetClass)) return YES;
    if ([vc isKindOfClass:UINavigationController.class]) {
        UIViewController *top = ((UINavigationController *)vc).topViewController;
        if (top && FBPViewControllerTreeContainsClass(top, targetClass)) return YES;
    }
    if ([vc isKindOfClass:UITabBarController.class]) {
        UIViewController *selected = ((UITabBarController *)vc).selectedViewController;
        if (selected && FBPViewControllerTreeContainsClass(selected, targetClass)) return YES;
    }
    return NO;
}

static BOOL FBPPlusSettingsIsPresented(UIWindow *window) {
    Class settingsClass = objc_getClass("FBPSettingsController");
    return settingsClass && window &&
           FBPViewControllerTreeContainsClass(window.rootViewController, settingsClass);
}

- (void)tick:(__unused CADisplayLink *)link {
    if (!gSidebars || gSidebars.count == 0) return;

    UIWindow *window = nil;
    for (UIView *sidebar in gSidebars.allObjects) {
        if (sidebar.window) { window = sidebar.window; break; }
    }
    if (!window) return;

    BOOL downloaderEnabled =
        [FBPPrefs.shared boolForKey:FBPKeyReelsDownloaderEnabled];
    BOOL hideEnabled =
        [FBPPrefs.shared boolForKey:FBPKeyReelsHideOverlay];

    UIButton *downloadButton =
        (UIButton *)[window viewWithTag:kFBPDownloadButtonTag];
    UIButton *toggleButton =
        (UIButton *)[window viewWithTag:kFBPHideOverlayButtonTag];

    // Toggle feature switched off in settings while chrome was hidden: restore
    // everything so the user is never stuck looking at a stripped reel.
    if (!hideEnabled && gOverlayHidden) {
        FBPUnhideAllOverlays();
        FBPShowTabBars();
        gOverlayHidden = NO;
        if (toggleButton) FBPUpdateHideOverlayButtonIcon(toggleButton);
    }

    // Production gate: both features OFF means no overlay at all. Also suppress
    // our floating buttons while Facebook Plus settings is presented over the
    // still-live Reels hierarchy (long-press tab case).
    if ((!downloaderEnabled && !hideEnabled) ||
        FBPPlusSettingsIsPresented(window)) {
        // Keep the tab bar faded while settings sits over an active cinema-mode
        // reel (so returning looks unchanged); otherwise restore it.
        if (gOverlayHidden && hideEnabled && FBPPlusSettingsIsPresented(window)) {
            FBPReassertHiddenTabBars();
        } else {
            FBPShowTabBars();
        }
        [self hideButton:downloadButton andToggle:toggleButton];
        self.lastSidebar = nil;
        self.hasLastCandidateFrame = NO;
        self.stableFrames = 0;
        return;
    }

    // Keep every reel currently laid out stripped while hide-mode is on, so a
    // reel swiped in after the toggle was pressed comes up without chrome too.
    if (gOverlayHidden && hideEnabled) {
        FBPHideOverlaysForWindow(window);
    }

    CGFloat viewportMidY = CGRectGetMidY(window.bounds);
    UIView *bestSidebar = nil;
    CGRect bestButtonFrame = CGRectZero;
    CGFloat bestDistance = CGFLOAT_MAX;

    for (UIView *sidebar in gSidebars.allObjects) {
        if (![self sidebarHierarchyIsVisible:sidebar inWindow:window])
            continue;

        CGRect sidebarFrame = [sidebar convertRect:sidebar.bounds toView:window];

        /*
         * The candidate must ACTUALLY be on the current screen. An earlier
         * revision allowed a tracking area as wide as ±1 screen, so a Reels
         * sidebar that had already left the tab could still win and keep the
         * button alive like a ghost.
         */
        if (!CGRectIntersectsRect(window.bounds, sidebarFrame))
            continue;

        CGRect buttonFrame = CGRectZero;
        if (!FBPFrameForSidebar(sidebar, window, &buttonFrame)) continue;

        CGFloat distance = fabs(CGRectGetMidY(sidebarFrame) - viewportMidY);
        if (distance < bestDistance) {
            bestDistance = distance;
            bestSidebar = sidebar;
            bestButtonFrame = buttonFrame;
        }
    }

    if (!bestSidebar) {
        // No Reel on screen (another tab, feed, etc.) — the tab bar belongs there.
        FBPShowTabBars();
        [self hideButton:downloadButton andToggle:toggleButton];
        self.lastSidebar = nil;
        self.hasLastCandidateFrame = NO;
        self.stableFrames = 0;
        return;
    }

    // On a Reel: fade the tab bar in lock-step with cinema mode, restore it when
    // cinema mode is off.
    if (gOverlayHidden && hideEnabled) {
        if (!gHiddenTabBars || gHiddenTabBars.count == 0) FBPHideTabBars(window);
        else FBPReassertHiddenTabBars();
    } else {
        FBPShowTabBars();
    }

    // Create only the buttons whose feature is enabled; take down any button
    // whose feature was turned off in settings.
    UIButton *download =
        downloaderEnabled ? FBPGetOrCreateWindowButton(window) : nil;
    UIButton *toggle =
        hideEnabled ? FBPGetOrCreateHideOverlayButton(window) : nil;

    if (!downloaderEnabled && downloadButton)
        [self setButton:downloadButton visible:NO];
    if (!hideEnabled && toggleButton)
        [self setButton:toggleButton visible:NO];

    if (!download && !toggle) return;

    /*
     * Stop the buttons from chasing the Reel while it moves.
     *
     * - A finger dragging the UIScrollView => hide immediately, do NOT move the
     *   buttons' frames.
     * - After the finger lifts, Facebook still decelerates / snaps => the
     *   candidate keeps changing, so keep hiding.
     * - Candidate held still for 5 frames => the snap is done: set the frames
     *   ONCE and then show.
     *
     * This way the buttons never appear at an intermediate position mid-swipe.
     */
    BOOL dragging = [self userIsDraggingSidebar:bestSidebar];

    if (dragging) {
        self.stableFrames = 0;
        self.lastSidebar = bestSidebar;
        self.lastCandidateFrame = bestButtonFrame;
        self.hasLastCandidateFrame = YES;
        [self hideButton:download andToggle:toggle];
        return;
    }

    if (!self.hasLastCandidateFrame || self.lastSidebar != bestSidebar) {
        self.lastSidebar = bestSidebar;
        self.lastCandidateFrame = bestButtonFrame;
        self.hasLastCandidateFrame = YES;
        self.stableFrames = 0;
        [self hideButton:download andToggle:toggle];
        return;
    }

    CGFloat dx = fabs(CGRectGetMidX(bestButtonFrame) - CGRectGetMidX(self.lastCandidateFrame));
    CGFloat dy = fabs(CGRectGetMidY(bestButtonFrame) - CGRectGetMidY(self.lastCandidateFrame));

    self.lastCandidateFrame = bestButtonFrame;

    /* Deceleration / snap is still running. */
    if (dx > 0.35 || dy > 0.35) {
        self.stableFrames = 0;
        [self hideButton:download andToggle:toggle];
        return;
    }

    self.stableFrames += 1;

    /*
     * Wait for 5 genuinely still frames before showing. Do not animate the
     * position. The frames are only updated at the moment the buttons are still
     * hidden. The toggle sits one slot directly above the download button.
     */
    if (self.stableFrames >= 5) {
        CGRect base = CGRectIntegral(bestButtonFrame);

        if (download) {
            download.frame = base;
            [window bringSubviewToFront:download];
            [self setButton:download visible:YES];
        }

        if (toggle) {
            CGRect toggleFrame = base;
            toggleFrame.origin.y -= (base.size.height + kFBPButtonGap);
            toggle.frame = CGRectIntegral(toggleFrame);
            [window bringSubviewToFront:toggle];
            [self setButton:toggle visible:YES];
        }
    }
}

@end

#pragma mark - Anti-flash layout hook

// FBShortsCustomHitTestView is the container that parents the overlay component.
// It re-lays-out whenever a (recycled) cell is reconfigured for a newly-swiped
// reel — the same runloop pass in which Facebook re-shows the overlay. Re-hiding
// it here, synchronously, means the frame never renders with chrome, so there is
// no brief flash before the display-link tracker catches it next frame.
static void
FBPHitTestLayoutSubviews(
    id self,
    SEL _cmd
) {
    if (gOriginalHitTestLayoutSubviews) {
        gOriginalHitTestLayoutSubviews(self, _cmd);
    }

    if (!gOverlayHidden)
        return;

    if (![self isKindOfClass:[UIView class]])
        return;

    UIView *hitTest = (UIView *)self;
    if (!hitTest.window)
        return;

    FBPHideOverlayChildrenOf(hitTest);
}

#pragma mark - Sidebar hook

static void
FBPSidebarDidMoveToWindow(
    id self,
    SEL _cmd
) {
    if (gOriginalSidebarDidMoveToWindow) {

        gOriginalSidebarDidMoveToWindow(
            self,
            _cmd
        );
    }

    if (![self
        isKindOfClass:
            [UIView class]])
        return;

    UIView *sidebar =
        (UIView *)self;

    if (!sidebar.window)
        return;

    // If hide-mode is already on when a fresh reel's sidebar moves on screen,
    // strip it right away rather than waiting for the next display-link tick.
    if (gOverlayHidden) {
        UIView *overlay = FBPOverlayForSidebar(sidebar);
        if (overlay && !overlay.hidden) {
            overlay.hidden = YES;
            FBPSetViewHiddenByUs(overlay, YES);
            if (!gHiddenOverlays)
                gHiddenOverlays = [NSHashTable weakObjectsHashTable];
            [gHiddenOverlays addObject:overlay];
        }
    }

    dispatch_async(
        dispatch_get_main_queue(), ^{

        [[FBPReelButtonTracker shared]
            registerSidebar:sidebar];
    });
}

#pragma mark - Current video

static void
FBPDidStartPlayback(
    id self,
    SEL _cmd,
    id videoID,
    int64_t position,
    id analyticsContext,
    id playbackController
) {
    if (gOriginalDidStartPlayback) {
        gOriginalDidStartPlayback(
            self,
            _cmd,
            videoID,
            position,
            analyticsContext,
            playbackController
        );
    }

    FBPDownloadSource *source =
        FBPDownloadSourceFromPlaybackController(playbackController);
    if (source.variants.count == 0) return;

    NSString *newID = nil;
    if ([videoID isKindOfClass:[NSString class]]) {
        newID = [(NSString *)videoID copy];
    } else if (videoID) {
        newID = [[videoID description] copy];
    } else {
        newID = source.videoID;
    }

    @synchronized([NSFileManager class]) {
        gCurrentVariants = source.variants;
        gCurrentVideoID = [newID copy];
        gCurrentItemVideoID = [source.videoID copy];
        gMediaOwnerPlayerVC = self;
    }
}

#pragma mark - Player lifecycle

static void
FBPPlayerViewWillAppear(
    id self,
    SEL _cmd,
    BOOL animated
) {
    /*
     * A newly-created fullscreen player must never inherit the previous
     * viewer's CDN URL.
     */
    @synchronized([NSFileManager class]) {
        if (gMediaOwnerPlayerVC &&
            gMediaOwnerPlayerVC != self) {

            gCurrentVariants = nil;
            gCurrentVideoID = nil;
            gCurrentItemVideoID = nil;
            gMediaOwnerPlayerVC = nil;
        }
    }

    if (gOriginalPlayerViewWillAppear) {
        gOriginalPlayerViewWillAppear(
            self,
            _cmd,
            animated
        );
    }
}

static void
FBPPlayerViewDidDisappear(
    id self,
    SEL _cmd,
    BOOL animated
) {
    if (gOriginalPlayerViewDidDisappear) {
        gOriginalPlayerViewDidDisappear(
            self,
            _cmd,
            animated
        );
    }

    @synchronized([NSFileManager class]) {
        if (!gMediaOwnerPlayerVC ||
            gMediaOwnerPlayerVC == self) {

            gCurrentVariants = nil;
            gCurrentVideoID = nil;
            gCurrentItemVideoID = nil;
            gMediaOwnerPlayerVC = nil;
        }
    }

    dispatch_async(
        dispatch_get_main_queue(), ^{

        // Leaving the player: restore any chrome we stripped so recycled Shorts
        // views never leak a hidden state elsewhere. gOverlayHidden is kept, so
        // returning to Reels re-strips automatically.
        FBPUnhideAllOverlays();
        FBPShowTabBars();

        for (UIScene *scene in
             [UIApplication sharedApplication].connectedScenes) {

            if (![scene
                isKindOfClass:[UIWindowScene class]])
                continue;

            for (UIWindow *window in
                 ((UIWindowScene *)scene).windows) {

                NSInteger tags[] = { kFBPDownloadButtonTag,
                                     kFBPHideOverlayButtonTag };

                for (size_t i = 0; i < sizeof(tags) / sizeof(tags[0]); i++) {

                    UIButton *button =
                        (UIButton *)[window viewWithTag:tags[i]];

                    if (button) {
                        button.hidden = YES;
                        button.alpha = 0.0;
                    }
                }
            }
        }
    });
}

static BOOL
FBPInstallOneLifecycleHook(
    Class cls,
    SEL sel,
    IMP replacement,
    IMP *originalOut
) {
    Method method =
        class_getInstanceMethod(cls, sel);

    if (!method ||
        method_getNumberOfArguments(method) != 3)
        return NO;

    char *returnType =
        method_copyReturnType(method);

    BOOL valid =
        returnType &&
        returnType[0] == 'v';

    if (returnType)
        free(returnType);

    if (!valid)
        return NO;

    MSHookMessageEx(
        cls,
        sel,
        replacement,
        originalOut
    );

    return YES;
}

static void
FBPInstallLifecycleHooks(void) {
    if (gLifecycleHooksInstalled)
        return;

    Class cls =
        NSClassFromString(
            @"FBVideoHomeUnifiedPlayerViewController"
        );
    if (!cls)
        return;

    BOOL willAppearOK =
        FBPInstallOneLifecycleHook(
            cls,
            @selector(viewWillAppear:),
            (IMP)FBPPlayerViewWillAppear,
            (IMP *)&gOriginalPlayerViewWillAppear
        );

    BOOL didDisappearOK =
        FBPInstallOneLifecycleHook(
            cls,
            @selector(viewDidDisappear:),
            (IMP)FBPPlayerViewDidDisappear,
            (IMP *)&gOriginalPlayerViewDidDisappear
        );

    gLifecycleHooksInstalled =
        willAppearOK &&
        didDisappearOK;
}

#pragma mark - Hook installers

static void
FBPInstallPlayerHook(void) {

    if (gPlayerHookInstalled)
        return;

    Class cls =
        NSClassFromString(
            @"FBVideoHomeUnifiedPlayerViewController"
        );

    if (!cls)
        return;

    SEL sel =
        NSSelectorFromString(
            @"didStartPlaybackForVideo:"
            @"position:"
            @"analyticsContext:"
            @"playbackController:"
        );

    Method method =
        class_getInstanceMethod(
            cls,
            sel
        );

    if (!method)
        return;

    const char *encoding =
        method_getTypeEncoding(method);

    if (!encoding ||
        strcmp(
            encoding,
            "v48@0:8@16q24@32@40"
        ) != 0) {


        return;
    }

    MSHookMessageEx(
        cls,
        sel,
        (IMP)FBPDidStartPlayback,
        (IMP *)
            &gOriginalDidStartPlayback
    );

    gPlayerHookInstalled =
        YES;

}

static void
FBPInstallSidebarHook(void) {

    if (gSidebarHookInstalled)
        return;

    Class cls =
        NSClassFromString(
            @"FBShortsSideBarView"
        );

    if (!cls)
        return;

    SEL sel =
        @selector(didMoveToWindow);

    Method method =
        class_getInstanceMethod(
            cls,
            sel
        );

    if (!method)
        return;

    if (method_getNumberOfArguments(
        method) != 2)
        return;

    char *returnType =
        method_copyReturnType(
            method);

    BOOL valid =
        returnType &&
        returnType[0] == 'v';

    if (returnType)
        free(returnType);

    if (!valid)
        return;

    MSHookMessageEx(
        cls,
        sel,
        (IMP)FBPSidebarDidMoveToWindow,
        (IMP *)
            &gOriginalSidebarDidMoveToWindow
    );

    gSidebarHookInstalled =
        YES;

}

static void
FBPInstallHitTestHook(void) {

    if (gHitTestHookInstalled)
        return;

    Class cls =
        NSClassFromString(
            @"FBShortsCustomHitTestView"
        );

    if (!cls)
        return;

    SEL sel =
        @selector(layoutSubviews);

    // Only hook if this class defines -layoutSubviews itself. If it merely
    // inherited UIView's, hooking here would swizzle UIView globally.
    Class superCls =
        class_getSuperclass(cls);

    if (superCls &&
        class_getMethodImplementation(cls, sel) ==
            class_getMethodImplementation(superCls, sel))
        return;

    Method method =
        class_getInstanceMethod(
            cls,
            sel
        );

    if (!method ||
        method_getNumberOfArguments(method) != 2)
        return;

    char *returnType =
        method_copyReturnType(method);

    BOOL valid =
        returnType &&
        returnType[0] == 'v';

    if (returnType)
        free(returnType);

    if (!valid)
        return;

    MSHookMessageEx(
        cls,
        sel,
        (IMP)FBPHitTestLayoutSubviews,
        (IMP *)
            &gOriginalHitTestLayoutSubviews
    );

    gHitTestHookInstalled =
        YES;

}

void FBPInitReelsDownloader(void) {
    // Seed the quality diagnostic's cached flag and keep it in step with the
    // settings panel. Both download surfaces share it, and this installer is the
    // one FBPEntry always runs, so it is registered here; it is re-run on every
    // dyld image load, hence the latch.
    FBP_ONCE(gDownloadDiagnostic) { FBPDownloadInstallDiagnostic(); }

    // Start watching FBPDownloadStore so any download — from either surface —
    // raises a HUD pill that leads back to the manager. Registered here for the
    // same reason as the diagnostic: downloads in general, not Reels, and this
    // is the installer FBPEntry always runs.
    FBP_ONCE(gDownloadActivity) { FBPDownloadActivityInstall(); }

    FBPInstallPlayerHook();
    FBPInstallSidebarHook();
    FBPInstallLifecycleHooks();
    FBPInstallHitTestHook();
}
