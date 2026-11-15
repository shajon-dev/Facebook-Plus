// AV1 -> HEVC conversion, H.264 fallback. See FBPMediaConverter.h for the
// rationale and why this is separate from FBPMediaMuxer.
//
// The muxer's pipeline with the video input changed to decode-and-encode:
//
//   video:  AVAssetReaderTrackOutput(pixel buffers)  ->  AVAssetWriterInput(HEVC)
//   audio:  AVAssetReaderTrackOutput(nil settings)   ->  AVAssetWriterInput(nil)
//
// Pixel-format output settings on the reader force a decode; compression
// settings on the writer input force an encode. Audio is the muxer's
// passthrough: Facebook's audio is already AAC, so re-encoding gains nothing.
//
// Structural parts (control queue, per-input queues, peeked first sample for
// the session start time, single exit, in-flight registry for +cancelAll) are
// the muxer's and commented there. New here: the two capability probes (AV1
// decode, HEVC encode) and the bitrate policy, all measured. Below.

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

/// A CMFormatDescription's media subtype as its four characters. Diagnostic
/// only, hence __unused: FBPLog and every call compile away under FINALPACKAGE.
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

// Can this device decode AV1 at all? The picker must answer this before
// offering an AV1 rung, with no file in hand. Three obvious checks are all
// wrong, two of them misleadingly so.
//
// Measured inside Facebook on an iPhone SE (A13, iOS 18.6.1), against a remuxed
// AV1 file the same device's Photos had already refused:
//
//     isPlayable                         false   <- correct
//     isExportable                       true    <- wrong
//     exportPresetsCompatibleWithAsset:  all 12  <- wrong
//     AVAssetExportSession 1920x1080     status 4, "Operation Stopped"
//
// isExportable and exportPresetsCompatibleWithAsset: judge the container and
// track types, not whether anything can decode them: both say yes on hardware
// with no AV1 decoder. (isPlayable is correct and -canDecodeVideoAtURL: uses it,
// but it needs a file, so it cannot gate the picker.)
//
// VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) is honest but too narrow:
// false on any device without a *hardware* AV1 block, so it refuses devices that
// decode AV1 in software.
//
// What works: ask VideoToolbox for a decompression session and read the refusal
// status. A bare CMVideoFormatDescription — no av1C record, no bitstream here to
// take one from — can never decode, so the call always fails. The reason is the
// answer:
//
//     kVTCouldNotFindVideoDecoderErr (-12906)  no decoder for this codec
//     anything else                            a decoder exists, description
//                                              just unusable
//
// Measured both ways:
//
//     A13 / iOS 18.6.1   av01 -12906   vp09 -12906   avc1 0       hvc1 -8971
//     Apple silicon Mac  av01 -8971    vp09 -12906   avc1 0       hvc1 -1000
//
// The A13, which cannot play these files, reports no AV1 decoder; the Mac, which
// decodes them (verified against the fixture), reports one. A codec that exists
// nowhere ('zzzz') reports -12906 on both, so the signal is not an artifact of
// the bare description.
static BOOL FBPConverterVideoToolboxDecodes(CMVideoCodecType codec) {
    CMVideoFormatDescriptionRef format = NULL;
    // Dimensions are arbitrary: nothing is decoded, and a decoder's existence
    // does not depend on them.
    OSStatus created = CMVideoFormatDescriptionCreate(kCFAllocatorDefault, codec,
                                                      1920, 1080, NULL, &format);
    if (created != noErr || !format) {
        if (format) CFRelease(format);
        // CoreMedia could not describe the codec. "No" is the safe direction:
        // withhold a rung rather than offer one that cannot be delivered.
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
    // The answer cannot change within a process, and the probe costs a
    // VideoToolbox round trip, so ask once.
    static BOOL available;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        available = FBPConverterVideoToolboxDecodes(kCMVideoCodecType_AV1);
        if (!available) {
            // Tier 2 would cover this device but is not live; log why once so a
            // short ladder on a device with no AV1 decoder explains itself.
            available = FBPDav1dTierIsAvailable();
            FBPLog(@"converter: no AV1 decoder on this device · %@",
                   FBPDav1dTierDeclineReason());
        }
        FBPLog(@"converter: AV1 conversion %@",
               available ? @"available" : @"unavailable");
    });
    return available;
}

#pragma mark - Encoder probe

