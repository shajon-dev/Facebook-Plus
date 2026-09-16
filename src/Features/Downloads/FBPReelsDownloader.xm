#import "FBPlus.h"
#import "FBPHeaders.h"
#import "FBPPrefs.h"

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

static NSURL *gCurrentDownloadURL = nil;
static NSString *gCurrentVideoID = nil;

static BOOL gPlayerHookInstalled = NO;
static BOOL gSidebarHookInstalled = NO;
static BOOL gLifecycleHooksInstalled = NO;

static __weak id gMediaOwnerPlayerVC = nil;

static const NSInteger kFBPDownloadButtonTag =
    0x46425044;

static NSHashTable<UIView *> *gSidebars = nil;

#pragma mark - Runtime helpers

static id FBPSafeObjectGetter(
    id object,
    NSString *getterName
) {
    if (!object || !getterName)
        return nil;

    SEL selector =
        NSSelectorFromString(getterName);

    Method method =
        class_getInstanceMethod(
            [object class],
            selector
        );

    if (!method)
        return nil;

    if (method_getNumberOfArguments(method) != 2)
        return nil;

    char *returnType =
        method_copyReturnType(method);

    BOOL valid =
        returnType &&
        returnType[0] == '@';

    if (returnType)
        free(returnType);

    if (!valid)
        return nil;

    @try {

        id (*sendObject)(id, SEL) =
            (id (*)(id, SEL))objc_msgSend;

        return sendObject(
            object,
            selector
        );

    } @catch (__unused NSException *e) {

        return nil;
    }
}

static NSURL *FBPURLFromObject(id object) {

    if (!object)
        return nil;

    if ([object
        isKindOfClass:
            [NSURL class]]) {

        return object;
    }

    if ([object
        isKindOfClass:
            [NSString class]]) {

        return [NSURL
            URLWithString:object];
    }

    return nil;
}

static NSURL *FBPPlaybackURLFromItem(id item, NSString **videoIDOut) {
    if (!item) return nil;

    NSURL *hdURL = FBPURLFromObject(FBPSafeObjectGetter(item, @"HDPlaybackURL"));
    NSURL *sdURL = FBPURLFromObject(FBPSafeObjectGetter(item, @"SDPlaybackURL"));
    NSURL *chosen = hdURL ?: sdURL;

    if (videoIDOut) {
        id rawID = FBPSafeObjectGetter(item, @"videoID");
        if ([rawID isKindOfClass:[NSString class]]) {
            *videoIDOut = [(NSString *)rawID copy];
        } else if (rawID) {
            *videoIDOut = [[rawID description] copy];
        } else {
            *videoIDOut = nil;
        }
    }

    return chosen;
}

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
                actionWithTitle:@"OK"
                style:
                    UIAlertActionStyleDefault
                handler:nil]];

        [vc
            presentViewController:alert
                         animated:YES
                       completion:nil];
    });
}

#pragma mark - Progress UI

@interface FBPDownloadProgressController :
    UIViewController

@property(nonatomic, strong)
    UIActivityIndicatorView *spinner;

@property(nonatomic, strong)
    UIProgressView *progressView;

@property(nonatomic, strong)
    UILabel *percentLabel;

@property(nonatomic, strong)
    UILabel *titleLabel;

- (void)setProgressValue:(float)value;

@end

@implementation FBPDownloadProgressController

