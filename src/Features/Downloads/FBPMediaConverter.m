// AV1 -> H.264 conversion. See FBPMediaConverter.h for what this is for and why
// it is not part of FBPMediaMuxer.
//
// Shape of the pipeline
// ------------------------------------------------------------------------
// It is the muxer's pipeline with one input changed, deliberately, so the two
// read alike and the differences are the interesting part:
//
//   video:  AVAssetReaderTrackOutput(pixel buffers)  ->  AVAssetWriterInput(H.264)
//   audio:  AVAssetReaderTrackOutput(nil settings)   ->  AVAssetWriterInput(nil)
//
// The video reader is given pixel-format output settings, which is what makes it
// *decode* rather than hand back compressed samples; the writer input is given
// H.264 compression settings, which is what makes it encode. The audio path is
// byte-for-byte the muxer's passthrough, hint and all: Facebook's audio is
// already AAC, and re-encoding it would cost quality to achieve nothing.
//
// Everything structural — one control queue, a queue per input, the peeked first
// sample that fixes the session start time, the single exit that cleans up
// after itself, the in-flight registry that keeps the job alive and gives
// +cancelAll something to walk — is the muxer's, and is commented there.
//
// The two things that are genuinely new are the capability probe and the
// bitrate, and both were measured rather than reasoned about. They are below.

#import "FBPMediaConverter.h"

#import "FBPDav1dBridge.h"
#import "FBPlus.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <stdatomic.h>

NSString *const FBPMediaConverterErrorDomain = @"com.shajon.fbplus.converter";

#pragma mark - Error construction

static NSError *FBPConvertError(FBPMediaConverterError code,
                                NSString *description,
                                NSError *_Nullable underlying) {
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithCapacity:2];
    info[NSLocalizedDescriptionKey] = description ?: @"Converting failed.";
    if (underlying) info[NSUnderlyingErrorKey] = underlying;

    return [NSError errorWithDomain:FBPMediaConverterErrorDomain
                               code:code
                           userInfo:info];
}

/// A CMFormatDescription's media subtype as the four characters it really is.
/// Diagnostic only, hence __unused: FBPLog and every call to this compile away
/// under FINALPACKAGE.
__attribute__((unused))
static NSString *FBPConvertFourCC(CMFormatDescriptionRef format) {
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

#pragma mark - Capability probe

// Can this device decode AV1 at all?
//
// This is the question the picker has to answer before it offers an AV1 rung,
// and it has to answer it with no file in hand. Three obvious ways to ask it are
// all wrong, and two of them were measured to be actively misleading.
//
// Measured inside Facebook on an iPhone SE (A13, iOS 18.6.1), against a real
// remuxed AV1 file that the same device's Photos had already refused:
//
//     isPlayable                         false   <- correct
//     isExportable                       true    <- wrong
//     exportPresetsCompatibleWithAsset:  all 12  <- wrong
//     AVAssetExportSession 1920x1080     status 4, "Operation Stopped"
//
// So `isExportable` and `exportPresetsCompatibleWithAsset:` judge the container
// and the track types, not whether anything on the device can decode them: both
// say yes on hardware with no AV1 decoder whatsoever. Neither can be used, here
// or anywhere else. (`isPlayable` is right, and is what
// -canDecodeVideoAtURL: uses — but it needs a file, so it cannot gate the
// picker.)
//
// The third wrong way is `VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)`,
// which is honest but too narrow: it is false on every device without a
// *hardware* AV1 block, so it would refuse a device whose VideoToolbox decodes
// AV1 in software.
//
// What works is to ask VideoToolbox for a decompression session and read the
// status it refuses with. A bare CMVideoFormatDescription — no av1C
// configuration record, because we have no bitstream here to take one from — is
// never good enough to actually decode with, so the call always fails. The
// *reason* is the answer:
//
//     kVTCouldNotFindVideoDecoderErr (-12906)  there is no decoder for this codec
//     anything else                            a decoder exists, the description
//                                              is just not usable
//
// Measured both ways, which is what makes it trustworthy rather than clever:
//
//     A13 / iOS 18.6.1   av01 -12906   vp09 -12906   avc1 0       hvc1 -8971
//     Apple silicon Mac  av01 -8971    vp09 -12906   avc1 0       hvc1 -1000
//
// The A13 — which cannot play these files — reports no AV1 decoder. The Mac —
// which decodes them fine, verified by reading real frames out of the fixture —
// reports one. A codec that exists nowhere ('zzzz') reports -12906 on both, so
// the signal is not an artifact of the bare description.
static BOOL FBPConverterVideoToolboxDecodes(CMVideoCodecType codec) {
    CMVideoFormatDescriptionRef format = NULL;
    // The dimensions are arbitrary: nothing is decoded, and a decoder's
    // existence does not depend on them.
    OSStatus created = CMVideoFormatDescriptionCreate(kCFAllocatorDefault, codec,
                                                      1920, 1080, NULL, &format);
    if (created != noErr || !format) {
        if (format) CFRelease(format);
        // CoreMedia would not even describe the codec. Treat that as "no", which
        // is the safe direction: it withholds a rung rather than offering one
        // that cannot be delivered.
        return NO;
    }

    VTDecompressionSessionRef session = NULL;
    OSStatus status = VTDecompressionSessionCreate(kCFAllocatorDefault, format,
                                                   NULL, NULL, NULL, &session);
    if (session) {
        VTDecompressionSessionInvalidate(session);
        CFRelease(session);
    }
    CFRelease(format);

    return status != kVTCouldNotFindVideoDecoderErr;
}

BOOL FBPMediaConversionIsAvailable(void) {
    // The answer cannot change within a process — a decoder does not appear
    // mid-run — and the probe costs a VideoToolbox round trip, so it is asked
    // once. Every picker tap would otherwise re-ask it.
    static BOOL available;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        available = FBPConverterVideoToolboxDecodes(kCMVideoCodecType_AV1);
        if (!available) {
            // Tier 2 would be the answer for exactly this device. It is not
            // live; log why once, here, so a short ladder on a device with no
            // AV1 decoder explains itself in Console.
            available = FBPDav1dTierIsAvailable();
            FBPLog(@"converter: no AV1 decoder on this device · %@",
                   FBPDav1dTierDeclineReason());
        }
        FBPLog(@"converter: AV1 -> H.264 conversion %@",
               available ? @"available" : @"unavailable");
    });
    return available;
}

