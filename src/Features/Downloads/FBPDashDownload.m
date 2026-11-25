#import "FBPDashDownload.h"
#import "FBPMediaConverter.h"
#import "FBPVP9Converter.h"
#import "FBPMediaMuxer.h"

#import <os/log.h>
#import <stdatomic.h>
#import <math.h>

// Declared here rather than imported from FBPResources.h and
// FBPDownloadVariants.h, which pull in UIKit and would stop the host harness
// compiling this .m. Canonical declarations are there; keep them in step.
extern NSString *FBPLocalizedString(NSString *key);
extern BOOL FBPDownloadQualityLoggingEnabled(void);

#define FBPDashL(key) FBPLocalizedString(key)

NSString *const FBPDashDownloadErrorDomain = @"com.shajon.fbplus.dashdownload";
NSString *const FBPDashDownloadStatusCodeKey = @"FBPDashDownloadStatusCode";

#pragma mark - Tuning

// The share of the bar that belongs to the two downloads. The remainder is
// reserved for the merge, which reports no intermediate progress of its own, so
// without the slice the bar would sit at 100% while samples are still copying.
static const float kFBPDashFetchShare = 0.88f;

// The same share for a flow that converts, and necessarily a much smaller one:
// a conversion is minutes of encoding after the same seconds of network, where a
// merge is a fraction of a second. At 0.88 the bar would park for the encode.
static const float kFBPDashConvertFetchShare = 0.30f;

// Matches FBPReelDownloadManager's own session, and shared by both streams,
// which is what makes the two timeouts equivalent to the single-URL path's one.
static const NSTimeInterval kFBPDashRequestTimeout = 60.0;
static const NSTimeInterval kFBPDashResourceTimeout = 180.0;

#pragma mark - Diagnostic

// Same subsystem and category as the quality diagnostic in
// FBPDownloadVariants.m, so one Console filter covers the tap and the flow.
static os_log_t FBPDashDownloadLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.shajon.fbplus", "DownloadQualities");
    });
    return log;
}