- (void)viewDidLoad {

    [super viewDidLoad];

    self.view.backgroundColor =
        [UIColor systemBackgroundColor];

    self.preferredContentSize =
        CGSizeMake(280.0, 165.0);

    self.spinner =
        [[UIActivityIndicatorView alloc]
            initWithActivityIndicatorStyle:
                UIActivityIndicatorViewStyleMedium];

    self.spinner
        .translatesAutoresizingMaskIntoConstraints =
            NO;

    [self.spinner startAnimating];

    self.titleLabel =
        [[UILabel alloc] init];

    self.titleLabel
        .translatesAutoresizingMaskIntoConstraints =
            NO;

    self.titleLabel.text =
        @"Đang tải Reel...";

    self.titleLabel.font =
        [UIFont
            boldSystemFontOfSize:17.0];

    self.titleLabel.textAlignment =
        NSTextAlignmentCenter;

    self.progressView =
        [[UIProgressView alloc]
            initWithProgressViewStyle:
                UIProgressViewStyleDefault];

    self.progressView
        .translatesAutoresizingMaskIntoConstraints =
            NO;

    self.progressView.progress =
        0.0f;

    self.percentLabel =
        [[UILabel alloc] init];

    self.percentLabel
        .translatesAutoresizingMaskIntoConstraints =
            NO;

    self.percentLabel.text =
        @"0%";

    self.percentLabel.font =
        [UIFont
            monospacedDigitSystemFontOfSize:16.0
            weight:
                UIFontWeightSemibold];

    self.percentLabel.textAlignment =
        NSTextAlignmentCenter;

    [self.view
        addSubview:self.spinner];

    [self.view
        addSubview:self.titleLabel];

    [self.view
        addSubview:self.progressView];

    [self.view
        addSubview:self.percentLabel];

    [NSLayoutConstraint
        activateConstraints:@[

        [self.spinner.topAnchor
            constraintEqualToAnchor:
                self.view.topAnchor
                constant:20.0],

        [self.spinner.centerXAnchor
            constraintEqualToAnchor:
                self.view.centerXAnchor],

        [self.titleLabel.topAnchor
            constraintEqualToAnchor:
                self.spinner.bottomAnchor
                constant:8.0],

        [self.titleLabel.leadingAnchor
            constraintEqualToAnchor:
                self.view.leadingAnchor
                constant:20.0],

        [self.titleLabel.trailingAnchor
            constraintEqualToAnchor:
                self.view.trailingAnchor
                constant:-20.0],

        [self.progressView.topAnchor
            constraintEqualToAnchor:
                self.titleLabel.bottomAnchor
                constant:18.0],

        [self.progressView.leadingAnchor
            constraintEqualToAnchor:
                self.view.leadingAnchor
                constant:28.0],

        [self.progressView.trailingAnchor
            constraintEqualToAnchor:
                self.view.trailingAnchor
                constant:-28.0],

        [self.percentLabel.topAnchor
            constraintEqualToAnchor:
                self.progressView.bottomAnchor
                constant:9.0],

        [self.percentLabel.centerXAnchor
            constraintEqualToAnchor:
                self.view.centerXAnchor]
    ]];
}

- (void)setProgressValue:(float)value {

    value =
        MAX(
            0.0f,
            MIN(1.0f, value)
        );

    dispatch_async(
        dispatch_get_main_queue(), ^{

        [self.progressView
            setProgress:value
               animated:YES];

        NSInteger percent =
            (NSInteger)lrintf(
                value * 100.0f);

        self.percentLabel.text =
            [NSString
                stringWithFormat:
                    @"%ld%%",
                    (long)percent];

        if (percent >= 100) {

            self.titleLabel.text =
                @"Đã tải xong, đang lưu...";
        }
    });
}

@end

#pragma mark - Download manager

@interface FBPReelDownloadManager :
    NSObject
    <NSURLSessionDownloadDelegate>

@property(nonatomic, strong)
    NSURLSession *session;

@property(nonatomic, strong)
    NSURLSessionDownloadTask *task;

@property(nonatomic, strong)
    FBPDownloadProgressController
        *progressController;

@property(nonatomic, strong)
    UIViewController *progressContainer;

@property(nonatomic, copy)
    NSString *videoID;

@property(nonatomic, assign)
    BOOL downloading;

+ (instancetype)shared;

- (void)startDownloadWithURL:
    (NSURL *)url
    videoID:
    (NSString *)videoID;

@end

@implementation FBPReelDownloadManager

+ (instancetype)shared {

    static FBPReelDownloadManager *manager =
        nil;

    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{

        manager =
            [[FBPReelDownloadManager alloc]
                init];
    });

    return manager;
}

