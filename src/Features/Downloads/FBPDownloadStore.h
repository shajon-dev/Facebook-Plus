// Every download the tweak has started this session, as a job the user can look
// at, cancel, retry and clear.
//
// Why a store at all. A download used to live inside the progress popup that
// presented it: the alert owned the task, the percentage and the only Cancel
// there was, so dismissing the alert left a transfer running with nothing left
// pointing at it. "Download manager a hobe, sekhan theke dekha jabe sob" — so
// the state moved here, and the popup (now a HUD pill) and the manager list are
// both only *views* of it. Dismissing either changes nothing; the job is the
// record.
//
// Deliberately free of UIKit, exactly like FBPDashDownload. That is what lets
// the lifecycle — add, progress, stage, finish, fail, cancel, retry, clear, and
// several jobs at once — be compiled and exercised on a host machine instead of
// only on a device. The one tweak symbol it reaches for, FBPLocalizedString, is
// declared in the .m rather than imported, for the same reason.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Notification

/// Posted on the main queue whenever any job is added, advanced or removed.
///
/// Carries no userInfo: a listener re-reads @c jobs, which is a cheap immutable
/// snapshot. Progress updates arrive at most once per whole percentage point
/// (FBPDashDownload already coalesces them, and the single-URL path matches it),
/// so a plain reload per notification is not a treadmill.
extern NSNotificationName const FBPDownloadStoreDidChangeNotification;

#pragma mark - Job

/// Which step a download is on.
///
/// The two fetches of a two-stream DASH save are *concurrent* — FBPDashDownload
/// starts both and reports one combined fraction — so there is no honest moment
/// at which a job is "fetching audio" but not video. One fetching stage
/// therefore covers both, and @c needsMux is what makes the row say so (see
/// -stageText). Inventing two sequential stages would mean showing a step that
/// never happens.
typedef NS_ENUM(NSInteger, FBPDownloadJobStage) {
    /// Created, nothing in flight yet. Also where a retry puts a job.
    FBPDownloadJobStageQueued = 0,
    /// Bytes are moving: one GET for a progressive variant, two at once for a
    /// DASH rung.
    FBPDownloadJobStageFetching,
    /// Both streams are down and FBPMediaMuxer is running. DASH only.
    FBPDownloadJobStageMerging,
    /// Both streams are down and FBPMediaConverter is re-encoding the picture to
    /// H.264, because the chosen rung is AV1 and Photos refuses AV1. DASH only,
    /// and mutually exclusive with @c FBPDownloadJobStageMerging — a conversion
    /// does the merge in the same pass, so a job goes through one or the other,
    /// never both.
    ///
    /// Unlike merging, this one is slow enough to need a bar of its own: a
    /// 127-second 1080p rung is minutes of sustained encoding, so @c fraction
    /// keeps advancing through it (FBPMediaConverter reports real per-frame
    /// progress) and cancelling here actually stops work rather than tidying up
    /// after it.
    FBPDownloadJobStageConverting,
    /// Handing the finished file to Photos.
    FBPDownloadJobStageSaving,
    /// In Photos. Terminal.
    FBPDownloadJobStageDone,
    /// Terminal, with @c error set when we were told why.
    FBPDownloadJobStageFailed,
    /// The user stopped it. Terminal, and never reported as a failure.
    FBPDownloadJobStageCancelled,
};

/// Where a download came from, so a row can say "Reel" or "Story" without the
/// store knowing anything about either surface.
typedef NS_ENUM(NSInteger, FBPDownloadJobSurface) {
    FBPDownloadJobSurfaceReel = 0,
    FBPDownloadJobSurfaceStory,
};

@class FBPDownloadJob;

/// Work a surface hands the store so the manager's buttons have something to
/// call. Always invoked on the main queue, with the job it belongs to.
typedef void (^FBPDownloadJobWork)(FBPDownloadJob *job);