// Can this device encode HEVC? Unlike the decode probe, VideoToolbox answers
// directly: VTCopySupportedPropertyDictionaryForEncoder picks an encoder for a
// (size, codec) pair and returns its supported properties, failing with
// kVTCouldNotFindVideoEncoderErr when the codec has no encoder at all.
//
// Not any of these:
//
//   * a device-model or OS-version table — would have to be maintained against
//     hardware that does not exist yet;
//   * VTIsHardwareDecodeSupported — wrong direction, and hardware-only;
//   * trying the AVAssetWriterInput and watching it fail — needs a track and an
//     output file in hand, so it cannot answer for a picker row that states a
//     size before anything is fetched.
//
// 1920x1080 because an encoder's existence does not depend on the dimensions;
// nothing is encoded here. A device that answers yes then refuses the real
// settings is still caught: -canAddInput: is checked at setup.
static BOOL FBPConverterVideoToolboxEncodesHEVC(void) {
    CFDictionaryRef supported = NULL;
    CFStringRef encoderIdentifier = NULL;

    OSStatus status = VTCopySupportedPropertyDictionaryForEncoder(
        1920, 1080, kCMVideoCodecType_HEVC, NULL, &encoderIdentifier, &supported);

    if (encoderIdentifier) CFRelease(encoderIdentifier);
    if (supported) CFRelease(supported);

    return status == noErr;
}

FBPConverterCodec FBPMediaConversionCodec(void) {
    // Cached like the decode probe: the answer cannot change within a process,
    // and the call is a VideoToolbox round trip.
    static FBPConverterCodec codec;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        codec = FBPConverterVideoToolboxEncodesHEVC() ? FBPConverterCodecHEVC
                                                      : FBPConverterCodecH264;
        FBPLog(@"converter: encoding to %@",
               codec == FBPConverterCodecHEVC ? @"HEVC (hvc1)" : @"H.264 (avc1)");
    });
    return codec;
}

void FBPMediaConversionPrewarm(void) {
    // QOS_CLASS_UTILITY: speculative work for a feature the user may never
    // reach, so it must not compete with the app. The inner dispatch_once makes
    // a racing caller's duplicate work free.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        (void)FBPMediaConversionIsAvailable();
        // Needed by the picker too (it decides the size a row shows), so settle
        // it here rather than on the first tap.
        (void)FBPMediaConversionCodec();
    });
}

#pragma mark - Bitrate policy