- (void)showProgress {

    dispatch_async(
        dispatch_get_main_queue(), ^{

        UIViewController *presenter =
            FBPTopViewController();

        if (!presenter)
            return;

        FBPDownloadProgressController
            *progress =
                [[FBPDownloadProgressController
                    alloc] init];

        UIAlertController *container =
            [UIAlertController
                alertControllerWithTitle:nil
                message:nil
                preferredStyle:
                    UIAlertControllerStyleAlert];

        @try {

            [container
                setValue:progress
                forKey:
                    @"contentViewController"];

        } @catch (__unused NSException *e) {

        }

        self.progressController =
            progress;

        self.progressContainer =
            container;

        [presenter
            presentViewController:container
                         animated:YES
                       completion:nil];
    });
}

- (void)dismissProgressWithCompletion:
    (void (^)(void))completion {

    dispatch_async(
        dispatch_get_main_queue(), ^{

        UIViewController *container =
            self.progressContainer;

        self.progressController =
            nil;

        self.progressContainer =
            nil;

        if (container &&
            container
                .presentingViewController) {

            [container
                dismissViewControllerAnimated:YES
                                   completion:
                    completion];

        } else if (completion) {

            completion();
        }
    });
}

- (void)finishWithError:
    (NSString *)message {

    self.downloading =
        NO;

    [self.session
        invalidateAndCancel];

    self.session =
        nil;

    self.task =
        nil;

    [self
        dismissProgressWithCompletion:^{

        FBPShowMessage(
            @"Facebook Plus",
            message ?:
                @"Tải Reel thất bại."
        );
    }];
}

- (void)saveVideo:
    (NSURL *)fileURL {


    [[PHPhotoLibrary
        sharedPhotoLibrary]
        performChanges:^{

        [PHAssetChangeRequest
            creationRequestForAssetFromVideoAtFileURL:
                fileURL];

    } completionHandler:^(
        BOOL success,
        NSError *error
    ) {

        [[NSFileManager
            defaultManager]
            removeItemAtURL:fileURL
                     error:nil];

        self.downloading =
            NO;

        [self.session
            finishTasksAndInvalidate];

        self.session =
            nil;

        self.task =
            nil;

        if (success) {


            [self
                dismissProgressWithCompletion:^{

                FBPShowMessage(
                    @"Facebook Plus",
                    @"Reel đã được lưu vào Photos ✓"
                );
            }];

        } else {


            [self
                dismissProgressWithCompletion:^{

                FBPShowMessage(
                    @"Facebook Plus",
                    [NSString
                        stringWithFormat:
                            @"Không lưu được vào Photos.\n%@",
                        error.localizedDescription
                            ?: @"Unknown error"]
                );
            }];
        }
    }];
}

- (void)startDownloadWithURL:
    (NSURL *)url
    videoID:
    (NSString *)videoID {

    if (!url)
        return;

    if (self.downloading) {

        FBPShowMessage(
            @"Facebook Plus",
            @"Một Reel đang được tải."
        );

        return;
    }

    self.downloading =
        YES;

    self.videoID =
        videoID ?: @"unknown";




    [self showProgress];

    NSURLSessionConfiguration *config =
        [NSURLSessionConfiguration
            defaultSessionConfiguration];

    config.requestCachePolicy =
        NSURLRequestReloadIgnoringLocalCacheData;

    config.timeoutIntervalForRequest =
        60.0;

    config.timeoutIntervalForResource =
        180.0;

    NSOperationQueue *queue =
        [[NSOperationQueue alloc]
            init];

    queue.maxConcurrentOperationCount =
        1;

    self.session =
        [NSURLSession
            sessionWithConfiguration:config
            delegate:self
            delegateQueue:queue];

    NSMutableURLRequest *request =
        [NSMutableURLRequest
            requestWithURL:url
            cachePolicy:
                NSURLRequestReloadIgnoringLocalCacheData
            timeoutInterval:60.0];

    request.HTTPMethod =
        @"GET";

    self.task =
        [self.session
            downloadTaskWithRequest:
                request];

    [self.task resume];
}

