// The job store: one lock, one notification, and the only code that mutates a
// job.

#import "FBPDownloadStore.h"
#import "FBPDashDownload.h"

// Declared rather than imported, exactly as FBPDashDownload.m does it: the
// canonical declaration lives in FBPResources.h, which pulls in UIKit and would
// stop this file compiling on a host machine. Keep the signature in step.
extern NSString *FBPLocalizedString(NSString *key);

#define FBPStoreL(key) FBPLocalizedString(key)

NSNotificationName const FBPDownloadStoreDidChangeNotification =
    @"com.shajon.fbplus.downloads.storeDidChange";

// A session's worth of history, not a forever log. Finished jobs are trimmed
// oldest-first past this; running ones are never trimmed, however many there
// are, because dropping the record of a live download is the bug this whole
// file exists to fix.
static const NSUInteger kFBPDownloadStoreCapacity = 60;

#pragma mark - Job

@interface FBPDownloadJob ()

@property (atomic, copy) NSString *identifier;
@property (atomic, assign) FBPDownloadJobSurface surface;
@property (atomic, copy, nullable) NSString *title;
@property (atomic, copy, nullable) NSString *quality;
@property (atomic, copy, nullable) NSURL *thumbnailURL;
@property (atomic, assign) BOOL needsMux;
@property (atomic, assign) FBPDownloadJobStage stage;
@property (atomic, assign) float fraction;
@property (atomic, assign) long long bytesReceived;
@property (atomic, assign) long long bytesExpected;
@property (atomic, strong, nullable) NSError *error;
@property (atomic, copy, nullable) NSString *assetIdentifier;
@property (atomic, copy) NSDate *createdAt;
@property (atomic, copy, nullable) NSDate *finishedAt;

/// The user has asked for this one to stop. Set before the flow is told, so the
/// cancellation that comes back is recognised as one.
@property (atomic, assign) BOOL cancelRequested;

@property (atomic, copy, nullable) FBPDownloadJobWork cancelWork;
@property (atomic, copy, nullable) FBPDownloadJobWork retryWork;

@end

@implementation FBPDownloadJob

- (NSString *)surfaceName {
    return self.surface == FBPDownloadJobSurfaceStory
        ? FBPStoreL(@"download.manager.source.story")
        : FBPStoreL(@"download.manager.source.reel");
}

- (BOOL)isActive {
    switch (self.stage) {
        case FBPDownloadJobStageQueued:
        case FBPDownloadJobStageFetching:
        case FBPDownloadJobStageMerging:
        case FBPDownloadJobStageSaving:
            return YES;
        default:
            return NO;
    }
}

- (BOOL)isFinished {
    return !self.isActive;
}

- (BOOL)canCancel {
    return self.isActive && !self.cancelRequested && self.cancelWork != nil;
}

- (BOOL)canRetry {
    return (self.stage == FBPDownloadJobStageFailed ||
            self.stage == FBPDownloadJobStageCancelled) && self.retryWork != nil;
}

- (NSString *)stageText {
    switch (self.stage) {
        case FBPDownloadJobStageQueued:
            return FBPStoreL(@"download.job.stage.queued");
        case FBPDownloadJobStageFetching:
            // The one place needsMux shows through to the user: a two-stream
            // save is pulling picture and sound at the same time, and saying so
            // is what makes the merge step that follows make sense.
            return self.needsMux ? FBPStoreL(@"download.job.stage.fetchingBoth")
                                 : FBPStoreL(@"download.job.stage.fetching");
        case FBPDownloadJobStageMerging:
            // Reuses the wording the progress card already used for this step,
            // rather than a second key that could drift from it in translation.
            return FBPStoreL(@"download.merge.progress");
        case FBPDownloadJobStageSaving:
            return FBPStoreL(@"download.job.stage.saving");
        case FBPDownloadJobStageDone:
            return FBPStoreL(@"download.job.stage.done");
        case FBPDownloadJobStageCancelled:
            return FBPStoreL(@"download.job.stage.cancelled");
        case FBPDownloadJobStageFailed:
            break;
    }
    // A failure says what went wrong where there is room for it, and falls back
    // to the bare word when the flow did not tell us.
    return self.failureMessage ?: FBPStoreL(@"download.job.stage.failed");
}

- (NSString *)failureMessage {
    if (self.stage != FBPDownloadJobStageFailed || !self.error) return nil;

    // The two-stream flow already writes a finished sentence for every way it
    // can fail, including folding a 403 on either stream into the expired-link
    // wording, so its errors are handed straight to it.
    if ([self.error.domain isEqualToString:FBPDashDownloadErrorDomain]) {
        NSString *message = FBPDashDownloadMessageForError(self.error);
        if (message.length) return message;
    }

    // Everything else — a progressive GET, Photos refusing the save — arrives
    // already carrying the sentence the surface wanted shown, as its
    // localizedDescription. Running those through the dash builder would wrap an
    // explanation inside "Reel download failed." a second time.
    NSString *described = self.error.localizedDescription;
    return described.length ? described : nil;
}

