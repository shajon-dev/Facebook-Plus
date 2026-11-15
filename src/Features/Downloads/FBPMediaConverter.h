// AV1 -> HEVC conversion (H.264 where HEVC cannot be encoded), so an AV1 quality
// rung can be saved to Photos.
//
// Why this exists, and why it is not FBPMediaMuxer
// ------------------------------------------------------------------------
// FBPMediaMuxer is a stream copy and must stay one: it keeps a saved H.264 rung
// bit-identical to what Facebook served. But five of six captured Meta manifests
// are AV1-only, and an AV1 file — however correctly muxed — is refused by Photos.
// Measured on device (iPhone SE, A13, iOS 27.2), same muxer and code path for
// both: a remuxed `av01.0.08M.08` + `mp4a` file comes back from
// `PHAssetCreationRequest` with `PHPhotosErrorDomain` 3302
// (`PHPhotosErrorInvalidResource`), while a remuxed `avc1.4d001e` + `mp4a` file
// saves and returns an identifier. `AVAssetWriter` passes AV1 through fine —
// ffprobe reads `av1 + aac` off the output — so the wall is Photos, not the
// muxer.
//
// Offering the real ladder means re-encoding the picture before the save. That
// is this file. It sits beside the muxer, not inside it: the two are opposite
// promises, one that nothing changed and one that everything did.
//
// HEVC, not H.264
// ------------------------------------------------------------------------
// The target is HEVC, not an exotic choice for a Photos library: every iPhone
// since the A10 records HEVC by default, so most of what is already in Photos is
// this codec.
//
// What it buys is measured — see FBPConverterTargetBitRate for the full sweep.
// Converting the whole 127-second 1080x1920 AV1 fixture with each codec at its
// own measured multiplier, scored with VMAF against the decoded AV1 source:
//
//     H.264 at 3x source bandwidth   92.54 VMAF   14.36 MB
//     HEVC  at 2x source bandwidth   92.94 VMAF    9.98 MB
//
// Same picture, marginally better, for 30% fewer bytes. The multiplier is lower
// because the codec is more efficient, and it was re-swept, not inherited: 3x
// was fitted to H.264 and is the wrong number here.
//
// H.264 stays as the fallback, chosen at runtime from a VideoToolbox encoder
// probe, not a device-model check — see FBPMediaConversionCodec().
//
// One pass, not two
// ------------------------------------------------------------------------
// The obvious shape — mux first, then transcode the muxed file — writes the
// whole video to disk twice. This takes the two downloaded streams directly and
// produces the finished MP4 in one pass: one AVAssetWriter with two inputs, the
// video input re-encoding and the audio input the same passthrough the muxer
// uses. Facebook's audio is already AAC (HE-AAC v1, mp4a.40.5), exactly what an
// MP4 wants, so re-encoding would cost quality for nothing.
//
// No third-party library, and no shipped bytes
// ------------------------------------------------------------------------
// Decoding is AVFoundation's (VideoToolbox's), encoding is VideoToolbox's via
// AVAssetWriter. The obvious alternative statically links ~15 MB of FFmpeg to
// reach `hevc_videotoolbox`, itself a thin wrapper around the encoder called
// here directly. This project ships no ffmpeg and should keep shipping none.
//
// Two tiers, and only one of them is live
// ------------------------------------------------------------------------
// Tier 1, implemented here, is AVFoundation-native: on a device whose
// VideoToolbox can decode AV1, `AVAssetReader` hands up decoded pixel buffers
// and `AVAssetWriter` re-encodes them.
//
// Tier 2 would borrow the dav1d that `FBSharedFramework` already exports, for
// devices with no AV1 decoder. It is NOT live — see FBPDav1dBridge.h for the
// measurement that stopped it. Tier 1 alone covers every device with an AV1
// decoder, which is the population that can play these videos at all.
//
// What a caller must do with a conversion
// ------------------------------------------------------------------------
// Treat it as a separate, slow, battery-hungry stage, not a slower mux. A
// 127-second 1080p rung is minutes of sustained encoding on older hardware. It
// reports real per-frame progress and honours cancellation between frames; a
// caller that shows neither is misusing it.
//
// It is also lossy and bigger. The output is a re-encode, and because AV1 is
// more efficient than HEVC at equal quality, an HEVC version of a Meta AV1 rung
// is about twice the source's byte size. A picker must not present the rung's
// download size as the size of what lands in Photos — but it can state the right
// number, since the multiplier makes the output predictable.
// FBPConverterExpectedOutputBytes is that prediction, and FBPDownloadVariants.m
// puts it on the row.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Errors

/// Domain of every error this converter reports.
extern NSString *const FBPMediaConverterErrorDomain;

