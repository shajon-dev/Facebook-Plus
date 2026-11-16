// VP9 -> HEVC/H.264 conversion. See FBPVP9Converter.h for the shape and why it
// is separate from FBPMediaConverter.

#import "FBPVP9Converter.h"
#import "FBPVP9Bridge.h"
#import "FBPMediaConverter.h"   // error domain + codes, encode-maths C helpers
#import "FBPMediaMuxer.h"       // pass 2: stream-copy the audio back in
#import "FBPlus.h"              // FBPLog -> the exportable diagnostic log

#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <stdatomic.h>

extern NSString *FBPLocalizedString(NSString *key);

#pragma mark - Error helper

// Every user-facing reason is a localized string (keys in Localizations/), never
// a hardcoded sentence: a convert failure surfaces to the user through
// FBPDashDownload's "download.convert.failed" with this localizedDescription as
// its reason. @c logLine is the developer-facing diagnostic — English, like
// every other FBPLog line — recorded so an exception is detectable from the log.
static NSError *FBPVP9Error(FBPMediaConverterError code, NSString *messageKey) {
    NSString *message = FBPLocalizedString(messageKey);
    return [NSError errorWithDomain:FBPMediaConverterErrorDomain
                               code:code
                           userInfo:@{ NSLocalizedDescriptionKey: message ?: messageKey }];
}

#pragma mark - Registry (for +cancelAll)

static NSMutableSet *gVP9Jobs = nil;
static NSLock *gVP9JobsLock = nil;
static void FBPVP9EnsureRegistry(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gVP9Jobs = [NSMutableSet set];
        gVP9JobsLock = [NSLock new];
    });
}

#pragma mark - Sample bytes

static NSData *FBPVP9SampleData(CMSampleBufferRef sb) {
    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
    if (!bb) return nil;
    size_t len = CMBlockBufferGetDataLength(bb);
    if (len == 0) return nil;
    NSMutableData *d = [NSMutableData dataWithLength:len];
    if (CMBlockBufferCopyDataBytes(bb, 0, len, d.mutableBytes) != kCMBlockBufferNoErr) return nil;
    return d;
}

#pragma mark - Converter job

@interface FBPVP9Converter ()
@end

@implementation FBPVP9Converter {
    NSURL *_videoURL;
    NSURL *_audioURL;
    NSURL *_outputURL;
    long long _sourceBitRate;
    void (^_progress)(float);
    void (^_completion)(NSURL *_Nullable, NSError *_Nullable);

    dispatch_queue_t _queue;
    atomic_bool _cancelled;

    AVAssetWriter *_writer;
    NSURL *_tempURL;   // pass-1 video-only output, merged with audio in pass 2

    double _duration;
    double _startSeconds;
    NSInteger _lastPercent;
    NSInteger _framesAppended;
    BOOL _completed;
}

+ (void)convertVideoURL:(NSURL *)videoURL
               audioURL:(NSURL *)audioURL
          sourceBitRate:(long long)sourceBitRate
              outputURL:(NSURL *)outputURL
               progress:(void (^)(float))progress
             completion:(void (^)(NSURL *_Nullable, NSError *_Nullable))completion {
    if (!completion) return;
    FBPVP9Converter *job = [FBPVP9Converter new];
    job->_videoURL = [videoURL copy];
    job->_audioURL = [audioURL copy];
    job->_outputURL = [outputURL copy];
    job->_sourceBitRate = MAX(sourceBitRate, 0LL);
    job->_progress = [progress copy];
    job->_completion = [completion copy];
    job->_queue = dispatch_queue_create("com.shajon.fbplus.vp9.convert", DISPATCH_QUEUE_SERIAL);
    job->_lastPercent = -1;
    atomic_init(&job->_cancelled, false);

    FBPVP9EnsureRegistry();
    [gVP9JobsLock lock];
    [gVP9Jobs addObject:job];
    [gVP9JobsLock unlock];

    dispatch_async(job->_queue, ^{ [job run]; });
}

+ (void)cancelAll {
    FBPVP9EnsureRegistry();
    [gVP9JobsLock lock];
    NSArray *jobs = gVP9Jobs.allObjects;
    [gVP9JobsLock unlock];
    for (FBPVP9Converter *job in jobs) [job cancel];
}