// One relaxed atomic load and a not-taken branch when the switch is off (see
// FBPDownloadQualityLoggingEnabled), so every call site below can be written
// unconditionally.
#define FBPDashLog(fmt, ...)                                                   \
    do {                                                                       \
        if (FBPDownloadQualityLoggingEnabled()) {                              \
            os_log(FBPDashDownloadLog(), "dash      " fmt, ##__VA_ARGS__);     \
        }                                                                      \
    } while (0)

#pragma mark - Per-stream state

/// One of the two transfers. A plain struct rather than an object: it is only
/// ever touched on the control queue, and keeping it a value makes that obvious.
typedef struct {
    int64_t received;
    /// Content-Length, once the response has arrived. 0 while unknown — which is
    /// also what it stays if the CDN answers chunked.
    int64_t expected;
    bool done;
} FBPDashStreamProgress;

/// How far along one stream is, 0…1. A stream whose length the CDN never
/// published contributes 0 until it finishes, rather than a made-up number.
static float FBPDashStreamFraction(FBPDashStreamProgress stream) {
    if (stream.done) return 1.0f;
    if (stream.expected <= 0) return 0.0f;
    double fraction = (double)stream.received / (double)stream.expected;
    if (!isfinite(fraction) || fraction < 0.0) return 0.0f;
    return (float)MIN(fraction, 1.0);
}

static BOOL FBPDashURLIsFetchable(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString;
    return [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"] ||
           // file:// is never what Facebook serves; it is what the host-side
           // harness serves, so the flow can be exercised without a network.
           [scheme isEqualToString:@"file"];
}

#pragma mark - Download

@interface FBPDashDownload () <NSURLSessionDownloadDelegate>
@end

@implementation FBPDashDownload {
    NSURL *_videoURL;
    NSURL *_audioURL;
    NSURL *_outputURL;

    /// A directory rather than two loose files, so cleanup is one call that
    /// cannot half-succeed. Set once in -prepare and never cleared, so the
    /// delayed cleanup in -URLSession:didBecomeInvalidWithError: still finds it.
    NSString *_scratchPath;
    NSURL *_videoFile;
    NSURL *_audioFile;

    FBPDashDownloadProgress _progress;
    FBPDashDownloadCompletion _completion;

    NSURLSession *_session;
    /// Write-once in -begin, before either is resumed, and never cleared: the
    /// delegate callbacks compare against them from the session's own queue, and
    /// a strong reference that is only ever read is one fewer thing to race on.
    NSURLSessionDownloadTask *_videoTask;
    NSURLSessionDownloadTask *_audioTask;

    /// Every decision is made here: which stream reported what, whether the flow
    /// is past the point of starting a merge, and the single exit. The URL session
    /// delegate queue and the muxer's main-queue completion both hop onto it, so
    /// no state below needs a lock.
    dispatch_queue_t _control;

    FBPDashStreamProgress _videoProgress;
    FBPDashStreamProgress _audioProgress;

    FBPDashDownloadStage _stage;
    /// Last value handed to the progress block, as whole percent, so a 40 MB
    /// download does not wake the main queue thousands of times.
    NSInteger _lastReportedPercent;
    /// High-water mark of what has been reported, so the bar cannot go
    /// backwards. See -reportProgress for the case that makes this necessary.
    float _reportedFraction;

    /// Re-encode the picture rather than copy it, and the source's own bitrate
    /// to derive the output's from. Write-once in +start…, read on the control
    /// queue.
    BOOL _convertVideo;
    long long _sourceBitRate;
    /// Where the conversion has got to, 0…1, as last reported by
    /// FBPMediaConverter. Control queue only.
    float _convertFraction;

    BOOL _cancelled;
    BOOL _muxStarted;
    /// Atomic only so -finished can be read from the main queue; the
    /// test-and-set in -finishWithOutput:error: is made safe by the serial
    /// control queue, not by this.
    atomic_bool _finishedFlag;

    /// Diagnostic only; written and read on the control queue.
    NSString *_videoContentType;
    NSString *_audioContentType;
}

#pragma mark Registry

// NSURLSession retains its delegate, but only until the session is invalidated —
// and the merge runs after that. This is what keeps the flow alive across that
// gap without asking either downloader to park it in a global of its own.
// Touched on the main queue only.
static NSMutableSet<FBPDashDownload *> *gFBPDashDownloadsInFlight = nil;

static void FBPDashRetain(FBPDashDownload *download) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gFBPDashDownloadsInFlight) {
            gFBPDashDownloadsInFlight = [NSMutableSet set];
        }
        [gFBPDashDownloadsInFlight addObject:download];
    });
}

static void FBPDashRelease(FBPDashDownload *download) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [gFBPDashDownloadsInFlight removeObject:download];
    });
}

#pragma mark Start

+ (instancetype)startWithVideoURL:(NSURL *)videoURL
                         audioURL:(NSURL *)audioURL
                        outputURL:(NSURL *)outputURL
                         progress:(FBPDashDownloadProgress)progress
                       completion:(FBPDashDownloadCompletion)completion {
    return [self startWithVideoURL:videoURL
                          audioURL:audioURL
                         outputURL:outputURL
                      convertVideo:NO
                     sourceBitRate:0
                          progress:progress
                        completion:completion];
}

+ (instancetype)startWithVideoURL:(NSURL *)videoURL
                         audioURL:(NSURL *)audioURL
                        outputURL:(NSURL *)outputURL
                     convertVideo:(BOOL)convertVideo
                    sourceBitRate:(long long)sourceBitRate
                         progress:(FBPDashDownloadProgress)progress
                       completion:(FBPDashDownloadCompletion)completion {
    if (!completion) return nil;

    FBPDashDownload *download = [[FBPDashDownload alloc] init];
    download->_videoURL = [videoURL copy];
    download->_audioURL = [audioURL copy];
    download->_outputURL = [outputURL copy];
    download->_convertVideo = convertVideo;
    download->_sourceBitRate = MAX(sourceBitRate, 0LL);
    download->_progress = [progress copy];
    download->_completion = [completion copy];
    download->_control = dispatch_queue_create("com.shajon.fbplus.dashdownload",
                                               DISPATCH_QUEUE_SERIAL);
    download->_stage = FBPDashDownloadStageFetching;
    download->_lastReportedPercent = -1;
    atomic_store(&download->_finishedFlag, false);

    FBPDashRetain(download);
    dispatch_async(download->_control, ^{ [download begin]; });
    return download;
}

