// VP9 -> HEVC (H.264 fallback) conversion, so a VP9 rung can be saved to Photos.
//
// The sibling of FBPMediaConverter, for the one codec AVFoundation cannot
// decode at all: VideoToolbox has no VP9 decoder on any Apple device, so `vp09`
// returns kVTCouldNotFindVideoDecoderErr. The decode front-end is therefore
// FBPVP9Decoder (Facebook's own borrowed libavcodec), while the container is
// still demuxed by an AVAssetReader with nil output settings, which hands up the
// compressed access units without decoding them.
//
// Safety: the first decoded frame's size is cross-checked against the track's
// natural size before a pixel is copied; a mismatch marks the tier unhealthy
// (FBPVP9BridgeMarkUnhealthy) and fails this conversion rather than trusting the
// decode.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FBPVP9Converter : NSObject

/// Same contract as @c +[FBPMediaConverter convertVideoURL:…]: returns
/// immediately, does everything off the main thread, calls @c completion once on
/// the main queue. On failure (cancellation included) @c outputURL is nil and
/// nothing is left at the output path. Errors use @c FBPMediaConverterErrorDomain
/// so the download flow's existing cancellation check and messaging work
/// unchanged.
+ (void)convertVideoURL:(nullable NSURL *)videoURL
               audioURL:(nullable NSURL *)audioURL
          sourceBitRate:(long long)sourceBitRate
              outputURL:(nullable NSURL *)outputURL
               progress:(nullable void (^)(float fraction))progress
             completion:(void (^)(NSURL *_Nullable outputURL,
                                  NSError *_Nullable error))completion;

/// Abandon every VP9 conversion in flight; each completion still fires with
/// @c FBPMediaConverterErrorCancelled and no file left behind.
+ (void)cancelAll;

@end

NS_ASSUME_NONNULL_END
