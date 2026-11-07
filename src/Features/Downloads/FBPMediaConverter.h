// AV1 -> H.264 conversion, so an AV1 quality rung can be saved to Photos.
//
// Why this exists, and why it is not FBPMediaMuxer
// ------------------------------------------------------------------------
// FBPMediaMuxer is a stream copy and must stay one: it is what makes a saved
// H.264 rung bit-identical to what Facebook served. But five of six captured
// Meta manifests are AV1-only, and an AV1 file — however correctly muxed — is
// refused by Photos. Measured on device (iPhone SE, A13, iOS 27.2), same muxer
// and same code path for both: a remuxed `av01.0.08M.08` + `mp4a` file comes
// back from `PHAssetCreationRequest` with `PHPhotosErrorDomain` 3302
// (`PHPhotosErrorInvalidResource`), while a remuxed `avc1.4d001e` + `mp4a` file
// saves and returns an identifier. `AVAssetWriter` itself passes AV1 through
// perfectly well — ffprobe reads `av1 + aac` off the output — so the wall is
// Photos, not the muxer.
//
// So offering the real ladder means re-encoding the picture to H.264 before the
// save. That is this file. It sits *beside* the muxer rather than inside it,
// because the two are opposite promises: one guarantees nothing changed, the
// other necessarily changes everything.
//
// One pass, not two
// ------------------------------------------------------------------------
// The obvious shape — mux first, then transcode the muxed file — is what the
// rival tweak does, and it writes the whole video to disk twice. This takes the
// two downloaded streams directly and produces the finished MP4 in one pass:
// one AVAssetWriter with two inputs, where the video input re-encodes and the
// audio input is the same passthrough the muxer uses. Facebook's audio is
// already AAC (HE-AAC v1, mp4a.40.5), which is exactly what an MP4 wants, so
// re-encoding it would cost quality for nothing.
//
// No third-party library, and no shipped bytes
// ------------------------------------------------------------------------
// Decoding is AVFoundation's (which is VideoToolbox's), encoding is
// VideoToolbox's by way of AVAssetWriter. The rival statically links ~15 MB of
// FFmpeg to reach `h264_videotoolbox`, which is itself only a thin wrapper
// around the encoder we are calling directly. This project ships no ffmpeg and
// should keep shipping none.
//
// Two tiers, and only one of them is live
// ------------------------------------------------------------------------
// Tier 1, implemented here, is AVFoundation-native: on a device whose
// VideoToolbox can decode AV1, `AVAssetReader` hands up decoded pixel buffers
// and `AVAssetWriter` re-encodes them to H.264.
//
// Tier 2 would borrow the dav1d that `FBSharedFramework` already exports, for
// devices with no AV1 decoder of their own. It is **not live** — see
// FBPDav1dBridge.h, which records the measurement that stopped it. Tier 1 alone
// covers every device that has an AV1 decoder, which is the population that can
// play these videos in the first place.
//
// What a caller must do with a conversion
// ------------------------------------------------------------------------
// Treat it as a separate, slow, battery-hungry stage, not as a slower mux. A
// 127-second 1080p rung is minutes of sustained encoding on older hardware. It
// reports real per-frame progress and honours cancellation between frames, and
// a caller that shows neither is misusing it.
//
// It is also *lossy and bigger*. The output is a re-encode, and because AV1 is
// roughly twice as efficient as H.264 at equal quality, an honest H.264 version
// of a Meta AV1 rung is several times the source's byte size. A picker that
// shows the rung's download size must not present it as the size of what lands
// in Photos. See FBPDownloadVariants.m, where such a row shows no size at all.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Errors

/// Domain of every error this converter reports.
extern NSString *const FBPMediaConverterErrorDomain;