- (void)begin {
    if (![self prepare]) return;

    NSURLSessionConfiguration *config =
        [NSURLSessionConfiguration defaultSessionConfiguration];
    // The same two settings the single-URL path uses, for the same reasons: a
    // signed CDN URL must never be answered out of the URL cache (the cached
    // copy outlives the signature), and a stalled transfer has to give up rather
    // than hold the progress HUD open forever.
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    config.timeoutIntervalForRequest = kFBPDashRequestTimeout;
    config.timeoutIntervalForResource = kFBPDashResourceTimeout;

    // Serial delegate queue, as in FBPReelDownloadManager. Both tasks share it,
    // so the two streams' callbacks cannot interleave and the scratch-file move
    // below is safe to do inline.
    NSOperationQueue *queue = [[NSOperationQueue alloc] init];
    queue.maxConcurrentOperationCount = 1;

    _session = [NSURLSession sessionWithConfiguration:config
                                             delegate:self
                                        delegateQueue:queue];

    _videoTask = [_session downloadTaskWithRequest:[self requestForURL:_videoURL]];
    if (_audioURL) {
        _audioTask = [_session downloadTaskWithRequest:[self requestForURL:_audioURL]];
    }

    if (!_videoTask || (_audioURL && !_audioTask)) {
        [self finishWithOutput:nil
                         error:[self errorWithCode:FBPDashDownloadErrorBadArguments
                                       description:@"could not create a transfer"
                                   underlyingError:nil
                                        statusCode:0]];
        return;
    }

    FBPDashLog("start video=%{private}@ audio=%{private}@ convert=%{public}s",
               _videoURL.absoluteString, _audioURL.absoluteString,
               _convertVideo ? "yes" : "no");

    // Concurrently, on purpose: two independent complete files with no ordering
    // between them, and serialising would cost a whole extra round trip.
    [_videoTask resume];
    [_audioTask resume];

    [self reportProgress];
}

/// Validate the arguments and build the scratch directory. NO when the flow has
/// already been finished off with an error.
- (BOOL)prepare {
    // A nil audio URL means "silent video", an ordinary case. One that is
    // present but unusable, or identical to the video URL, is still a refusal.
    BOOL audioIsUsable = (_audioURL == nil) ||
        (FBPDashURLIsFetchable(_audioURL) &&
         ![_videoURL.absoluteString isEqualToString:_audioURL.absoluteString]);

    if (!FBPDashURLIsFetchable(_videoURL) || !audioIsUsable ||
        !_outputURL.isFileURL || _outputURL.path.length == 0) {
        [self finishWithOutput:nil
                         error:[self errorWithCode:FBPDashDownloadErrorBadArguments
                                       description:@"missing or unusable URLs"
                                   underlyingError:nil
                                        statusCode:0]];
        return NO;
    }

    NSURL *scratch = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
        URLByAppendingPathComponent:[@"FBPDash-"
            stringByAppendingString:NSUUID.UUID.UUIDString]
                        isDirectory:YES];

    NSError *createError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:scratch
                               withIntermediateDirectories:YES
                                                attributes:nil
                                                     error:&createError]) {
        [self finishWithOutput:nil
                         error:[self errorWithCode:FBPDashDownloadErrorTemporaryFile
                                       description:@"could not create a scratch directory"
                                   underlyingError:createError
                                        statusCode:0]];
        return NO;
    }

    _scratchPath = [scratch.path copy];
    // Extensions matter: AVURLAsset's type inference leans on them, and handing
    // the muxer an audio-only file named .mp4 is a needless way to lose.
    _videoFile = [scratch URLByAppendingPathComponent:@"video.mp4"];
    _audioFile = _audioURL
        ? [scratch URLByAppendingPathComponent:@"audio.m4a"]
        : nil;

    // A silent video's audio stream is finished before it begins, so the
    // readiness test below needs no special case and -fetchFraction has one
    // fewer thing to weigh.
    if (!_audioURL) _audioProgress.done = true;
    return YES;
}

