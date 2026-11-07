// Two-stream download: fetch a DASH video rung and its audio, mux them, hand
// back one file.
//
// Why this is its own unit. A progressive variant is one GET and one file, and
// both download surfaces already know how to do that. A DASH variant is two
// GETs, a merge, three temporary files and four distinguishable ways to fail —
// and *both* surfaces (Reels, Stories) offer DASH rungs. Putting that in either
// .xm would mean writing it twice.
//
// Deliberately free of UIKit. Everything here is Foundation plus FBPMediaMuxer,
// which is what lets the whole flow — the progress weighting, the temp-file
// lifecycle, the failure matrix — be compiled and run on a host machine against
// a local HTTP server instead of only on a device.
//
// What it does *not* do: it never touches Photos. The caller is handed a
// finished file and saves it through whatever path it already uses, so a DASH
// download lands in exactly the same place, with the same name and the same
// album behaviour, as a single-URL one.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Errors

/// Domain of every error this class reports.
extern NSString *const FBPDashDownloadErrorDomain;

/// The HTTP status, as an NSNumber, in the userInfo of the two …HTTP errors.
extern NSString *const FBPDashDownloadStatusCodeKey;

/// Why a two-stream download failed.
///
/// The video and audio cases are separate on purpose: "it didn't work" is not
/// something a user can act on, but "the audio stream came back 403" is the
/// expired-signed-URL case, which tapping download again fixes. The underlying
/// NSURLSession / FBPMediaMuxer error is carried in @c NSUnderlyingErrorKey.
typedef NS_ENUM(NSInteger, FBPDashDownloadError) {
    /// A nil URL, a non-http(s) URL, or an output path we could not prepare.
    FBPDashDownloadErrorBadArguments = 1,
    /// The video stream answered with a non-2xx status. 403 is the expiry case.
    FBPDashDownloadErrorVideoHTTP,
    /// Same, for the audio stream.
    FBPDashDownloadErrorAudioHTTP,
    /// The video transfer failed outright — no response, or a dropped
    /// connection.
    FBPDashDownloadErrorVideoTransport,
    /// Same, for the audio stream.
    FBPDashDownloadErrorAudioTransport,
    /// A downloaded stream could not be moved out of NSURLSession's scratch
    /// location into our own temporary directory.
    FBPDashDownloadErrorTemporaryFile,
    /// Both streams arrived but FBPMediaMuxer refused them. The muxer's own
    /// error — which distinguishes an unreadable input from a missing track —
    /// is the underlying error.
    FBPDashDownloadErrorMux,
    /// The streams arrived but FBPMediaConverter could not turn the picture into
    /// H.264. Separate from @c FBPDashDownloadErrorMux because the two are
    /// different conversations with the user: a merge failing points at the
    /// download, while a conversion failing usually points at the device —
    /// FBPMediaConverterErrorNoConversionPath means this iPhone has no AV1
    /// decoder at all, which no amount of tapping again will fix. The
    /// converter's own error is the underlying error.
    FBPDashDownloadErrorConvert,
    /// -cancel was called before the output file was handed over.
    FBPDashDownloadErrorCancelled,
};

#pragma mark - Progress

/// Which step the flow is on.
///
/// The two are reported separately because they are not the same wait: fetching
/// is bounded by the network and has a real fraction, merging is bounded by
/// local I/O and has none. A caller that collapsed them would be showing a bar
/// that sat still at 100% for the length of a 1080p merge.
typedef NS_ENUM(NSInteger, FBPDashDownloadStage) {
    /// Both streams are in flight. @c fraction is the combined download
    /// progress, scaled so it stops short of 1.0 — the remainder belongs to the
    /// merge.
    FBPDashDownloadStageFetching = 1,
    /// Both streams are down and FBPMediaMuxer is running. @c fraction holds
    /// wherever fetching left off and does not advance: the muxer reports no
    /// intermediate progress, and inventing one would be a lie. The stage
    /// change is the signal; show it.
    FBPDashDownloadStageMerging,
    /// Both streams are down and FBPMediaConverter is re-encoding the picture to
    /// H.264. @c fraction *does* advance here, because this step has real
    /// progress to report — frames encoded against the source's own duration —
    /// and it is far too long to leave a bar sitting still through.
    ///
    /// Reached instead of @c FBPDashDownloadStageMerging, never after it: the
    /// conversion merges in the same pass. A flow goes through one or the other.
    FBPDashDownloadStageConverting,
};

