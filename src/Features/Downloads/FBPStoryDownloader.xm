#import "FBPlus.h"
#import "FBPHeaders.h"
#import "FBPPrefs.h"
#import "FBPResources.h"
#import "FBPDownloadVariants.h"
#import "FBPDashDownload.h"
#import "FBPDownloadStore.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <stdarg.h>
#import <string.h>

// Story Downloader
// iOS 17 / Facebook 578.1.0 discovery path:
// FBSnacksNewVideoView -> playbackController
// -> currentVideoPlaybackItem -> HDPlaybackURL (fallback SDPlaybackURL)
//
// Downloads current Story video/photo media and saves it to Photos.

static void (*gOrigStoryDidStartPlaying)(id, SEL, id, id) = NULL;
static BOOL gStoryHookInstalled = NO;

static __weak UIViewController *gStoryController = nil;
static __weak UIView *gStoryMediaView = nil;
// Every rendition of the current story, best first — resolved by the shared
// resolver in FBPDownloadVariants.m, the same one Reels uses. A photo story has
// exactly one, so it takes the same path with no special case.
static NSArray<FBPDownloadVariant *> *gStoryVariants = nil;
static NSString *gStoryVideoID = nil;
// Facebook's own title for the current story and its poster frame, when the
// playback item published them. Presentation only: they label the row in the
// download manager, and nil there just means the row says "Story".
static NSString *gStoryMediaTitle = nil;
static NSURL *gStoryThumbnailURL = nil;
static BOOL gStoryMediaIsVideo = NO;
static UIButton *gStoryDownloadButton = nil;
static UIProgressView *gStoryProgress = nil;
static BOOL gStoryDownloading = NO;
// The two-stream flow for a DASH rung, nil whenever the single-file path is what
// is running. Non-nil is also what turns the download button into a stop button:
// a story that is two transfers plus a merge is no longer instant, and a user who
// started one needs a way out of it.
static FBPDashDownload *gStoryDashDownload = nil;

static const NSInteger kFBPStoryDownloadTag = 0x53444C31; // SDL1
static const NSInteger kFBPStoryProgressTag = 0x53445031; // SDP1

static NSString *FBPStoryLogPath(void) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                           NSUserDomainMask,
                                                           YES) firstObject];
    return [docs stringByAppendingPathComponent:@"FBP-StoryDownload.txt"];
}

static void FBPStoryLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = FBPStoryLogPath();

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
        return;
    }

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) return;
    [fh seekToEndOfFile];
    [fh writeData:data];
    [fh closeFile];
}

static Method FBPStoryObjectGetterMethod(id obj, NSString *name) {
    if (!obj || !name.length) return NULL;
    SEL sel = NSSelectorFromString(name);
    Method m = class_getInstanceMethod(object_getClass(obj), sel);
    if (!m || method_getNumberOfArguments(m) != 2) return NULL;

    char ret[32] = {0};
    method_getReturnType(m, ret, sizeof(ret));
    return ret[0] == '@' ? m : NULL;
}

static id FBPStoryObjectGetter(id obj, NSString *name) {
    if (!FBPStoryObjectGetterMethod(obj, name)) return nil;
    @try {
        id (*sendObj)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        return sendObj(obj, NSSelectorFromString(name));
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static BOOL FBPStoryControllerVisible(UIViewController *vc) {
    if (!vc || !vc.isViewLoaded || !vc.view.window) return NO;
    UIView *v = vc.view;
    for (UIView *p = v; p; p = p.superview) {
        if (p.hidden || p.alpha < 0.05) return NO;
        if ([p isKindOfClass:UIWindow.class]) break;
    }
    return YES;
}

static BOOL FBPStoryDownloaderEnabled(void) {
    return [FBPPrefs.shared boolForKey:FBPKeyStoryDownloaderEnabled];
}

static void FBPStoryHideButton(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gStoryDownloadButton.hidden = YES;
        gStoryDownloadButton.userInteractionEnabled = NO;
        gStoryProgress.hidden = YES;
    });
}

static void FBPStorySetButtonState(BOOL enabled) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gStoryDownloadButton.enabled = enabled;
        gStoryDownloadButton.alpha = enabled ? 1.0 : 0.45;
    });
}