- (NSURLRequest *)requestForURL:(NSURL *)url {
    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:url
                                cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                            timeoutInterval:kFBPDashRequestTimeout];
    // Unranged, deliberately. Each representation's <BaseURL> is one complete
    // self-contained file — the manifest's SegmentBase only indexes into what is
    // already there — so there is nothing to assemble and no range to ask for.
    request.HTTPMethod = @"GET";
    return request;
}

#pragma mark Cancel

- (void)cancel {
    dispatch_async(_control, ^{
        if (atomic_load(&self->_finishedFlag) || self->_cancelled) return;
        self->_cancelled = YES;

        FBPDashLog("cancelled during %{public}s",
                   self->_muxStarted
                       ? (self->_convertVideo ? "conversion" : "merge")
                       : "fetch");

        // Both, unconditionally: a task that has already finished ignores this.
        [self->_videoTask cancel];
        [self->_audioTask cancel];

        if (self->_muxStarted) {
            // The step's completion still fires, with its own cancel error,
            // and that is what reaches -finishWithOutput:error:.
            if (self->_convertVideo) {
                // Either converter may be the one in flight (the VP9 path is
                // chosen per file in -startConversion); cancelling both is safe —
                // the one that is not running has nothing to cancel.
                [FBPMediaConverter cancelAll];
                [FBPVP9Converter cancelAll];
            } else {
                [FBPMediaMuxer cancelAll];
            }
            return;
        }

        // Nothing in flight can be relied on to report back — a task cancelled
        // before it started may never reach the delegate at all — so close the
        // flow out here.
        [self finishWithOutput:nil
                         error:[self errorWithCode:FBPDashDownloadErrorCancelled
                                       description:@"cancelled"
                                   underlyingError:nil
                                        statusCode:0]];
    });
}

- (BOOL)finished {
    return atomic_load(&_finishedFlag) ? YES : NO;
}

#pragma mark Progress

/// Combined fraction of the two transfers, 0…1.
///
/// Weighted by each stream's Content-Length when both are known; the picker's
/// own figure covers video and audio together, so it cannot be split across the
/// two bars. With either length missing this falls back to a simple average,
/// which is what the weighting degenerates to when the weights are equal.
- (float)fetchFraction {
    float videoFraction = FBPDashStreamFraction(_videoProgress);

    // A silent video has one stream, and its progress is the whole fetch.
    // Without this the pre-satisfied audio stream would contribute a constant
    // 1.0 to the average and the bar would open at 50%.
    if (!_audioURL) return videoFraction;

    float audioFraction = FBPDashStreamFraction(_audioProgress);

    int64_t videoWeight = _videoProgress.expected;
    int64_t audioWeight = _audioProgress.expected;

    if (videoWeight > 0 && audioWeight > 0) {
        double total = (double)videoWeight + (double)audioWeight;
        return (float)(((double)videoWeight * (double)videoFraction +
                        (double)audioWeight * (double)audioFraction) / total);
    }

    return (videoFraction + audioFraction) / 2.0f;
}

