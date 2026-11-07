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

/// Draw a poster frame from the saved Photos asset.
///
/// Best-effort in every direction: no asset identifier, an asset the user has
/// since deleted, or a library the app may only add to and not read, all end
/// with the row keeping its glyph rather than with an error. Cached under a
/// key that cannot collide with a URL's.
static void FBPDownloadLoadAssetThumbnail(NSString *assetIdentifier,
                                          CGSize size,
                                          void (^then)(UIImage *image)) {
    if (assetIdentifier.length == 0 || !then) return;

    NSString *key = [@"asset:" stringByAppendingString:assetIdentifier];
    UIImage *cached = [FBPDownloadThumbnailCache() objectForKey:key];
    if (cached) { then(cached); return; }

    NSMutableSet *inFlight = FBPDownloadThumbnailsInFlight();
    if ([inFlight containsObject:key]) return;
    [inFlight addObject:key];

    PHAsset *asset =
        [PHAsset fetchAssetsWithLocalIdentifiers:@[assetIdentifier] options:nil].firstObject;
    if (!asset) {
        [inFlight removeObject:key];
        return;
    }

    PHImageRequestOptions *options = [[PHImageRequestOptions alloc] init];
    options.networkAccessAllowed = NO;   // an iCloud round trip for a 44pt row is not worth it
    options.deliveryMode = PHImageRequestOptionsDeliveryModeOpportunistic;
    options.resizeMode = PHImageRequestOptionsResizeModeFast;

    CGFloat scale = UIScreen.mainScreen.scale;
    CGSize pixels = CGSizeMake(size.width * scale, size.height * scale);

    [PHImageManager.defaultManager
        requestImageForAsset:asset
                  targetSize:pixels
                 contentMode:PHImageContentModeAspectFill
                     options:options
               resultHandler:^(UIImage *image, __unused NSDictionary *info) {
        // Opportunistic delivery calls back more than once — a thumbnail first,
        // then the real thing. Both are welcome; only the last one is cached.
        dispatch_async(dispatch_get_main_queue(), ^{
            [FBPDownloadThumbnailsInFlight() removeObject:key];
            if (!image) return;
            [FBPDownloadThumbnailCache() setObject:image forKey:key cost:(NSUInteger)(pixels.width * pixels.height * 4)];
            then(image);
        });
    }];
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

    NSString *wanted = job.identifier;
    void (^show)(UIImage *) = ^(UIImage *image) {
        // The row may have been reused for another download while the poster
        // frame was in flight.
        if (!image || ![cell.jobIdentifier isEqualToString:wanted]) return;
        cell.thumbView.image = image;
        cell.placeholderView.hidden = YES;
    };

    NSURL *url = job.thumbnailURL;
    if (url) {
        FBPDownloadLoadThumbnail(url, show);
        return;
    }

    // No poster URL. Most Reels have none — -firstFrameThumbnailURL is simply
    // absent on the playback item — which is why these rows used to sit on a
    // grey glyph for the whole session. Once the video is in Photos the asset
    // itself can draw one, and that is a local read with no network at all.
    FBPDownloadLoadAssetThumbnail(job.assetIdentifier,
                                  CGSizeMake(kThumbWidth, kThumbHeight),
                                  show);
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

#pragma mark Deleting

/// The job a row stands for, or nil if the table is asking about a row the
/// snapshot no longer has — a swipe can outlive the reload that removed it.
- (nullable FBPDownloadJob *)jobAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 0) return nil;
    if (indexPath.row < 0 || (NSUInteger)indexPath.row >= _jobs.count) return nil;
    return _jobs[(NSUInteger)indexPath.row];
}

/// Every row can go. A running download is stopped first, so there is no case
/// the user has to think about before swiping.
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self jobAtIndexPath:indexPath] != nil;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self deleteConfigForIndexPath:indexPath];
}

// Either direction, the same as the imported fonts in FBPFontController — that
// is the gesture the user already has in their hands for this.
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self deleteConfigForIndexPath:indexPath];
}

- (nullable UISwipeActionsConfiguration *)deleteConfigForIndexPath:(NSIndexPath *)indexPath {
    FBPDownloadJob *job = [self jobAtIndexPath:indexPath];
    if (!job) return nil;

    __weak typeof(self) weakSelf = self;
    UIContextualAction *remove =
        [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                title:FBPL(@"download.manager.delete")
                                              handler:^(UIContextualAction *action,
                                                        UIView *sourceView,
                                                        void (^completion)(BOOL)) {
        // Hand the swipe back first, then confirm — nothing is deleted on OK alone.
        completion(NO);
        [weakSelf confirmDeleteJob:job];
    }];
    remove.image = [UIImage systemImageNamed:@"trash"];

    UISwipeActionsConfiguration *config =
        [UISwipeActionsConfiguration configurationWithActions:@[remove]];
    // A video the user downloaded is not something a flick should be able to
    // destroy, so the action has to be tapped.
    config.performsFirstActionWithFullSwipe = NO;
    return config;
}