- (void)cancel {
    atomic_store_explicit(&_cancelled, true, memory_order_relaxed);
}

- (BOOL)isCancelled {
    return atomic_load_explicit(&_cancelled, memory_order_relaxed);
}

#pragma mark Encode settings

- (NSDictionary *)videoSettingsForSize:(CGSize)natural
                                   fps:(float)fps
                                 codec:(FBPConverterCodec)codec {
    NSInteger width  = ((NSInteger)llround(natural.width)  / 2) * 2;
    NSInteger height = ((NSInteger)llround(natural.height) / 2) * 2;
    if (width <= 0 || height <= 0) return nil;

    BOOL hevc = (codec == FBPConverterCodecHEVC);
    long long bitRate = FBPConverterTargetBitRateForCodec(_sourceBitRate,
                                                          CGSizeMake(width, height),
                                                          fps, codec);

    NSMutableDictionary *compression = [NSMutableDictionary dictionary];
    compression[AVVideoAverageBitRateKey] = @(bitRate);
    if (hevc) {
        compression[AVVideoProfileLevelKey] =
            (__bridge NSString *)kVTProfileLevel_HEVC_Main_AutoLevel;
    } else {
        compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel;
        compression[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC;
    }
    compression[AVVideoAllowFrameReorderingKey] = @YES;
    compression[AVVideoMaxKeyFrameIntervalDurationKey] = @(2.0);
    if (fps > 0.5f) compression[AVVideoExpectedSourceFrameRateKey] = @(llround(fps));

    return @{
        AVVideoCodecKey: hevc ? AVVideoCodecTypeHEVC : AVVideoCodecTypeH264,
        AVVideoWidthKey: @(width),
        AVVideoHeightKey: @(height),
        AVVideoCompressionPropertiesKey: compression,
    };
}

#pragma mark Run

- (void)run {
    FBPLog(@"vp9: converting %@ (audio=%@) sourceBitRate=%lld",
           _videoURL.lastPathComponent ?: @"(nil)",
           _audioURL ? @"yes" : @"no", _sourceBitRate);
    if ([self isCancelled]) {
        [self finishWithOutput:nil error:FBPVP9Error(FBPMediaConverterErrorCancelled, @"vp9.error.cancelled")];
        return;
    }
    if (!_videoURL || !_outputURL) {
        [self finishWithOutput:nil error:FBPVP9Error(FBPMediaConverterErrorBadArguments,
                                                     @"vp9.error.badArguments")];
        return;
    }
    if (!FBPVP9ConversionIsAvailable()) {
        [self finishWithOutput:nil error:FBPVP9Error(FBPMediaConverterErrorNoConversionPath,
                                                     @"vp9.error.unavailable")];
        return;
    }

    NSDictionary *options = @{ AVURLAssetPreferPreciseDurationAndTimingKey: @YES };
    AVURLAsset *videoAsset = [AVURLAsset URLAssetWithURL:_videoURL options:options];
    AVAssetTrack *videoTrack = [videoAsset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!videoTrack) {
        [self finishWithOutput:nil error:FBPVP9Error(FBPMediaConverterErrorVideoUnreadable,
                                                     @"vp9.error.unreadable")];
        return;
    }

    CGSize natural = videoTrack.naturalSize;
    float fps = videoTrack.nominalFrameRate;
    CMTime td = videoTrack.timeRange.duration;
    double seconds = CMTIME_IS_NUMERIC(td) ? CMTimeGetSeconds(td) : 0;
    if (!(seconds > 0)) {
        CMTime ad = videoAsset.duration;
        seconds = CMTIME_IS_NUMERIC(ad) ? CMTimeGetSeconds(ad) : 0;
    }
    _duration = (seconds > 0 && isfinite(seconds)) ? seconds : 0;

    NSError *err = nil;

    // --- Demux reader (passthrough: compressed VP9 samples, no decode) ---
    AVAssetReader *videoReader = [AVAssetReader assetReaderWithAsset:videoAsset error:&err];
    if (!videoReader) {
        [self finishWithOutput:nil error:FBPVP9Error(FBPMediaConverterErrorSetupFailed,
                                                     @"vp9.error.setup")];
        return;
    }
    AVAssetReaderTrackOutput *videoOutput =
        [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack outputSettings:nil];
    videoOutput.alwaysCopiesSampleData = NO;
    if (![videoReader canAddOutput:videoOutput]) {
        [self finishWithOutput:nil error:FBPVP9Error(FBPMediaConverterErrorVideoUndecodable,
                                                     @"vp9.error.undecodable")];
        return;
    }
    [videoReader addOutput:videoOutput];

    // --- Pass 1 writer: VIDEO ONLY, to a temp file. ---
    // A single-input AVAssetWriter cannot deadlock on readyForMoreMediaData the
    // way a two-input one does when the tracks are appended one track at a time
    // (it stalls the first track waiting for the second to interleave). The audio
    // is merged back in pass 2 by FBPMediaMuxer — a tested stream copy — which
    // also avoids re-implementing interleaving here.
    _tempURL = [NSURL fileURLWithPath:
        [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"fbp-vp9-%@.mp4", NSUUID.UUID.UUIDString]]];
    [NSFileManager.defaultManager removeItemAtURL:_tempURL error:nil];
    _writer = [AVAssetWriter assetWriterWithURL:_tempURL fileType:AVFileTypeMPEG4 error:&err];
    if (!_writer) {
        [self finishWithOutput:nil error:FBPVP9Error(FBPMediaConverterErrorSetupFailed,
                                                     @"vp9.error.output")];
        return;
    }
    _writer.shouldOptimizeForNetworkUse = YES;

    FBPConverterCodec codecs[2];
    NSInteger codecCount = 0;
    if (FBPMediaConversionCodec() == FBPConverterCodecHEVC) codecs[codecCount++] = FBPConverterCodecHEVC;
    codecs[codecCount++] = FBPConverterCodecH264;

    AVAssetWriterInput *videoInput = nil;
    AVAssetWriterInputPixelBufferAdaptor *adaptor = nil;
    for (NSInteger i = 0; i < codecCount; i++) {
        NSDictionary *settings = [self videoSettingsForSize:natural fps:fps codec:codecs[i]];
        if (!settings) break;
        AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                                       outputSettings:settings];
        input.expectsMediaDataInRealTime = NO;
        input.transform = videoTrack.preferredTransform;
        if ([_writer canAddInput:input]) { videoInput = input; break; }
    }
    if (!videoInput) {
        [self finishWithOutput:nil error:FBPVP9Error(FBPMediaConverterErrorSetupFailed,
                                                     @"vp9.error.encoder")];
        return;
    }
    adaptor = [AVAssetWriterInputPixelBufferAdaptor
        assetWriterInputPixelBufferAdaptorWithAssetWriterInput:videoInput
                                   sourcePixelBufferAttributes:@{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (id)kCVPixelBufferWidthKey: @((NSInteger)llround(natural.width)),
            (id)kCVPixelBufferHeightKey: @((NSInteger)llround(natural.height)),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        }];

    @try {
        [_writer addInput:videoInput];
    } @catch (NSException *ex) {
        FBPLog(@"vp9: addInput threw: %@", ex.reason ?: ex.name);
        [self finishWithOutput:nil error:FBPVP9Error(FBPMediaConverterErrorSetupFailed,
                                                     @"vp9.error.tracks")];
        return;
    }

    // --- Borrowed decoder ---
    FBPVP9Decoder *decoder = [FBPVP9Decoder new];
    if (!decoder) {
        [self finishWithOutput:nil error:FBPVP9Error(FBPMediaConverterErrorNoConversionPath,
                                                     @"vp9.error.unavailable")];
        return;
    }

    if (![videoReader startReading] || ![_writer startWriting]) {
        [self finishWithOutput:nil error:FBPVP9Error(FBPMediaConverterErrorReadFailed,
                                                     @"vp9.error.read")];
        return;
    }

    // --- Pass 1: demux -> borrowed decode -> HEVC/H.264 encode (video only) ---
    __block NSError *fatal = nil;
    __block BOOL sessionStarted = NO;
    __block BOOL selfTestDone = NO;
    CGSize nat = natural;

    // Appends one decoded frame, starting the writer session on the first and
    // self-testing the borrowed layout against the track's own size before any
    // frame is trusted. Shared by the per-sample decode and the end flush.
    void (^appendFrame)(CVPixelBufferRef, CMTime) = ^(CVPixelBufferRef pb, CMTime pts) {
        if (fatal) return;
        if (!selfTestDone) {
            selfTestDone = YES;
            size_t w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb);
            double nw = llround(nat.width), nh = llround(nat.height);
            BOOL sane = (nw <= 0 || nh <= 0) ||
                        ((double)w >= nw * 0.5 && (double)w <= nw * 2.0 + 64 &&
                         (double)h >= nh * 0.5 && (double)h <= nh * 2.0 + 64);
            if (!sane) {
                FBPVP9BridgeMarkUnhealthy();
                fatal = FBPVP9Error(FBPMediaConverterErrorVideoUndecodable, @"vp9.error.mismatch");
                return;
            }
        }
        if (!sessionStarted) {
            [self->_writer startSessionAtSourceTime:pts];
            self->_startSeconds = CMTIME_IS_NUMERIC(pts) ? CMTimeGetSeconds(pts) : 0;
            sessionStarted = YES;
        }
        // A single-input writer: readyForMoreMediaData toggles back to YES as the
        // encoder drains on its own threads, so this cannot deadlock.
        while (!videoInput.readyForMoreMediaData) {
            if ([self isCancelled]) { fatal = FBPVP9Error(FBPMediaConverterErrorCancelled, @"vp9.error.cancelled"); return; }
            usleep(2000);
        }
        if (![adaptor appendPixelBuffer:pb withPresentationTime:pts]) {
            fatal = FBPVP9Error(FBPMediaConverterErrorWriteFailed, @"vp9.error.write");
            return;
        }
        self->_framesAppended++;
        [self reportProgressForSeconds:(CMTIME_IS_NUMERIC(pts) ? CMTimeGetSeconds(pts) : 0)];
    };

    while (!fatal) {
      @autoreleasepool {   // per-frame: one NSData + sample buffer, thousands of times
        if ([self isCancelled]) { fatal = FBPVP9Error(FBPMediaConverterErrorCancelled, @"vp9.error.cancelled"); break; }
        CMSampleBufferRef sb = [videoOutput copyNextSampleBuffer];
        if (!sb) break;
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
        NSData *au = FBPVP9SampleData(sb);
        CFRelease(sb);
        if (!au) continue;
        [decoder decodeAccessUnit:au.bytes length:au.length handler:^(CVPixelBufferRef pb) {
            appendFrame(pb, pts);
        }];
      }
    }

    if (!fatal) [decoder flushWithHandler:^(CVPixelBufferRef pb) {
        appendFrame(pb, CMTimeMakeWithSeconds(self->_startSeconds + self->_duration, 600));
    }];

    if (!fatal && videoReader.status == AVAssetReaderStatusFailed) {
        fatal = FBPVP9Error(FBPMediaConverterErrorReadFailed, @"vp9.error.read");
    }
    // Nothing decoded from a stream we were told was VP9: the borrowed decode is
    // not working on this build. Refuse and turn the tier off.
    if (!fatal && _framesAppended == 0) {
        FBPVP9BridgeMarkUnhealthy();
        fatal = FBPVP9Error(FBPMediaConverterErrorNoSamples, @"vp9.error.noFrames");
    }

    if (fatal) {
        [videoReader cancelReading];
        [_writer cancelWriting];
        [NSFileManager.defaultManager removeItemAtURL:_tempURL error:nil];
        [self finishWithOutput:nil error:fatal];
        return;
    }

    [videoInput markAsFinished];

    __weak typeof(self) weakSelf = self;
    [_writer finishWritingWithCompletionHandler:^{
        typeof(self) s = weakSelf; if (!s) return;
        if (s->_writer.status != AVAssetWriterStatusCompleted) {
            FBPLog(@"vp9: pass-1 writer status=%ld error=%@",
                   (long)s->_writer.status, s->_writer.error);
            [NSFileManager.defaultManager removeItemAtURL:s->_tempURL error:nil];
            [s finishWithOutput:nil error:FBPVP9Error(FBPMediaConverterErrorWriteFailed,
                                                      @"vp9.error.finalize")];
            return;
        }
        [s mergeAudioThenFinish];
    }];
}