- (void)reportProgress {
    if (atomic_load(&_finishedFlag) || !_progress) return;

    float share = _convertVideo ? kFBPDashConvertFetchShare : kFBPDashFetchShare;

    // Initialized before the switch, which is then still written without a
    // `default:` so that -Wswitch flags a new stage rather than letting it fall
    // through silently. The initializer is what makes that safe: a stage nobody
    // handled parks the bar instead of reading uninitialized stack.
    float fraction = share;
    switch (_stage) {
        case FBPDashDownloadStageMerging:
            // No progress of its own; park at the end of the fetch slice.
            fraction = share;
            break;
        case FBPDashDownloadStageConverting:
            // This one does have progress, so the remaining slice is spent
            // rather than parked. The converter already caps itself just under
            // 1.0, so the bar stops short of full until the file is finalized.
            fraction = share + _convertFraction * (1.0f - share);
            break;
        case FBPDashDownloadStageFetching:
            fraction = [self fetchFraction] * share;
            break;
    }

    // Never backwards. The weights arrive with the responses, so there is a
    // window in which one length is known and the other is not, and the two
    // formulas disagree across it — the average can read 50% where the weighted
    // figure for the same state is 23%. The bar pauses rather than retreating.
    if (fraction < _reportedFraction) fraction = _reportedFraction;
    _reportedFraction = fraction;

    NSInteger percent = (NSInteger)lrintf(fraction * 100.0f);
    if (percent == _lastReportedPercent) return;
    _lastReportedPercent = percent;

    FBPDashDownloadStage stage = _stage;
    FBPDashDownloadProgress block = _progress;
    dispatch_async(dispatch_get_main_queue(), ^{ block(stage, fraction); });
}

#pragma mark Merge or convert

/// Both streams are down: start whichever last step this flow was asked for.
/// The two are alternatives, not a sequence — FBPMediaConverter writes the audio
/// track in the same pass, so converting *is* the merge for an AV1 rung.
- (void)startMuxIfReady {
    if (atomic_load(&_finishedFlag) || _cancelled || _muxStarted) return;
    if (!_videoProgress.done || !_audioProgress.done) return;

    _muxStarted = YES;
    _stage = _convertVideo ? FBPDashDownloadStageConverting
                           : FBPDashDownloadStageMerging;
    // Force the stage change out even if the percentage happens not to move.
    _lastReportedPercent = -1;
    [self reportProgress];

    FBPDashLog("fetched video=%lld bytes type=%{public}@ · audio=%lld bytes "
               "type=%{public}@ · %{public}s",
               (long long)_videoProgress.received, _videoContentType ?: @"(none)",
               (long long)_audioProgress.received, _audioContentType ?: @"(none)",
               _convertVideo ? "converting" : "merging");

    // Replace whatever is at the output path first: the single-URL path does the
    // same before its move, and a stale file there would otherwise be what the
    // muxer refuses.
    [NSFileManager.defaultManager removeItemAtURL:_outputURL error:nil];

    if (_convertVideo) {
        [self startConversion];
        return;
    }

    [FBPMediaMuxer muxVideoURL:_videoFile
                      audioURL:_audioFile
                     outputURL:_outputURL
                    completion:^(NSURL *muxed, NSError *muxError) {
        dispatch_async(self->_control, ^{
            if (muxed && !muxError && !self->_cancelled) {
                FBPDashLog("merge ok -> %{private}@", muxed.path);
                [self finishWithOutput:muxed error:nil];
                return;
            }

            BOOL wasCancelled =
                self->_cancelled ||
                ([muxError.domain isEqualToString:FBPMediaMuxerErrorDomain] &&
                 muxError.code == FBPMediaMuxerErrorCancelled);

            FBPDashLog("merge did not deliver (%{public}s) code=%ld",
                       wasCancelled ? "cancelled" : "failed", (long)muxError.code);

            [self finishWithOutput:nil
                             error:[self errorWithCode:
                                        (wasCancelled ? FBPDashDownloadErrorCancelled
                                                      : FBPDashDownloadErrorMux)
                                           description:(wasCancelled
                                               ? @"cancelled"
                                               : @"the two streams could not be merged")
                                       underlyingError:muxError
                                            statusCode:0]];
        });
    }];
}