- (void)URLSession:
    (NSURLSession *)session
    downloadTask:
    (NSURLSessionDownloadTask *)downloadTask
    didWriteData:
    (int64_t)bytesWritten
    totalBytesWritten:
    (int64_t)totalBytesWritten
    totalBytesExpectedToWrite:
    (int64_t)totalBytesExpectedToWrite {

    if (totalBytesExpectedToWrite <= 0)
        return;

    float progress =
        (float)totalBytesWritten /
        (float)totalBytesExpectedToWrite;

    [self.progressController
        setProgressValue:progress];
}

- (void)URLSession:
    (NSURLSession *)session
    downloadTask:
    (NSURLSessionDownloadTask *)downloadTask
    didFinishDownloadingToURL:
    (NSURL *)location {

    NSHTTPURLResponse *response =
        [downloadTask.response
            isKindOfClass:
                [NSHTTPURLResponse class]]
        ? (NSHTTPURLResponse *)
            downloadTask.response
        : nil;

    NSInteger status =
        response
        ? response.statusCode
        : 0;


    if (status < 200 ||
        status >= 300) {

        [self
            finishWithError:
                [NSString
                    stringWithFormat:
                        @"Facebook CDN trả HTTP %ld.",
                        (long)status]];

        return;
    }

    NSString *filename =
        [NSString
            stringWithFormat:
                @"FBP-Reel-%@.mp4",
                self.videoID
                    ?: @"unknown"];

    NSString *path =
        [NSTemporaryDirectory()
            stringByAppendingPathComponent:
                filename];

    NSURL *destination =
        [NSURL
            fileURLWithPath:path];

    NSFileManager *fm =
        [NSFileManager
            defaultManager];

    [fm
        removeItemAtURL:destination
                 error:nil];

    NSError *moveError =
        nil;

    BOOL moved =
        [fm moveItemAtURL:location
                    toURL:destination
                    error:&moveError];

    if (!moved) {


        [self
            finishWithError:
                @"Không tạo được file video tạm."];

        return;
    }



    [self.progressController
        setProgressValue:1.0f];

    [self saveVideo:destination];
}