- (NSString *)byteText {
    if (self.bytesExpected <= 0 && self.bytesReceived <= 0) return nil;

    NSByteCountFormatterCountStyle style = NSByteCountFormatterCountStyleFile;

    // Nothing to compare against yet: show what has arrived on its own rather
    // than "4.1 MB / 0 bytes".
    if (self.bytesExpected <= 0) {
        return [NSByteCountFormatter stringFromByteCount:self.bytesReceived
                                              countStyle:style];
    }

    NSString *total = [NSByteCountFormatter stringFromByteCount:self.bytesExpected
                                                    countStyle:style];
    if (self.bytesReceived <= 0 || self.isFinished) return total;

    return [NSString stringWithFormat:FBPStoreL(@"download.job.bytes"),
            [NSByteCountFormatter stringFromByteCount:self.bytesReceived
                                           countStyle:style],
            total];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ %@ %@ stage=%ld %.0f%%>",
            NSStringFromClass(self.class), self.identifier, self.quality ?: @"-",
            (long)self.stage, self.fraction * 100.0f];
}

@end

#pragma mark - Store

@implementation FBPDownloadStore {
    // Recursive because a notification listener that reads -jobs from inside the
    // same turn (the manager reloading on the main queue while a progress
    // callback is still unwinding) would otherwise deadlock on itself.
    NSRecursiveLock *_lock;
    NSMutableArray<FBPDownloadJob *> *_jobs;   // newest first
}

+ (FBPDownloadStore *)shared {
    static FBPDownloadStore *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [[self alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = [[NSRecursiveLock alloc] init];
        _jobs = [NSMutableArray array];
    }
    return self;
}

#pragma mark Reading

- (NSArray<FBPDownloadJob *> *)jobs {
    [_lock lock];
    NSArray *snapshot = [_jobs copy];
    [_lock unlock];
    return snapshot;
}

- (NSUInteger)activeCount {
    NSUInteger count = 0;
    for (FBPDownloadJob *job in self.jobs) {
        if (job.isActive) count++;
    }
    return count;
}

- (float)activeFraction {
    float total = 0.0f;
    NSUInteger count = 0;
    for (FBPDownloadJob *job in self.jobs) {
        if (!job.isActive) continue;
        total += job.fraction;
        count++;
    }
    return count ? (total / (float)count) : 0.0f;
}

#pragma mark Change notification

/// One place that announces a change, so no mutation can forget to.
///
/// Always asynchronous, even when already on the main queue: a listener that
/// rebuilt a table synchronously from inside a progress callback would be
/// reloading while the flow that caused it is still unwinding.
- (void)postChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter
            postNotificationName:FBPDownloadStoreDidChangeNotification
                          object:self];
    });
}

#pragma mark Adding

- (FBPDownloadJob *)addJobWithSurface:(FBPDownloadJobSurface)surface
                                title:(NSString *)title
                              quality:(NSString *)quality
                         thumbnailURL:(NSURL *)thumbnailURL
                             needsMux:(BOOL)needsMux
                        expectedBytes:(long long)expectedBytes {
    FBPDownloadJob *job = [[FBPDownloadJob alloc] init];
    job.identifier = NSUUID.UUID.UUIDString;
    job.surface = surface;
    job.title = title.length ? title : nil;
    job.quality = quality.length ? quality : nil;
    job.thumbnailURL = thumbnailURL;
    job.needsMux = needsMux;
    job.stage = FBPDownloadJobStageQueued;
    job.bytesExpected = MAX(0LL, expectedBytes);
    job.createdAt = [NSDate date];

    [_lock lock];
    [_jobs insertObject:job atIndex:0];
    [self trimLocked];
    [_lock unlock];

    [self postChange];
    return job;
}

/// Drop finished jobs, oldest first, until the list is back within capacity.
/// Called with the lock held.
- (void)trimLocked {
    if (_jobs.count <= kFBPDownloadStoreCapacity) return;

    NSMutableIndexSet *doomed = [NSMutableIndexSet indexSet];
    NSUInteger over = _jobs.count - kFBPDownloadStoreCapacity;

    for (NSUInteger i = _jobs.count; i > 0 && doomed.count < over; i--) {
        FBPDownloadJob *job = _jobs[i - 1];
        if (job.isFinished) [doomed addIndex:i - 1];
    }

    [_jobs removeObjectsAtIndexes:doomed];
}

#pragma mark Work blocks

- (void)setCancelWork:(FBPDownloadJobWork)work forJob:(FBPDownloadJob *)job {
    if (!job) return;
    [_lock lock];
    job.cancelWork = work;
    [_lock unlock];
    [self postChange];
}

- (void)setRetryWork:(FBPDownloadJobWork)work forJob:(FBPDownloadJob *)job {
    if (!job) return;
    [_lock lock];
    job.retryWork = work;
    [_lock unlock];
    [self postChange];
}

#pragma mark Progress reporting

- (void)job:(FBPDownloadJob *)job didEnterStage:(FBPDownloadJobStage)stage {
    if (!job) return;

    [_lock lock];
    // A terminal stage is final. A late progress callback from a flow that has
    // already been cancelled or has already failed must not drag the job back
    // into looking busy.
    BOOL ignore = job.isFinished;
    if (!ignore) job.stage = stage;
    [_lock unlock];

    if (!ignore) [self postChange];
}