// Pass 2: put the audio back. The temp is now HEVC/H.264, which AVFoundation can
// read, so FBPMediaMuxer stream-copies it with the original audio. A video-only
// source (no audio URL) just moves the temp into place.
- (void)mergeAudioThenFinish {
    if ([self isCancelled]) {
        [NSFileManager.defaultManager removeItemAtURL:_tempURL error:nil];
        [self finishWithOutput:nil error:FBPVP9Error(FBPMediaConverterErrorCancelled, @"vp9.error.cancelled")];
        return;
    }
    [NSFileManager.defaultManager removeItemAtURL:_outputURL error:nil];

    if (!_audioURL) {
        NSError *mv = nil;
        if ([NSFileManager.defaultManager moveItemAtURL:_tempURL toURL:_outputURL error:&mv]) {
            [self finishWithOutput:_outputURL error:nil];
        } else {
            FBPLog(@"vp9: move temp->output failed: %@", mv);
            [NSFileManager.defaultManager removeItemAtURL:_tempURL error:nil];
            [self finishWithOutput:nil error:FBPVP9Error(FBPMediaConverterErrorWriteFailed, @"vp9.error.finalize")];
        }
        return;
    }

    NSURL *temp = _tempURL;
    __weak typeof(self) weakSelf = self;
    [FBPMediaMuxer muxVideoURL:temp
                     audioURL:_audioURL
                    outputURL:_outputURL
                   completion:^(NSURL *muxed, NSError *muxError) {
        typeof(self) s = weakSelf; if (!s) return;
        [NSFileManager.defaultManager removeItemAtURL:temp error:nil];
        if (muxed && !muxError && ![s isCancelled]) {
            [s finishWithOutput:muxed error:nil];
            return;
        }
        BOOL cancelled = [s isCancelled] ||
            ([muxError.domain isEqualToString:FBPMediaMuxerErrorDomain] &&
             muxError.code == FBPMediaMuxerErrorCancelled);
        FBPLog(@"vp9: audio mux did not deliver (%s) code=%ld",
               cancelled ? "cancelled" : "failed", (long)muxError.code);
        [s finishWithOutput:nil
                      error:FBPVP9Error(cancelled ? FBPMediaConverterErrorCancelled
                                                  : FBPMediaConverterErrorWriteFailed,
                                        cancelled ? @"vp9.error.cancelled" : @"vp9.error.finalize")];
    }];
}