- (void)URLSession:
    (NSURLSession *)session
    task:
    (NSURLSessionTask *)task
    didCompleteWithError:
    (NSError *)error {

    if (!error)
        return;


    [self
        finishWithError:
            [NSString
                stringWithFormat:
                    @"Tải Reel thất bại.\n%@",
                error.localizedDescription
                    ?: @"Unknown error"]];
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

static BOOL FBPCaptureActivePlaybackController(UIButton *sender) {
    UIWindow *window = sender.window;
    if (!window) return NO;

    Class playerClass =
        NSClassFromString(@"FBVideoHomeUnifiedPlayerViewController");
    if (!playerClass) return NO;

    UIViewController *playerVC =
        FBPFindControllerOfClass(
            window.rootViewController,
            playerClass
        );
    if (!playerVC) return NO;

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
    if (!playbackController) return NO;

    id item =
        FBPSafeObjectGetter(
            playbackController,
            @"currentVideoPlaybackItem"
        );
    if (!item) return NO;

    NSString *videoID = nil;
    NSURL *url =
        FBPPlaybackURLFromItem(
            item,
            &videoID
        );
    if (!url) return NO;

    @synchronized([NSFileManager class]) {
        gCurrentDownloadURL = url;
        gCurrentVideoID = [videoID copy];
        gMediaOwnerPlayerVC = playerVC;
    }

    return YES;
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

@end

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

    NSURL *url = nil;
    NSString *videoID = nil;

    @synchronized([NSFileManager class]) {
        url = gCurrentDownloadURL;
        videoID = [gCurrentVideoID copy];
    }

    /*
     * Reels/swipe normally arrive through didStartPlayback.
     * The first video opened from Home can already be playing before that
     * callback reaches this controller, so resolve Facebook's active playback
     * controller on demand when the user actually taps Download.
     */
    if (!url &&
        FBPCaptureActivePlaybackController(sender)) {

        @synchronized([NSFileManager class]) {
            url = gCurrentDownloadURL;
            videoID = [gCurrentVideoID copy];
        }
    }

    if (!url) {
        FBPShowMessage(
            @"Facebook Plus",
            @"Chưa lấy được link của video này."
        );
        return;
    }

    [[FBPReelDownloadManager shared]
        startDownloadWithURL:url
        videoID:videoID];
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

    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration
            configurationWithPointSize:29.0
            weight:
                UIImageSymbolWeightMedium];

    UIImage *image =
        [UIImage
            systemImageNamed:
                @"arrow.down.to.line"
            withConfiguration:config];

    [button
        setImage:image
        forState:UIControlStateNormal];

    button.tintColor =
        [UIColor whiteColor];

    button.accessibilityLabel =
        @"Download Reel";

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

#pragma mark - Display-link tracker

@interface FBPReelButtonTracker : NSObject
@property(nonatomic, strong) CADisplayLink *displayLink;
@property(nonatomic, weak) UIView *lastSidebar;
@property(nonatomic, assign) CGRect lastCandidateFrame;
@property(nonatomic, assign) BOOL hasLastCandidateFrame;
@property(nonatomic, assign) NSInteger stableFrames;
@property(nonatomic, assign) BOOL buttonShown;
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

- (void)setButton:(UIButton *)button visible:(BOOL)visible {
    if (!button) return;

    if (visible) {
        if (self.buttonShown && !button.hidden && button.alpha > 0.99) return;
        self.buttonShown = YES;
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
        if (!self.buttonShown && (button.hidden || button.alpha < 0.01)) return;
        self.buttonShown = NO;
        button.userInteractionEnabled = NO;
        [UIView animateWithDuration:0.05
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionCurveEaseOut
                         animations:^{ button.alpha = 0.0; }
                         completion:^(BOOL finished) {
            if (finished && !self.buttonShown) button.hidden = YES;
        }];
    }
}

/*
 * Tìm UIScrollView đang chứa sidebar. Facebook có thể bọc sidebar qua nhiều
 * container, nên leo toàn bộ superview chain thay vì đoán class cụ thể.
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
 * Sidebar có thể vẫn còn window khi user đã chuyển sang tab khác.
 * Vì vậy sidebar.window != nil là CHƯA đủ để kết luận Reels đang hiển thị.
 * Kiểm tra toàn bộ ancestor tới UIWindow: chỉ cần một thằng hidden/alpha thấp
 * thì sidebar đó không còn là UI active.
 */
- (BOOL)sidebarHierarchyIsVisible:(UIView *)sidebar inWindow:(UIWindow *)window {
    if (!sidebar || !window || sidebar.window != window) return NO;

    UIView *view = sidebar;
    while (view && view != window) {
        if (view.hidden || view.alpha < 0.05) return NO;
        view = view.superview;
    }

    return view == window;
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

    // Production gate: OFF means no overlay at all. Also suppress the floating
    // Reels button while Facebook Plus settings is presented over the still-live
    // Reels hierarchy (long-press tab case).
    if (![FBPPrefs.shared boolForKey:FBPKeyReelsDownloaderEnabled] ||
        FBPPlusSettingsIsPresented(window)) {
        UIButton *existingButton = (UIButton *)[window viewWithTag:kFBPDownloadButtonTag];
        if (existingButton) [self setButton:existingButton visible:NO];
        self.lastSidebar = nil;
        self.hasLastCandidateFrame = NO;
        self.stableFrames = 0;
        return;
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
         * V0.27: candidate phải THỰC SỰ nằm trên màn hình hiện tại.
         * V0.26 cho trackingArea rộng tới ±1 màn hình nên sidebar của Reels
         * đã rời tab vẫn có thể thắng cuộc và giữ button sống như ma :)).
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
        UIButton *existingButton =
            (UIButton *)[window viewWithTag:kFBPDownloadButtonTag];

        if (existingButton) {
            [self setButton:existingButton visible:NO];
        }

        self.lastSidebar = nil;
        self.hasLastCandidateFrame = NO;
        self.stableFrames = 0;
        return;
    }

    UIButton *button = FBPGetOrCreateWindowButton(window);
    if (!button) return;

    /*
     * V0.27: DẸP HẲN chuyện button chạy theo Reel.
     *
     * - Ngón tay đang kéo UIScrollView => hide ngay, KHÔNG đổi frame button.
     * - Sau khi thả tay, Facebook còn decelerate/snap => candidate vẫn đổi,
     *   tiếp tục hide.
     * - Candidate đứng yên 5 frame => snap xong: đặt frame MỘT LẦN rồi show.
     *
     * Vì vậy lúc vuốt, button không bao giờ xuất hiện ở vị trí trung gian.
     */
    BOOL dragging = [self userIsDraggingSidebar:bestSidebar];

    if (dragging) {
        self.stableFrames = 0;
        self.lastSidebar = bestSidebar;
        self.lastCandidateFrame = bestButtonFrame;
        self.hasLastCandidateFrame = YES;
        [self setButton:button visible:NO];
        return;
    }

    if (!self.hasLastCandidateFrame || self.lastSidebar != bestSidebar) {
        self.lastSidebar = bestSidebar;
        self.lastCandidateFrame = bestButtonFrame;
        self.hasLastCandidateFrame = YES;
        self.stableFrames = 0;
        [self setButton:button visible:NO];
        return;
    }

    CGFloat dx = fabs(CGRectGetMidX(bestButtonFrame) - CGRectGetMidX(self.lastCandidateFrame));
    CGFloat dy = fabs(CGRectGetMidY(bestButtonFrame) - CGRectGetMidY(self.lastCandidateFrame));

    self.lastCandidateFrame = bestButtonFrame;

    /* Deceleration / snap vẫn đang chạy. */
    if (dx > 0.35 || dy > 0.35) {
        self.stableFrames = 0;
        [self setButton:button visible:NO];
        return;
    }

    self.stableFrames += 1;

    /*
     * Chờ 5 frame thực sự đứng yên rồi mới hiện. Không animate vị trí.
     * Frame chỉ được cập nhật đúng khoảnh khắc button còn đang hidden.
     */
    if (self.stableFrames >= 5) {
        CGRect finalFrame = CGRectIntegral(bestButtonFrame);
        button.frame = finalFrame;
        [window bringSubviewToFront:button];

        [self setButton:button visible:YES];

    }
}

