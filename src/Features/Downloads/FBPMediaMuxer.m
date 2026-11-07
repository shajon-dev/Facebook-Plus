// Lossless video + audio muxer. See FBPMediaMuxer.h for what this is for.
//
// Why AVFoundation and not FFmpeg
// ------------------------------------------------------------------------
// The obvious reference implementation for this job statically links roughly
// 15 MB of near-default FFmpeg and then uses it as nothing more than a stream
// copy: avformat_open_input, avcodec_parameters_copy, av_interleaved_write_frame,
// movflags=+faststart. Not one frame is re-encoded. AVFoundation does exactly
// that, is already linked, and costs no bytes.
//
// Borrowing Facebook's own copy is not an option either, and shipping our own
// dylib under those names is actively dangerous: the app bundles
// libavcodec.framework and libavutil.framework with install names
// @rpath/libavcodec.framework/libavcodec — a VP9 *decoder*, with no libavformat,
// so no muxer at all. A dynamic library of ours with the same @rpath name would
// collide with the host's.
//
// How the stream copy works
// ------------------------------------------------------------------------
// An AVAssetReaderTrackOutput built with `outputSettings: nil` hands back the
// track's samples still compressed. An AVAssetWriterInput built with
// `outputSettings: nil` writes appended samples through "doing no processing"
// (AVAssetWriterInput.h:63). The one catch, which is also the single most
// common way to get this wrong: for any file type other than
// AVFileTypeQuickTimeMovie — and we want MPEG-4 — passthrough requires a
// non-NULL sourceFormatHint, via
// +assetWriterInputWithMediaType:outputSettings:sourceFormatHint:
// (AVAssetWriterInput.h:113), and -addInput: throws without one
// (AVAssetWriter.h:276). So every input here is created with the source track's
// own CMFormatDescription as its hint.
//
// Reader/writer rather than AVMutableComposition + AVAssetExportSession: the
// composition route is fewer lines, but passthrough export of a composition has
// credible reports of progressive audio drift (Apple Developer Forums 663734),
// worst with mono audio — which is exactly what a Reel's audio representation
// often is. Reader/writer also lets us choose the session start time from the
// real first sample of each track instead of hoping the composition's idea of
// zero matches ours.

#import "FBPMediaMuxer.h"

#import "FBPlus.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <stdatomic.h>

NSString *const FBPMediaMuxerErrorDomain = @"com.shajon.fbplus.muxer";

#pragma mark - Error construction

static NSError *FBPMuxError(FBPMediaMuxerError code,
                            NSString *description,
                            NSError *_Nullable underlying) {
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithCapacity:2];
    info[NSLocalizedDescriptionKey] = description ?: @"Muxing failed.";
    if (underlying) info[NSUnderlyingErrorKey] = underlying;

    return [NSError errorWithDomain:FBPMediaMuxerErrorDomain
                               code:code
                           userInfo:info];
}

/// A CMFormatDescription's media subtype as the four characters it really is, so
/// the diagnostic can say "avc1" / "mp4a" rather than a bare integer. Used only
/// to prove, in the log, that what went in is what came out — hence __unused,
/// since FBPLog and every call to this compile away in release.
__attribute__((unused))
static NSString *FBPMuxFourCC(CMFormatDescriptionRef format) {
    if (!format) return @"none";

    FourCharCode code = CMFormatDescriptionGetMediaSubType(format);
    char chars[5] = {
        (char)((code >> 24) & 0xFF), (char)((code >> 16) & 0xFF),
        (char)((code >> 8) & 0xFF),  (char)(code & 0xFF), 0,
    };

    for (int i = 0; i < 4; i++) {
        if (chars[i] < 0x20 || chars[i] > 0x7E) {
            return [NSString stringWithFormat:@"0x%08x", (unsigned)code];
        }
    }
    return @(chars);
}

#pragma mark - In-flight registry

// A mux owns itself for its lifetime: the caller gets no handle back, so
// something has to keep the job alive between the two GETs finishing and the
// completion firing. This set is that owner, and it is also what +cancelAll
// walks. Entries are added before any work starts and removed in the single
// exit point, -finishWithError:.

static NSMutableSet *gFBPMuxJobs = nil;
static NSLock *gFBPMuxJobsLock = nil;