static void FBPStorySetProgress(CGFloat value, BOOL visible) {
    // V1.1: Story files are small; user requested no visible "downloading" UI.
    // Keep the progress object hidden for compatibility with the existing flow.
    (void)value;
    (void)visible;
    dispatch_async(dispatch_get_main_queue(), ^{
        gStoryProgress.hidden = YES;
    });
}

static void FBPShowStoryMessage(NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = gStoryController;
        if (!vc || !vc.view.window || vc.presentedViewController) return;

        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:nil
                                                message:message
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:FBPL(@"common.ok")
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [vc presentViewController:alert animated:YES completion:nil];
    });
}

static void FBPStoryShowSavedPopup(void) {
    FBPShowStoryMessage(FBPL(@"download.story.saved"));
}

static void FBPStoryFlashSymbol(NSString *symbol) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gStoryDownloadButton) return;
        UIImage *old = [gStoryDownloadButton imageForState:UIControlStateNormal];
        UIImage *img = [UIImage systemImageNamed:symbol];
        if (img) [gStoryDownloadButton setImage:img forState:UIControlStateNormal];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (gStoryDownloadButton && old)
                [gStoryDownloadButton setImage:old forState:UIControlStateNormal];
        });
    });
}

// Hand a finished local file to Photos, then clean up after it.
//
// Lifted out of the single-file delegate below, unchanged, so the two-stream
// path lands in exactly the same place: same PHAssetChangeRequest, same album
// behaviour, same temporary-file deletion, same feedback. @c then runs once the
// save has been attempted, which is where the single-file path invalidates its
// session.
static void FBPStorySaveToPhotos(NSURL *fileURL,
                                 BOOL isVideo,
                                 FBPDownloadJob *job,
                                 void (^then)(void)) {
    [FBPDownloadStore.shared job:job didEnterStage:FBPDownloadJobStageSaving];

    // Kept so the manager's row can offer "View in Photos" afterwards. Only
    // valid to read once the change block has been handed over.
    __block NSString *assetIdentifier = nil;

    [[PHPhotoLibrary sharedPhotoLibrary]
     performChanges:^{
        PHAssetChangeRequest *request = isVideo
            ? [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:fileURL]
            : [PHAssetChangeRequest creationRequestForAssetFromImageAtFileURL:fileURL];
        assetIdentifier = request.placeholderForCreatedAsset.localIdentifier;
    } completionHandler:^(BOOL success, NSError *error) {
        FBPStoryLog(@"Photos save success=%d type=%@ error=%@",
                    success, isVideo ? @"video" : @"photo", error);

        [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];

        if (success) {
            [FBPDownloadStore.shared job:job didFinishWithAssetIdentifier:assetIdentifier];
        } else {
            [FBPDownloadStore.shared job:job didFailWithError:error];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            gStoryDownloading = NO;
            FBPStorySetButtonState(YES);
            FBPStorySetProgress(0, NO);
            FBPStoryFlashSymbol(success ? @"checkmark" : @"xmark");
            if (success) {
                FBPStoryShowSavedPopup();
            } else {
                // Previously a silent xmark on this path. A save that Photos
                // refused is not something to flash past: it is the one failure
                // where the reason (permissions, storage, an unplayable file)
                // is actionable.
                FBPShowStoryMessage(
                    [NSString stringWithFormat:FBPL(@"download.reel.saveFailed"),
                              error.localizedDescription
                                  ?: FBPL(@"download.error.unknown")]);
            }
        });

        if (then) then();
    }];
}

/// An error whose localizedDescription is already the sentence to show.
///
/// This file's own wording for each failure is kept exactly as it was; wrapping
/// it in an NSError is only how it reaches the store, which reads
/// -localizedDescription for anything outside FBPDashDownload's own domain.
static NSError *FBPStoryError(NSString *message) {
    return [NSError errorWithDomain:@"com.shajon.fbplus.downloads"
                               code:1
                           userInfo:@{
        NSLocalizedDescriptionKey : message ?: FBPL(@"download.reel.failed"),
    }];
}

