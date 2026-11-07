// The manager list, its row, the poster-frame cache, and the HUD pill that
// stands in for the progress popup this replaced.

#import "FBPDownloadManagerController.h"
#import "FBPDownloadStore.h"
#import "FBPResources.h"
#import "FBPSheet.h"
#import "FBPToast.h"

#import <Photos/Photos.h>

static NSString *const kJobCell = @"fbp.download.job";

static const CGFloat kRowHeight = 78.0;
static const CGFloat kThumbWidth = 44.0;
static const CGFloat kThumbHeight = 58.0;
static const CGFloat kInset = 16.0;

#pragma mark - Poster frames

/// Small in-memory cache of the poster frames the rows show.
///
/// A thumbnail is decoration: it is fetched once per URL, never retried, never
/// persisted, and a row without one shows a glyph. Capped by count *and* by
/// total cost so a long session cannot turn the list into a photo album.
static NSCache<NSString *, UIImage *> *FBPDownloadThumbnailCache(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 40;
        cache.totalCostLimit = 8 * 1024 * 1024;
    });
    return cache;
}

/// URLs already being fetched, so a reload during a fetch does not start a
/// second one for the same row.
static NSMutableSet<NSString *> *FBPDownloadThumbnailsInFlight(void) {
    static NSMutableSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

/// Fetch a poster frame, then call @c then on the main queue. Never calls back
/// on failure — the row keeps its glyph.
static void FBPDownloadLoadThumbnail(NSURL *url, void (^then)(UIImage *image)) {
    NSString *key = url.absoluteString;
    if (key.length == 0 || !then) return;

    UIImage *cached = [FBPDownloadThumbnailCache() objectForKey:key];
    if (cached) { then(cached); return; }

    NSMutableSet *inFlight = FBPDownloadThumbnailsInFlight();
    if ([inFlight containsObject:key]) return;
    [inFlight addObject:key];

    NSURLSessionDataTask *task = [NSURLSession.sharedSession
        dataTaskWithURL:url
      completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http =
            [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        BOOL ok = !error && data.length > 0 && data.length < 4 * 1024 * 1024 &&
                  (!http || (http.statusCode >= 200 && http.statusCode < 300));
        UIImage *image = ok ? [UIImage imageWithData:data] : nil;

        dispatch_async(dispatch_get_main_queue(), ^{
            [FBPDownloadThumbnailsInFlight() removeObject:key];
            if (!image) return;
            [FBPDownloadThumbnailCache() setObject:image forKey:key cost:(NSUInteger)data.length];
            then(image);
        });
    }];
    [task resume];
}

#pragma mark - Row

/// FBP-prefixed so the OLED sweep leaves its card colour alone, like every other
/// cell the tweak draws.
@interface FBPDownloadJobCell : UITableViewCell
@property (nonatomic, strong) UIImageView *thumbView;
@property (nonatomic, strong) UIImageView *placeholderView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *stageLabel;
@property (nonatomic, strong) UILabel *bytesLabel;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UIButton *actionButton;
/// Identifies the job this cell was last configured for, so a thumbnail that
/// arrives after the cell was reused is dropped instead of landing on a
/// different download's row.
@property (nonatomic, copy, nullable) NSString *jobIdentifier;
@property (nonatomic, copy, nullable) void (^actionHandler)(void);
@end

@implementation FBPDownloadJobCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = FBPCardColor();
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _thumbView = [[UIImageView alloc] init];
        _thumbView.contentMode = UIViewContentModeScaleAspectFill;
        _thumbView.clipsToBounds = YES;
        _thumbView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.07];
        _thumbView.layer.cornerRadius = 8.0;
        _thumbView.layer.cornerCurve = kCACornerCurveContinuous;
        _thumbView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_thumbView];

        // Shown inside the thumbnail slot whenever there is no poster frame, so
        // the row never has a grey hole in it.
        _placeholderView = [[UIImageView alloc] init];
        _placeholderView.contentMode = UIViewContentModeScaleAspectFit;
        _placeholderView.tintColor = [UIColor colorWithWhite:1.0 alpha:0.35];
        _placeholderView.translatesAutoresizingMaskIntoConstraints = NO;
        [_thumbView addSubview:_placeholderView];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = FBPFont(15, UIFontWeightMedium);
        _titleLabel.textColor = UIColor.labelColor;
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;

        _stageLabel = [[UILabel alloc] init];
        _stageLabel.font = FBPFont(12, UIFontWeightRegular);
        _stageLabel.textColor = UIColor.secondaryLabelColor;
        _stageLabel.numberOfLines = 2;

        _bytesLabel = [[UILabel alloc] init];
        _bytesLabel.font = [UIFont monospacedDigitSystemFontOfSize:11
                                                            weight:UIFontWeightRegular];
        _bytesLabel.textColor = UIColor.tertiaryLabelColor;

        UIStackView *text = [[UIStackView alloc]
            initWithArrangedSubviews:@[_titleLabel, _stageLabel, _bytesLabel]];
        text.axis = UILayoutConstraintAxisVertical;
        text.alignment = UIStackViewAlignmentFill;
        text.spacing = 2;
        text.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:text];

        _progressView = [[UIProgressView alloc]
            initWithProgressViewStyle:UIProgressViewStyleDefault];
        _progressView.progressTintColor = FBPTintColor();
        _progressView.trackTintColor = [UIColor colorWithWhite:1.0 alpha:0.12];
        _progressView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_progressView];

        _actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _actionButton.tintColor = FBPTintColor();
        _actionButton.translatesAutoresizingMaskIntoConstraints = NO;
        [_actionButton addTarget:self
                          action:@selector(actionTapped)
                forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:_actionButton];

        [NSLayoutConstraint activateConstraints:@[
            [_thumbView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor
                                                     constant:kInset],
            [_thumbView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_thumbView.widthAnchor constraintEqualToConstant:kThumbWidth],
            [_thumbView.heightAnchor constraintEqualToConstant:kThumbHeight],

            [_placeholderView.centerXAnchor constraintEqualToAnchor:_thumbView.centerXAnchor],
            [_placeholderView.centerYAnchor constraintEqualToAnchor:_thumbView.centerYAnchor],
            [_placeholderView.widthAnchor constraintEqualToConstant:20],
            [_placeholderView.heightAnchor constraintEqualToConstant:20],

            [text.leadingAnchor constraintEqualToAnchor:_thumbView.trailingAnchor constant:12],
            [text.topAnchor constraintEqualToAnchor:_thumbView.topAnchor constant:-1],
            [text.trailingAnchor constraintEqualToAnchor:_actionButton.leadingAnchor
                                                constant:-10],

            [_progressView.leadingAnchor constraintEqualToAnchor:text.leadingAnchor],
            [_progressView.trailingAnchor constraintEqualToAnchor:text.trailingAnchor],
            [_progressView.bottomAnchor constraintEqualToAnchor:_thumbView.bottomAnchor
                                                       constant:-1],

            [_actionButton.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor
                                                         constant:-kInset],
            [_actionButton.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_actionButton.widthAnchor constraintEqualToConstant:34],
            [_actionButton.heightAnchor constraintEqualToConstant:34],
        ]];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.jobIdentifier = nil;
    self.actionHandler = nil;
    self.thumbView.image = nil;
    self.placeholderView.hidden = NO;
}