// Output bitrate: why not a preset, and why the two codecs differ.
//
// AVAssetExportSession's presets are unusable here. Measured on the 127-second
// 1080x1920 AV1 fixture (av01.0.08M.08, 285 769 bits/s, 4.55 MB):
//
//     AVAssetExportPreset1920x1080  ->  88.95 MB   (5.47 Mbit/s)   ~19x
//
// A preset targets a quality tier for ordinary camera footage, not knowing
// Meta's ladder encodes this rung at 286 kbit/s. So the output bitrate is
// derived from the source representation's own bandwidth, stated per rung in the
// manifest and already carried by FBPDownloadVariant.
//
// H.264: 3x, measured
// ------------------------------------------------------------------------
// The first 20s of the fixture, re-encoded at eight bitrates with the settings
// below, each scored with VMAF against the decoded AV1 source (100 = indistin-
// guishable from what Facebook plays):
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
// The curve is smooth with no knee, so this is a cost decision, not a
// threshold: past ~3x, each further doubling buys under a point of VMAF.
//
// HEVC: 2x, measured the same way and not inherited
// ------------------------------------------------------------------------
// 3x was fitted to H.264, so the sweep was re-run for HEVC — same fixture, same
// 20s excerpt, same VMAF reference, only AVVideoCodecKey and the profile
// changed:
//
//     bits/s    x source   VMAF    SSIM     extrapolated size for 127s
//      142 885     0.50    87.39   0.9901      5.0 MB   <- encoder floors out
//      214 327     0.75    87.47   0.9901      5.0 MB      here: it will not go
//      285 769     1.00    88.03   0.9906      5.1 MB      below ~314 kbit/s
//      400 077     1.40    92.57   0.9940      6.8 MB
//      500 096     1.75    94.31   0.9952      8.3 MB
//      571 538     2.00    94.89   0.9954      9.2 MB   <- chosen
//      800 000     2.80    95.32   0.9960     11.3 MB
//    1 143 076     4.00    95.60   0.9963     12.5 MB
//    1 600 306     5.60    95.65   0.9963     12.9 MB
//    2 200 000     7.70    95.67   0.9963     13.0 MB
//    3 000 000    10.50    95.76   0.9965     13.8 MB
//
// Same rule — the point past which a further doubling buys under a point of
// VMAF — and here that is 2x: 2.00x -> 4.00x is +0.71, while 1.40x -> 2.80x is
// still +2.75. The curve saturates around 95.7 because above 2x the encoder
// stops spending what it is offered.
//
// The same sweep on a second fixture (640x360 avc1 rung from call-003,
// 168 561 bits/s, five times the pixel density — the opposite end of what Meta
// serves) puts the knee at or below 2x:
// 1.00x 92.73, 1.40x 93.81, 1.75x 94.35, 2.00x 94.52, 2.80x 94.73, 4.00x 95.10.
// There 1.40x -> 2.80x is already +0.92. 2x is the conservative choice, so it
// is taken.
//
// Both sweeps score a 20s excerpt, so the two multipliers were then run over the
// whole 127s fixture and the finished files scored end to end — real bytes:
//
//                  bytes       MB      VMAF mean   harmonic
//     H.264 3.00x  13 766 478  14.36     92.54      92.29
//     HEVC  2.00x   9 382 281   9.98     92.94      92.66
//
// Marginally better for 32% fewer bytes of video (30% of the finished file,
// audio included and passed through either way). Both numbers are lower than the
// excerpt's because the back of the clip is harder than its first 20s; they move
// together, so the two multipliers are the same quality tier in two codecs.
//
// Per-pixel bounds
// ------------------------------------------------------------------------
// Floor and ceiling are in bits per pixel per frame, not absolute, since a 240p
// and a 1080p rung share nothing in absolute terms. Both are pathology guards
// set to bind on nothing Meta has been observed to serve: across 29 real AV1
// representations in the six captured manifests the source density runs 0.0042
// to 0.0944 bpp/frame. 3x runs 0.0127…0.2833 and 2x runs 0.0084…0.1888, so each
// codec gets its own pair just outside its own range. They cannot be shared: the
// H.264 floor of 0.012 would clamp the HEVC target upward on the lowest rungs,
// undoing the measurement above and making every promised size wrong.
//
// They stop a future manifest with an absurd rung producing an absurd file, not
// second-guess the measurement.
typedef struct {
    double multiplier;
    double floorBPP;
    double ceilBPP;
    /// Used only when the manifest stated no bandwidth, which no observed Meta
    /// manifest does. Geometric mean of the two bounds, so it errs neither way.
    double defaultBPP;
} FBPConvertRatePolicy;

static FBPConvertRatePolicy FBPConvertPolicyFor(FBPConverterCodec codec) {
    if (codec == FBPConverterCodecH264) {
        return (FBPConvertRatePolicy){ 3.0, 0.012, 0.300, 0.060 };
    }
    return (FBPConvertRatePolicy){ 2.0, 0.008, 0.200, 0.040 };
}

// Absolute backstops for a frame size too small or too large for the per-pixel
// bounds to stay sensible. Shared by both codecs: the smallest real rung is
// 105 123 bits/s (2x clears the 120 kbit/s floor) and the largest is 4 072 929
// (3x = 12.2 Mbit/s stays under the 16 Mbit/s ceiling).
static const long long kFBPConvertMinBitRate =    120000;   // 120 kbit/s
static const long long kFBPConvertMaxBitRate =  16000000;   //  16 Mbit/s
// Assumed when the track declares no frame rate. Meta's rungs are 30 fps (25 in
// one captured manifest); this only has to keep the arithmetic off zero.
static const float kFBPConvertAssumedFPS = 30.0f;

long long FBPConverterTargetBitRateForCodec(long long sourceBitsPerSecond,
                                            CGSize frameSize,
                                            float framesPerSecond,
                                            FBPConverterCodec codec) {
    FBPConvertRatePolicy policy = FBPConvertPolicyFor(codec);

    double fps = (framesPerSecond > 0.5f && framesPerSecond < 240.0f)
        ? (double)framesPerSecond
        : (double)kFBPConvertAssumedFPS;

    double pixels = (double)frameSize.width * (double)frameSize.height;
    if (!(pixels > 0)) {
        // No frame size. Fall back to the source's own number (at least a
        // measurement of this video), then to the floor.
        long long scaled = (long long)llround((double)MAX(sourceBitsPerSecond, 0LL) *
                                              policy.multiplier);
        return MAX(MIN(scaled, kFBPConvertMaxBitRate), kFBPConvertMinBitRate);
    }

    double perFrame = pixels * fps;
    double floorRate = perFrame * policy.floorBPP;
    double ceilRate  = perFrame * policy.ceilBPP;

    double target = (sourceBitsPerSecond > 0)
        ? (double)sourceBitsPerSecond * policy.multiplier
        : perFrame * policy.defaultBPP;

    if (target < floorRate) target = floorRate;
    if (target > ceilRate)  target = ceilRate;

    long long rate = (long long)llround(target);
    if (rate < kFBPConvertMinBitRate) rate = kFBPConvertMinBitRate;
    if (rate > kFBPConvertMaxBitRate) rate = kFBPConvertMaxBitRate;
    return rate;
}

