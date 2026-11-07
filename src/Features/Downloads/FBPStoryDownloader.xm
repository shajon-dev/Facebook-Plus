#import "FBPlus.h"
#import "FBPHeaders.h"
#import "FBPPrefs.h"
#import "FBPResources.h"
#import "FBPDownloadVariants.h"
#import "FBPDashDownload.h"
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
static void FBPStorySaveToPhotos(NSURL *fileURL, BOOL isVideo, void (^then)(void)) {
    [[PHPhotoLibrary sharedPhotoLibrary]
     performChanges:^{
        if (isVideo) {
            [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:fileURL];
        } else {
            [PHAssetChangeRequest creationRequestForAssetFromImageAtFileURL:fileURL];
        }
    } completionHandler:^(BOOL success, NSError *error) {
        FBPStoryLog(@"Photos save success=%d type=%@ error=%@",
                    success, isVideo ? @"video" : @"photo", error);

        [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];

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

@interface FBPStoryDownloadDelegate : NSObject <NSURLSessionDownloadDelegate>
@property(nonatomic, copy) NSURL *sourceURL;
@end

@implementation FBPStoryDownloadDelegate

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    if (totalBytesExpectedToWrite > 0) {
        CGFloat p = (CGFloat)totalBytesWritten / (CGFloat)totalBytesExpectedToWrite;
        FBPStorySetProgress(p, YES);
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

    NSString *extension = gStoryMediaIsVideo ? @"mp4" : @"jpg";
    NSString *tmpName = [NSString stringWithFormat:@"FBP-Story-%@-%@.%@",
                         gStoryVideoID ?: (gStoryMediaIsVideo ? @"video" : @"photo"),
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

    FBPStorySaveToPhotos(dstURL, gStoryMediaIsVideo, ^{
        [session finishTasksAndInvalidate];
    });
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (!error) return;

    FBPStoryLog(@"download error: %@", error);
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

static void FBPStoryStartDownload(NSURL *sourceURL) {
    if (!FBPStoryDownloaderEnabled()) { FBPStoryHideButton(); return; }
    if (gStoryDownloading || !sourceURL) return;

    NSURL *url = [sourceURL copy];
    if (![url.scheme.lowercaseString hasPrefix:@"http"]) return;

    gStoryDownloading = YES;
    FBPStorySetButtonState(NO);
    FBPStorySetProgress(0.01, YES);

    FBPStoryLog(@"download start mediaID=%@ type=%@ url=%@", gStoryVideoID, gStoryMediaIsVideo ? @"video" : @"photo", url.absoluteString);

    FBPStoryDownloadDelegate *delegate = [FBPStoryDownloadDelegate new];
    delegate.sourceURL = url;

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

static void FBPStoryStartDashDownload(FBPDownloadVariant *variant) {
    if (!FBPStoryDownloaderEnabled()) { FBPStoryHideButton(); return; }
    if (gStoryDownloading || !variant.url || !variant.audioURL) return;

    gStoryDownloading = YES;

    // Same shape of name, in the same directory, as the single-file story path,
    // so the asset Photos ends up with is indistinguishable from one saved
    // before the DASH tier existed.
    NSString *tmpName = [NSString stringWithFormat:@"FBP-Story-%@-%@.mp4",
                         gStoryVideoID ?: @"video", NSUUID.UUID.UUIDString];
    NSURL *output = [NSURL fileURLWithPath:
        [NSTemporaryDirectory() stringByAppendingPathComponent:tmpName]];

    FBPStoryLog(@"dash download start mediaID=%@ video=%@ audio=%@",
                gStoryVideoID, variant.url.absoluteString,
                variant.audioURL.absoluteString);

    gStoryDashDownload = [FBPDashDownload
        startWithVideoURL:variant.url
                 audioURL:variant.audioURL
                outputURL:output
                 progress:^(FBPDashDownloadStage stage, float fraction) {
        // Driven even though FBPStorySetProgress swallows it, so that one
        // function stays the only thing between Stories and a visible bar if the
        // maintainer ever wants one.
        (void)stage;
        FBPStorySetProgress(fraction, YES);
    } completion:^(NSURL *merged, NSError *error) {
        gStoryDashDownload = nil;
        // Before the save, so the checkmark/xmark flash restores the download
        // glyph rather than the stop one.
        FBPStorySetStopGlyph(NO);

        if (merged) {
            FBPStoryLog(@"dash download merged -> %@", merged.path);
            FBPStorySaveToPhotos(merged, YES, nil);
            return;
        }

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

    FBPStorySetStopGlyph(YES);
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
            // A DASH rung is a video-only file plus a separate audio file, so it
            // takes the two-stream path and gets merged before it is saved.
            // Everything else is one complete MP4 and goes down the path it
            // always has.
            if (variant.needsMux) {
                FBPStoryStartDashDownload(variant);
                return;
            }
            FBPStoryStartDownload(variant.url);
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