/// Called on the main queue, at most once per whole percentage point.
typedef void (^FBPDashDownloadProgress)(FBPDashDownloadStage stage, float fraction);

/// Called on the main queue, exactly once.
///
/// On success @c outputURL is the finished MP4 and @c error is nil; the file is
/// the caller's to save and then delete, exactly as with a single-URL download.
/// On failure — including cancellation — @c outputURL is nil and nothing is left
/// anywhere: both downloaded streams and any partial merge output are gone by
/// the time this runs.
typedef void (^FBPDashDownloadCompletion)(NSURL *_Nullable outputURL,
                                          NSError *_Nullable error);

#pragma mark - Download

@interface FBPDashDownload : NSObject

/// Fetch both representations concurrently, merge them, and report the result.
///
/// Returns immediately, holding itself alive until the completion has fired, so
/// the caller does not have to park it in a global. Returns nil, without calling
/// anything, only when @c completion is nil — every other bad argument is
/// reported through @c completion like any other failure, so a caller has one
/// error path rather than two.
///
/// @param videoURL  A DASH video representation's @c <BaseURL>. One complete
///   self-contained file, so a plain unranged GET is the whole story — Facebook's
///   manifests carry @c SegmentBase index ranges, but the file they index is
///   already there in full.
/// @param audioURL  The matching audio representation. Must differ from
///   @c videoURL. Nil for a silent video, whose manifest lists no audio at all:
///   the flow then fetches one stream and the output has one track, which is a
///   success rather than something to refuse.
/// @param outputURL Where the merged MP4 goes. The caller chooses it so the
///   saved asset keeps the filename its single-URL counterpart would have had.
+ (nullable instancetype)startWithVideoURL:(nullable NSURL *)videoURL
                                  audioURL:(nullable NSURL *)audioURL
                                 outputURL:(nullable NSURL *)outputURL
                                  progress:(nullable FBPDashDownloadProgress)progress
                                completion:(FBPDashDownloadCompletion)completion;

/// As above, but re-encode the picture to H.264 instead of copying it.
///
/// For an AV1 rung, which Photos refuses as-is. The conversion replaces the
/// merge rather than following it — FBPMediaConverter writes both tracks in one
/// pass — so a converting flow never reports
/// @c FBPDashDownloadStageMerging.
///
/// @param convertVideo NO behaves exactly like the method above, so there is one
///   flow to reason about rather than two.
/// @param sourceBitRate The chosen representation's own @c bandwidth from the
///   manifest, in bits per second, or 0 when it stated none. The output bitrate
///   is derived from it; see FBPMediaConverter.m for the measurements that make
///   this the number that matters.
+ (nullable instancetype)startWithVideoURL:(nullable NSURL *)videoURL
                                  audioURL:(nullable NSURL *)audioURL
                                 outputURL:(nullable NSURL *)outputURL
                              convertVideo:(BOOL)convertVideo
                             sourceBitRate:(long long)sourceBitRate
                                  progress:(nullable FBPDashDownloadProgress)progress
                                completion:(FBPDashDownloadCompletion)completion;

/// Abandon the flow.
///
/// Cancels both transfers if they are still running, and calls
/// @c +[FBPMediaMuxer cancelAll] or @c +[FBPMediaConverter cancelAll] if that
/// step has started. The completion still fires, with
/// @c FBPDashDownloadErrorCancelled, once everything is cleaned up. Calling this
/// after the completion has run does nothing.
///
/// Cancelling a conversion matters far more than cancelling a merge: it stops
/// the encoder within one frame, rather than letting minutes of work finish for
/// a file nobody will save.
- (void)cancel;

/// NO until the completion has fired. Read from the main queue.
@property (nonatomic, assign, readonly) BOOL finished;

@end

#pragma mark - Reporting

#ifdef __cplusplus
extern "C" {
#endif

/// A finished, localized sentence for an error this class reported.
///
/// Returns nil for a cancellation — the user asked for the download to stop, and
/// telling them it stopped is noise — and nil for a nil error, so a caller can
/// write `NSString *message = FBPDashDownloadMessageForError(error); if
/// (message) …` on every path.
///
/// Lives beside the flow rather than in either downloader because both surfaces
/// have to say the same things about the same ways this can go wrong: the
/// picture stream failed, the audio stream failed, the merge failed. A 403 on
/// either stream is folded into the existing expired-link wording, which is the
/// one failure the user can actually fix.
extern NSString *_Nullable FBPDashDownloadMessageForError(NSError *_Nullable error);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