static void FBPMuxEnsureRegistry(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gFBPMuxJobs = [NSMutableSet set];
        gFBPMuxJobsLock = [[NSLock alloc] init];
    });
}

#pragma mark - Muxer

@implementation FBPMediaMuxer {
    NSURL *_videoURL;
    NSURL *_audioURL;
    NSURL *_outputURL;
    FBPMediaMuxCompletion _completion;

    /// Every decision — setup, finalization, the single exit — is made here, so
    /// the two sample pumps never race over the writer's state.
    dispatch_queue_t _controlQueue;
    /// AVAssetWriterInput wants each input driven from its own serial queue;
    /// sharing one between a video and an audio input risks one input's
    /// not-ready state starving the other.
    dispatch_queue_t _videoQueue;
    dispatch_queue_t _audioQueue;

    AVAssetReader *_videoReader;
    AVAssetReader *_audioReader;
    AVAssetReaderTrackOutput *_videoOutput;
    AVAssetReaderTrackOutput *_audioOutput;

    AVAssetWriter *_writer;
    AVAssetWriterInput *_videoInput;
    AVAssetWriterInput *_audioInput;

    /// First error from either pump, whichever got there first. Read and written
    /// under @synchronized(self) because the two pumps run on two queues.
    NSError *_failure;

    atomic_bool _cancelled;
    /// Control queue only. Guarantees the completion block runs exactly once.
    BOOL _completed;
}

#pragma mark Entry points

+ (void)muxVideoURL:(NSURL *)videoURL
           audioURL:(NSURL *)audioURL
          outputURL:(NSURL *)outputURL
         completion:(FBPMediaMuxCompletion)completion {
    if (!completion) return;

    FBPMediaMuxer *job = [[FBPMediaMuxer alloc] initWithVideoURL:videoURL
                                                       audioURL:audioURL
                                                      outputURL:outputURL
                                                     completion:completion];
    [job start];
}

+ (void)cancelAll {
    FBPMuxEnsureRegistry();

    [gFBPMuxJobsLock lock];
    NSArray *jobs = gFBPMuxJobs.allObjects;
    [gFBPMuxJobsLock unlock];

    for (FBPMediaMuxer *job in jobs) [job cancel];
}

#pragma mark Lifetime

- (instancetype)initWithVideoURL:(NSURL *)videoURL
                        audioURL:(NSURL *)audioURL
                       outputURL:(NSURL *)outputURL
                      completion:(FBPMediaMuxCompletion)completion {
    if ((self = [super init])) {
        _videoURL = [videoURL copy];
        _audioURL = [audioURL copy];
        _outputURL = [outputURL copy];
        _completion = [completion copy];

        _controlQueue = dispatch_queue_create("com.shajon.fbplus.muxer.control",
                                              DISPATCH_QUEUE_SERIAL);
        _videoQueue = dispatch_queue_create("com.shajon.fbplus.muxer.video",
                                            DISPATCH_QUEUE_SERIAL);
        _audioQueue = dispatch_queue_create("com.shajon.fbplus.muxer.audio",
                                            DISPATCH_QUEUE_SERIAL);

        atomic_init(&_cancelled, false);
    }
    return self;
}

- (void)cancel {
    atomic_store_explicit(&_cancelled, true, memory_order_relaxed);

    // Nudge the control queue too: a job still waiting on asset headers has no
    // pump running to notice the flag.
    dispatch_async(_controlQueue, ^{
        [self checkCancelled];
    });
}

/// YES when this job has been cancelled, recording the cancellation as the
/// failure if nothing else has failed yet.
- (BOOL)checkCancelled {
    if (!atomic_load_explicit(&_cancelled, memory_order_relaxed)) return NO;

    [self recordFailure:FBPMuxError(FBPMediaMuxerErrorCancelled,
                                    @"Muxing was cancelled.", nil)];
    return YES;
}

- (void)recordFailure:(NSError *)error {
    if (!error) return;
    @synchronized (self) {
        if (!_failure) _failure = error;
    }
}

- (NSError *)failure {
    @synchronized (self) {
        return _failure;
    }
}

#pragma mark Setup