void FBPMediaConversionPrewarm(void) {
    // QOS_CLASS_UTILITY, not the default: this is speculative work for a feature
    // the user may never reach in this session, so it must never compete with
    // anything the app is actually doing. dispatch_once inside makes the
    // duplicate work of a racing caller free rather than merely harmless.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        (void)FBPMediaConversionIsAvailable();
    });
}

#pragma mark - Bitrate policy

// What the output bitrate should be, and why it is not a preset.
//
// AVAssetExportSession's presets are the obvious way to re-encode and they are
// unusable for this. Measured on the real 127-second 1080x1920 AV1 fixture
// (av01.0.08M.08, 285 769 bits/s, **4.55 MB**):
//
//     AVAssetExportPreset1920x1080  ->  88.95 MB   (5.47 Mbit/s)   ~19x
//
// A preset targets a quality tier for ordinary camera footage; it has no idea
// that Meta's ladder encodes this rung at 286 kbit/s. So the output bitrate is
// derived from the *source* representation's own bandwidth, which the manifest
// states per rung and which FBPDownloadVariant already carries.
//
// The multiplier was measured, not assumed. The first 20 seconds of that same
// fixture were re-encoded at eight bitrates with exactly the settings below, and
// each result scored with VMAF against the AV1 source decoded — so 100 would
// mean "indistinguishable from what Facebook plays":
//
//     bits/s    x source   VMAF    SSIM     extrapolated size for 127s
//      400 000     1.40    91.31   0.9941      6.9 MB
//      600 000     2.10    92.87   0.9950      9.9 MB
//      800 000     2.80    93.49   0.9954     12.9 MB
//    1 100 000     3.85    94.07   0.9957     16.7 MB
//    1 555 200     5.44    94.70   0.9963     22.2 MB
//    2 200 000     7.70    95.25   0.9968     29.9 MB
//    3 000 000    10.50    95.37   0.9969     33.0 MB
//    5 469 299    19.14    95.57   0.9972     38.7 MB   <- what the preset chose
//
// The curve is smooth with no knee, so this is a cost decision rather than a
// threshold: past about 3x, each further doubling of the file buys under a point
// of VMAF. 3x sits where the curve flattens, and it is also where the
// "AV1 is about twice as efficient as H.264" rule of thumb lands once a little
// headroom is allowed for the generation loss of re-encoding someone else's
// lossy encode — the only defence available, since the original pixels are gone.
//
// The floor and ceiling are in bits per pixel per frame rather than absolute,
// because a 240p rung and a 1080p rung have nothing in common in absolute terms.
// Both are pathology guards, and both are deliberately set where they bind on
// *nothing* Meta has actually been observed to serve: across 29 real AV1
// representations in the six captured manifests the source density runs from
// 0.0042 to 0.0944 bits/pixel/frame, so 3x of it runs from 0.0127 to 0.2833, and
// the bounds below sit just outside that range at each end. They exist to stop a
// future manifest with an absurd rung producing an absurd file, not to second-
// guess the measurement above.
static const double kFBPConvertMultiplier = 3.0;
static const double kFBPConvertFloorBPP   = 0.012;
static const double kFBPConvertCeilBPP    = 0.300;
// Used only when the manifest stated no bandwidth at all, which no observed Meta
// manifest does; midway between the bounds, so it errs neither way.
static const double kFBPConvertDefaultBPP = 0.060;
// Absolute backstops, for a frame size so small or so large that the per-pixel
// bounds stop being sensible on their own.
static const long long kFBPConvertMinBitRate =    120000;   // 120 kbit/s
static const long long kFBPConvertMaxBitRate =  16000000;   //  16 Mbit/s
// What to assume when the track declares no frame rate. Every Meta rung observed
// is 30 fps; this only has to stop the arithmetic collapsing to zero.
static const float kFBPConvertAssumedFPS = 30.0f;