@end

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

    id item =
        FBPSafeObjectGetter(
            playbackController,
            @"currentVideoPlaybackItem"
        );
    if (!item) return;

    NSString *itemVideoID = nil;
    NSURL *url =
        FBPPlaybackURLFromItem(
            item,
            &itemVideoID
        );
    if (!url) return;

    NSString *newID = nil;
    if ([videoID isKindOfClass:[NSString class]]) {
        newID = [(NSString *)videoID copy];
    } else if (videoID) {
        newID = [[videoID description] copy];
    } else {
        newID = itemVideoID;
    }

    @synchronized([NSFileManager class]) {
        gCurrentDownloadURL = url;
        gCurrentVideoID = [newID copy];
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

            gCurrentDownloadURL = nil;
            gCurrentVideoID = nil;
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

            gCurrentDownloadURL = nil;
            gCurrentVideoID = nil;
            gMediaOwnerPlayerVC = nil;
        }
    }

    dispatch_async(
        dispatch_get_main_queue(), ^{

        for (UIScene *scene in
             [UIApplication sharedApplication].connectedScenes) {

            if (![scene
                isKindOfClass:[UIWindowScene class]])
                continue;

            for (UIWindow *window in
                 ((UIWindowScene *)scene).windows) {

                UIButton *button =
                    (UIButton *)
                    [window
                        viewWithTag:
                            kFBPDownloadButtonTag];

                if (button) {
                    button.hidden = YES;
                    button.alpha = 0.0;
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

void FBPInitReelsDownloader(void) {
    FBPInstallPlayerHook();
    FBPInstallSidebarHook();
    FBPInstallLifecycleHooks();
}