@interface FBPStoryDownloadDelegate : NSObject <NSURLSessionDownloadDelegate>
@property(nonatomic, copy) NSURL *sourceURL;
/// The manager's record of this transfer. Everything reported to it is in
/// addition to what this file already did; none of the existing feedback — the
/// glyph flash, the saved popup, the hidden progress view — changed.
@property(nonatomic, strong) FBPDownloadJob *job;
/// Whether *this* transfer is a video, captured when it started.
///
/// It used to read gStoryMediaIsVideo at completion time, which is the story on
/// screen when the download lands rather than the one it belongs to. That was
/// already wrong if the user swiped on mid-transfer, and the manager's Retry
/// makes it reachable on purpose: a photo retried later would be handed to
/// Photos as a video and refused.
@property(nonatomic, assign) BOOL isVideo;
@end

@implementation FBPStoryDownloadDelegate

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    FBPDownloadStore *store = FBPDownloadStore.shared;
    [store job:self.job
        didReceiveBytes:totalBytesWritten
               expected:(totalBytesExpectedToWrite > 0) ? totalBytesExpectedToWrite : 0];

    if (totalBytesExpectedToWrite > 0) {
        CGFloat p = (CGFloat)totalBytesWritten / (CGFloat)totalBytesExpectedToWrite;
        // Stories still shows no bar of its own (FBPStorySetProgress swallows
        // this); the manager is where the number is visible.
        FBPStorySetProgress(p, YES);
        [store job:self.job didProgress:(float)p];
    }
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    // A refused transfer still "finishes" — with the CDN's error body as its
    // payload — so without this an expired link was saved to Photos as a
    // seconds-long broken .mp4. 403 specifically means the signed URL's `oe=`
    // expiry has passed, which tapping download again fixes.
    NSHTTPURLResponse *response =
        [downloadTask.response isKindOfClass:NSHTTPURLResponse.class]
        ? (NSHTTPURLResponse *)downloadTask.response : nil;
    NSInteger status = response ? response.statusCode : 0;

    if (response && (status < 200 || status >= 300)) {
        FBPStoryLog(@"download rejected HTTP %ld", (long)status);
        NSString *message = (status == 403)
            ? FBPL(@"download.reel.expired")
            : [NSString stringWithFormat:FBPL(@"download.reel.httpError"), (long)status];
        [FBPDownloadStore.shared job:self.job didFailWithError:FBPStoryError(message)];

        dispatch_async(dispatch_get_main_queue(), ^{
            gStoryDownloading = NO;
            FBPStorySetButtonState(YES);
            FBPStorySetProgress(0, NO);
            FBPStoryFlashSymbol(@"xmark");
            if (status == 403) {
                FBPShowStoryMessage(FBPL(@"download.reel.expired"));
            }
        });
        [session finishTasksAndInvalidate];
        return;
    }

    NSString *extension = self.isVideo ? @"mp4" : @"jpg";
    NSString *tmpName = [NSString stringWithFormat:@"FBP-Story-%@-%@.%@",
                         gStoryVideoID ?: (self.isVideo ? @"video" : @"photo"),
                         NSUUID.UUID.UUIDString,
                         extension];
    NSString *dst = [NSTemporaryDirectory() stringByAppendingPathComponent:tmpName];
    NSURL *dstURL = [NSURL fileURLWithPath:dst];

    [[NSFileManager defaultManager] removeItemAtURL:dstURL error:nil];
    NSError *moveError = nil;
    if (![[NSFileManager defaultManager] moveItemAtURL:location
                                                 toURL:dstURL
                                                 error:&moveError]) {
        FBPStoryLog(@"move failed: %@", moveError);
        [FBPDownloadStore.shared job:self.job
                    didFailWithError:FBPStoryError(FBPL(@"download.reel.tmpFailed"))];

        dispatch_async(dispatch_get_main_queue(), ^{
            gStoryDownloading = NO;
            FBPStorySetButtonState(YES);
            FBPStorySetProgress(0, NO);
            FBPStoryFlashSymbol(@"xmark");
        });
        [session finishTasksAndInvalidate];
        return;
    }

    FBPStoryLog(@"download complete: %@", dst);

    FBPStorySaveToPhotos(dstURL, self.isVideo, self.job, ^{
        [session finishTasksAndInvalidate];
    });
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (!error) return;

    FBPStoryLog(@"download error: %@", error);
    // A transfer the user cancelled from the manager arrives here as
    // NSURLErrorCancelled; the store knows it was asked for and files the job as
    // cancelled rather than failed.
    [FBPDownloadStore.shared job:self.job didFailWithError:error];

    dispatch_async(dispatch_get_main_queue(), ^{
        gStoryDownloading = NO;
        FBPStorySetButtonState(YES);
        FBPStorySetProgress(0, NO);
        FBPStoryFlashSymbol(@"xmark");
    });
    [session finishTasksAndInvalidate];
}