- (void)start {
    if (!_videoURL || !_audioURL || !_outputURL) {
        // No registration yet, so fail straight out rather than through the
        // normal exit, which expects to deregister.
        FBPMediaMuxCompletion completion = _completion;
        _completion = nil;
        NSError *error = FBPMuxError(FBPMediaMuxerErrorBadArguments,
                                     @"Muxing needs a video, an audio and an "
                                     @"output URL.", nil);
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, error);
        });
        return;
    }

    FBPMuxEnsureRegistry();
    [gFBPMuxJobsLock lock];
    [gFBPMuxJobs addObject:self];
    [gFBPMuxJobsLock unlock];

    dispatch_async(_controlQueue, ^{
        [self loadAssets];
    });
}

/// Pull both files' headers before touching a reader or a writer.
///
/// This is the cheap half of the robustness story. Both inputs are files we just
/// downloaded from signed, short-lived CDN URLs, so a "video.mp4" on disk can
/// just as easily be an HTML error page, a JSON expiry response, or the first
/// 60 KB of a real MP4 that the connection dropped in the middle of. All three
/// show up here as unreadable, or readable with no track of the type we need.
- (void)loadAssets {
    if ([self checkCancelled]) {
        [self finishWithError:self.failure];
        return;
    }

    // Precise timing costs a header scan but is what makes the track time
    // ranges we pick the session start from trustworthy.
    NSDictionary *options = @{ AVURLAssetPreferPreciseDurationAndTimingKey: @YES };
    AVURLAsset *videoAsset = [AVURLAsset URLAssetWithURL:_videoURL options:options];
    AVURLAsset *audioAsset = [AVURLAsset URLAssetWithURL:_audioURL options:options];

    NSArray<NSString *> *keys = @[ @"readable", @"tracks" ];
    dispatch_group_t group = dispatch_group_create();

    for (AVURLAsset *asset in @[ videoAsset, audioAsset ]) {
        dispatch_group_enter(group);
        [asset loadValuesAsynchronouslyForKeys:keys completionHandler:^{
            dispatch_group_leave(group);
        }];
    }

    dispatch_group_notify(group, _controlQueue, ^{
        [self buildPipelineWithVideoAsset:videoAsset audioAsset:audioAsset];
    });
}

/// Is this asset loaded, readable, and does it have a track of @c mediaType?
/// Returns the track, or nil with @c errorOut populated.
- (AVAssetTrack *)trackOfType:(AVMediaType)mediaType
                      inAsset:(AVURLAsset *)asset
                 unreadableAs:(FBPMediaMuxerError)unreadableCode
                   missingAs:(FBPMediaMuxerError)missingCode
                        error:(NSError **)errorOut {
    NSError *loadError = nil;
    AVKeyValueStatus status = [asset statusOfValueForKey:@"readable" error:&loadError];

    if (status != AVKeyValueStatusLoaded || !asset.readable) {
        if (errorOut) {
            *errorOut = FBPMuxError(unreadableCode,
                                    @"The downloaded file is not playable media.",
                                    loadError);
        }
        return nil;
    }

    if ([asset statusOfValueForKey:@"tracks" error:&loadError] != AVKeyValueStatusLoaded) {
        if (errorOut) {
            *errorOut = FBPMuxError(unreadableCode,
                                    @"The downloaded file's track list could not "
                                    @"be read.", loadError);
        }
        return nil;
    }

    AVAssetTrack *track = [asset tracksWithMediaType:mediaType].firstObject;
    if (!track) {
        if (errorOut) {
            *errorOut = FBPMuxError(missingCode,
                                    @"The downloaded file does not contain the "
                                    @"expected track.", nil);
        }
        return nil;
    }
    return track;
}