- (void)confirmDeleteJob:(FBPDownloadJob *)job {
    NSString *name = job.title.length ? job.title : job.surfaceName;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:FBPL(@"download.manager.delete.title")
                         message:[NSString stringWithFormat:FBPL(@"download.manager.delete.message"), name]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:FBPL(@"common.cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:FBPL(@"download.manager.delete")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [self deleteJob:job];
    }]];
    alert.view.tintColor = FBPTintColor();
    [self presentViewController:alert animated:YES completion:nil];
}

/// Remove the row and, when the video reached Photos, the video itself.
///
/// Photos puts up its own confirmation for a delete — that sheet is the system's
/// and cannot be suppressed, which is exactly right for something permanent.
/// The row is dropped either way: the user asked for it gone from this list, and
/// a video they chose to keep in Photos is not a reason to keep a finished job.
- (void)deleteJob:(FBPDownloadJob *)job {
    if (job.canCancel) [FBPDownloadStore.shared cancelJob:job];

    NSString *identifier = job.assetIdentifier;
    PHFetchResult<PHAsset *> *assets = identifier.length
        ? [PHAsset fetchAssetsWithLocalIdentifiers:@[identifier] options:nil]
        : nil;

    if (assets.count == 0) {
        // Never saved, or already gone from Photos. Dropping the row is the
        // whole of the delete.
        [FBPDownloadStore.shared removeJob:job];
        [FBPToastManager.shared showMessage:FBPL(@"download.manager.deleted") success:YES];
        return;
    }

    [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
        [PHAssetChangeRequest deleteAssets:assets];
    } completionHandler:^(BOOL success, __unused NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [FBPDownloadStore.shared removeJob:job];
            [FBPToastManager.shared
                showMessage:(success ? FBPL(@"download.manager.deleted")
                                     : FBPL(@"download.manager.deleteKept"))
                    success:success];
        });
    }];
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

#pragma mark - Download announcements

/// Says a download started, and says how it ended. Nothing in between.
///
/// This replaced a live progress pill. The pill was an FBPToastView parked in
/// FBPToastWindow that followed the transfer percent by percent and opened the
/// manager when tapped — and watching a number climb is not what the user wants
/// from a feed: "quality select korar sathe sathe eta toast message er moddhe
/// download hoy and toast ei download progress dekhay — jetar dorkar nai".
///
/// So a tap now says "Downloading", and when the file is in Photos it says
/// "Download Completed". The percentages, the stop button and the per-job
/// history all still exist, in the one place that is for them: the download
/// manager, under Settings → Downloads.
@interface FBPDownloadActivity : NSObject
@property (class, readonly) FBPDownloadActivity *shared;
/// Jobs already told the user about. Two sets rather than one flag per job,
/// because a download can be announced as started and as finished, and a fast
/// cached one is only ever announced as finished. Both are pruned against the
/// store on every pass, so neither can outgrow the job list.
@property (nonatomic, strong) NSMutableSet<NSString *> *started;
@property (nonatomic, strong) NSMutableSet<NSString *> *announced;
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
        _started = [NSMutableSet set];
        _announced = [NSMutableSet set];
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

        if (job.isActive) {
            // Said once, on the first notification this job produces, and never
            // updated — the store posts one of these per percentage point and
            // reacting to them is the behaviour being removed.
            if ([self.started containsObject:job.identifier]) continue;
            [self.started addObject:job.identifier];
            [FBPToastManager.shared showMessage:FBPL(@"download.toast.started") success:YES];
            continue;
        }

        if ([self.announced containsObject:job.identifier]) continue;
        [self.announced addObject:job.identifier];
        // A cached progressive file can be fetched and saved inside one turn of
        // the run loop, so this may be the first time we have seen the job at
        // all. Marking it started keeps the sets consistent.
        [self.started addObject:job.identifier];

        // A cancellation is the user's own doing; telling them it stopped is
        // noise, the same judgement the surfaces already made.
        if (job.stage == FBPDownloadJobStageCancelled) continue;

        BOOL ok = (job.stage == FBPDownloadJobStageDone);
        NSString *message = ok
            ? FBPL(@"download.toast.finished")
            : (job.failureMessage.length ? job.failureMessage
                                         : FBPL(@"download.job.stage.failed"));
        [FBPToastManager.shared showMessage:message success:ok];
    }

    [self.started intersectSet:seen];
    [self.announced intersectSet:seen];
}

@end

void FBPDownloadActivityInstall(void) {
    // Instantiating the singleton is what registers its observer.
    (void)[FBPDownloadActivity shared];
}