@end

static NSMutableSet *gStoryDownloadDelegates = nil;

/// @param job The manager's record of this download.
/// @param isRetry YES when the manager restarted a finished job rather than the
///   user tapping the story's own button. A retry leaves the on-screen button
///   alone — it belongs to whatever story is showing now, not to the one being
///   retried — and is not blocked by another download being in flight, because
///   each transfer here already has its own delegate and session.
/// @param isVideo What this media is, decided by the caller when the download
///   was first started — never re-read from the globals later, which by then
///   describe whatever story is on screen.
static void FBPStoryStartDownload(NSURL *sourceURL,
                                  FBPDownloadJob *job,
                                  BOOL isRetry,
                                  BOOL isVideo) {
    if (!FBPStoryDownloaderEnabled()) { FBPStoryHideButton(); return; }
    if (!sourceURL || (!isRetry && gStoryDownloading)) return;

    NSURL *url = [sourceURL copy];
    if (![url.scheme.lowercaseString hasPrefix:@"http"]) return;

    if (!isRetry) {
        gStoryDownloading = YES;
        FBPStorySetButtonState(NO);
        FBPStorySetProgress(0.01, YES);
    }

    [FBPDownloadStore.shared job:job didEnterStage:FBPDownloadJobStageFetching];

    FBPStoryLog(@"download start mediaID=%@ type=%@ url=%@", gStoryVideoID, gStoryMediaIsVideo ? @"video" : @"photo", url.absoluteString);

    FBPStoryDownloadDelegate *delegate = [FBPStoryDownloadDelegate new];
    delegate.sourceURL = url;
    delegate.job = job;
    delegate.isVideo = isVideo;

    if (!gStoryDownloadDelegates) gStoryDownloadDelegates = [NSMutableSet set];
    [gStoryDownloadDelegates addObject:delegate];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 30.0;
    cfg.timeoutIntervalForResource = 300.0;

    NSOperationQueue *queue = [NSOperationQueue new];
    queue.maxConcurrentOperationCount = 1;

    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg
                                                         delegate:delegate
                                                    delegateQueue:queue];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"Mozilla/5.0" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDownloadTask *task = [session downloadTaskWithRequest:request];
    [task resume];

    // The single-file story path had no cancel before, because a story file was
    // small enough that there was nothing to back out of. The manager asks for
    // one anyway — a job sitting in a list with no way to stop it is the thing
    // this feature set out to remove — and a download task has always had one.
    [FBPDownloadStore.shared setCancelWork:^(__unused FBPDownloadJob *cancelled) {
        [task cancel];
    } forJob:job];

    // Keep delegate alive for the transfer; release it later after the normal max resource window.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(310.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [gStoryDownloadDelegates removeObject:delegate];
    });
}

// Turn the download button into a stop button, and back.
//
// Stories shows no progress bar — story files are small and the maintainer asked
// for no visible downloading UI — but a two-stream DASH save is two transfers
// and a merge, so it is neither small nor instant. Rather than break that
// promise with a bar, the one control already on screen carries the state: while
// a two-stream save runs the button is a stop glyph, and tapping it cancels.
// That keeps Stories silent and still gives cancel a route.
static void FBPStorySetStopGlyph(BOOL stop) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIButton *button = gStoryDownloadButton;
        if (!button) return;

        UIImage *image = stop ? [UIImage systemImageNamed:@"stop.circle"]
                              : [UIImage fbp_imageNamed:@"download"];
        if (image) [button setImage:image forState:UIControlStateNormal];

        // Stays enabled on purpose while a two-stream save runs: it is the only
        // way out of one. The single-file path still greys the button out.
        button.enabled = YES;
        button.alpha = 1.0;
    });
}