long long FBPConverterTargetBitRate(long long sourceBitsPerSecond,
                                    CGSize frameSize,
                                    float framesPerSecond) {
    return FBPConverterTargetBitRateForCodec(sourceBitsPerSecond, frameSize,
                                             framesPerSecond,
                                             FBPMediaConversionCodec());
}

long long FBPConverterExpectedOutputBytes(long long sourceBitsPerSecond,
                                          CGSize frameSize,
                                          float framesPerSecond,
                                          long long audioBitsPerSecond,
                                          double durationSeconds) {
    if (!(durationSeconds > 0) || !isfinite(durationSeconds)) return 0;
    // No bandwidth and no frame size: nothing to derive a rate from, so the
    // result would be the floor — a constant, not a prediction. Say nothing.
    if (sourceBitsPerSecond <= 0 &&
        !(frameSize.width > 0 && frameSize.height > 0)) {
        return 0;
    }

    double bitsPerSecond =
        (double)FBPConverterTargetBitRate(sourceBitsPerSecond, frameSize,
                                          framesPerSecond);
    // Audio is passed through, so it lands at the bitrate the manifest states.
    if (audioBitsPerSecond > 0) bitsPerSecond += (double)audioBitsPerSecond;

    double bytes = bitsPerSecond * durationSeconds / 8.0;
    // 1 TB is not a Reel; a number that big means a misread.
    if (!isfinite(bytes) || bytes <= 0 || bytes > 1e12) return 0;
    return (long long)llround(bytes);
}

#pragma mark - In-flight registry

// As the muxer's: a conversion owns itself for its lifetime, and this set is
// its last owner and what +cancelAll walks. Separate from the muxer's registry
// because +[FBPMediaMuxer cancelAll] and +[FBPMediaConverter cancelAll] are
// different requests, and a converting flow has no mux to stop.

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

    /// Source duration in seconds, for progress. 0 when unknown, which falls
    /// back to a frame-count estimate.
    double _duration;
    /// The video track's first-sample time, so progress measures from the real
    /// start, not zero.
    double _videoStartSeconds;
    /// Frames expected (duration x frame rate). Only used when `_duration` is
    /// unusable.
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

    // -isPlayable is the honest per-file answer; see the measurement at the top
    // for what the alternatives claim. Synchronous is fine: every caller is off
    // the main thread (the control queue, or the host harness).
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

    // A job still loading asset headers has no pump to notice the flag.
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

    // Neither tier available: nothing on this device can decode the source.
    // Refused here rather than at a setup failure, so the error says "this
    // device cannot" instead of "the file is broken".
    if (!FBPMediaConversionIsAvailable()) {
        [self finishWithError:
            FBPConvertError(FBPMediaConverterErrorNoConversionPath,
                            @"This device cannot convert this video.", nil)];
        return;
    }

    // The per-file authority. -isAvailable only said a decoder exists; this says
    // AVFoundation will decode *this* asset, stopping a 10-bit or otherwise
    // awkward stream from becoming a mysterious setup failure later.
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

    // Progress needs a denominator: the video track's duration (the output is as
    // long as the picture), falling back to the asset's.
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

    // Asking for a pixel format makes this a decode. 420v (8-bit bi-planar
    // video-range 4:2:0) is what VideoToolbox's AV1 decoder produces and what
    // both encoders consume (HEVC Main and H.264 High are 8-bit 4:2:0), so the
    // common case costs no pixel conversion. Every observed Meta AV1 rung is
    // 8-bit (the `.08` in `av01.0.05M.08`), so nothing is truncated in practice;
    // a 10-bit source is flattened to 8-bit here, a real but invisible loss and
    // better than refusing the rung.
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

        // nil settings: the AAC comes out as it went in, same as the muxer.
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