- (void)buildPipelineWithVideoAsset:(AVURLAsset *)videoAsset
                         audioAsset:(AVURLAsset *)audioAsset {
    if ([self checkCancelled]) {
        [self finishWithError:self.failure];
        return;
    }

    NSError *error = nil;

    AVAssetTrack *videoTrack = [self trackOfType:AVMediaTypeVideo
                                         inAsset:videoAsset
                                    unreadableAs:FBPMediaMuxerErrorVideoUnreadable
                                       missingAs:FBPMediaMuxerErrorNoVideoTrack
                                           error:&error];
    if (!videoTrack) {
        [self finishWithError:error];
        return;
    }

    AVAssetTrack *audioTrack = [self trackOfType:AVMediaTypeAudio
                                         inAsset:audioAsset
                                    unreadableAs:FBPMediaMuxerErrorAudioUnreadable
                                       missingAs:FBPMediaMuxerErrorNoAudioTrack
                                           error:&error];
    if (!audioTrack) {
        [self finishWithError:error];
        return;
    }

    // The hint that makes passthrough into an MP4 legal at all. A track with no
    // format description is not something we can pass through, and guessing one
    // would mean guessing the codec.
    CMFormatDescriptionRef videoFormat =
        (__bridge CMFormatDescriptionRef)videoTrack.formatDescriptions.firstObject;
    CMFormatDescriptionRef audioFormat =
        (__bridge CMFormatDescriptionRef)audioTrack.formatDescriptions.firstObject;

    if (!videoFormat || !audioFormat) {
        [self finishWithError:
            FBPMuxError(FBPMediaMuxerErrorMissingFormatDescription,
                        @"A track carries no format description, so it cannot be "
                        @"copied without re-encoding.", nil)];
        return;
    }

    FBPLog(@"muxer: in video=%@ %.0fx%.0f audio=%@",
           FBPMuxFourCC(videoFormat), videoTrack.naturalSize.width,
           videoTrack.naturalSize.height, FBPMuxFourCC(audioFormat));

    if (![self startReadersForVideoAsset:videoAsset
                             videoTrack:videoTrack
                             audioAsset:audioAsset
                             audioTrack:audioTrack
                                  error:&error]) {
        [self finishWithError:error];
        return;
    }

    if (![self createWriterWithVideoTrack:videoTrack
                             videoFormat:videoFormat
                             audioFormat:audioFormat
                                   error:&error]) {
        [self finishWithError:error];
        return;
    }

    [self startSessionAndPumpWithVideoTrack:videoTrack audioTrack:audioTrack];
}

- (BOOL)startReadersForVideoAsset:(AVURLAsset *)videoAsset
                      videoTrack:(AVAssetTrack *)videoTrack
                      audioAsset:(AVURLAsset *)audioAsset
                      audioTrack:(AVAssetTrack *)audioTrack
                           error:(NSError **)errorOut {
    NSError *readerError = nil;

    _videoReader = [AVAssetReader assetReaderWithAsset:videoAsset error:&readerError];
    if (!_videoReader) {
        if (errorOut) {
            *errorOut = FBPMuxError(FBPMediaMuxerErrorSetupFailed,
                                    @"The video file could not be opened for "
                                    @"reading.", readerError);
        }
        return NO;
    }

    _audioReader = [AVAssetReader assetReaderWithAsset:audioAsset error:&readerError];
    if (!_audioReader) {
        if (errorOut) {
            *errorOut = FBPMuxError(FBPMediaMuxerErrorSetupFailed,
                                    @"The audio file could not be opened for "
                                    @"reading.", readerError);
        }
        return NO;
    }

    // nil output settings is the whole point: the samples come out in the
    // codec they are stored in, with no decode step.
    _videoOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack
                                                             outputSettings:nil];
    _audioOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack
                                                             outputSettings:nil];

    // We hand each buffer straight to the writer and release it, so there is
    // nothing to protect by copying the sample data first. The one buffer held
    // across a queue hop — the peeked first sample below — is appended before
    // anything else asks the same output for another, so the reader has no
    // opportunity to recycle underneath it.
    _videoOutput.alwaysCopiesSampleData = NO;
    _audioOutput.alwaysCopiesSampleData = NO;

    if (![_videoReader canAddOutput:_videoOutput] ||
        ![_audioReader canAddOutput:_audioOutput]) {
        if (errorOut) {
            *errorOut = FBPMuxError(FBPMediaMuxerErrorSetupFailed,
                                    @"This media cannot be read without "
                                    @"re-encoding.", nil);
        }
        return NO;
    }

    [_videoReader addOutput:_videoOutput];
    [_audioReader addOutput:_audioOutput];

    if (![_videoReader startReading] || ![_audioReader startReading]) {
        NSError *underlying = _videoReader.error ?: _audioReader.error;
        if (errorOut) {
            *errorOut = FBPMuxError(FBPMediaMuxerErrorReadFailed,
                                    @"Reading the downloaded media failed.",
                                    underlying);
        }
        return NO;
    }
    return YES;
}

