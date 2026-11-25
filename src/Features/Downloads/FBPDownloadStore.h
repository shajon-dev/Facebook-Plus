// Every download started this session. The popup and the manager list are only
// views of this. Free of UIKit, so the lifecycle runs on a host machine.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Notification

/// Main queue, no userInfo: a listener re-reads @c jobs. Progress is coalesced
/// to one per whole percentage point, so a reload per notification is cheap.
extern NSNotificationName const FBPDownloadStoreDidChangeNotification;

#pragma mark - Job

/// One Fetching stage covers both streams of a DASH save: the fetches are
/// concurrent and reported as one combined fraction.
typedef NS_ENUM(NSInteger, FBPDownloadJobStage) {
    FBPDownloadJobStageQueued = 0,
    FBPDownloadJobStageFetching,
    FBPDownloadJobStageMerging,
    /// Mutually exclusive with Merging: a conversion merges in the same pass.
    FBPDownloadJobStageConverting,
    FBPDownloadJobStageSaving,
    FBPDownloadJobStageDone,
    FBPDownloadJobStageFailed,
    FBPDownloadJobStageCancelled,
};

typedef NS_ENUM(NSInteger, FBPDownloadJobSurface) {
    FBPDownloadJobSurfaceReel = 0,
    FBPDownloadJobSurfaceStory,
};

@class FBPDownloadJob;

/// Always invoked on the main queue, with the job it belongs to.
typedef void (^FBPDownloadJobWork)(FBPDownloadJob *job);

/// Changed only through its store, so one place posts the change notification.
/// Every property is @c atomic deliberately: a job is written from wherever its
/// flow reports (an NSURLSession delegate queue, Photos' completion handler) and
/// read from the main queue, while the store's lock covers the job *array*, not
/// a reader reaching into a job.
@interface FBPDownloadJob : NSObject

@property (atomic, copy, readonly) NSString *identifier;

@property (atomic, assign, readonly) FBPDownloadJobSurface surface;
@property (atomic, copy, readonly) NSString *surfaceName;

@property (atomic, copy, readonly, nullable) NSString *title;

@property (atomic, copy, readonly, nullable) NSString *quality;

@property (atomic, copy, readonly, nullable) NSURL *thumbnailURL;

@property (atomic, assign, readonly) BOOL needsMux;

@property (atomic, assign, readonly) BOOL needsConversion;

@property (atomic, assign, readonly) FBPDownloadJobStage stage;
/// Holds still through a merge, which reports no progress; advances in a convert.
@property (atomic, assign, readonly) float fraction;

/// 0 when unknown; @c bytesExpected is the Content-Length, else an estimate.
@property (atomic, assign, readonly) long long bytesReceived;
@property (atomic, assign, readonly) long long bytesExpected;

@property (atomic, strong, readonly, nullable) NSError *error;

@property (atomic, copy, readonly, nullable) NSString *failureMessage;

@property (atomic, copy, readonly, nullable) NSString *assetIdentifier;

@property (atomic, copy, readonly) NSDate *createdAt;
@property (atomic, copy, readonly, nullable) NSDate *finishedAt;

#pragma mark Derived

@property (atomic, assign, readonly) BOOL isActive;
@property (atomic, assign, readonly) BOOL isFinished;

@property (atomic, assign, readonly) BOOL canCancel;
@property (atomic, assign, readonly) BOOL canRetry;

@property (atomic, copy, readonly) NSString *stageText;

@property (atomic, copy, readonly, nullable) NSString *byteText;

@end

#pragma mark - Store

@interface FBPDownloadStore : NSObject

@property (class, readonly) FBPDownloadStore *shared;

@property (nonatomic, copy, readonly) NSArray<FBPDownloadJob *> *jobs;

@property (nonatomic, assign, readonly) NSUInteger activeCount;

@property (nonatomic, assign, readonly) float activeFraction;

/// @param expectedBytes What the variant will *download*, not the size the
///   picker row showed: the Content-Length replaces it. 0 when unknown.
- (FBPDownloadJob *)addJobWithSurface:(FBPDownloadJobSurface)surface
                                title:(nullable NSString *)title
                              quality:(nullable NSString *)quality
                         thumbnailURL:(nullable NSURL *)thumbnailURL
                             needsMux:(BOOL)needsMux
                      needsConversion:(BOOL)needsConversion
                        expectedBytes:(long long)expectedBytes;

- (void)setCancelWork:(nullable FBPDownloadJobWork)work forJob:(FBPDownloadJob *)job;

- (void)setRetryWork:(nullable FBPDownloadJobWork)work forJob:(FBPDownloadJob *)job;

#pragma mark Progress reporting

- (void)job:(FBPDownloadJob *)job didEnterStage:(FBPDownloadJobStage)stage;
- (void)job:(FBPDownloadJob *)job didProgress:(float)fraction;
- (void)job:(FBPDownloadJob *)job
    didReceiveBytes:(long long)received
         expected:(long long)expected;

- (void)job:(FBPDownloadJob *)job
    didFinishWithAssetIdentifier:(nullable NSString *)identifier;

/// A job the user asked to stop lands on Cancelled instead, whatever the flow
/// reports: NSURLSession answers a cancelled transfer with NSURLErrorCancelled.
- (void)job:(FBPDownloadJob *)job didFailWithError:(nullable NSError *)error;

- (void)jobWasCancelled:(FBPDownloadJob *)job;

#pragma mark User actions

- (void)cancelJob:(FBPDownloadJob *)job;

- (BOOL)retryJob:(FBPDownloadJob *)job;

- (void)clearFinishedJobs;

/// Does not cancel the job — cancel first.
- (void)removeJob:(FBPDownloadJob *)job;

@end

NS_ASSUME_NONNULL_END
