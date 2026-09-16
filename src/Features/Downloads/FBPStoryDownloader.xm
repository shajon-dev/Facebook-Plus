#import "FBPlus.h"
#import "FBPHeaders.h"
#import "FBPPrefs.h"
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
static NSURL *gStoryVideoURL = nil;
static NSString *gStoryVideoID = nil;
static BOOL gStoryMediaIsVideo = NO;
static UIButton *gStoryDownloadButton = nil;
static UIProgressView *gStoryProgress = nil;
static BOOL gStoryDownloading = NO;

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

static void FBPStoryShowSavedPopup(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = gStoryController;
        if (!vc || !vc.view.window || vc.presentedViewController) return;

        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:nil
                                                message:@"Đã lưu vào Photos"
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [vc presentViewController:alert animated:YES completion:nil];
    });
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

    BOOL isVideo = gStoryMediaIsVideo;
    [[PHPhotoLibrary sharedPhotoLibrary]
     performChanges:^{
        if (isVideo) {
            [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:dstURL];
        } else {
            [PHAssetChangeRequest creationRequestForAssetFromImageAtFileURL:dstURL];
        }
    } completionHandler:^(BOOL success, NSError *error) {
        FBPStoryLog(@"Photos save success=%d type=%@ error=%@",
                    success, isVideo ? @"video" : @"photo", error);

        [[NSFileManager defaultManager] removeItemAtURL:dstURL error:nil];

        dispatch_async(dispatch_get_main_queue(), ^{
            gStoryDownloading = NO;
            FBPStorySetButtonState(YES);
            FBPStorySetProgress(0, NO);
            FBPStoryFlashSymbol(success ? @"checkmark" : @"xmark");
            if (success) FBPStoryShowSavedPopup();
        });

        [session finishTasksAndInvalidate];
    }];
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

static void FBPStoryStartDownload(void) {
    if (!FBPStoryDownloaderEnabled()) { FBPStoryHideButton(); return; }
    if (gStoryDownloading || !gStoryVideoURL) return;

    NSURL *url = [gStoryVideoURL copy];
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
    FBPStoryStartDownload();
}
@end

static void FBPStoryInstallOrUpdateButton(UIViewController *vc) {
    if (!FBPStoryDownloaderEnabled()) { FBPStoryHideButton(); return; }
    if (!vc || !FBPStoryControllerVisible(vc) || !gStoryVideoURL) return;

    UIView *host = vc.view;
    if (!host) return;

    UIButton *button = (UIButton *)[host viewWithTag:kFBPStoryDownloadTag];
    if (![button isKindOfClass:UIButton.class]) {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = kFBPStoryDownloadTag;
        button.tintColor = UIColor.whiteColor;
        button.backgroundColor = UIColor.clearColor;
        button.frame = CGRectMake(0, 0, 38, 38);
        button.accessibilityLabel = @"Download Story";
        [button setImage:[UIImage systemImageNamed:@"arrow.down.to.line"]
                forState:UIControlStateNormal];
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

    // V1.1: the previous two-row position overlapped Facebook's eye/privacy
    // control. Move Download one full row farther down.
    CGFloat cx = CGRectGetWidth(host.bounds) - 24.0;
    CGFloat cy = 41.0 + (44.0 * 3.0);
    button.center = CGPointMake(cx, cy);
    progress.frame = CGRectMake(cx - 15.0, cy + 21.0, 30.0, 2.0);

    [host bringSubviewToFront:button];
    [host bringSubviewToFront:progress];

    button.hidden = NO;
    button.enabled = !gStoryDownloading;
    button.alpha = button.enabled ? 1.0 : 0.45;

    gStoryDownloadButton = button;
    gStoryProgress = progress;
}

static void FBPStoryCaptureCurrentVideo(id controller, id mediaView) {
    Class videoClass = objc_getClass("FBSnacksNewVideoView");
    if (!videoClass || !mediaView || ![mediaView isKindOfClass:videoClass]) return;

    id playbackController = FBPStoryObjectGetter(mediaView, @"playbackController");
    id item = FBPStoryObjectGetter(playbackController, @"currentVideoPlaybackItem");
    if (!item) return;

    id videoID = FBPStoryObjectGetter(item, @"videoID");
    id hd = FBPStoryObjectGetter(item, @"HDPlaybackURL");
    id sd = FBPStoryObjectGetter(item, @"SDPlaybackURL");

    NSURL *url = nil;
    if ([hd isKindOfClass:NSURL.class]) url = hd;
    else if ([hd isKindOfClass:NSString.class]) url = [NSURL URLWithString:hd];

    if (!url) {
        if ([sd isKindOfClass:NSURL.class]) url = sd;
        else if ([sd isKindOfClass:NSString.class]) url = [NSURL URLWithString:sd];
    }

    if (!url || ![url.scheme.lowercaseString hasPrefix:@"http"]) return;

    gStoryController = controller;
    gStoryMediaView = mediaView;
    gStoryMediaIsVideo = YES;
    gStoryVideoURL = [url copy];
    gStoryVideoID = [videoID isKindOfClass:NSString.class] ? [videoID copy] : [videoID description];

    FBPStoryLog(@"captured videoID=%@ url=%@", gStoryVideoID, gStoryVideoURL.absoluteString);

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
    gStoryVideoURL = [url copy];
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