/// The encoder settings. The one place the conversion is lossy, so every key
/// here is a deliberate choice, not a default.
- (NSDictionary *)videoOutputSettingsForTrack:(AVAssetTrack *)videoTrack
                                        codec:(FBPConverterCodec)codec {
    CGSize natural = videoTrack.naturalSize;

    // Both codecs want even dimensions; an odd one rounds down, so the output is
    // never larger than the source. naturalSize is the encoded size, before any
    // rotation matrix — correct, since rotation is carried as a matrix below,
    // not baked into pixels.
    NSInteger width  = ((NSInteger)llround(natural.width)  / 2) * 2;
    NSInteger height = ((NSInteger)llround(natural.height) / 2) * 2;
    if (width <= 0 || height <= 0) return nil;

    BOOL hevc = (codec == FBPConverterCodecHEVC);

    float fps = videoTrack.nominalFrameRate;
    long long bitRate = FBPConverterTargetBitRateForCodec(_sourceBitRate,
                                                          CGSizeMake(width, height),
                                                          fps, codec);

    NSMutableDictionary *compression = [NSMutableDictionary dictionaryWithCapacity:6];
    compression[AVVideoAverageBitRateKey] = @(bitRate);

    if (hevc) {
        // Main profile, auto level. Main is 8-bit 4:2:0, matching what the
        // reader hands up (420v) and every Meta AV1 rung; Main10 would promise a
        // depth there is none of. A hand-pinned level would get 1080p60 wrong
        // one day.
        //
        // No AVFoundation spelling exists, so use VideoToolbox's constant:
        // AVVideoProfileLevelKey forwards it to
        // kVTCompressionPropertyKey_ProfileLevel.
        compression[AVVideoProfileLevelKey] =
            (__bridge NSString *)kVTProfileLevel_HEVC_Main_AutoLevel;
        // AVVideoH264EntropyModeKey is absent on purpose: an H.264 key, and HEVC
        // has only CABAC, so passing it makes -canAddInput: refuse the input.
    } else {
        // High profile, auto level. High is what every iOS H.264 encoder
        // produces for camera video and what Photos has always accepted.
        compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel;
        // CABAC over CAVLC: ~10% better at equal quality, and the reason to use
        // High profile at all.
        compression[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC;
    }

    // B-frames: cost encode time, buy bitrate — the trade this function makes.
    compression[AVVideoAllowFrameReorderingKey] = @YES;
    // A keyframe at least every two seconds, so scrubbing in Photos is not
    // miserable. A duration rather than a frame count, so it holds at any fps.
    compression[AVVideoMaxKeyFrameIntervalDurationKey] = @(2.0);
    if (fps > 0.5f) compression[AVVideoExpectedSourceFrameRateKey] = @(llround(fps));

    FBPLog(@"converter: encoding %ldx%ld @%.2ffps source=%lld -> %@ %lld bit/s",
           (long)width, (long)height, fps, _sourceBitRate,
           hevc ? @"hevc" : @"h264", bitRate);

    // hvc1, not hev1. Both are HEVC in an MP4, differing only in where the
    // parameter sets live: hvc1 keeps VPS/SPS/PPS in the sample entry, hev1
    // allows them inline. Apple requires hvc1 for MP4 playback; an hev1 file is
    // the usual way an HEVC export ends up refused.
    //
    // No public key selects one, and none is needed: AVAssetWriter with
    // AVFileTypeMPEG4 writes hvc1 (verified on the fixture: codec_tag_string=
    // hvc1, profile=Main). -logOutputTracks asserts it on every debug
    // conversion, so a future OS changing its mind shows up as a failing check,
    // not a file Photos refuses.
    return @{
        AVVideoCodecKey: hevc ? AVVideoCodecTypeHEVC : AVVideoCodecTypeH264,
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

    // movflags=+faststart, as in the muxer.
    _writer.shouldOptimizeForNetworkUse = YES;

    // HEVC first where the probe said this device encodes it, then H.264.
    //
    // The second entry is not redundant with the probe. The probe asks whether
    // an HEVC encoder exists; -canAddInput: asks whether *these settings* are
    // accepted — a different question, and the only one that can still say no
    // here (an unusual frame size, a level no encoder on this chip reaches).
    // Falling back costs one dictionary and saves the download, where refusing
    // would error on a file H.264 produces fine.
    //
    // The one path where the picker's promised size can be wrong — sized for
    // HEVC at 2x, delivered as H.264 at 3x. Taken anyway: a file half again as
    // big beats no file, and it needs a device that reports an HEVC encoder then
    // refuses to use it, which nothing measured does. The log line below would
    // identify such a device from a report.
    FBPConverterCodec codecs[2];
    NSInteger codecCount = 0;
    if (FBPMediaConversionCodec() == FBPConverterCodecHEVC) {
        codecs[codecCount++] = FBPConverterCodecHEVC;
    }
    codecs[codecCount++] = FBPConverterCodecH264;

    BOOL accepted = NO;
    BOOL hadSettings = NO;
    for (NSInteger index = 0; index < codecCount && !accepted; index++) {
        NSDictionary *videoSettings = [self videoOutputSettingsForTrack:videoTrack
                                                                  codec:codecs[index]];
        if (!videoSettings) break;   // No usable frame size; the codec is not why.
        hadSettings = YES;

        // No sourceFormatHint: a hint is for passthrough, and this input is the
        // opposite of passthrough.
        _videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                        outputSettings:videoSettings];
        // NO: quality over latency. Nothing waits on a frame, so the encoder may
        // take as long as it likes per frame.
        _videoInput.expectsMediaDataInRealTime = NO;

        // The muxer's rotation trap, biting identically even though every pixel
        // is re-encoded: rotation in an MP4 is a matrix on the track, not in the
        // picture, and a fresh input's matrix is the identity. Without this every
        // portrait Reel lands in Photos on its side.
        _videoInput.transform = videoTrack.preferredTransform;

        accepted = [_writer canAddInput:_videoInput];
        if (!accepted) {
            FBPLog(@"converter: %@ settings refused, %@",
                   codecs[index] == FBPConverterCodecHEVC ? @"hevc" : @"h264",
                   index + 1 < codecCount ? @"falling back" : @"nothing left to try");
            _videoInput = nil;
        }
    }

    if (!accepted) {
        if (errorOut) {
            *errorOut = FBPConvertError(FBPMediaConverterErrorSetupFailed,
                                        hadSettings
                                            ? @"This device would not accept these "
                                              @"encoder settings."
                                            : @"The video track has no usable frame "
                                              @"size.", nil);
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

/// Fraction through the picture, 0…1.
///
/// From the presentation time of the frame just handed to the encoder, not a
/// frame tally. A frame count needs a denominator, and the only one available is
/// duration x nominalFrameRate — wrong for any variable-frame-rate video, so the
/// bar would finish early or stall short. A timestamp is exact. The frame tally
/// is kept for the log and as the fallback when the source declares no duration.
///
/// Capped just under 1.0: finalizing an MP4 this size is itself a real wait, and
/// a bar at 100% while the file is still being written is the lie the
/// fetch/merge split exists to avoid.
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
    // Never backwards: B-frame reordering means samples arrive in decode order,
    // whose timestamps are not monotonic.
    if (fraction < _reportedFraction) fraction = _reportedFraction;
    _reportedFraction = fraction;

    NSInteger percent = (NSInteger)lrintf(fraction * 100.0f);
    if (percent == _lastReportedPercent) return;
    _lastReportedPercent = percent;

    FBPMediaConvertProgress block = _progress;
    dispatch_async(dispatch_get_main_queue(), ^{ block(fraction); });
}

#pragma mark Pumps

/// Decode-and-encode. One frame per loop turn, with the cancellation check
/// inside the loop: a conversion the user gave up on stops within one frame's
/// work, not at the end of the file.
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

/// Read the finished file back and log its tracks.
///
/// Standing proof that this produced what Photos needs: the video track's
/// four-character code must read `hvc1` (not `hev1`, the same codec in a layout
/// Apple will not play) or `avc1` on the fallback, and flags AV1 getting through
/// untouched. Debug builds only.
- (void)logOutputTracks {
#ifdef DEBUG
    AVURLAsset *result = [AVURLAsset URLAssetWithURL:_outputURL options:nil];

    for (AVAssetTrack *track in result.tracks) {
        CMFormatDescriptionRef format =
            (__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject;
        NSString *fourCC = FBPConvertFourCC(format);
        FBPLog(@"converter: out %@ %@ %.3fs", track.mediaType, fourCC,
               CMTimeGetSeconds(track.timeRange.duration));

        if (![track.mediaType isEqualToString:AVMediaTypeVideo]) continue;
        if (![fourCC isEqualToString:@"hvc1"] && ![fourCC isEqualToString:@"avc1"]) {
            FBPLog(@"converter: !! output video is %@, which Photos will refuse "
                   @"(expected hvc1 or avc1)", fourCC);
        }
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
    // self. Dropping them lets this object — and its registry entry, its last
    // owner — go away.
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