/// Re-encode the picture (HEVC, or H.264 as the fallback) and write both tracks,
/// in one pass. Structurally the mux branch plus a progress block: the encode is
/// the long pole of an AV1 save, so its fraction is forwarded into the bar.
- (void)startConversion {
    // AV1 goes to AVFoundation (FBPMediaConverter), VP9 to the borrowed decoder
    // (FBPVP9Converter). -canDecodeVideoAtURL: is a per-file -isPlayable, so the
    // split follows the device's real capability rather than a codec guess.
    BOOL avfoundationDecodes = [FBPMediaConverter canDecodeVideoAtURL:_videoFile];

    void (^progress)(float) = ^(float fraction) {
        dispatch_async(self->_control, ^{
            if (self->_stage != FBPDashDownloadStageConverting) return;
            self->_convertFraction = fraction;
            [self reportProgress];
        });
    };

    void (^completion)(NSURL *_Nullable, NSError *_Nullable) = ^(NSURL *converted, NSError *convertError) {
        dispatch_async(self->_control, ^{
            if (converted && !convertError && !self->_cancelled) {
                FBPDashLog("convert ok -> %{private}@", converted.path);
                [self finishWithOutput:converted error:nil];
                return;
            }

            BOOL wasCancelled =
                self->_cancelled ||
                ([convertError.domain isEqualToString:FBPMediaConverterErrorDomain] &&
                 convertError.code == FBPMediaConverterErrorCancelled);

            FBPDashLog("convert did not deliver (%{public}s) code=%ld",
                       wasCancelled ? "cancelled" : "failed",
                       (long)convertError.code);

            [self finishWithOutput:nil
                             error:[self errorWithCode:
                                        (wasCancelled ? FBPDashDownloadErrorCancelled
                                                      : FBPDashDownloadErrorConvert)
                                           description:(wasCancelled
                                               ? @"cancelled"
                                               : @"the video could not be converted")
                                       underlyingError:convertError
                                            statusCode:0]];
        });
    };

    if (avfoundationDecodes) {
        [FBPMediaConverter convertVideoURL:_videoFile
                                 audioURL:_audioFile
                            sourceBitRate:_sourceBitRate
                                outputURL:_outputURL
                                 progress:progress
                               completion:completion];
    } else {
        [FBPVP9Converter convertVideoURL:_videoFile
                               audioURL:_audioFile
                          sourceBitRate:_sourceBitRate
                              outputURL:_outputURL
                               progress:progress
                             completion:completion];
    }
}

#pragma mark Exit

/// The one way out. Runs on the control queue, at most once. Everything this
/// flow created is gone by the time the completion runs, except the output when
/// it is handed over, so a caller never guesses whether it owns a file.
- (void)finishWithOutput:(NSURL *)output error:(NSError *)error {
    if (atomic_load(&_finishedFlag)) return;
    atomic_store(&_finishedFlag, true);

    // Cancels whatever is still running and, importantly, breaks the session's
    // strong reference to this object. Asynchronous, so the scratch directory is
    // swept again once it finishes — see -URLSession:didBecomeInvalidWithError:.
    [_session invalidateAndCancel];
    _session = nil;

    [self removeScratchDirectory];

    if (!output && _outputURL) {
        // FBPMediaMuxer already deletes its own partial output, but a cancel
        // that landed between the merge finishing and this point, or an output
        // path never muxed into, would otherwise leave a file behind.
        // Idempotent, so doing it anyway costs nothing.
        [NSFileManager.defaultManager removeItemAtURL:_outputURL error:nil];
    }

    NSError *reported = error;
    if (!output && !reported) {
        reported = [self errorWithCode:FBPDashDownloadErrorMux
                           description:@"the merge produced no file"
                       underlyingError:nil
                            statusCode:0];
    }

    FBPDashDownloadCompletion completion = _completion;
    _completion = nil;
    _progress = nil;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) completion(output, reported);
        FBPDashRelease(self);
    });
}

/// Idempotent, and called twice on purpose: at the exit, and again when the
/// session confirms no further delegate messages. The second sweep covers a
/// scratch-file move still in flight on the delegate queue when the exit ran.
- (void)removeScratchDirectory {
    NSString *path = _scratchPath;
    if (path.length == 0) return;
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
}

- (NSError *)errorWithCode:(FBPDashDownloadError)code
               description:(NSString *)description
           underlyingError:(NSError *)underlying
                statusCode:(NSInteger)statusCode {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (description) info[NSLocalizedDescriptionKey] = description;
    if (underlying) info[NSUnderlyingErrorKey] = underlying;
    if (statusCode != 0) info[FBPDashDownloadStatusCodeKey] = @(statusCode);
    return [NSError errorWithDomain:FBPDashDownloadErrorDomain
                               code:code
                           userInfo:info];
}