- (void)actionTapped {
    if (self.actionHandler) self.actionHandler();
}

@end

#pragma mark - Manager

@implementation FBPDownloadManagerController {
    NSArray<FBPDownloadJob *> *_jobs;
}

+ (void)presentFromViewController:(UIViewController *)viewController {
    UIViewController *host = viewController ?: [FBPSheetPresenter topViewController];
    while (host.presentedViewController) host = host.presentedViewController;
    if (!host) {
        FBPLog(@"no host view controller — cannot present the download manager");
        return;
    }

    FBPDownloadManagerController *manager = [[FBPDownloadManagerController alloc] init];
    UINavigationController *navigation =
        [[UINavigationController alloc] initWithRootViewController:manager];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    navigation.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    // Paint it black up front, the same reason FBPSettingsController does: the
    // cards otherwise arrive a frame before the background behind them.
    navigation.view.backgroundColor = FBPPanelColor();
    [host presentViewController:navigation animated:YES completion:nil];
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = FBPL(@"download.manager.title");

    // Fixed dark panel, matching the rest of the tweak's own screens.
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.tintColor = FBPTintColor();
    self.tableView.backgroundColor = FBPPanelColor();
    UIView *panel = [[UIView alloc] init];
    panel.backgroundColor = FBPPanelColor();
    self.tableView.backgroundView = panel;
    self.tableView.separatorInset = UIEdgeInsetsMake(0, kInset, 0, 0);
    self.tableView.separatorColor = [UIColor colorWithWhite:1 alpha:0.08];
    self.tableView.rowHeight = kRowHeight;
    if (@available(iOS 15.0, *)) self.tableView.sectionHeaderTopPadding = 0;
    [self.tableView registerClass:FBPDownloadJobCell.class forCellReuseIdentifier:kJobCell];

    // Presented on its own (from the HUD pill) there is no stack to pop back to,
    // so it needs its own way out. Pushed from Settings the back button is
    // already there and this stays absent.
    if (self.navigationController.viewControllers.firstObject == self) {
        self.navigationItem.leftBarButtonItem =
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                          target:self
                                                          action:@selector(closeTapped)];
    }

    [self applyNavigationChrome];
    [self reload];

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(storeDidChange)
                                               name:FBPDownloadStoreDidChangeNotification
                                             object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

