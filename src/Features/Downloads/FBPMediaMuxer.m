// Lossless video + audio muxer. See FBPMediaMuxer.h for what this is for.
//
// Why AVFoundation and not FFmpeg
// ------------------------------------------------------------------------
// The obvious alternative statically links ~15 MB of near-default FFmpeg and
// uses it as nothing more than a stream copy: avformat_open_input,
// avcodec_parameters_copy, av_interleaved_write_frame, movflags=+faststart. Not
// one frame re-encoded. AVFoundation does the same, is already linked, and costs
// no bytes.
//
// Borrowing Facebook's own copy is not an option, and shipping a dylib under
// those names is dangerous: the app bundles libavcodec.framework and
// libavutil.framework with install names @rpath/libavcodec.framework/libavcodec
// — a VP9 *decoder*, with no libavformat, so no muxer at all. A dylib of this
// tweak's with the same @rpath name would collide with the host's.
//
// How the stream copy works
// ------------------------------------------------------------------------
// An AVAssetReaderTrackOutput with `outputSettings: nil` hands back the track's
// samples still compressed. An AVAssetWriterInput with `outputSettings: nil`
// writes appended samples through "doing no processing" (AVAssetWriterInput.h:
// 63). The catch, and the most common way to get this wrong: for any file type
// other than AVFileTypeQuickTimeMovie — MPEG-4 here — passthrough requires a
// non-NULL sourceFormatHint, via
// +assetWriterInputWithMediaType:outputSettings:sourceFormatHint:
// (AVAssetWriterInput.h:113), and -addInput: throws without one
// (AVAssetWriter.h:276). So every input is created with the source track's own
// CMFormatDescription as its hint.
//
// Reader/writer, not AVMutableComposition + AVAssetExportSession: the
// composition route is fewer lines, but passthrough export of a composition has
// credible reports of progressive audio drift (Apple Developer Forums 663734),
// worst with mono audio — often a Reel's audio representation. Reader/writer
// also lets the session start time come from each track's real first sample
// rather than the composition's idea of zero.

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

/// A CMFormatDescription's media subtype as its four characters, so the
/// diagnostic says "avc1" / "mp4a" rather than a bare integer. Proves in the log
/// that what went in came out — hence __unused, since FBPLog and every call
/// compile away in release.
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
// something must keep the job alive between the two GETs finishing and the
// completion firing. This set is that owner, and what +cancelAll walks. Entries
// are added before any work starts and removed in the single exit,
// -finishWithError:.

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
    /// sharing one risks one input's not-ready state starving the other.
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
    // pump to notice the flag.
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
        // Not registered yet, so fail straight out rather than through the
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
/// The cheap half of the robustness story. Both inputs are files downloaded from
/// signed, short-lived CDN URLs, so a "video.mp4" on disk can just as easily be
/// an HTML error page, a JSON expiry response, or the first 60 KB of an MP4 the
/// connection dropped mid-file. All three show up here as unreadable, or
/// readable with no track of the needed type.
- (void)loadAssets {
    if ([self checkCancelled]) {
        [self finishWithError:self.failure];
        return;
    }

    // Precise timing costs a header scan but makes the track time ranges the
    // session start is picked from trustworthy.
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
    // format description cannot be passed through, and guessing one means
    // guessing the codec.
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

    // nil output settings is the point: samples come out in the codec they are
    // stored in, with no decode step.
    _videoOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack
                                                             outputSettings:nil];
    _audioOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack
                                                             outputSettings:nil];

    // Each buffer goes straight to the writer and is released, so there is
    // nothing to protect by copying sample data first. The one buffer held
    // across a queue hop — the peeked first sample below — is appended before
    // anything asks the same output for another, so the reader cannot recycle
    // underneath it.
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

    // The AVFoundation equivalent of movflags=+faststart: the moov atom is
    // written ahead of the media, so the file streams from the first byte.
    _writer.shouldOptimizeForNetworkUse = YES;

    _videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                    outputSettings:nil
                                                  sourceFormatHint:videoFormat];
    _audioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                    outputSettings:nil
                                                  sourceFormatHint:audioFormat];

    _videoInput.expectsMediaDataInRealTime = NO;
    _audioInput.expectsMediaDataInRealTime = NO;

    // The most likely visible bug in this file. Rotation in an MP4 is not in the
    // pixels, it is a 3x3 matrix on the video track, and a fresh
    // AVAssetWriterInput's matrix is the identity. Copy it across and a portrait
    // Reel saves portrait; forget, and every portrait video lands in Photos on
    // its side, picture untouched.
    _videoInput.transform = videoTrack.preferredTransform;

    // VP9 is why this is a check, not an assumption: Facebook ships a VP9
    // decoder, and a chosen DASH representation that turns out to be VP9 or Opus
    // is not in AVAssetWriter's restricted passthrough subtypes for MPEG-4.
    // -canAddInput: turns that into a clean error instead of the exception
    // -addInput: would throw.
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
/// the track was empty or the read failed outright.
///
/// Peeking starts the writing session at the real start time instead of
/// assuming zero. A track's timeRange is a header claim; the first sample's
/// presentation timestamp is what the writer is actually asked to accept, and a
/// session started later than that is a hard failure. Doubles as the last
/// readability check: a file whose headers promise a track it does not contain
/// fails here rather than producing a silent video.
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
/// time and then to zero, so the writer never gets an invalid CMTime.
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

    // The two files are separate downloads of the same video, so usually both
    // based at zero — but a representation can carry an edit list or encoder
    // delay that puts its first sample elsewhere, and the two need not agree.
    // Taking the earlier as the session start keeps the gap between them as it
    // was: whichever track starts later still starts later in the output by the
    // same amount, so nothing drifts and nothing is nudged into sync it never
    // had.
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

    // Nothing enforces equal durations. Each pump drives its track to the end of
    // its file and marks its input finished there; the shorter track stops, and
    // the output runs as long as the longer one.
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

/// Copy one track's samples across, oldest first, for as long as the writer
/// takes them.
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
    // Diagnostic only, unused once FBPLog compiles away in release.
    __block __unused NSInteger appended = 0;

    [input requestMediaDataWhenReadyOnQueue:queue usingBlock:^{
        // AVFoundation keeps invoking this block until the input is marked
        // finished, so the latch is what balances the group.
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
                // End of this track — or a read that died partway, which is how
                // a download truncated mid-file looks from here.
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
        // Delivered on an arbitrary queue; every decision belongs on the
        // control queue.
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

/// Read the finished file back and log its tracks.
///
/// Cheap standing proof that the pipeline is a stream copy: a future change that
/// re-encodes makes these four-character codes stop matching the ones logged on
/// the way in. Debug builds only — FBPLog compiles away in release, and so does
/// the asset this builds.
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
        // Never leave a half-written MP4 behind: the caller's next step hands
        // this path to Photos, which would happily import a broken file.
        if (_writer.status == AVAssetWriterStatusWriting) [_writer cancelWriting];
        [NSFileManager.defaultManager removeItemAtURL:_outputURL error:nil];

        FBPLog(@"muxer: failed (%ld) %@", (long)error.code, error.localizedDescription);
    }

    [_videoReader cancelReading];
    [_audioReader cancelReading];

    // The writer retains its inputs, which retain the pump blocks, which retain
    // self. Dropping them lets this object — and the registry entry below, its
    // last owner — go away.
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
