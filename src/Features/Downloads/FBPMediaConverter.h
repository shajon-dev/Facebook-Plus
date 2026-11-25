// AV1 -> HEVC conversion (H.264 where HEVC cannot be encoded), because Photos
// refuses a correctly muxed AV1 file with PHPhotosErrorDomain 3302. One pass,
// not mux-then-transcode; no shipped ffmpeg. The bitrate multiplier was swept
// for HEVC, not inherited. Output is lossy and about twice the source's size.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Errors

extern NSString *const FBPMediaConverterErrorDomain;

typedef NS_ENUM(NSInteger, FBPMediaConverterError) {
    FBPMediaConverterErrorBadArguments = 1,
    /// About the device: no decoder for the codec, and no live borrowed tier.
    FBPMediaConverterErrorNoConversionPath,
    /// About the file: a decoder exists but the per-file probe said no.
    FBPMediaConverterErrorVideoUndecodable,
    FBPMediaConverterErrorVideoUnreadable,
    FBPMediaConverterErrorAudioUnreadable,
    FBPMediaConverterErrorNoVideoTrack,
    FBPMediaConverterErrorNoAudioTrack,
    FBPMediaConverterErrorMissingFormatDescription,
    FBPMediaConverterErrorSetupFailed,
    FBPMediaConverterErrorReadFailed,
    FBPMediaConverterErrorWriteFailed,
    FBPMediaConverterErrorNoSamples,
    FBPMediaConverterErrorCancelled,
};

#pragma mark - Progress and completion

typedef void (^FBPMediaConvertProgress)(float fraction);

/// Main queue, once. On failure nothing is left at the output path.
typedef void (^FBPMediaConvertCompletion)(NSURL *_Nullable outputURL,
                                          NSError *_Nullable error);

#pragma mark - Converter

@interface FBPMediaConverter : NSObject

/// A VideoToolbox AV1 decompression-session probe. @c isExportable and
/// @c exportPresetsCompatibleWithAsset: are useless here: both say yes on a
/// device that cannot decode AV1. Cached, and safe from any thread.
@property (class, readonly) BOOL isAvailable;

/// Off the main thread: the first probe is slow and its first caller is not.
+ (void)prewarm;

/// Loads the asset's headers synchronously, so call it off the main thread.
+ (BOOL)canDecodeVideoAtURL:(nullable NSURL *)videoURL;

/// @param audioURL Nil for a silent video, which succeeds with a video-only MP4.
/// @param sourceBitRate The manifest bandwidth; a preset gives 89 MB, not 9.
+ (void)convertVideoURL:(nullable NSURL *)videoURL
               audioURL:(nullable NSURL *)audioURL
          sourceBitRate:(long long)sourceBitRate
              outputURL:(nullable NSURL *)outputURL
               progress:(nullable FBPMediaConvertProgress)progress
             completion:(FBPMediaConvertCompletion)completion;

+ (void)cancelAll;

@end

#pragma mark - Reporting

#ifdef __cplusplus
extern "C" {
#endif

typedef NS_ENUM(NSInteger, FBPConverterCodec) {
    FBPConverterCodecHEVC = 0,
    FBPConverterCodecH264,
};

extern FBPConverterCodec FBPMediaConversionCodec(void);

extern long long FBPConverterTargetBitRate(long long sourceBitsPerSecond,
                                           CGSize frameSize,
                                           float framesPerSecond);

extern long long FBPConverterTargetBitRateForCodec(long long sourceBitsPerSecond,
                                                   CGSize frameSize,
                                                   float framesPerSecond,
                                                   FBPConverterCodec codec);

/// Only accurate when bitrate and pixels come from one representation; 0 if not.
extern long long FBPConverterExpectedOutputBytes(long long sourceBitsPerSecond,
                                                 CGSize frameSize,
                                                 float framesPerSecond,
                                                 long long audioBitsPerSecond,
                                                 double durationSeconds);

/// Mirrors @c +isAvailable; keep in step. Plain C for a UIKit-free caller.
extern BOOL FBPMediaConversionIsAvailable(void);

extern void FBPMediaConversionPrewarm(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