- (BOOL)createWriterWithVideoTrack:(AVAssetTrack *)videoTrack
                      videoFormat:(CMFormatDescriptionRef)videoFormat
                      audioFormat:(CMFormatDescriptionRef)audioFormat
                            error:(NSError **)errorOut {
    // AVAssetWriter refuses to start if anything already exists at its URL.
    [NSFileManager.defaultManager removeItemAtURL:_outputURL error:nil];

    NSError *writerError = nil;
    _writer = [AVAssetWriter assetWriterWithURL:_outputURL
                                       fileType:AVFileTypeMPEG4
                                          error:&writerError];
    if (!_writer) {
        if (errorOut) {
            *errorOut = FBPMuxError(FBPMediaMuxerErrorSetupFailed,
                                    @"The output file could not be created.",
                                    writerError);
        }
        return NO;
    }

    // The AVFoundation equivalent of FFmpeg's movflags=+faststart: the moov atom
    // is written ahead of the media, so the file streams from the first byte.
    _writer.shouldOptimizeForNetworkUse = YES;

    _videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                    outputSettings:nil
                                                  sourceFormatHint:videoFormat];
    _audioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                    outputSettings:nil
                                                  sourceFormatHint:audioFormat];

    _videoInput.expectsMediaDataInRealTime = NO;
    _audioInput.expectsMediaDataInRealTime = NO;

    // The single most likely visible bug in this whole file. Rotation in an MP4
    // is not in the pixels, it is a 3x3 matrix on the video track, and a fresh
    // AVAssetWriterInput's matrix is the identity. Copy it across and a portrait
    // Reel saves portrait; forget to, and every portrait video lands in Photos
    // lying on its side with the picture itself untouched.
    _videoInput.transform = videoTrack.preferredTransform;

    // VP9 is the reason this is a check and not an assumption: Facebook ships a
    // VP9 decoder in the app, and if a chosen DASH representation turns out to
    // be VP9 or Opus, AVAssetWriter's restricted set of passthrough subtypes for
    // MPEG-4 will not take it. -canAddInput: turns that into a clean error
    // instead of the exception -addInput: would throw.
    if (![_writer canAddInput:_videoInput] || ![_writer canAddInput:_audioInput]) {
        if (errorOut) {
            *errorOut = FBPMuxError(FBPMediaMuxerErrorSetupFailed,
                                    @"This combination of video and audio codecs "
                                    @"cannot be saved without re-encoding.", nil);
        }
        return NO;
    }

    @try {
        [_writer addInput:_videoInput];
        [_writer addInput:_audioInput];
    } @catch (NSException *exception) {
        if (errorOut) {
            *errorOut = FBPMuxError(FBPMediaMuxerErrorSetupFailed,
                                    exception.reason ?: @"The output file would "
                                    @"not accept these tracks.", nil);
        }
        return NO;
    }
    return YES;
}

#pragma mark Timing and sample pumps

/// The first sample of a track, or NULL — in which case @c errorOut says whether
/// the track was simply empty or the read failed outright.
///
/// Peeking is what lets us start the writing session at the real start time
/// instead of assuming zero. A track's timeRange is a header claim; the first
/// sample's presentation timestamp is the thing the writer will actually be
/// asked to accept, and a session started later than that is a hard failure.
/// It doubles as the last readability check: a file whose headers promise a
/// track it does not contain fails here rather than producing a silent video.
- (CMSampleBufferRef)copyFirstSampleFrom:(AVAssetReaderTrackOutput *)output
                                  reader:(AVAssetReader *)reader
                                   error:(NSError **)errorOut CF_RETURNS_RETAINED {
    CMSampleBufferRef sample = [output copyNextSampleBuffer];
    if (sample) return sample;

    if (reader.status == AVAssetReaderStatusFailed) {
        if (errorOut) {
            *errorOut = FBPMuxError(FBPMediaMuxerErrorReadFailed,
                                    @"The downloaded file is incomplete.",
                                    reader.error);
        }
    } else if (errorOut) {
        *errorOut = FBPMuxError(FBPMediaMuxerErrorNoSamples,
                                @"The downloaded file contains no media.", nil);
    }
    return NULL;
}