long long FBPConverterTargetBitRate(long long sourceBitsPerSecond,
                                    CGSize frameSize,
                                    float framesPerSecond) {
    double fps = (framesPerSecond > 0.5f && framesPerSecond < 240.0f)
        ? (double)framesPerSecond
        : (double)kFBPConvertAssumedFPS;

    double pixels = (double)frameSize.width * (double)frameSize.height;
    if (!(pixels > 0)) {
        // No frame size either. Fall back to the source's own number, which is
        // at least a measurement of this video, and only then to the floor.
        long long scaled = (long long)llround((double)MAX(sourceBitsPerSecond, 0LL) *
                                              kFBPConvertMultiplier);
        return MAX(MIN(scaled, kFBPConvertMaxBitRate), kFBPConvertMinBitRate);
    }

    double perFrame = pixels * fps;
    double floorRate = perFrame * kFBPConvertFloorBPP;
    double ceilRate  = perFrame * kFBPConvertCeilBPP;

    double target = (sourceBitsPerSecond > 0)
        ? (double)sourceBitsPerSecond * kFBPConvertMultiplier
        : perFrame * kFBPConvertDefaultBPP;

    if (target < floorRate) target = floorRate;
    if (target > ceilRate)  target = ceilRate;

    long long rate = (long long)llround(target);
    if (rate < kFBPConvertMinBitRate) rate = kFBPConvertMinBitRate;
    if (rate > kFBPConvertMaxBitRate) rate = kFBPConvertMaxBitRate;
    return rate;
}

#pragma mark - In-flight registry

// Identical in purpose to the muxer's: a conversion owns itself for its
// lifetime, and this set is both its last owner and what +cancelAll walks.
// Separate from the muxer's registry on purpose — +[FBPMediaMuxer cancelAll] and
// +[FBPMediaConverter cancelAll] are different requests, and a flow that is
// converting has no mux to stop.

static NSMutableSet *gFBPConvertJobs = nil;
static NSLock *gFBPConvertJobsLock = nil;

static void FBPConvertEnsureRegistry(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gFBPConvertJobs = [NSMutableSet set];
        gFBPConvertJobsLock = [[NSLock alloc] init];
    });
}

#pragma mark - Converter

@implementation FBPMediaConverter {
    NSURL *_videoURL;
    NSURL *_audioURL;
    NSURL *_outputURL;
    long long _sourceBitRate;
    FBPMediaConvertProgress _progress;
    FBPMediaConvertCompletion _completion;

    dispatch_queue_t _controlQueue;
    dispatch_queue_t _videoQueue;
    dispatch_queue_t _audioQueue;

    AVAssetReader *_videoReader;
    AVAssetReader *_audioReader;
    AVAssetReaderTrackOutput *_videoOutput;
    AVAssetReaderTrackOutput *_audioOutput;

    AVAssetWriter *_writer;
    AVAssetWriterInput *_videoInput;
    AVAssetWriterInput *_audioInput;

    /// Total source duration in seconds, for progress. 0 when unknown, which
    /// turns progress into a frame-count estimate instead.
    double _duration;
    /// Where the video track's first sample sits, so progress is measured from
    /// the real start rather than from zero.
    double _videoStartSeconds;
    /// Frames expected, from duration x frame rate. Only used when `_duration`
    /// is unusable.
    NSInteger _expectedFrames;

    /// Progress bookkeeping, video queue only.
    NSInteger _framesEncoded;
    NSInteger _lastReportedPercent;
    float _reportedFraction;

    NSError *_failure;

    atomic_bool _cancelled;
    BOOL _completed;
}

#pragma mark Capability

+ (BOOL)isAvailable { return FBPMediaConversionIsAvailable(); }

+ (void)prewarm { FBPMediaConversionPrewarm(); }

+ (BOOL)canDecodeVideoAtURL:(NSURL *)videoURL {
    if (!videoURL.isFileURL) return NO;

    // -isPlayable is the honest per-file answer, and the only one: see the
    // measurement at the top of this file for what the alternatives claim.
    // Reading it synchronously is fine because every caller is already off the
    // main thread — the conversion's own control queue, or the host harness.
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:videoURL options:nil];
    return asset.isPlayable;
}

#pragma mark Entry points

+ (void)convertVideoURL:(NSURL *)videoURL
               audioURL:(NSURL *)audioURL
          sourceBitRate:(long long)sourceBitRate
              outputURL:(NSURL *)outputURL
               progress:(FBPMediaConvertProgress)progress
             completion:(FBPMediaConvertCompletion)completion {
    if (!completion) return;

    FBPMediaConverter *job = [[FBPMediaConverter alloc] initWithVideoURL:videoURL
                                                               audioURL:audioURL
                                                          sourceBitRate:sourceBitRate
                                                              outputURL:outputURL
                                                               progress:progress
                                                             completion:completion];
    [job start];
}

+ (void)cancelAll {
    FBPConvertEnsureRegistry();

    [gFBPConvertJobsLock lock];
    NSArray *jobs = gFBPConvertJobs.allObjects;
    [gFBPConvertJobsLock unlock];

    for (FBPMediaConverter *job in jobs) [job cancel];
}

#pragma mark Lifetime