/// Why a conversion failed.
///
/// Kept as fine-grained as the muxer's, and for the same reason: both inputs are
/// files just pulled off a CDN, so a truncated download, an HTML error body
/// saved under an .mp4 name, and a device that simply has no AV1 decoder all
/// have to be tellable apart by the caller that writes the user-facing sentence.
typedef NS_ENUM(NSInteger, FBPMediaConverterError) {
    /// A nil video URL, or an output path we were never going to be able to
    /// write.
    FBPMediaConverterErrorBadArguments = 1,
    /// This device has no way to decode the source at all — no VideoToolbox
    /// decoder for the codec, and no live borrowed-decoder tier. Distinct from
    /// the next case: this one is about the device, not about the file.
    FBPMediaConverterErrorNoConversionPath,
    /// A decoder exists, but AVFoundation will not decode *this* asset: the
    /// honest per-file probe (-canDecodeVideoAtURL:) said no.
    FBPMediaConverterErrorVideoUndecodable,
    /// AVFoundation cannot read the video file at all — a truncated download, or
    /// an HTML/JSON error body under an .mp4 name.
    FBPMediaConverterErrorVideoUnreadable,
    /// Same, for the audio file.
    FBPMediaConverterErrorAudioUnreadable,
    /// The video file is readable but has no video track.
    FBPMediaConverterErrorNoVideoTrack,
    /// The audio file is readable but has no audio track.
    FBPMediaConverterErrorNoAudioTrack,
    /// An audio track exists but carries no CMFormatDescription, so there is no
    /// sourceFormatHint to pass it through with.
    FBPMediaConverterErrorMissingFormatDescription,
    /// AVAssetReader / AVAssetWriter would not start, or refused an input — the
    /// encoder settings among them.
    FBPMediaConverterErrorSetupFailed,
    /// A reader failed partway through: the usual signature of a file cut short
    /// while downloading.
    FBPMediaConverterErrorReadFailed,
    /// The encoder rejected a frame, or the file could not be finalized.
    FBPMediaConverterErrorWriteFailed,
    /// A track yielded zero samples: its headers promise media the file does not
    /// contain.
    FBPMediaConverterErrorNoSamples,
    /// -cancelAll was called while this conversion was in flight.
    FBPMediaConverterErrorCancelled,
};

#pragma mark - Progress and completion

/// 0…1, on the main queue, at most once per whole percentage point.
///
/// Unlike the muxer — which reports nothing, because a stream copy of a 40 MB
/// file is over before a bar could move — this is a real fraction of real work:
/// frames encoded over frames expected. It is the only honest progress in the
/// download flow that is not a byte count.
typedef void (^FBPMediaConvertProgress)(float fraction);

/// Called once, on the main queue.
///
/// On success @c outputURL is the finished H.264 + AAC MP4 and @c error is nil.
/// On failure — cancellation included — @c outputURL is nil, @c error says why,
/// and nothing is left at the output path. The input files are never touched
/// either way.
typedef void (^FBPMediaConvertCompletion)(NSURL *_Nullable outputURL,
                                          NSError *_Nullable error);

#pragma mark - Converter

@interface FBPMediaConverter : NSObject

/// Can this device convert AV1 at all?
///
/// A real capability query, not a device-model guess and not a guess from the
/// file. It asks VideoToolbox for an AV1 decompression session and reads the
/// status: @c kVTCouldNotFindVideoDecoderErr means there is no AV1 decoder on
/// this device, anything else means there is one. Measured both ways —
/// A13/iOS 18.6.1 answers @c kVTCouldNotFindVideoDecoderErr for @c av01 and
/// @c vp09 but not for @c avc1 or @c hvc1; an Apple-silicon Mac answers it for
/// @c vp09 only. See FBPMediaConverter.m for why the obvious alternatives
/// (@c isExportable, @c exportPresetsCompatibleWithAsset:) are useless here:
/// both say yes on a device that cannot decode AV1 at all.
///
/// Cached after the first call — the answer cannot change within a process — and
/// safe from any thread. The first call costs a VideoToolbox round trip, which
/// is why @c +prewarm exists.
@property (class, readonly) BOOL isAvailable;