/// A sample's presentation timestamp, falling back to the track's header start
/// time and then to zero, so we never hand the writer an invalid CMTime.
static CMTime FBPMuxStartTime(CMSampleBufferRef sample, AVAssetTrack *track) {
    CMTime pts = sample ? CMSampleBufferGetPresentationTimeStamp(sample) : kCMTimeInvalid;
    if (CMTIME_IS_NUMERIC(pts)) return pts;

    CMTime trackStart = track.timeRange.start;
    return CMTIME_IS_NUMERIC(trackStart) ? trackStart : kCMTimeZero;
}

- (void)startSessionAndPumpWithVideoTrack:(AVAssetTrack *)videoTrack
                              audioTrack:(AVAssetTrack *)audioTrack {
    NSError *error = nil;

    CMSampleBufferRef firstVideo = [self copyFirstSampleFrom:_videoOutput
                                                      reader:_videoReader
                                                       error:&error];
    if (!firstVideo) {
        [self finishWithError:error];
        return;
    }

    CMSampleBufferRef firstAudio = [self copyFirstSampleFrom:_audioOutput
                                                      reader:_audioReader
                                                       error:&error];
    if (!firstAudio) {
        CFRelease(firstVideo);
        [self finishWithError:error];
        return;
    }

    // The two files are separate downloads of the same video, so they are
    // *usually* both based at zero — but a representation can carry an edit list
    // or an encoder delay that puts its first sample somewhere else, and the two
    // need not agree. Taking the earlier of the two as the session start keeps
    // the gap between them exactly as it was: whichever track really starts
    // later still starts later in the output, by the same amount, so nothing
    // drifts and nothing is nudged into sync that was not in sync to begin with.
    CMTime videoStart = FBPMuxStartTime(firstVideo, videoTrack);
    CMTime audioStart = FBPMuxStartTime(firstAudio, audioTrack);
    CMTime sessionStart = CMTimeMinimum(videoStart, audioStart);

    FBPLog(@"muxer: session start %.3fs (video %.3fs, audio %.3fs)",
           CMTimeGetSeconds(sessionStart), CMTimeGetSeconds(videoStart),
           CMTimeGetSeconds(audioStart));

    if (![_writer startWriting]) {
        CFRelease(firstVideo);
        CFRelease(firstAudio);
        [self finishWithError:FBPMuxError(FBPMediaMuxerErrorSetupFailed,
                                          @"Writing the output file could not "
                                          @"start.", _writer.error)];
        return;
    }

    [_writer startSessionAtSourceTime:sessionStart];

    // Nothing enforces equal durations. Each pump drives its own track to the
    // end of its own file and marks its input finished there; the shorter track
    // simply stops, and the output runs as long as the longer one.
    dispatch_group_t group = dispatch_group_create();

    [self pumpInput:_videoInput
               from:_videoOutput
             reader:_videoReader
              first:firstVideo
              queue:_videoQueue
              label:@"video"
              group:group];

    [self pumpInput:_audioInput
               from:_audioOutput
             reader:_audioReader
              first:firstAudio
              queue:_audioQueue
              label:@"audio"
              group:group];

    dispatch_group_notify(group, _controlQueue, ^{
        [self finalizeWriting];
    });
}