- (instancetype)initWithVideoURL:(NSURL *)videoURL
                        audioURL:(NSURL *)audioURL
                   sourceBitRate:(long long)sourceBitRate
                       outputURL:(NSURL *)outputURL
                        progress:(FBPMediaConvertProgress)progress
                      completion:(FBPMediaConvertCompletion)completion {
    if ((self = [super init])) {
        _videoURL = [videoURL copy];
        _audioURL = [audioURL copy];
        _outputURL = [outputURL copy];
        _sourceBitRate = MAX(sourceBitRate, 0LL);
        _progress = [progress copy];
        _completion = [completion copy];

        _controlQueue = dispatch_queue_create("com.shajon.fbplus.converter.control",
                                              DISPATCH_QUEUE_SERIAL);
        _videoQueue = dispatch_queue_create("com.shajon.fbplus.converter.video",
                                            DISPATCH_QUEUE_SERIAL);
        _audioQueue = dispatch_queue_create("com.shajon.fbplus.converter.audio",
                                            DISPATCH_QUEUE_SERIAL);

        _lastReportedPercent = -1;
        atomic_init(&_cancelled, false);
    }
    return self;
}

- (void)cancel {
    atomic_store_explicit(&_cancelled, true, memory_order_relaxed);

    // A job still loading asset headers has no pump running to notice the flag.
    dispatch_async(_controlQueue, ^{
        [self checkCancelled];
    });
}

- (BOOL)checkCancelled {
    if (!atomic_load_explicit(&_cancelled, memory_order_relaxed)) return NO;

    [self recordFailure:FBPConvertError(FBPMediaConverterErrorCancelled,
                                        @"Converting was cancelled.", nil)];
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
    if (!_videoURL || !_outputURL) {
        FBPMediaConvertCompletion completion = _completion;
        _completion = nil;
        NSError *error = FBPConvertError(FBPMediaConverterErrorBadArguments,
                                         @"Converting needs a video and an output "
                                         @"URL.", nil);
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, error);
        });
        return;
    }

    FBPConvertEnsureRegistry();
    [gFBPConvertJobsLock lock];
    [gFBPConvertJobs addObject:self];
    [gFBPConvertJobsLock unlock];

    dispatch_async(_controlQueue, ^{
        [self loadAssets];
    });
}

- (void)loadAssets {
    if ([self checkCancelled]) {
        [self finishWithError:self.failure];
        return;
    }

    // Both tiers are unavailable: nothing on this device can decode the source.
    // Refused here rather than after a setup failure, so the error says "this
    // device cannot" instead of "the file is broken".
    if (!FBPMediaConversionIsAvailable()) {
        [self finishWithError:
            FBPConvertError(FBPMediaConverterErrorNoConversionPath,
                            @"This device cannot convert this video.", nil)];
        return;
    }

    // The per-file authority. -isAvailable only said a decoder exists; this says
    // AVFoundation will decode *this* asset, and it is the check that stops a
    // 10-bit or otherwise awkward stream becoming a mysterious setup failure
    // several steps later.
    if (![FBPMediaConverter canDecodeVideoAtURL:_videoURL]) {
        [self finishWithError:
            FBPConvertError(FBPMediaConverterErrorVideoUndecodable,
                            @"This video cannot be decoded on this device.", nil)];
        return;
    }

    NSDictionary *options = @{ AVURLAssetPreferPreciseDurationAndTimingKey: @YES };
    AVURLAsset *videoAsset = [AVURLAsset URLAssetWithURL:_videoURL options:options];
    AVURLAsset *audioAsset = _audioURL
        ? [AVURLAsset URLAssetWithURL:_audioURL options:options]
        : nil;

    NSArray<NSString *> *keys = @[ @"readable", @"tracks", @"duration" ];
    dispatch_group_t group = dispatch_group_create();

    for (AVURLAsset *asset in (audioAsset ? @[ videoAsset, audioAsset ]
                                          : @[ videoAsset ])) {
        dispatch_group_enter(group);
        [asset loadValuesAsynchronouslyForKeys:keys completionHandler:^{
            dispatch_group_leave(group);
        }];
    }

    dispatch_group_notify(group, _controlQueue, ^{
        [self buildPipelineWithVideoAsset:videoAsset audioAsset:audioAsset];
    });
}