static void FBPStoryStartDashDownload(FBPDownloadVariant *variant,
                                      FBPDownloadJob *job,
                                      BOOL isRetry) {
    if (!FBPStoryDownloaderEnabled()) { FBPStoryHideButton(); return; }
    if (!variant.url || !variant.audioURL) return;
    if (!isRetry && gStoryDownloading) return;

    if (!isRetry) gStoryDownloading = YES;

    [FBPDownloadStore.shared job:job didEnterStage:FBPDownloadJobStageFetching];

    // Same shape of name, in the same directory, as the single-file story path,
    // so the asset Photos ends up with is indistinguishable from one saved
    // before the DASH tier existed.
    NSString *tmpName = [NSString stringWithFormat:@"FBP-Story-%@-%@.mp4",
                         gStoryVideoID ?: @"video", NSUUID.UUID.UUIDString];
    NSURL *output = [NSURL fileURLWithPath:
        [NSTemporaryDirectory() stringByAppendingPathComponent:tmpName]];

    FBPStoryLog(@"dash download start mediaID=%@ video=%@ audio=%@ retry=%d",
                gStoryVideoID, variant.url.absoluteString,
                variant.audioURL.absoluteString, isRetry);

    FBPDashDownload *flow = [FBPDashDownload
        startWithVideoURL:variant.url
                 audioURL:variant.audioURL
                outputURL:output
                 progress:^(FBPDashDownloadStage stage, float fraction) {
        // Driven even though FBPStorySetProgress swallows it, so that one
        // function stays the only thing between Stories and a visible bar if the
        // maintainer ever wants one. The manager shows the real number.
        FBPStorySetProgress(fraction, YES);

        FBPDownloadStore *store = FBPDownloadStore.shared;
        [store job:job didProgress:fraction];
        [store job:job didEnterStage:(stage == FBPDashDownloadStageMerging)
                                         ? FBPDownloadJobStageMerging
                                         : FBPDownloadJobStageFetching];
    } completion:^(NSURL *merged, NSError *error) {
        // A retry started from the manager never owned the on-screen button or
        // the global flow handle — the story it belongs to left the screen long
        // ago — so it touches neither on the way out.
        if (!isRetry) {
            gStoryDashDownload = nil;
            // Before the save, so the checkmark/xmark flash restores the
            // download glyph rather than the stop one.
            FBPStorySetStopGlyph(NO);
        }

        if (merged) {
            FBPStoryLog(@"dash download merged -> %@", merged.path);
            FBPStorySaveToPhotos(merged, YES, job, nil);
            return;
        }

        // The flow's errors travel in its own domain, so the store's message
        // builder keeps folding a 403 on either stream into the expired-link
        // wording, and records a cancellation as one rather than a failure.
        [FBPDownloadStore.shared job:job didFailWithError:error];

        if (isRetry) return;

        gStoryDownloading = NO;
        FBPStorySetButtonState(YES);
        FBPStorySetProgress(0, NO);

        NSString *message = FBPDashDownloadMessageForError(error);
        if (!message) {
            // Cancelled by the user. Nothing saved, nothing left behind, and no
            // need to report back what they just asked for.
            FBPStoryLog(@"dash download cancelled");
            return;
        }

        // Unmistakable on purpose: with no progress bar, a silent xmark was the
        // only sign a story download had failed, and it was easy to miss.
        FBPStoryLog(@"dash download failed: %@", error);
        FBPStoryFlashSymbol(@"xmark");
        FBPShowStoryMessage(message);
    }];

    [FBPDownloadStore.shared setCancelWork:^(__unused FBPDownloadJob *cancelled) {
        [flow cancel];
    } forJob:job];

    if (!isRetry) {
        gStoryDashDownload = flow;
        FBPStorySetStopGlyph(YES);
    }
}