/// A black, opaque navigation bar with a white rounded title — the same chrome
/// FBPLanguageController applies, for the same reason.
- (void)applyNavigationChrome {
    UINavigationBar *bar = self.navigationController.navigationBar;
    if (!bar) return;
    self.navigationController.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    bar.tintColor = FBPTintColor();

    UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = FBPPanelColor();
    appearance.shadowColor = UIColor.clearColor;
    appearance.titleTextAttributes = @{
        NSForegroundColorAttributeName : FBPIconColor(),
        NSFontAttributeName : FBPFont(17, UIFontWeightSemibold),
    };
    bar.standardAppearance = appearance;
    bar.scrollEdgeAppearance = appearance;
    bar.compactAppearance = appearance;
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark Reloading

- (void)storeDidChange {
    // The store posts asynchronously on the main queue, so this is already on
    // it; a reload here cannot land inside a progress callback.
    [self reload];
    [self.tableView reloadData];
}

- (void)reload {
    _jobs = FBPDownloadStore.shared.jobs;

    BOOL anyFinished = NO;
    for (FBPDownloadJob *job in _jobs) {
        if (job.isFinished) { anyFinished = YES; break; }
    }

    // Offered only when there is something to clear, so the button is never a
    // no-op the user has to find out about by pressing it.
    self.navigationItem.rightBarButtonItem = anyFinished
        ? [[UIBarButtonItem alloc] initWithTitle:FBPL(@"download.manager.clear")
                                           style:UIBarButtonItemStylePlain
                                          target:self
                                          action:@selector(clearTapped)]
        : nil;
}

- (void)clearTapped {
    [FBPDownloadStore.shared clearFinishedJobs];
    [FBPToastManager.shared showMessage:FBPL(@"download.manager.cleared") success:YES];
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_jobs.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    // Doubles as the empty state: with no rows the footer is the only thing on
    // screen, which is exactly where an explanation belongs.
    return _jobs.count == 0 ? FBPL(@"download.manager.empty") : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    FBPDownloadJobCell *cell = [tableView dequeueReusableCellWithIdentifier:kJobCell
                                                              forIndexPath:indexPath];
    [self configureCell:cell withJob:_jobs[indexPath.row]];
    return cell;
}

- (void)configureCell:(FBPDownloadJobCell *)cell withJob:(FBPDownloadJob *)job {
    cell.jobIdentifier = job.identifier;

    cell.titleLabel.text = job.title ?: job.surfaceName;

    // "1080p · Merging audio and video…", or just the stage when the picker was
    // off and there was no quality to name.
    cell.stageLabel.text = job.quality.length
        ? [NSString stringWithFormat:@"%@ · %@", job.quality, job.stageText]
        : job.stageText;
    cell.stageLabel.textColor = (job.stage == FBPDownloadJobStageFailed)
        ? UIColor.systemRedColor
        : (job.stage == FBPDownloadJobStageDone ? UIColor.systemGreenColor
                                                : UIColor.secondaryLabelColor);

    NSString *bytes = job.byteText;
    cell.bytesLabel.text = bytes;
    cell.bytesLabel.hidden = (bytes.length == 0);

    cell.progressView.hidden = !job.isActive;
    if (job.isActive) [cell.progressView setProgress:job.fraction animated:NO];

    [self configureThumbnailInCell:cell forJob:job];
    [self configureActionInCell:cell forJob:job];
}

- (void)configureThumbnailInCell:(FBPDownloadJobCell *)cell forJob:(FBPDownloadJob *)job {
    cell.placeholderView.image =
        [UIImage fbp_symbolNamed:(job.surface == FBPDownloadJobSurfaceStory ? @"camera" : @"play")
                            size:18];

    NSURL *url = job.thumbnailURL;
    if (!url) return;

    NSString *wanted = job.identifier;
    FBPDownloadLoadThumbnail(url, ^(UIImage *image) {
        // The row may have been reused for another download while the poster
        // frame was in flight.
        if (![cell.jobIdentifier isEqualToString:wanted]) return;
        cell.thumbView.image = image;
        cell.placeholderView.hidden = YES;
    });
}

/// The one button on a row, which is whatever that job's state makes useful:
/// stop it, start it again, or go and look at what it saved.
- (void)configureActionInCell:(FBPDownloadJobCell *)cell forJob:(FBPDownloadJob *)job {
    NSString *symbol = nil;
    NSString *label = nil;
    void (^handler)(void) = nil;
    UIColor *tint = FBPTintColor();

    if (job.canCancel) {
        symbol = @"stop.circle";
        label = FBPL(@"download.manager.cancel");
        handler = ^{ [FBPDownloadStore.shared cancelJob:job]; };

    } else if (job.canRetry) {
        symbol = @"arrow.clockwise.circle";
        label = FBPL(@"download.manager.retry");
        handler = ^{ [FBPDownloadStore.shared retryJob:job]; };

    } else if (job.stage == FBPDownloadJobStageDone) {
        symbol = @"photo.on.rectangle";
        label = FBPL(@"download.manager.reveal");
        tint = UIColor.systemGreenColor;
        handler = ^{ [FBPDownloadManagerController revealJobInPhotos:job]; };
    }

    cell.actionButton.hidden = (symbol == nil);
    cell.actionButton.accessibilityLabel = label;
    cell.actionButton.tintColor = tint;
    cell.actionHandler = handler;
    [cell.actionButton setImage:(symbol ? [UIImage fbp_symbolNamed:symbol size:24] : nil)
                       forState:UIControlStateNormal];
}

/// Open Photos at the saved asset.
///
/// There is no public API that opens the Photos app on one asset, so this is
/// best-effort by design: the asset is looked up first, purely to confirm it is
/// still there, and then Photos is opened. A device where that scheme does not
/// answer, or an asset the user has since deleted, gets a message rather than a
/// silent dead button — the row's green "Saved to Photos" is the part that is
/// always true.
+ (void)revealJobInPhotos:(FBPDownloadJob *)job {
    NSString *identifier = job.assetIdentifier;

    if (identifier.length) {
        PHFetchResult *found =
            [PHAsset fetchAssetsWithLocalIdentifiers:@[identifier] options:nil];
        if (found.count == 0) {
            [FBPToastManager.shared showMessage:FBPL(@"download.manager.revealMissing")
                                        success:NO];
            return;
        }
    }

    NSURL *photos = [NSURL URLWithString:@"photos-redirect://"];
    if (photos && [UIApplication.sharedApplication canOpenURL:photos]) {
        [UIApplication.sharedApplication openURL:photos options:@{} completionHandler:nil];
        return;
    }

    [FBPToastManager.shared showMessage:FBPL(@"download.manager.revealFailed") success:NO];
}

@end

#pragma mark - HUD pill

/// Target for the pill's tap, kept separate so nothing is added to FBPToastView.
///
/// The pill is an ordinary FBPToastView; this object owns the gesture that opens
/// the manager from it, and refuses taps that landed on the pill's own stop
/// button — otherwise stopping a download would also push the manager into view.
@interface FBPDownloadPillTap : NSObject <UIGestureRecognizerDelegate>
@end

@implementation FBPDownloadPillTap

- (void)openManager {
    [FBPDownloadManagerController presentFromViewController:nil];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer
       shouldReceiveTouch:(UITouch *)touch {
    for (UIView *view = touch.view; view; view = view.superview) {
        if ([view isKindOfClass:UIControl.class]) return NO;
        if (view == recognizer.view) break;
    }
    return YES;
}

@end

/// One pill per running download, reconciled against the store.
///
/// This is what replaced the progress popup. The old one was a UIAlertController
/// with a progress view pushed into its private `contentViewController` key: it
/// blocked the app while a download ran, and dismissing it left the transfer
/// going with no way back to it. A pill lives in FBPToastWindow instead, which
/// already sits above the app through modals and full-screen video, so it keeps
/// showing while the user scrolls on — and tapping it opens the manager, which
/// is where the state actually is.
@interface FBPDownloadActivity : NSObject
@property (class, readonly) FBPDownloadActivity *shared;
@property (nonatomic, strong) NSMutableDictionary<NSString *, FBPToastView *> *pills;
/// Jobs whose outcome has already been shown, so a finished job is never
/// announced twice. Pruned against the store on every pass, so it cannot
/// outgrow the job list.
@property (nonatomic, strong) NSMutableSet<NSString *> *announced;
@property (nonatomic, strong) FBPDownloadPillTap *tapTarget;
@end

@implementation FBPDownloadActivity

+ (instancetype)shared {
    static FBPDownloadActivity *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[self alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _pills = [NSMutableDictionary dictionary];
        _announced = [NSMutableSet set];
        _tapTarget = [[FBPDownloadPillTap alloc] init];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(storeDidChange)
                                                   name:FBPDownloadStoreDidChangeNotification
                                                 object:nil];
    }
    return self;
}

- (void)storeDidChange {
    NSArray<FBPDownloadJob *> *jobs = FBPDownloadStore.shared.jobs;
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    for (FBPDownloadJob *job in jobs) {
        [seen addObject:job.identifier];
        FBPToastView *pill = self.pills[job.identifier];

        if (job.isActive) {
            if (!pill) pill = [self raisePillForJob:job];
            // FBPToastView appends the percentage itself, so the text is just
            // the quality and the stage.
            [pill updateText:[self pillTextForJob:job] progress:job.fraction];
            continue;
        }

        // Already reported. Nothing to do for the rest of the session.
        if ([self.announced containsObject:job.identifier]) continue;
        [self.announced addObject:job.identifier];

        // A cancellation is the user's own doing; telling them it stopped is
        // noise, the same judgement the surfaces already made.
        if (job.stage == FBPDownloadJobStageCancelled) {
            [pill hideWithCompletion:nil];
            [self.pills removeObjectForKey:job.identifier];
            continue;
        }

        NSString *outcome = [NSString stringWithFormat:@"%@ · %@",
                                                       job.surfaceName, job.stageText];
        BOOL ok = (job.stage == FBPDownloadJobStageDone);

        if (pill) {
            // Finished while its pill was up: the same pill carries the
            // outcome, so the HUD does not flash one capsule away and another
            // in. It hides itself after that (showMessage: schedules it), which
            // is why the dictionary entry goes now.
            [self.pills removeObjectForKey:job.identifier];
            [pill showMessage:outcome success:ok];
            continue;
        }

        // Finished before its pill ever went up — a cached progressive file can
        // be down and saved inside one turn of the run loop. Without this such a
        // download would be completely silent, which is what the progress card
        // used to prevent.
        [FBPToastManager.shared showMessage:outcome success:ok];
    }

    // A job cleared out of the store while its pill was up.
    for (NSString *identifier in self.pills.allKeys) {
        if ([seen containsObject:identifier]) continue;
        [self.pills[identifier] hideWithCompletion:nil];
        [self.pills removeObjectForKey:identifier];
    }

    // Keep the announced set to the jobs that still exist.
    [self.announced intersectSet:seen];
}

/// What a pill says while a download runs: which surface, and which quality.
///
/// FBPToastView appends the percentage to this itself on every update, so the
/// text deliberately carries no number.
- (NSString *)pillTextForJob:(FBPDownloadJob *)job {
    return job.quality.length
        ? [NSString stringWithFormat:@"%@ · %@", job.surfaceName, job.quality]
        : job.surfaceName;
}

- (FBPToastView *)raisePillForJob:(FBPDownloadJob *)job {
    // A stop button only when the flow behind this job actually has a cancel to
    // offer; the single-file story path does not, and a button that did nothing
    // would be worse than none.
    dispatch_block_t stop = job.canCancel
        ? ^{ [FBPDownloadStore.shared cancelJob:job]; }
        : nil;

    FBPToastView *pill = [FBPToastManager.shared showProgress:[self pillTextForJob:job]
                                              stopCompletion:stop];
    if (!pill) return nil;

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self.tapTarget
                                                action:@selector(openManager)];
    tap.delegate = self.tapTarget;
    // The pill already has a tap of its own (dismiss-on-tap, which it ignores
    // while processing). Making that one wait for this one to fail keeps which
    // gesture wins deterministic, without touching FBPToastView.
    for (UIGestureRecognizer *existing in pill.gestureRecognizers) {
        [existing requireGestureRecognizerToFail:tap];
    }
    [pill addGestureRecognizer:tap];

    self.pills[job.identifier] = pill;
    return pill;
}

@end

void FBPDownloadActivityInstall(void) {
    // Instantiating the singleton is what registers its observer.
    (void)[FBPDownloadActivity shared];
}