- (AVAssetTrack *)trackOfType:(AVMediaType)mediaType
                      inAsset:(AVURLAsset *)asset
                 unreadableAs:(FBPMediaConverterError)unreadableCode
                    missingAs:(FBPMediaConverterError)missingCode
                        error:(NSError **)errorOut {
    NSError *loadError = nil;
    AVKeyValueStatus status = [asset statusOfValueForKey:@"readable" error:&loadError];

    if (status != AVKeyValueStatusLoaded || !asset.readable) {
        if (errorOut) {
            *errorOut = FBPConvertError(unreadableCode,
                                        @"The downloaded file is not playable media.",
                                        loadError);
        }
        return nil;
    }

    if ([asset statusOfValueForKey:@"tracks" error:&loadError] != AVKeyValueStatusLoaded) {
        if (errorOut) {
            *errorOut = FBPConvertError(unreadableCode,
                                        @"The downloaded file's track list could "
                                        @"not be read.", loadError);
        }
        return nil;
    }

    AVAssetTrack *track = [asset tracksWithMediaType:mediaType].firstObject;
    if (!track) {
        if (errorOut) {
            *errorOut = FBPConvertError(missingCode,
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
                                    unreadableAs:FBPMediaConverterErrorVideoUnreadable
                                       missingAs:FBPMediaConverterErrorNoVideoTrack
                                           error:&error];
    if (!videoTrack) {
        [self finishWithError:error];
        return;
    }

    // Nil for a silent video, which is a success: the output is video-only.
    AVAssetTrack *audioTrack = nil;
    if (audioAsset) {
        audioTrack = [self trackOfType:AVMediaTypeAudio
                               inAsset:audioAsset
                          unreadableAs:FBPMediaConverterErrorAudioUnreadable
                             missingAs:FBPMediaConverterErrorNoAudioTrack
                                 error:&error];
        if (!audioTrack) {
            [self finishWithError:error];
            return;
        }
    }

    // Progress needs a denominator. The video track's own duration is the right
    // one — the output is as long as the picture — and the asset's is the
    // fallback.
    CMTime trackDuration = videoTrack.timeRange.duration;
    double seconds = CMTIME_IS_NUMERIC(trackDuration) ? CMTimeGetSeconds(trackDuration) : 0;
    if (!(seconds > 0)) {
        CMTime assetDuration = videoAsset.duration;
        seconds = CMTIME_IS_NUMERIC(assetDuration) ? CMTimeGetSeconds(assetDuration) : 0;
    }
    _duration = (seconds > 0 && isfinite(seconds)) ? seconds : 0;

    float fps = videoTrack.nominalFrameRate;
    _expectedFrames = (_duration > 0 && fps > 0.5f)
        ? (NSInteger)llround(_duration * (double)fps)
        : 0;

    if (![self startReadersForVideoAsset:videoAsset
                             videoTrack:videoTrack
                             audioAsset:audioAsset
                             audioTrack:audioTrack
                                  error:&error]) {
        [self finishWithError:error];
        return;
    }

    if (![self createWriterWithVideoTrack:videoTrack
                              audioTrack:audioTrack
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
            *errorOut = FBPConvertError(FBPMediaConverterErrorSetupFailed,
                                        @"The video file could not be opened for "
                                        @"reading.", readerError);
        }
        return NO;
    }

    // Asking for a pixel format is what makes this a decode. 420v — 8-bit
    // bi-planar video-range 4:2:0 — is what VideoToolbox's AV1 decoder produces
    // natively and what its H.264 encoder consumes natively, so the common case
    // costs no pixel conversion at all. Every AV1 rung Meta has been observed to
    // serve is 8-bit (the `.08` in `av01.0.05M.08`), so nothing is being
    // truncated in practice; a 10-bit source would be flattened to 8-bit here,
    // which is a real but invisible-in-practice loss and is better than refusing
    // the rung.
    _videoOutput = [AVAssetReaderTrackOutput
        assetReaderTrackOutputWithTrack:videoTrack
                         outputSettings:@{
            (id)kCVPixelBufferPixelFormatTypeKey:
                @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        }];
    _videoOutput.alwaysCopiesSampleData = NO;

    if (![_videoReader canAddOutput:_videoOutput]) {
        if (errorOut) {
            *errorOut = FBPConvertError(FBPMediaConverterErrorVideoUndecodable,
                                        @"This video cannot be decoded on this "
                                        @"device.", nil);
        }
        return NO;
    }
    [_videoReader addOutput:_videoOutput];

    if (audioTrack) {
        _audioReader = [AVAssetReader assetReaderWithAsset:audioAsset error:&readerError];
        if (!_audioReader) {
            if (errorOut) {
                *errorOut = FBPConvertError(FBPMediaConverterErrorSetupFailed,
                                            @"The audio file could not be opened "
                                            @"for reading.", readerError);
            }
            return NO;
        }

        // nil settings: the AAC comes out exactly as it went in, same as the
        // muxer.
        _audioOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack
                                                                 outputSettings:nil];
        _audioOutput.alwaysCopiesSampleData = NO;

        if (![_audioReader canAddOutput:_audioOutput]) {
            if (errorOut) {
                *errorOut = FBPConvertError(FBPMediaConverterErrorSetupFailed,
                                            @"This audio cannot be read without "
                                            @"re-encoding.", nil);
            }
            return NO;
        }
        [_audioReader addOutput:_audioOutput];
    }

    if (![_videoReader startReading] ||
        (_audioReader && ![_audioReader startReading])) {
        NSError *underlying = _videoReader.error ?: _audioReader.error;
        if (errorOut) {
            *errorOut = FBPConvertError(FBPMediaConverterErrorReadFailed,
                                        @"Reading the downloaded media failed.",
                                        underlying);
        }
        return NO;
    }
    return YES;
}

/// The encoder settings. This is the one place the conversion is lossy, so every
/// key here is a deliberate choice rather than a default.
- (NSDictionary *)videoOutputSettingsForTrack:(AVAssetTrack *)videoTrack {
    CGSize natural = videoTrack.naturalSize;

    // H.264 wants even dimensions; an odd one is rounded down rather than up, so
    // the output is never larger than the source. naturalSize is the *encoded*
    // size, before any rotation matrix — which is right, because rotation is
    // carried across as a matrix below and not baked into pixels.
    NSInteger width  = ((NSInteger)llround(natural.width)  / 2) * 2;
    NSInteger height = ((NSInteger)llround(natural.height) / 2) * 2;
    if (width <= 0 || height <= 0) return nil;

    float fps = videoTrack.nominalFrameRate;
    long long bitRate = FBPConverterTargetBitRate(_sourceBitRate,
                                                  CGSizeMake(width, height), fps);

    NSMutableDictionary *compression = [NSMutableDictionary dictionaryWithCapacity:6];
    compression[AVVideoAverageBitRateKey] = @(bitRate);
    // High profile with the level chosen for us. High is what every iOS H.264
    // encoder produces for camera video and what Photos has always accepted;
    // pinning a level by hand would mean getting 1080p60 wrong one day.
    compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel;
    // CABAC over CAVLC: ~10% better at the same quality, and the reason to use
    // High profile at all.
    compression[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC;
    // B-frames. Costs encode time, buys bitrate — which is the trade this whole
    // function is making.
    compression[AVVideoAllowFrameReorderingKey] = @YES;
    // A keyframe at least every two seconds, so scrubbing the saved file in
    // Photos is not miserable. Expressed as a duration rather than a frame count
    // so it means the same thing at any frame rate.
    compression[AVVideoMaxKeyFrameIntervalDurationKey] = @(2.0);
    if (fps > 0.5f) compression[AVVideoExpectedSourceFrameRateKey] = @(llround(fps));

    FBPLog(@"converter: encoding %ldx%ld @%.2ffps source=%lld -> target=%lld bit/s",
           (long)width, (long)height, fps, _sourceBitRate, bitRate);

    return @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(width),
        AVVideoHeightKey: @(height),
        AVVideoCompressionPropertiesKey: compression,
    };
}

- (BOOL)createWriterWithVideoTrack:(AVAssetTrack *)videoTrack
                        audioTrack:(AVAssetTrack *)audioTrack
                             error:(NSError **)errorOut {
    [NSFileManager.defaultManager removeItemAtURL:_outputURL error:nil];

    NSError *writerError = nil;
    _writer = [AVAssetWriter assetWriterWithURL:_outputURL
                                       fileType:AVFileTypeMPEG4
                                          error:&writerError];
    if (!_writer) {
        if (errorOut) {
            *errorOut = FBPConvertError(FBPMediaConverterErrorSetupFailed,
                                        @"The output file could not be created.",
                                        writerError);
        }
        return NO;
    }

    // movflags=+faststart, as in the muxer and as in the rival's own muxing step.
    _writer.shouldOptimizeForNetworkUse = YES;

    NSDictionary *videoSettings = [self videoOutputSettingsForTrack:videoTrack];
    if (!videoSettings) {
        if (errorOut) {
            *errorOut = FBPConvertError(FBPMediaConverterErrorSetupFailed,
                                        @"The video track has no usable frame "
                                        @"size.", nil);
        }
        return NO;
    }

    // No sourceFormatHint: a hint is what passthrough needs, and this input is
    // the opposite of passthrough.
    _videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                    outputSettings:videoSettings];
    // NO is the AVFoundation spelling of the rival's
    // av_opt_set(ctx, "realtime", "0"): quality over latency. Nothing is waiting
    // on a frame here, so the encoder may take as long as it likes per frame.
    _videoInput.expectsMediaDataInRealTime = NO;

    // The same trap as in the muxer, and it bites identically here even though
    // every pixel is being re-encoded: rotation in an MP4 is a matrix on the
    // track, not something in the picture. A fresh input's matrix is the
    // identity, so without this every portrait Reel converts to a file that
    // lands in Photos on its side.
    _videoInput.transform = videoTrack.preferredTransform;

    if (![_writer canAddInput:_videoInput]) {
        if (errorOut) {
            *errorOut = FBPConvertError(FBPMediaConverterErrorSetupFailed,
                                        @"This device would not accept these "
                                        @"encoder settings.", nil);
        }
        return NO;
    }

    if (audioTrack) {
        CMFormatDescriptionRef audioFormat =
            (__bridge CMFormatDescriptionRef)audioTrack.formatDescriptions.firstObject;
        if (!audioFormat) {
            if (errorOut) {
                *errorOut = FBPConvertError(FBPMediaConverterErrorMissingFormatDescription,
                                            @"The audio track carries no format "
                                            @"description, so it cannot be copied "
                                            @"without re-encoding.", nil);
            }
            return NO;
        }

        _audioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                        outputSettings:nil
                                                      sourceFormatHint:audioFormat];
        _audioInput.expectsMediaDataInRealTime = NO;

        if (![_writer canAddInput:_audioInput]) {
            if (errorOut) {
                *errorOut = FBPConvertError(FBPMediaConverterErrorSetupFailed,
                                            @"This audio codec cannot be saved "
                                            @"without re-encoding.", nil);
            }
            return NO;
        }
    }

    @try {
        [_writer addInput:_videoInput];
        if (_audioInput) [_writer addInput:_audioInput];
    } @catch (NSException *exception) {
        if (errorOut) {
            *errorOut = FBPConvertError(FBPMediaConverterErrorSetupFailed,
                                        exception.reason ?: @"The output file would "
                                        @"not accept these tracks.", nil);
        }
        return NO;
    }
    return YES;
}