/// Copy one track's samples across, oldest first, for as long as the writer will
/// take them.
///
/// @param first A sample already pulled off @c output by the peek above; this
///   pump owns it and appends it before asking for another, so peeking does not
///   drop the first frame.
- (void)pumpInput:(AVAssetWriterInput *)input
             from:(AVAssetReaderTrackOutput *)output
           reader:(AVAssetReader *)reader
            first:(CMSampleBufferRef CF_CONSUMED)first
            queue:(dispatch_queue_t)queue
            label:(NSString *)label
            group:(dispatch_group_t)group {
    dispatch_group_enter(group);

    // Both mutated only from `queue`, which AVFoundation drives serially.
    __block CMSampleBufferRef pending = first;
    __block BOOL left = NO;
    // Diagnostic only, so unused once FBPLog compiles away in release.
    __block __unused NSInteger appended = 0;

    [input requestMediaDataWhenReadyOnQueue:queue usingBlock:^{
        // AVFoundation keeps invoking this block until the input is marked
        // finished, so the latch is what makes the group balance.
        if (left) return;

        void (^finish)(NSError *) = ^(NSError *error) {
            if (left) return;
            left = YES;

            if (pending) {
                CFRelease(pending);
                pending = NULL;
            }
            [self recordFailure:error];
            [input markAsFinished];

            FBPLog(@"muxer: %@ pump ended after %ld samples%@", label,
                   (long)appended, error ? @" (failed)" : @"");

            dispatch_group_leave(group);
        };

        while (input.isReadyForMoreMediaData) {
            if ([self checkCancelled]) {
                finish(nil);  // -checkCancelled already recorded the reason.
                return;
            }

            CMSampleBufferRef sample = pending;
            if (sample) {
                pending = NULL;
            } else {
                sample = [output copyNextSampleBuffer];
            }

            if (!sample) {
                // End of this track — or a read that died partway, which is what
                // a download truncated mid-file looks like from here.
                NSError *error = nil;
                if (reader.status == AVAssetReaderStatusFailed) {
                    error = FBPMuxError(FBPMediaMuxerErrorReadFailed,
                                        @"The downloaded file is incomplete.",
                                        reader.error);
                }
                finish(error);
                return;
            }

            BOOL ok = [input appendSampleBuffer:sample];
            CFRelease(sample);

            if (!ok) {
                finish(FBPMuxError(FBPMediaMuxerErrorWriteFailed,
                                   @"A sample could not be written to the output "
                                   @"file.", self->_writer.error));
                return;
            }
            appended++;
        }
    }];
}

#pragma mark Finalization

- (void)finalizeWriting {
    NSError *failure = self.failure;
    if (failure) {
        [self finishWithError:failure];
        return;
    }

    [_writer finishWritingWithCompletionHandler:^{
        // Delivered on an arbitrary queue; every decision belongs on ours.
        dispatch_async(self->_controlQueue, ^{
            if (self->_writer.status == AVAssetWriterStatusCompleted) {
                [self logOutputTracks];
                [self finishWithError:nil];
            } else {
                [self finishWithError:
                    FBPMuxError(FBPMediaMuxerErrorWriteFailed,
                                @"The muxed file could not be finished.",
                                self->_writer.error)];
            }
        });
    }];
}

/// Read the finished file back and log what its tracks actually are.
///
/// This is the cheap standing proof that the pipeline is a stream copy: if a
/// future change ever makes it re-encode, these four-character codes stop
/// matching the ones logged on the way in. Debug builds only — FBPLog compiles
/// away in release, and so does the asset this builds.
- (void)logOutputTracks {
#ifdef DEBUG
    AVURLAsset *result = [AVURLAsset URLAssetWithURL:_outputURL options:nil];

    for (AVAssetTrack *track in result.tracks) {
        CMFormatDescriptionRef format =
            (__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject;
        FBPLog(@"muxer: out %@ %@ %.3fs", track.mediaType, FBPMuxFourCC(format),
               CMTimeGetSeconds(track.timeRange.duration));
    }
#endif
}

/// The one and only exit. Control queue only.
- (void)finishWithError:(NSError *)error {
    if (_completed) return;
    _completed = YES;

    if (error) {
        // Never leave a half-written MP4 behind: the caller's next step is
        // handing this path to Photos, which would happily import a broken file.
        if (_writer.status == AVAssetWriterStatusWriting) [_writer cancelWriting];
        [NSFileManager.defaultManager removeItemAtURL:_outputURL error:nil];

        FBPLog(@"muxer: failed (%ld) %@", (long)error.code, error.localizedDescription);
    }

    [_videoReader cancelReading];
    [_audioReader cancelReading];

    // The writer retains its inputs, which retain the pump blocks, which retain
    // self. Dropping them here is what lets this object — and the registry entry
    // below, its last owner — go away.
    _videoReader = nil;
    _audioReader = nil;
    _videoOutput = nil;
    _audioOutput = nil;
    _videoInput = nil;
    _audioInput = nil;
    _writer = nil;

    FBPMediaMuxCompletion completion = _completion;
    _completion = nil;
    NSURL *outputURL = _outputURL;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) completion(error ? nil : outputURL, error);
    });

    [gFBPMuxJobsLock lock];
    [gFBPMuxJobs removeObject:self];
    [gFBPMuxJobsLock unlock];
}

@end