/// The one way a story download starts, from a tap or from the manager's Retry.
///
/// Creating the job here — rather than inside either path — is what lets the
/// retry work be a block that captures only the variant: it re-enters this
/// function with the job it is retrying, and the two paths below attach to it.
static void FBPStoryBeginDownload(FBPDownloadVariant *variant,
                                  FBPDownloadJob *existing,
                                  BOOL isVideo) {
    if (!variant.url) return;

    FBPDownloadStore *store = FBPDownloadStore.shared;
    BOOL isRetry = (existing != nil);
    FBPDownloadJob *job = existing;

    if (!job) {
        job = [store addJobWithSurface:FBPDownloadJobSurfaceStory
                                 title:gStoryMediaTitle
                               quality:variant.title
                          thumbnailURL:gStoryThumbnailURL
                              needsMux:variant.needsMux
                         expectedBytes:variant.byteSize];

        // Captures the variant and the media type and nothing else, so the
        // block the job keeps for the session holds no session, no task and no
        // temporary file — and does not go looking at the globals, which by the
        // time Retry is pressed describe a different story. It re-runs from the
        // same URLs, which by then may have passed their `oe=` expiry — in which
        // case it reports exactly that, and the user taps download on the story
        // itself.
        FBPDownloadVariant *retryVariant = variant;
        BOOL retryIsVideo = isVideo;
        [store setRetryWork:^(FBPDownloadJob *retried) {
            FBPStoryBeginDownload(retryVariant, retried, retryIsVideo);
        } forJob:job];
    }

    // A DASH rung is a video-only file plus a separate audio file, so it takes
    // the two-stream path and gets merged before it is saved. Everything else is
    // one complete MP4 — or a photo — and goes down the path it always has.
    if (variant.needsMux) {
        FBPStoryStartDashDownload(variant, job, isRetry);
    } else {
        FBPStoryStartDownload(variant.url, job, isRetry, isVideo);
    }
}

@interface FBPStoryDownloadTarget : NSObject
+ (instancetype)shared;
- (void)downloadTapped:(UIButton *)sender;
@end

@implementation FBPStoryDownloadTarget
+ (instancetype)shared {
    static FBPStoryDownloadTarget *obj;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ obj = [FBPStoryDownloadTarget new]; });
    return obj;
}
- (void)downloadTapped:(UIButton *)sender {
    FBPStoryLog(@"button tapped currentVideoID=%@", gStoryVideoID);

    // While a two-stream save is running this button is a stop button — see
    // FBPStorySetStopGlyph. Checked first, before any re-resolution: the tap
    // means "stop", not "start another".
    if (gStoryDashDownload) {
        [gStoryDashDownload cancel];
        return;
    }

    NSArray<FBPDownloadVariant *> *variants = gStoryVariants;

    // Re-resolve at tap time. Story playback URLs are signed and carry a short
    // `oe=` expiry, and the picker sheet below can stay open for as long as the
    // user takes to choose, so the list read at the moment of the tap is the
    // only one worth trusting. The live read is only used when it produces
    // something; otherwise the captured list stands.
    //
    // Only video stories can be re-resolved — a photo story's single URL comes
    // from the controller's own -_getMediaUrl and has no playback item behind it.
    id playbackController = nil;
    id item = nil;

    if (gStoryMediaIsVideo && gStoryMediaView) {
        playbackController = FBPStoryObjectGetter(gStoryMediaView, @"playbackController");
        FBPDownloadSource *live =
            FBPDownloadSourceFromPlaybackController(playbackController);
        item = live.item;
        if (live.variants.count > 0) {
            variants = live.variants;
            gStoryVariants = live.variants;
            if (live.videoID.length > 0) gStoryVideoID = [live.videoID copy];
        }
    }

    if (variants.count == 0) {
        FBPStoryLog(@"tap with nothing downloadable captured");
        return;
    }

    // Diagnostic (off by default, free when off).
    FBPDownloadLogQualities(item, playbackController, variants);

    // And again on the pick, for the same expiry reason: the tap-time read
    // above is already stale by the time a sheet the user studied is dismissed.
    // Video stories only, for the same reason as above.
    // Assigned to a typed variable rather than written inline as a ternary:
    // this file compiles as Objective-C++, where `cond ? block : nil` cannot be
    // reconciled with nullptr.
    FBPDownloadVariantRefresher storyRefresh = nil;
    if (gStoryMediaIsVideo && gStoryMediaView != nil) {
        storyRefresh = ^NSArray<FBPDownloadVariant *> *{
            id view = gStoryMediaView;
            if (!gStoryMediaIsVideo || !view) return nil;
            id controller = FBPStoryObjectGetter(view, @"playbackController");
            return FBPDownloadSourceFromPlaybackController(controller).variants;
        };
    }

    FBPDownloadPresentPicker(
        variants,
        gStoryController,
        sender,
        storyRefresh,
        ^(FBPDownloadVariant *variant) {
            // One entry point now, which registers the job with the download
            // manager before routing to the single-file or two-stream path. The
            // media type is read here, at the tap, and travels with the job.
            FBPStoryBeginDownload(variant, nil, gStoryMediaIsVideo);
        }
    );
}
@end