#pragma mark Timing and sample pumps

- (CMSampleBufferRef)copyFirstSampleFrom:(AVAssetReaderTrackOutput *)output
                                  reader:(AVAssetReader *)reader
                                   error:(NSError **)errorOut CF_RETURNS_RETAINED {
    CMSampleBufferRef sample = [output copyNextSampleBuffer];
    if (sample) return sample;

    if (reader.status == AVAssetReaderStatusFailed) {
        if (errorOut) {
            *errorOut = FBPConvertError(FBPMediaConverterErrorReadFailed,
                                        @"The downloaded file is incomplete.",
                                        reader.error);
        }
    } else if (errorOut) {
        *errorOut = FBPConvertError(FBPMediaConverterErrorNoSamples,
                                    @"The downloaded file contains no media.", nil);
    }
    return NULL;
}

static CMTime FBPConvertStartTime(CMSampleBufferRef sample, AVAssetTrack *track) {
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

    CMSampleBufferRef firstAudio = NULL;
    if (_audioOutput) {
        firstAudio = [self copyFirstSampleFrom:_audioOutput
                                        reader:_audioReader
                                         error:&error];
        if (!firstAudio) {
            CFRelease(firstVideo);
            [self finishWithError:error];
            return;
        }
    }

    CMTime videoStart = FBPConvertStartTime(firstVideo, videoTrack);
    CMTime audioStart = firstAudio ? FBPConvertStartTime(firstAudio, audioTrack)
                                   : videoStart;
    // The earlier of the two, so whatever offset existed between the picture and
    // the sound survives rather than being nudged into a sync it never had.
    CMTime sessionStart = CMTimeMinimum(videoStart, audioStart);

    _videoStartSeconds = CMTimeGetSeconds(videoStart);
    if (!isfinite(_videoStartSeconds)) _videoStartSeconds = 0;

    if (![_writer startWriting]) {
        CFRelease(firstVideo);
        if (firstAudio) CFRelease(firstAudio);
        [self finishWithError:FBPConvertError(FBPMediaConverterErrorSetupFailed,
                                              @"Writing the output file could not "
                                              @"start.", _writer.error)];
        return;
    }

    [_writer startSessionAtSourceTime:sessionStart];

    dispatch_group_t group = dispatch_group_create();

    [self pumpVideoWithFirst:firstVideo group:group];

    if (_audioInput) {
        [self pumpAudioWithFirst:firstAudio group:group];
    }

    dispatch_group_notify(group, _controlQueue, ^{
        [self finalizeWriting];
    });
}