/// Why a conversion failed.
///
/// Fine-grained like the muxer's: both inputs are files just pulled off a CDN,
/// so a truncated download, an HTML error body under an .mp4 name, and a device
/// with no AV1 decoder must be tellable apart by the caller that writes the
/// user-facing sentence.
typedef NS_ENUM(NSInteger, FBPMediaConverterError) {
    /// A nil video URL, or an unwritable output path.
    FBPMediaConverterErrorBadArguments = 1,
    /// This device cannot decode the source: no VideoToolbox decoder for the
    /// codec, and no live borrowed-decoder tier. Distinct from the next case —
    /// this one is about the device, not the file.
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
/// Unlike the muxer (a stream copy is over before a bar could move), this is a
/// real fraction of work: frames encoded over frames expected. The only honest
/// progress in the download flow that is not a byte count.
typedef void (^FBPMediaConvertProgress)(float fraction);

/// Called once, on the main queue.
///
/// On success @c outputURL is the finished HEVC (or H.264) + AAC MP4 and
/// @c error is nil.
/// On failure — cancellation included — @c outputURL is nil, @c error says why,
/// and nothing is left at the output path. The input files are never touched
/// either way.
typedef void (^FBPMediaConvertCompletion)(NSURL *_Nullable outputURL,
                                          NSError *_Nullable error);

#pragma mark - Converter

@interface FBPMediaConverter : NSObject

/// Can this device convert AV1 at all?
///
/// A capability query, not a device-model or file guess. It asks VideoToolbox
/// for an AV1 decompression session and reads the status:
/// @c kVTCouldNotFindVideoDecoderErr means no AV1 decoder, anything else means
/// one exists. Measured both ways — A13/iOS 18.6.1 answers
/// @c kVTCouldNotFindVideoDecoderErr for @c av01 and @c vp09 but not @c avc1 or
/// @c hvc1; an Apple-silicon Mac answers it for @c vp09 only. See
/// FBPMediaConverter.m for why @c isExportable and
/// @c exportPresetsCompatibleWithAsset: are useless: both say yes on a device
/// that cannot decode AV1.
///
/// Cached after the first call and safe from any thread. The first call costs a
/// VideoToolbox round trip, which is why @c +prewarm exists.
///
/// Says nothing about which codec the conversion produces — that is
/// FBPMediaConversionCodec(), whose answer is never "none": H.264 is the floor.
@property (class, readonly) BOOL isAvailable;

/// Settle @c isAvailable and the encode codec now, off the main thread, so
/// nothing later waits for either.
///
/// Measured at 46 ms for the first call on an Apple-silicon Mac — creating a
/// decompression session, even a failing one, is not free. That is three dropped
/// frames, and the first caller is the DASH reader on the main thread during a
/// download tap, so without this the first download of a session hitches.
/// Idempotent: after the answer is cached this does nothing.
+ (void)prewarm;

/// Will AVFoundation decode *this* file?
///
/// @c AVURLAsset.isPlayable, the one property that answers honestly.
/// Synchronous: it loads the asset's headers, so call it off the main thread. A
/// nil or unreadable URL is NO.
///
/// The authority; @c isAvailable is only the cheap gate that decides whether to
/// offer the rung before a byte is fetched.
+ (BOOL)canDecodeVideoAtURL:(nullable NSURL *)videoURL;

/// Re-encode a video file to HEVC — H.264 where this device cannot encode HEVC
/// — and pair it with an audio file, in one pass.
///
/// Returns immediately; everything expensive happens off the main thread, and
/// @c completion runs on the main queue exactly once.
///
/// @param videoURL A local file with at least one video track, in any codec this
///   device can decode. Audio in this file is ignored.
/// @param audioURL A local file with at least one audio track, passed through
///   without re-encoding. Nil for a silent video, which succeeds and produces a
///   video-only MP4 — not an error, and not a reason to refuse the rung.
/// @param sourceBitRate The source representation's bandwidth in bits per
///   second, from the manifest, or 0 when unknown. The output bitrate derives
///   from this; taking it from the manifest rather than a preset is the
///   difference between a 9 MB output and an 89 MB one — see
///   FBPConverterTargetBitRate for the measurements.
/// @param outputURL Where to write. Anything already there is replaced; on
///   failure the partial file is deleted, not left for Photos to choke on.
+ (void)convertVideoURL:(nullable NSURL *)videoURL
               audioURL:(nullable NSURL *)audioURL
          sourceBitRate:(long long)sourceBitRate
              outputURL:(nullable NSURL *)outputURL
               progress:(nullable FBPMediaConvertProgress)progress
             completion:(FBPMediaConvertCompletion)completion;

/// Abandon every conversion in flight.
///
/// Each one's completion still fires, with @c FBPMediaConverterErrorCancelled
/// and no file left behind. Matters more than for the muxer: a conversion the
/// user walked away from is minutes of the encoder running flat out, so stopping
/// promptly is a battery decision. Cancellation is noticed between frames.
+ (void)cancelAll;

@end

#pragma mark - Reporting

#ifdef __cplusplus
extern "C" {
#endif

/// Which codec a conversion in this process produces.
///
/// Not a preference or setting: what this device's VideoToolbox will encode.
/// Both values are real outcomes, and every number derived from a conversion —
/// the target bitrate, and so a picker row's promised size — depends on which.
typedef NS_ENUM(NSInteger, FBPConverterCodec) {
    /// `hvc1` in an MP4. The normal answer on anything that can decode AV1 in
    /// the first place.
    FBPConverterCodecHEVC = 0,
    /// `avc1`. The fallback, for a device whose VideoToolbox has no HEVC
    /// encoder.
    FBPConverterCodecH264,
};

/// What this device will encode to.
///
/// A probe — @c VTCopySupportedPropertyDictionaryForEncoder asked for an HEVC
/// encoder, not a device-model or OS-version table. Cached after the first call
/// and safe from any thread; @c +prewarm settles it with the decoder probe.
extern FBPConverterCodec FBPMediaConversionCodec(void);

/// The output bitrate this converter chooses, in bits per second, for the codec
/// this device will use.
///
/// Exposed so it can be swept against real fixtures on a host machine — which is
/// how the constants behind it were picked.
extern long long FBPConverterTargetBitRate(long long sourceBitsPerSecond,
                                           CGSize frameSize,
                                           float framesPerSecond);

/// As above, for a named codec rather than this device's.
///
/// Only the sweep harness and tests need this; shipped code wants the function
/// above, since a row must predict what *this* phone produces.
extern long long FBPConverterTargetBitRateForCodec(long long sourceBitsPerSecond,
                                                   CGSize frameSize,
                                                   float framesPerSecond,
                                                   FBPConverterCodec codec);

/// Expected output bytes for converting a rung.
///
/// Lives next to the multiplier it derives from: the encoder is handed an
/// average bitrate, so the output is that bitrate plus the passed-through audio
/// over the clip's length. The number a picker row shows for a rung that will be
/// converted — the source's @c bandwidth x duration describes the download, not
/// the file that lands in Photos, and the two differ by the multiplier.
///
/// Checked, not trusted. Fourteen real rungs from five captured manifests were
/// fetched and converted, each with its own bandwidth, frame size and frame rate
/// (what a row is computed from); against the bytes produced this came out mean
/// 3.4% off, median 2.8%, worst 8.3%, nothing past 10%, biased +2.3% toward
/// under-predicting.
///
/// That accurate only because the bitrate and pixels come from the same
/// representation. A bandwidth that does not belong to the content gives
/// nonsense: the encoder cannot spend 5.9 Mbit/s on a clip Meta encodes at
/// 286 kbit/s, so it undershoots by two-thirds and the prediction runs far too
/// high. The picker does not do that, and a caller that would should not use
/// this.
///
/// 0 when there is not enough to go on, and the row then shows no size rather
/// than a guess.
///
/// @param sourceBitsPerSecond The rung's own @c bandwidth from the manifest.
/// @param frameSize The rung's frame size, or CGSizeZero when the manifest did
///   not state one.
/// @param framesPerSecond The rung's frame rate, or 0 when unstated.
/// @param audioBitsPerSecond The paired audio representation's @c bandwidth, or
///   0 for a silent video. Audio is passed through, so this reaches the output
///   unchanged.
/// @param durationSeconds The clip's length.
extern long long FBPConverterExpectedOutputBytes(long long sourceBitsPerSecond,
                                                 CGSize frameSize,
                                                 float framesPerSecond,
                                                 long long audioBitsPerSecond,
                                                 double durationSeconds);

/// Is an AV1 conversion path available in this process?
///
/// A plain C function because its one caller, FBPDashManifest.m, is UIKit-free
/// and AVFoundation-free so the DASH reader can be compiled and exercised on a
/// host machine. It declares this @c extern rather than importing this header,
/// as it does for FBPLocalizedString. Same symbol as @c +isAvailable; keep them
/// in step.
extern BOOL FBPMediaConversionIsAvailable(void);

/// Plain-C @c +prewarm, for the tweak's constructor — a .xm in src/Core that has
/// no business importing AVFoundation either.
extern void FBPMediaConversionPrewarm(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