#pragma mark NSURLSessionDelegate

- (void)URLSession:(NSURLSession *)session
    didBecomeInvalidWithError:(NSError *)error {
    dispatch_async(_control, ^{ [self removeScratchDirectory]; });
}

#pragma mark NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    BOOL isVideo = (downloadTask == _videoTask);
    if (!isVideo && downloadTask != _audioTask) return;

    dispatch_async(_control, ^{
        FBPDashStreamProgress *stream =
            isVideo ? &self->_videoProgress : &self->_audioProgress;
        stream->received = totalBytesWritten;
        // NSURLSessionTransferSizeUnknown is -1; anything <= 0 means the CDN did
        // not say, so the weight stays 0 and the simple average takes over.
        if (totalBytesExpectedToWrite > 0) {
            stream->expected = totalBytesExpectedToWrite;
        }
        [self reportProgress];
    });
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    BOOL isVideo = (downloadTask == _videoTask);
    if (!isVideo && downloadTask != _audioTask) return;

    NSHTTPURLResponse *response =
        [downloadTask.response isKindOfClass:NSHTTPURLResponse.class]
            ? (NSHTTPURLResponse *)downloadTask.response
            : nil;
    NSInteger status = response ? response.statusCode : 0;
    NSString *contentType = response.MIMEType;

    // A refused transfer still "finishes", with the CDN's error body as its
    // payload, and without this that error page reaches the muxer. 403 is the
    // signed URL's `oe=` expiry, which tapping download again fixes.
    if (response && (status < 200 || status >= 300)) {
        dispatch_async(_control, ^{
            FBPDashLog("%{public}s stream rejected HTTP %ld",
                       isVideo ? "video" : "audio", (long)status);
            [self finishWithOutput:nil
                             error:[self errorWithCode:
                                        (isVideo ? FBPDashDownloadErrorVideoHTTP
                                                 : FBPDashDownloadErrorAudioHTTP)
                                           description:@"the CDN refused the request"
                                       underlyingError:nil
                                            statusCode:status]];
        });
        return;
    }

    // Has to happen synchronously, here: NSURLSession deletes `location` as soon
    // as this method returns. The delegate queue is serial, so the two streams
    // cannot be doing this at the same time.
    NSURL *destination = isVideo ? _videoFile : _audioFile;
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtURL:destination error:nil];

    NSError *moveError = nil;
    BOOL moved = (destination != nil) && [fm moveItemAtURL:location
                                                     toURL:destination
                                                     error:&moveError];

    // What is actually on disk, rather than the task's byte counter, so the
    // diagnostic reports the file the muxer will be handed.
    long long bytes = 0;
    if (moved) {
        NSDictionary *attributes =
            [fm attributesOfItemAtPath:destination.path error:NULL];
        bytes = (long long)[attributes[NSFileSize] longLongValue];
    }

    dispatch_async(_control, ^{
        if (atomic_load(&self->_finishedFlag) || self->_cancelled) return;

        if (!moved) {
            FBPDashLog("%{public}s stream could not be moved into place",
                       isVideo ? "video" : "audio");
            [self finishWithOutput:nil
                             error:[self errorWithCode:FBPDashDownloadErrorTemporaryFile
                                           description:@"could not store the downloaded stream"
                                       underlyingError:moveError
                                            statusCode:0]];
            return;
        }

        FBPDashStreamProgress *stream =
            isVideo ? &self->_videoProgress : &self->_audioProgress;
        stream->done = true;
        stream->received = bytes;
        if (bytes > 0) stream->expected = bytes;

        if (isVideo) {
            self->_videoContentType = [contentType copy];
        } else {
            self->_audioContentType = [contentType copy];
        }

        [self reportProgress];
        [self startMuxIfReady];
    });
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (!error) return;

    BOOL isVideo = (task == _videoTask);
    if (!isVideo && task != _audioTask) return;

    NSError *captured = error;
    dispatch_async(_control, ^{
        if (atomic_load(&self->_finishedFlag)) return;

        // -cancel cancelled these tasks; reporting that as a transport failure
        // would put an alert in front of a user who just asked it to stop.
        if (self->_cancelled || captured.code == NSURLErrorCancelled) {
            [self finishWithOutput:nil
                             error:[self errorWithCode:FBPDashDownloadErrorCancelled
                                           description:@"cancelled"
                                       underlyingError:nil
                                            statusCode:0]];
            return;
        }

        FBPDashLog("%{public}s stream transport failure: %{public}@",
                   isVideo ? "video" : "audio", captured.localizedDescription);

        [self finishWithOutput:nil
                         error:[self errorWithCode:
                                    (isVideo ? FBPDashDownloadErrorVideoTransport
                                             : FBPDashDownloadErrorAudioTransport)
                                       description:@"the transfer failed"
                                   underlyingError:captured
                                        statusCode:0]];
    });
}