#pragma mark Progress

/// How far through the picture we are, 0…1.
///
/// Measured from the *presentation time* of the frame just handed to the
/// encoder, not from a frame tally, and the difference matters. A frame count
/// needs a denominator, and the only available one is duration x
/// nominalFrameRate — an estimate that is wrong for every variable-frame-rate
/// video, so the bar would reach 100% early or stall short of it. A timestamp is
/// exact and monotonic by construction. The frame tally is still kept, for the
/// log and as the fallback when the source declares no duration at all.
///
/// Capped just under 1.0: finalizing an MP4 of this size is a real wait of its
/// own, and a bar sitting at 100% while the file is still being written is the
/// same lie the fetch/merge split exists to avoid.
- (void)reportProgressForPresentationTime:(CMTime)pts {
    if (!_progress || atomic_load_explicit(&_cancelled, memory_order_relaxed)) return;

    float fraction = 0.0f;
    if (_duration > 0) {
        double seconds = CMTimeGetSeconds(pts);
        if (isfinite(seconds)) {
            double elapsed = seconds - _videoStartSeconds;
            if (elapsed > 0) fraction = (float)(elapsed / _duration);
        }
    } else if (_expectedFrames > 0) {
        fraction = (float)((double)_framesEncoded / (double)_expectedFrames);
    }

    if (fraction > 0.99f) fraction = 0.99f;
    if (fraction < 0.0f) fraction = 0.0f;
    // Never backwards: B-frame reordering means the samples we see are in decode
    // order, whose timestamps are not monotonic.
    if (fraction < _reportedFraction) fraction = _reportedFraction;
    _reportedFraction = fraction;

    NSInteger percent = (NSInteger)lrintf(fraction * 100.0f);
    if (percent == _lastReportedPercent) return;
    _lastReportedPercent = percent;

    FBPMediaConvertProgress block = _progress;
    dispatch_async(dispatch_get_main_queue(), ^{ block(fraction); });
}

#pragma mark Pumps