#pragma mark Progress / finish

- (void)reportProgressForSeconds:(double)seconds {
    if (!_progress || _duration <= 0) return;
    double f = (seconds - _startSeconds) / _duration;
    if (f < 0) f = 0; if (f > 1) f = 1;
    NSInteger pct = (NSInteger)(f * 100);
    if (pct == _lastPercent) return;
    _lastPercent = pct;
    void (^p)(float) = _progress;
    dispatch_async(dispatch_get_main_queue(), ^{ p((float)f); });
}

- (void)finishWithOutput:(NSURL *)output error:(NSError *)error {
    if (_completed) return;
    _completed = YES;

    // One place every outcome is logged, so a failure (an exception on any path)
    // is always detectable in the exportable log, with its code and reason.
    if (error) {
        FBPLog(@"vp9: conversion failed code=%ld reason=%@ (frames appended=%ld)",
               (long)error.code, error.localizedDescription, (long)_framesAppended);
    } else {
        FBPLog(@"vp9: conversion ok -> %@ (frames appended=%ld)",
               output.lastPathComponent, (long)_framesAppended);
    }

    FBPVP9EnsureRegistry();
    [gVP9JobsLock lock];
    [gVP9Jobs removeObject:self];
    [gVP9JobsLock unlock];

    if (!output) [NSFileManager.defaultManager removeItemAtURL:_outputURL error:nil];

    void (^completion)(NSURL *, NSError *) = _completion;
    _completion = nil;
    _progress = nil;
    if (!completion) return;
    dispatch_async(dispatch_get_main_queue(), ^{ completion(output, error); });
}

@end