static void FBPStoryInstallOrUpdateButton(UIViewController *vc) {
    if (!FBPStoryDownloaderEnabled()) { FBPStoryHideButton(); return; }
    if (!vc || !FBPStoryControllerVisible(vc) || gStoryVariants.count == 0) return;

    UIView *host = vc.view;
    if (!host) return;

    UIButton *button = (UIButton *)[host viewWithTag:kFBPStoryDownloadTag];
    if (![button isKindOfClass:UIButton.class]) {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = kFBPStoryDownloadTag;
        button.tintColor = UIColor.whiteColor;
        button.backgroundColor = UIColor.clearColor;
        button.frame = CGRectMake(0, 0, 38, 38);
        button.accessibilityLabel = FBPL(@"download.story.a11y");
        [button setImage:[UIImage fbp_imageNamed:@"download"]
                forState:UIControlStateNormal];
        button.imageView.contentMode = UIViewContentModeScaleAspectFit;
        // Match the eye (mark-as-seen) button's glyph size in FBPStoryHooks.xm,
        // which in turn matches Facebook's own header controls.
        button.contentEdgeInsets = UIEdgeInsetsMake(8, 8, 8, 8);
        [button addTarget:[FBPStoryDownloadTarget shared]
                   action:@selector(downloadTapped:)
         forControlEvents:UIControlEventTouchUpInside];
        [host addSubview:button];
    }

    UIProgressView *progress = (UIProgressView *)[host viewWithTag:kFBPStoryProgressTag];
    if (![progress isKindOfClass:UIProgressView.class]) {
        progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        progress.tag = kFBPStoryProgressTag;
        progress.hidden = YES;
        [host addSubview:progress];
    }

    // Sit directly under the eye (mark-as-seen) button, on the same right-hand
    // axis and one row-gap below it. This mirrors the eye button's grid in
    // FBPStoryHooks.xm: centre = safe-area top + header row (41) + one gap (44)
    // per row. The eye is at row 1 (safeTop + 41 + 44); Download is the next row.
    static const CGFloat kHeaderRowCentre = 41.0;
    static const CGFloat kCloseCentreFromRight = 24.0;
    static const CGFloat kRowGap = 44.0;
    CGFloat cx = CGRectGetWidth(host.bounds) - host.safeAreaInsets.right - kCloseCentreFromRight;
    CGFloat cy = host.safeAreaInsets.top + kHeaderRowCentre + kRowGap * 2.0;
    button.center = CGPointMake(cx, cy);
    progress.frame = CGRectMake(cx - 15.0, cy + 21.0, 30.0, 2.0);

    [host bringSubviewToFront:button];
    [host bringSubviewToFront:progress];

    button.hidden = NO;
    // A running two-stream save keeps the button live, because it is that
    // download's stop control for as long as it lasts — including across a
    // layout pass triggered by the next story starting to play.
    button.enabled = !gStoryDownloading || gStoryDashDownload != nil;
    button.alpha = button.enabled ? 1.0 : 0.45;

    gStoryDownloadButton = button;
    gStoryProgress = progress;

    if (gStoryDashDownload) FBPStorySetStopGlyph(YES);
}

static void FBPStoryCaptureCurrentVideo(id controller, id mediaView) {
    Class videoClass = objc_getClass("FBSnacksNewVideoView");
    if (!videoClass || !mediaView || ![mediaView isKindOfClass:videoClass]) return;

    // The HD/SD longhand that used to live here is gone: both download surfaces
    // now go through the one resolver in FBPDownloadVariants.m, so Stories gets
    // the quality picker for free and a new format only has to be taught once.
    id playbackController = FBPStoryObjectGetter(mediaView, @"playbackController");
    FBPDownloadSource *source =
        FBPDownloadSourceFromPlaybackController(playbackController);
    if (source.variants.count == 0) return;

    gStoryController = controller;
    gStoryMediaView = mediaView;
    gStoryMediaIsVideo = YES;
    gStoryVariants = source.variants;
    gStoryVideoID = [source.videoID copy];
    gStoryMediaTitle = [source.mediaTitle copy];
    gStoryThumbnailURL = [source.thumbnailURL copy];

    FBPStoryLog(@"captured videoID=%@ variants=%lu best=%@", gStoryVideoID,
                (unsigned long)source.variants.count,
                source.variants.firstObject.url.absoluteString);

    dispatch_async(dispatch_get_main_queue(), ^{
        FBPStoryInstallOrUpdateButton((UIViewController *)controller);
    });
}