/// Decode-and-encode. One frame per loop turn, and the cancellation check is
/// inside that loop, which is what "honours cancellation at frame granularity"
/// means: a conversion the user has given up on stops within one frame's work
/// rather than at the end of the file.
- (void)pumpVideoWithFirst:(CMSampleBufferRef CF_CONSUMED)first
                     group:(dispatch_group_t)group {
    dispatch_group_enter(group);

    __block CMSampleBufferRef pending = first;
    __block BOOL left = NO;

    [_videoInput requestMediaDataWhenReadyOnQueue:_videoQueue usingBlock:^{
        if (left) return;

        void (^finish)(NSError *) = ^(NSError *error) {
            if (left) return;
            left = YES;

            if (pending) {
                CFRelease(pending);
                pending = NULL;
            }
            [self recordFailure:error];
            [self->_videoInput markAsFinished];

            FBPLog(@"converter: video pump ended after %ld frames%@",
                   (long)self->_framesEncoded, error ? @" (failed)" : @"");

            dispatch_group_leave(group);
        };

        while (self->_videoInput.isReadyForMoreMediaData) {
            if ([self checkCancelled]) {
                finish(nil);  // -checkCancelled already recorded the reason.
                return;
            }

            CMSampleBufferRef sample = pending;
            if (sample) {
                pending = NULL;
            } else {
                sample = [self->_videoOutput copyNextSampleBuffer];
            }

            if (!sample) {
                NSError *error = nil;
                if (self->_videoReader.status == AVAssetReaderStatusFailed) {
                    error = FBPConvertError(FBPMediaConverterErrorReadFailed,
                                            @"The downloaded file is incomplete.",
                                            self->_videoReader.error);
                }
                finish(error);
                return;
            }

            CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
            BOOL ok = [self->_videoInput appendSampleBuffer:sample];
            CFRelease(sample);

            if (!ok) {
                finish(FBPConvertError(FBPMediaConverterErrorWriteFailed,
                                       @"A frame could not be encoded into the "
                                       @"output file.", self->_writer.error));
                return;
            }

            self->_framesEncoded++;
            [self reportProgressForPresentationTime:pts];
        }
    }];
}

/// Passthrough, identical to the muxer's audio pump.
- (void)pumpAudioWithFirst:(CMSampleBufferRef CF_CONSUMED)first
                     group:(dispatch_group_t)group {
    dispatch_group_enter(group);

    __block CMSampleBufferRef pending = first;
    __block BOOL left = NO;
    __block __unused NSInteger appended = 0;

    [_audioInput requestMediaDataWhenReadyOnQueue:_audioQueue usingBlock:^{
        if (left) return;

        void (^finish)(NSError *) = ^(NSError *error) {
            if (left) return;
            left = YES;

            if (pending) {
                CFRelease(pending);
                pending = NULL;
            }
            [self recordFailure:error];
            [self->_audioInput markAsFinished];

            FBPLog(@"converter: audio pump ended after %ld samples%@",
                   (long)appended, error ? @" (failed)" : @"");

            dispatch_group_leave(group);
        };

        while (self->_audioInput.isReadyForMoreMediaData) {
            if ([self checkCancelled]) {
                finish(nil);
                return;
            }

            CMSampleBufferRef sample = pending;
            if (sample) {
                pending = NULL;
            } else {
                sample = [self->_audioOutput copyNextSampleBuffer];
            }

            if (!sample) {
                NSError *error = nil;
                if (self->_audioReader.status == AVAssetReaderStatusFailed) {
                    error = FBPConvertError(FBPMediaConverterErrorReadFailed,
                                            @"The downloaded file is incomplete.",
                                            self->_audioReader.error);
                }
                finish(error);
                return;
            }

            BOOL ok = [self->_audioInput appendSampleBuffer:sample];
            CFRelease(sample);

            if (!ok) {
                finish(FBPConvertError(FBPMediaConverterErrorWriteFailed,
                                       @"A sample could not be written to the "
                                       @"output file.", self->_writer.error));
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
        dispatch_async(self->_controlQueue, ^{
            if (self->_writer.status == AVAssetWriterStatusCompleted) {
                [self logOutputTracks];
                [self finishWithError:nil];
            } else {
                [self finishWithError:
                    FBPConvertError(FBPMediaConverterErrorWriteFailed,
                                    @"The converted file could not be finished.",
                                    self->_writer.error)];
            }
        });
    }];
}

/// Read the finished file back and log what its tracks actually are.
///
/// The standing proof that this produced what Photos needs: these four-character
/// codes have to read `avc1` and `mp4a`, and if a future change ever lets AV1
/// through untouched they will say so. Debug builds only.
- (void)logOutputTracks {
#ifdef DEBUG
    AVURLAsset *result = [AVURLAsset URLAssetWithURL:_outputURL options:nil];

    for (AVAssetTrack *track in result.tracks) {
        CMFormatDescriptionRef format =
            (__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject;
        FBPLog(@"converter: out %@ %@ %.3fs", track.mediaType,
               FBPConvertFourCC(format), CMTimeGetSeconds(track.timeRange.duration));
    }
#endif
}

/// The one and only exit. Control queue only.
- (void)finishWithError:(NSError *)error {
    if (_completed) return;
    _completed = YES;

    if (error) {
        if (_writer.status == AVAssetWriterStatusWriting) [_writer cancelWriting];
        [NSFileManager.defaultManager removeItemAtURL:_outputURL error:nil];

        FBPLog(@"converter: failed (%ld) %@", (long)error.code,
               error.localizedDescription);
    }

    [_videoReader cancelReading];
    [_audioReader cancelReading];

    // The writer retains its inputs, which retain the pump blocks, which retain
    // self. Dropping them is what lets this object — and its registry entry, its
    // last owner — go away.
    _videoReader = nil;
    _audioReader = nil;
    _videoOutput = nil;
    _audioOutput = nil;
    _videoInput = nil;
    _audioInput = nil;
    _writer = nil;

    FBPMediaConvertCompletion completion = _completion;
    _completion = nil;
    _progress = nil;
    NSURL *outputURL = _outputURL;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) completion(error ? nil : outputURL, error);
    });

    [gFBPConvertJobsLock lock];
    [gFBPConvertJobs removeObject:self];
    [gFBPConvertJobsLock unlock];
}

@end