- (void)job:(FBPDownloadJob *)job didProgress:(float)fraction {
    if (!job) return;

    [_lock lock];
    BOOL ignore = job.isFinished;
    if (!ignore) {
        job.fraction = MAX(0.0f, MIN(1.0f, fraction));
        // The first byte is also the start of the fetch, so a caller does not
        // have to announce the stage separately.
        if (job.stage == FBPDownloadJobStageQueued) {
            job.stage = FBPDownloadJobStageFetching;
        }
    }
    [_lock unlock];

    if (!ignore) [self postChange];
}

- (void)job:(FBPDownloadJob *)job
    didReceiveBytes:(long long)received
           expected:(long long)expected {
    if (!job) return;

    [_lock lock];
    BOOL ignore = job.isFinished;
    if (!ignore) {
        job.bytesReceived = MAX(0LL, received);
        // A real Content-Length replaces the picker's estimate; a missing one
        // (chunked, or a CDN that did not say) leaves the estimate standing
        // rather than blanking the total mid-download.
        if (expected > 0) job.bytesExpected = expected;
    }
    [_lock unlock];

    if (!ignore) [self postChange];
}

- (void)job:(FBPDownloadJob *)job
    didFinishWithAssetIdentifier:(NSString *)identifier {
    if (!job) return;

    [_lock lock];
    job.stage = FBPDownloadJobStageDone;
    job.fraction = 1.0f;
    job.error = nil;
    job.assetIdentifier = identifier.length ? identifier : nil;
    job.finishedAt = [NSDate date];
    if (job.bytesExpected > 0 && job.bytesReceived <= 0) {
        job.bytesReceived = job.bytesExpected;
    }
    [_lock unlock];

    [self postChange];
}

- (void)job:(FBPDownloadJob *)job didFailWithError:(NSError *)error {
    if (!job) return;

    [_lock lock];
    if (job.cancelRequested) {
        job.stage = FBPDownloadJobStageCancelled;
        job.error = nil;
    } else {
        job.stage = FBPDownloadJobStageFailed;
        job.error = error;
    }
    job.finishedAt = [NSDate date];
    [_lock unlock];

    [self postChange];
}

- (void)jobWasCancelled:(FBPDownloadJob *)job {
    if (!job) return;

    [_lock lock];
    job.stage = FBPDownloadJobStageCancelled;
    job.error = nil;
    job.finishedAt = [NSDate date];
    [_lock unlock];

    [self postChange];
}

#pragma mark User actions

- (void)cancelJob:(FBPDownloadJob *)job {
    if (!job) return;

    FBPDownloadJobWork work = nil;

    [_lock lock];
    if (job.isActive) {
        job.cancelRequested = YES;
        work = job.cancelWork;
    }
    [_lock unlock];

    if (!work) {
        // Nothing to stop. A queued job that never got a flow is still the
        // user's to abandon; one that is mid-flight with no cancel stays put,
        // and its own completion decides the outcome.
        [_lock lock];
        BOOL queued = (job.stage == FBPDownloadJobStageQueued);
        [_lock unlock];
        if (queued) [self jobWasCancelled:job];
        else [self postChange];
        return;
    }

    [self postChange];

    // Outside the lock, and on the main queue, because this reaches back into
    // the surface that owns the transfer.
    if (NSThread.isMainThread) {
        work(job);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ work(job); });
    }
}

- (BOOL)retryJob:(FBPDownloadJob *)job {
    if (!job) return NO;

    FBPDownloadJobWork work = nil;

    [_lock lock];
    if (job.canRetry) {
        work = job.retryWork;
        job.stage = FBPDownloadJobStageQueued;
        job.fraction = 0.0f;
        job.bytesReceived = 0;
        job.error = nil;
        job.assetIdentifier = nil;
        job.finishedAt = nil;
        job.cancelRequested = NO;
    }
    [_lock unlock];

    if (!work) return NO;

    [self postChange];

    if (NSThread.isMainThread) {
        work(job);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ work(job); });
    }
    return YES;
}

- (void)clearFinishedJobs {
    [_lock lock];
    NSMutableIndexSet *doomed = [NSMutableIndexSet indexSet];
    [_jobs enumerateObjectsUsingBlock:^(FBPDownloadJob *job, NSUInteger idx,
                                        __unused BOOL *stop) {
        if (job.isFinished) [doomed addIndex:idx];
    }];
    BOOL changed = doomed.count > 0;
    [_jobs removeObjectsAtIndexes:doomed];
    [_lock unlock];

    if (changed) [self postChange];
}

- (void)removeJob:(FBPDownloadJob *)job {
    if (!job) return;

    [_lock lock];
    NSUInteger index = [_jobs indexOfObjectIdenticalTo:job];
    BOOL changed = (index != NSNotFound);
    if (changed) [_jobs removeObjectAtIndex:index];
    [_lock unlock];

    if (changed) [self postChange];
}

@end