/// One download, from the tap that started it to the end of the session.
///
/// Every property is read-only: a job is only ever changed through its store, so
/// there is exactly one place that also posts the change notification.
///
/// And every property is @c atomic, which is unusual in this codebase and is
/// deliberate. A job is written from wherever its flow reports — an
/// NSURLSession delegate queue, which is not the main queue, plus Photos'
/// completion handler — and read from the main queue by the manager list and the
/// HUD pill. The store's own lock covers the job *array*, not a reader reaching
/// straight into a job, so without this the UI's reads race the flow's writes
/// (confirmed by ThreadSanitizer on the host harness, which reported exactly
/// that on -fraction, -bytesReceived and -bytesExpected before this was
/// changed).
///
/// What atomic buys is per-property: no torn or stale read. It does not make a
/// *group* of properties consistent, so a row can show a fraction and a byte
/// count that are one update apart. That is a cosmetic difference of a few
/// milliseconds in a progress row, and the alternative — holding a lock across
/// the whole of a UI read — would be paying for a guarantee nothing here needs.
@interface FBPDownloadJob : NSObject

/// Stable for the life of the job, including across a retry.
@property (atomic, copy, readonly) NSString *identifier;

@property (atomic, assign, readonly) FBPDownloadJobSurface surface;
/// Localized surface name ("Reel" / "Story"), for a row that wants a word.
@property (atomic, copy, readonly) NSString *surfaceName;

/// Facebook's own title for the media, when the playback item had one. Nil is
/// normal — most Reels have none — and a row falls back to @c surfaceName.
@property (atomic, copy, readonly, nullable) NSString *title;

/// The picked variant's row title, e.g. "1080p", or "HD" when Facebook served
/// no manifest and only the progressive pair was on offer.
@property (atomic, copy, readonly, nullable) NSString *quality;

/// A poster frame, when one was cheaply available (-firstFrameThumbnailURL on
/// the playback item, or the image itself for a photo story). Never fetched by
/// the store — it is a URL for the list UI to load if it wants to.
@property (atomic, copy, readonly, nullable) NSURL *thumbnailURL;

/// This job is a two-stream DASH save, so it has a merge step.
@property (atomic, assign, readonly) BOOL needsMux;

/// The chosen rung is AV1, so the picture has to be re-encoded to H.264 before
/// Photos will take it. Set at the tap, from the variant, so a row can say the
/// save will be slow *before* the stage arrives rather than only once it does.
///
/// When this is set the job's merge step is replaced by
/// @c FBPDownloadJobStageConverting, not joined by it.
@property (atomic, assign, readonly) BOOL needsConversion;

@property (atomic, assign, readonly) FBPDownloadJobStage stage;
/// 0…1. Holds where it was during a merge, which reports no progress of its
/// own; keeps advancing through a conversion, which does.
@property (atomic, assign, readonly) float fraction;

/// Bytes, 0 when unknown. @c bytesExpected is the Content-Length when the CDN
/// sent one, and the picker's estimate otherwise.
@property (atomic, assign, readonly) long long bytesReceived;
@property (atomic, assign, readonly) long long bytesExpected;

/// Why it failed. Nil on every other stage, and nil for a cancellation.
@property (atomic, strong, readonly, nullable) NSError *error;

/// A finished, localized sentence for @c error, or nil.
@property (atomic, copy, readonly, nullable) NSString *failureMessage;

/// The created PHAsset's localIdentifier, once Photos has it. Nil until then,
/// and nil when the save path did not report one.
@property (atomic, copy, readonly, nullable) NSString *assetIdentifier;

@property (atomic, copy, readonly) NSDate *createdAt;
@property (atomic, copy, readonly, nullable) NSDate *finishedAt;

#pragma mark Derived

/// Still working: queued, fetching, merging or saving.
@property (atomic, assign, readonly) BOOL isActive;
/// Done, failed or cancelled.
@property (atomic, assign, readonly) BOOL isFinished;