static void FBPStoryCaptureCurrentPhoto(id controller, id mediaView) {
    Class photoClass = objc_getClass("FBSnacksPhotoView");
    if (!photoClass || !mediaView || ![mediaView isKindOfClass:photoClass]) return;

    // V0.2 proved _getMediaUrl returns the real image URL for photo Stories.
    id raw = FBPStoryObjectGetter(controller, @"_getMediaUrl");
    NSURL *url = nil;
    if ([raw isKindOfClass:NSURL.class]) url = raw;
    else if ([raw isKindOfClass:NSString.class]) url = [NSURL URLWithString:raw];

    if (!url || ![url.scheme.lowercaseString hasPrefix:@"http"]) {
        FBPStoryLog(@"photo Story has no direct HTTP media URL: %@", raw);
        return;
    }

    gStoryController = controller;
    gStoryMediaView = mediaView;
    gStoryMediaIsVideo = NO;
    // One rendition, so the picker is skipped entirely and the tap behaves
    // exactly as it did before quality selection existed.
    gStoryVariants = FBPDownloadSingleVariant(url, nil);
    gStoryVideoID = [NSString stringWithFormat:@"photo-%lu",
                     (unsigned long)url.absoluteString.hash];
    gStoryMediaTitle = nil;
    // A photo story's own media URL *is* its thumbnail, so the manager's row
    // gets a real preview for free — no extra getter, no second request beyond
    // the one the list makes anyway.
    gStoryThumbnailURL = url;

    FBPStoryLog(@"captured PHOTO url=%@", url.absoluteString);

    dispatch_async(dispatch_get_main_queue(), ^{
        FBPStoryInstallOrUpdateButton((UIViewController *)controller);
    });
}

static void FBPStoryDidStartPlayingHook(id self, SEL _cmd, id mediaView, id info) {
    if (gOrigStoryDidStartPlaying)
        gOrigStoryDidStartPlaying(self, _cmd, mediaView, info);

    if (!FBPStoryDownloaderEnabled()) {
        FBPStoryHideButton();
        return;
    }

    Class videoClass = objc_getClass("FBSnacksNewVideoView");
    if (videoClass && mediaView && [mediaView isKindOfClass:videoClass]) {
        FBPStoryCaptureCurrentVideo(self, mediaView);
        return;
    }

    FBPStoryCaptureCurrentPhoto(self, mediaView);
}

static void FBPInstallStoryDownloader(void) {
    if (gStoryHookInstalled) return;

    Class cls = objc_getClass("FBSnacksBucketViewController");
    if (!cls) return;

    SEL sel = NSSelectorFromString(@"mediaView:didStartPlayingWithInfo:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    const char *enc = method_getTypeEncoding(m);
    if (!enc || strcmp(enc, "v32@0:8@16@24") != 0) {
        FBPStoryLog(@"REFUSED hook unexpected encoding=%s", enc ?: "(null)");
        return;
    }

    @synchronized (cls) {
        if (gStoryHookInstalled) return;
        MSHookMessageEx(cls, sel,
                        (IMP)FBPStoryDidStartPlayingHook,
                        (IMP *)&gOrigStoryDidStartPlaying);
        gStoryHookInstalled = YES;
    }

    FBPStoryLog(@"Story Downloader V1.0 installed");
}

__attribute__((constructor))
static void FBPStoryDownloaderCtor(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        FBPInstallStoryDownloader();

        if (!gStoryHookInstalled) {
            __block NSInteger attempts = 0;
            __block NSTimer *timer = nil;
            timer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(__unused NSTimer *t) {
                attempts++;
                FBPInstallStoryDownloader();
                if (gStoryHookInstalled || attempts >= 30) {
                    [timer invalidate];
                    timer = nil;
                }
            }];
        }
    });
}