/// Work out @c isAvailable now, off the main thread, so nothing later has to
/// wait for it.
///
/// Measured at **46 ms** for the first call on an Apple-silicon Mac — creating a
/// decompression session is not free, even a failing one. That is three dropped
/// frames, and the natural first caller is the DASH reader running on the main
/// thread during a download tap, so without this the first download of a session
/// gets a visible hitch. Cheap and idempotent: after the answer is cached this
/// does nothing at all.
+ (void)prewarm;

/// Will AVFoundation decode *this* file?
///
/// @c AVURLAsset.isPlayable, which is the one property that answers the question
/// honestly. Synchronous: it loads the asset's headers, so call it off the main
/// thread. A nil or unreadable URL is NO.
///
/// This is the authority, and @c isAvailable is only the cheap gate that decides
/// whether to offer the rung before a byte has been fetched.
+ (BOOL)canDecodeVideoAtURL:(nullable NSURL *)videoURL;

/// Re-encode a video file to H.264 and pair it with an audio file, in one pass.
///
/// Returns immediately; everything expensive happens off the main thread, and
/// @c completion runs on the main queue exactly once.
///
/// @param videoURL A local file with at least one video track, in any codec this
///   device can decode. Audio in this file is ignored.
/// @param audioURL A local file with at least one audio track, passed through
///   without re-encoding. Nil for a silent video, which is a success and
///   produces a video-only MP4 — not an error, and not a reason to refuse the
///   rung.
/// @param sourceBitRate The source representation's own bandwidth in bits per
///   second, from the manifest, or 0 when unknown. This is what the output
///   bitrate is derived from, and getting it from the manifest rather than from
///   a preset is the whole difference between an 11 MB output and an 89 MB one —
///   see FBPConverterTargetBitRate in the implementation, which has the
///   measurements.
/// @param outputURL Where to write. Anything already there is replaced; on
///   failure the partial file is deleted rather than left for Photos to choke
///   on.
+ (void)convertVideoURL:(nullable NSURL *)videoURL
               audioURL:(nullable NSURL *)audioURL
          sourceBitRate:(long long)sourceBitRate
              outputURL:(nullable NSURL *)outputURL
               progress:(nullable FBPMediaConvertProgress)progress
             completion:(FBPMediaConvertCompletion)completion;

/// Abandon every conversion in flight.
///
/// Each one's completion still fires, with @c FBPMediaConverterErrorCancelled
/// and no file left behind. This matters far more than it does for the muxer: a
/// conversion the user has walked away from is minutes of the encoder block
/// running flat out, so stopping promptly is a battery decision, not just
/// tidiness. Cancellation is noticed between frames.
+ (void)cancelAll;

@end

#pragma mark - Reporting

#ifdef __cplusplus
extern "C" {
#endif

/// The output bitrate this converter would choose, in bits per second.
///
/// Exposed so it can be swept against real fixtures on a host machine rather
/// than argued about — which is how the constants behind it were picked.
extern long long FBPConverterTargetBitRate(long long sourceBitsPerSecond,
                                           CGSize frameSize,
                                           float framesPerSecond);

/// Is an AV1 -> H.264 conversion path available in this process?
///
/// A plain C function, deliberately, because its one caller is
/// FBPDashManifest.m — which is UIKit-free and AVFoundation-free on purpose, so
/// the DASH reader can be compiled and exercised on a host machine. It declares
/// this @c extern rather than importing this header, exactly as it already does
/// for FBPLocalizedString. Same symbol as @c +isAvailable; keep them in step.
extern BOOL FBPMediaConversionIsAvailable(void);

/// Plain-C @c +prewarm, for the tweak's constructor — which is a .xm in
/// src/Core and has no business importing AVFoundation either.
extern void FBPMediaConversionPrewarm(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