/// Running, and the surface gave us something to stop.
@property (atomic, assign, readonly) BOOL canCancel;
/// Finished badly, and the surface gave us something to start again.
@property (atomic, assign, readonly) BOOL canRetry;

/// Localized line for the current stage, e.g. "Merging audio and video…".
@property (atomic, copy, readonly) NSString *stageText;

/// Localized "4.1 MB / 12.4 MB", or nil when neither number is known.
@property (atomic, copy, readonly, nullable) NSString *byteText;

@end

#pragma mark - Store

/// The jobs, and the only way to change one.
@interface FBPDownloadStore : NSObject

@property (class, readonly) FBPDownloadStore *shared;

/// Newest first. An immutable snapshot, safe to hold across a reload.
@property (nonatomic, copy, readonly) NSArray<FBPDownloadJob *> *jobs;

/// How many are still working. What the HUD pill and the Settings row count.
@property (nonatomic, assign, readonly) NSUInteger activeCount;

/// Mean progress of the active jobs, 0 when there are none.
@property (nonatomic, assign, readonly) float activeFraction;

/// Register a download that is about to start.
///
/// @param expectedBytes The picker's size for the chosen variant — exact for a
///   progressive one, an estimate for a DASH rung — so a row can show a total
///   before the first response header arrives. 0 when unknown.
- (FBPDownloadJob *)addJobWithSurface:(FBPDownloadJobSurface)surface
                                title:(nullable NSString *)title
                              quality:(nullable NSString *)quality
                         thumbnailURL:(nullable NSURL *)thumbnailURL
                             needsMux:(BOOL)needsMux
                      needsConversion:(BOOL)needsConversion
                        expectedBytes:(long long)expectedBytes;

/// What the manager's Cancel button calls. Nil means this flow cannot be
/// stopped (the single-file story path has no cancel), and the button is then
/// not offered.
- (void)setCancelWork:(nullable FBPDownloadJobWork)work forJob:(FBPDownloadJob *)job;

/// What the manager's Retry button calls, after the store has put the job back
/// to @c FBPDownloadJobStageQueued. Nil means retry is not offered.
- (void)setRetryWork:(nullable FBPDownloadJobWork)work forJob:(FBPDownloadJob *)job;

#pragma mark Progress reporting

- (void)job:(FBPDownloadJob *)job didEnterStage:(FBPDownloadJobStage)stage;
- (void)job:(FBPDownloadJob *)job didProgress:(float)fraction;
- (void)job:(FBPDownloadJob *)job
    didReceiveBytes:(long long)received
         expected:(long long)expected;

/// Terminal success. @c identifier is the created asset's localIdentifier when
/// Photos gave us one.
- (void)job:(FBPDownloadJob *)job
    didFinishWithAssetIdentifier:(nullable NSString *)identifier;

/// Terminal failure. A job the user already asked to stop lands on
/// @c FBPDownloadJobStageCancelled instead, whatever error the flow reports —
/// NSURLSession answers a cancelled transfer with NSURLErrorCancelled, and
/// showing that as a failure would be telling the user their own tap broke
/// something.
- (void)job:(FBPDownloadJob *)job didFailWithError:(nullable NSError *)error;

/// Terminal, by the user's own request.
- (void)jobWasCancelled:(FBPDownloadJob *)job;

#pragma mark User actions

/// Ask the surface to stop this job. Marks it as cancel-requested either way, so
/// whatever the flow reports next is read as a cancellation rather than a
/// failure. Does nothing to a job that has already finished.
- (void)cancelJob:(FBPDownloadJob *)job;

/// Put a finished-badly job back to queued and run its retry work.
/// Returns NO when there is nothing to retry.
- (BOOL)retryJob:(FBPDownloadJob *)job;

/// Drop every finished job. Running ones stay.
- (void)clearFinishedJobs;

/// Drop one job, whatever its stage. Does not cancel it — cancel first.
- (void)removeJob:(FBPDownloadJob *)job;

@end

NS_ASSUME_NONNULL_END
