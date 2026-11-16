// VP9 -> HEVC (H.264 fallback) conversion, so a VP9 rung can be saved to Photos.
//
// The sibling of FBPMediaConverter, for the one codec AVFoundation cannot decode
// at all. It has the same shape — one AVAssetWriter, a re-encoding video input
// and a passthrough audio input, in one pass — but its decode front-end is
// FBPVP9Decoder (Facebook's own borrowed libavcodec) instead of an
// AVAssetReader, because VideoToolbox has no VP9 decoder on any Apple device
// (measured: `vp09` returns kVTCouldNotFindVideoDecoderErr on A13, Apple-silicon
// Mac, and there is no VP9 block on A18 Pro either).
//
// The container is still demuxed by AVFoundation: an AVAssetReader with nil
// output settings hands up the compressed VP9 access units (one MP4 sample is
// one VP9 superframe) without decoding them, which Apple's demuxer does reliably
// for a `vp09` track it will not play. Those bytes go to the borrowed decoder,
// the NV12 frames it returns go to the encoder, and the audio is passed through
// exactly as FBPMediaConverter and FBPMediaMuxer do.
//
// Why it is a separate file and does not touch FBPMediaConverter: that file's
// AV1 path is tested and must not regress, and the two front-ends share nothing
// (one reads decoded pixel buffers from an AVAssetReader, the other feeds a
// borrowed decoder). The encode maths ARE shared — this reuses
// FBPConverterTargetBitRateForCodec and FBPMediaConversionCodec so a VP9 save
// and an AV1 save produce the same bitrate for the same pixels.
//
// Safety: the first decoded frame's size is cross-checked against the track's
// own natural size before a pixel is copied; a mismatch means the borrowed
// build's layout is not the one assumed, so it marks the tier unhealthy
// (FBPVP9BridgeMarkUnhealthy) and fails this conversion cleanly rather than
// trusting the decode. The VP9 rung is only ever offered when
// FBPVP9ConversionIsAvailable() is YES.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FBPVP9Converter : NSObject

/// Same contract as @c +[FBPMediaConverter convertVideoURL:…]: returns
/// immediately, does everything off the main thread, calls @c completion once on
/// the main queue. On success @c outputURL is the finished HEVC/H.264 + AAC MP4;
/// on failure (cancellation included) it is nil, @c error says why, and nothing
/// is left at the output path. Errors use @c FBPMediaConverterErrorDomain so the
/// download flow's existing cancellation check and messaging work unchanged.
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
