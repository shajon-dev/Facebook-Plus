// Lossless video + audio muxer: two single-track files in, one MP4 out.
//
// Why this exists. Facebook's DASH ladder keeps video and audio in *separate*
// files — confirmed by -_representationsForVideoTrack / -_representationsForAudioTrack
// and the per-track -representationsForTrack:, which hand up two disjoint
// quality lists. Each representation's <BaseURL> is one complete self-contained
// file, so the downloader can fetch a chosen video rendition and a chosen audio
// rendition with two ordinary GETs. What it cannot do is hand Photos two files:
// a saved video is one MP4 with both tracks in it. That last step is this file.
//
// It is a *stream copy*, never a transcode. The samples that come out of the
// downloaded files go into the output byte-identical: same codec, same
// resolution, same bitrate, same frames. See FBPMediaMuxer.m for how, and for
// why this is AVFoundation rather than the ~15 MB of statically linked FFmpeg
// the obvious reference implementation uses.
//
// Nothing in the tweak calls this yet — wiring it into the download flow is a
// separate change. The interface is fixed first so the DASH side can be written
// against it.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Errors

/// Domain of every error this muxer reports.
extern NSString *const FBPMediaMuxerErrorDomain;

/// Why a mux failed.
///
/// These are deliberately fine-grained: both inputs are files we just pulled
/// off a CDN, so "it didn't work" covers an expired signed URL that returned an
/// HTML error body, a connection that dropped mid-file, and a representation
/// that turned out not to contain the track we picked it for. The caller shows
/// different text for those, so it has to be able to tell them apart.
typedef NS_ENUM(NSInteger, FBPMediaMuxerError) {
    /// A nil URL, or an output path we were never going to be able to write.
    FBPMediaMuxerErrorBadArguments = 1,
    /// AVFoundation cannot read the video file at all — a truncated download,
    /// or an HTML/JSON error body saved under an .mp4 name.
    FBPMediaMuxerErrorVideoUnreadable,
    /// Same, for the audio file.
    FBPMediaMuxerErrorAudioUnreadable,
    /// The video file is readable but has no video track.
    FBPMediaMuxerErrorNoVideoTrack,
    /// The audio file is readable but has no audio track.
    FBPMediaMuxerErrorNoAudioTrack,
    /// A track exists but carries no CMFormatDescription, so there is no
    /// sourceFormatHint to pass through with. Without one, passthrough into an
    /// MP4 is not permitted at all (AVAssetWriter.h:276).
    FBPMediaMuxerErrorMissingFormatDescription,
    /// AVAssetReader / AVAssetWriter would not start, or refused an input.
    FBPMediaMuxerErrorSetupFailed,
    /// A reader failed partway through — the usual signature of a file that was
    /// cut short while downloading.
    FBPMediaMuxerErrorReadFailed,
    /// The writer rejected a sample, or could not finalize the file.
    FBPMediaMuxerErrorWriteFailed,
    /// A track yielded zero samples: its container headers promise media the
    /// file does not actually contain.
    FBPMediaMuxerErrorNoSamples,
    /// -cancelAll was called while this mux was in flight.
    FBPMediaMuxerErrorCancelled,
};

#pragma mark - Muxer

/// Called once, on the main queue.
///
/// On success @c outputURL is the finished file and @c error is nil. On failure
/// @c outputURL is nil, @c error says why, and nothing is left at the output
/// path. The input files are never touched either way — deleting those is the
/// caller's business, since only the caller knows whether it wants to retry.
typedef void (^FBPMediaMuxCompletion)(NSURL *_Nullable outputURL,
                                      NSError *_Nullable error);

@interface FBPMediaMuxer : NSObject

/// Combine a video-only file and an audio-only file into one MP4, without
/// re-encoding either.
///
/// Returns immediately; every expensive step (reading the asset's headers,
/// copying samples, finalizing the file) happens off the main thread. The
/// completion runs on the main queue exactly once.
///
/// @param videoURL  A local file containing at least one video track. Audio in
///   this file is ignored.
/// @param audioURL  A local file containing at least one audio track. Video in
///   this file is ignored.
/// @param outputURL Where to write. Any existing file there is replaced; on
///   failure the partial file is deleted rather than left behind for Photos to
///   choke on.
+ (void)muxVideoURL:(NSURL *)videoURL
           audioURL:(NSURL *)audioURL
          outputURL:(NSURL *)outputURL
         completion:(FBPMediaMuxCompletion)completion;

/// Abandon every mux currently in flight.
///
/// Each one's completion still fires, with @c FBPMediaMuxerErrorCancelled and no
/// file left behind. For the download flow this is the "user backed out of the
/// save" path: a 1080p mux is tens of megabytes of I/O and there is no reason to
/// finish it once nobody is waiting for the result.
+ (void)cancelAll;

@end

NS_ASSUME_NONNULL_END