@end

#pragma mark - Reporting

/// The best sentence available for whatever went wrong underneath — the CDN's
/// status, or the system's own description of a dropped connection.
static NSString *FBPDashDownloadReason(NSError *error) {
    NSNumber *status = error.userInfo[FBPDashDownloadStatusCodeKey];
    if (status != nil) {
        return [NSString stringWithFormat:FBPDashL(@"download.reel.httpError"),
                                          (long)status.integerValue];
    }

    NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
    NSString *reason = underlying.localizedDescription;
    return reason.length > 0 ? reason : FBPDashL(@"download.error.unknown");
}

NSString *FBPDashDownloadMessageForError(NSError *error) {
    if (!error) return nil;
    if (![error.domain isEqualToString:FBPDashDownloadErrorDomain]) {
        return [NSString stringWithFormat:FBPDashL(@"download.reel.failedDetail"),
                                          error.localizedDescription
                                              ?: FBPDashL(@"download.error.unknown")];
    }

    // A 403 on either stream is the signed URL's `oe=` expiry, and that already
    // has wording that tells the user the one thing that helps: tap again. Which
    // of the two streams expired is not information they can use.
    NSNumber *status = error.userInfo[FBPDashDownloadStatusCodeKey];
    if (status.integerValue == 403) return FBPDashL(@"download.reel.expired");

    switch ((FBPDashDownloadError)error.code) {
        case FBPDashDownloadErrorCancelled:
            return nil;

        case FBPDashDownloadErrorVideoHTTP:
        case FBPDashDownloadErrorVideoTransport:
            return [NSString stringWithFormat:FBPDashL(@"download.stream.videoFailed"),
                                              FBPDashDownloadReason(error)];

        case FBPDashDownloadErrorAudioHTTP:
        case FBPDashDownloadErrorAudioTransport:
            return [NSString stringWithFormat:FBPDashL(@"download.stream.audioFailed"),
                                              FBPDashDownloadReason(error)];

        case FBPDashDownloadErrorTemporaryFile:
            return FBPDashL(@"download.reel.tmpFailed");

        case FBPDashDownloadErrorMux:
            return [NSString stringWithFormat:FBPDashL(@"download.merge.failed"),
                                              FBPDashDownloadReason(error)];

        case FBPDashDownloadErrorConvert: {
            // A device with no AV1 decoder will never convert this rung, so it
            // gets its own sentence: the only useful advice is another quality.
            // Every other conversion failure is a this-time problem.
            NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
            if ([underlying.domain isEqualToString:FBPMediaConverterErrorDomain] &&
                (underlying.code == FBPMediaConverterErrorNoConversionPath ||
                 underlying.code == FBPMediaConverterErrorVideoUndecodable)) {
                return FBPDashL(@"download.convert.unsupported");
            }
            return [NSString stringWithFormat:FBPDashL(@"download.convert.failed"),
                                              FBPDashDownloadReason(error)];
        }

        case FBPDashDownloadErrorBadArguments:
            break;
    }

    return FBPDashL(@"download.reel.failed");
}
