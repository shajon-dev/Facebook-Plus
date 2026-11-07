// Shared download-variant model, resolver, quality picker and DASH diagnostic.
//
// Both download surfaces (Reels — FBPReelsDownloader.xm, Stories —
// FBPStoryDownloader.xm) reach the same object, FBVideoPlaybackItem, through
// their own route: Reels via the playbackController argument of
// -didStartPlaybackForVideo:…, Stories via
// FBSnacksVideoManager.videoPlaybackController -> -currentVideoPlaybackItem.
// Everything that turns that item into "what can we download, and how big is
// it" lives here, so a new format only has to be taught to one file.
//
// Two tiers of variant come out of here.
//
//   * Progressive — Facebook's -HDPlaybackURL / -SDPlaybackURL (and the
//     spherical pair). Each is one complete MP4 with audio already muxed in,
//     fetched with a single GET, and its byte length is published exactly as
//     -atomSize. On real content -HDPlaybackURL tops out at 720p, which is why
//     this tier alone can only ever offer two rows — and why it can only call
//     them "HD" and "SD": the one resolution Facebook publishes per item is the
//     source upload's, not either rendition's.
//   * DASH — the representations listed in the MPD that -DashPlaylist inlines on
//     the playback item, read by FBPDashManifest. This is where 360p, 480p,
//     1080p and anything above it live, each naming itself from Facebook's own
//     FBQualityLabel. Video and audio are separate representations there, so
//     such a variant carries two URLs (see -audioURL) and has to be muxed into
//     one file after both are fetched.
//
// The two tiers do not mix in one picker. Every row the user sees is a
// resolution, so when a usable ladder is there it is the whole list and the
// progressive pair is dropped — it covers the same ground and cannot name
// itself as precisely. The pair is what is offered when there is no ladder.
//
// A DASH variant's byte size is an estimate, never an exact length, and its
// detail string marks it with a "~". Two numbers hide behind it and they are not
// the same: `byteSize` is what the *download* costs (bandwidth x duration),
// which is what the progress bar is weighted by; the row's `detail` is what the
// saved *file* will be, which for a rung that has to be re-encoded is the
// converter's predicted output and not the download at all.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Which of the two tiers above a rendition came from.
///
/// @c needsMux is not a substitute: a silent video's DASH rungs have no audio
/// representation to pair, so they need no merge while still being DASH rows
/// whose size is an estimate. The picker shows the two facts separately because
/// they are separate — one is "how big is it, really", the other is "is there a
/// step that can fail".
typedef NS_ENUM(NSInteger, FBPDownloadVariantTier) {
    /// -HDPlaybackURL / -SDPlaybackURL: one muxed MP4, exact @c byteSize.
    FBPDownloadVariantTierProgressive = 0,
    /// The spherical pair on a 360° video. For those this *is* the content.
    FBPDownloadVariantTierSpherical,
    /// A representation from the MPD. @c byteSize is bandwidth x duration.
    FBPDownloadVariantTierDash,
};

/// One downloadable rendition of a video.
///
/// `pixelHeight`, `bitRate` and `byteSize` are 0 when Facebook did not give us
/// that number — they are presentation sugar, never a precondition for the
/// download itself.
@interface FBPDownloadVariant : NSObject

/// The video file to GET. Always non-nil for a variant that exists.
///
/// A complete muxed MP4 for a progressive variant; a video-only DASH
/// representation when @c audioURL is set.
@property (nonatomic, copy, readonly) NSURL *url;

/// The separate audio file to GET alongside @c url, or nil.
///
/// Nil for every progressive variant — those are already muxed, so there is
/// nothing to pair. Non-nil for a DASH variant, where Facebook serves video and
/// audio as separate representations: both files have to be fetched and then
/// muxed into one (FBPMediaMuxer) before the result is worth saving. Saving
/// @c url on its own when this is set would write a silent video.
@property (nonatomic, copy, readonly, nullable) NSURL *audioURL;

/// @c audioURL != nil. A variant that cannot be saved by downloading one URL.
@property (nonatomic, assign, readonly) BOOL needsMux;

/// This rung is AV1, so the picture has to be re-encoded — to HEVC, or H.264
/// where this device cannot encode HEVC — before Photos will accept it
/// (FBPMediaConverter) rather than copied (FBPMediaMuxer).
///
/// Only ever YES where the device can decode AV1 — the DASH reader refuses AV1
/// rungs outright where it cannot — so a downloader can treat this as "convert
/// it", never as "find out whether conversion is possible".
///
/// A converting variant is strictly more expensive than any other: minutes of
/// encoding, a battery cost, and an output about twice the size of the source.
/// The ladder already ranks an H.264 rung ahead of an AV1 one at the same label,
/// and the no-picker path below prefers a variant that needs neither a merge nor
/// a conversion, so this is normally reached only when the whole ladder is AV1 —
/// which, on real Meta content, it usually is.
@property (nonatomic, assign, readonly) BOOL needsConversion;

/// Which tier this rendition came from. Presentation only — the download path
/// branches on @c needsMux, not on this.
@property (nonatomic, assign, readonly) FBPDownloadVariantTier tier;

/// The row's first line, and the whole of the decision: a resolution, e.g.
/// "1080p", for every DASH rung. "HD" / "SD" for the two progressive renditions,
/// which Facebook publishes no per-rendition resolution for and so must not
/// claim one; "360° HD" / "360° SD" for the spherical pair. Already localized.
@property (nonatomic, copy, readonly) NSString *title;

/// The row's second line: how big the saved file will be, and nothing else —
/// "12.4 MB" for an exact progressive size, "~12.4 MB" for a DASH estimate. Nil
/// when no size is known, and then the row shows its resolution alone.
///
/// For a rung with @c needsConversion this is the *post-conversion* size, which
/// is roughly twice @c byteSize. The two are deliberately different numbers: one
/// is what the user waits for, the other is what ends up in Photos.
@property (nonatomic, copy, readonly, nullable) NSString *detail;

/// The rung this rendition sits on: the number in Facebook's own FBQualityLabel
/// for a DASH variant. 0 for every other variant — a progressive or spherical
/// row sits on no rung and must claim none, which is the whole of the fix in
/// 09c3120 and above.
///
/// Deliberately not the pixel height, despite the name, which predates the DASH
/// tier: Facebook encodes several rungs per resolution — 480p, 540p, 640p and
/// 720p are all 1280x720 in a real feed manifest — so pixel height does not
/// identify a quality.
@property (nonatomic, assign, readonly) NSInteger pixelHeight;
@property (nonatomic, assign, readonly) long long bitRate;
/// Bytes. Exact for a progressive variant (straight from -atomSize /
/// -hdAtomSize, so the picker can promise a real size before a single byte is
/// fetched); an estimate from bandwidth x duration for a DASH variant, which is
/// why those rows show it with a "~".
@property (nonatomic, assign, readonly) long long byteSize;

@end

/// Everything one download tap needs, resolved from a playback controller.
@interface FBPDownloadSource : NSObject

/// The FBVideoPlaybackItem the variants came from. Held only for the lifetime of
/// the tap (the diagnostic reads the MPD off it); never parked in a global.
@property (nonatomic, strong, readonly, nullable) id item;
@property (nonatomic, strong, readonly, nullable) id playbackController;
@property (nonatomic, copy, readonly, nullable) NSString *videoID;
/// Best first. Empty when nothing downloadable was found.
@property (nonatomic, copy, readonly) NSArray<FBPDownloadVariant *> *variants;

/// Facebook's own @c -title for the item, when it has one and it is a string.
///
/// Nil is the normal case — most Reels carry no title — and it is presentation
/// only: the download manager labels a row with it instead of a bare "Reel".
/// Capped in length so a caption-as-title cannot turn into a wall of text.
@property (nonatomic, copy, readonly, nullable) NSString *mediaTitle;

/// The item's @c -firstFrameThumbnailURL, when it has one.
///
/// A poster frame the download manager can load for its row. Never fetched
/// here; this is only the URL, and a build that renamed the getter simply has
/// none, which is why no row depends on it.
@property (nonatomic, copy, readonly, nullable) NSURL *thumbnailURL;

@end

#ifdef __cplusplus
extern "C" {
#endif

/// Guarded zero-argument, object-returning getter: checks the selector exists,
/// takes no arguments and returns an object before any objc_msgSend.
extern id _Nullable FBPDownloadSafeObjectGetter(id _Nullable object,
                                                NSString *getterName);

/// Ordered, best-first variants for an FBVideoPlaybackItem, plus its video id.
///
/// Replaces the old `hdURL ?: sdURL` collapse: capture now keeps every
/// rendition, and the choice is made later, by the user.
///
/// Both tiers are resolved here, but only one of them reaches the list. The
/// spherical pair, when the item is a 360° video, stays pinned to the front —
/// for those the spherical streams *are* the content. After it comes the DASH
/// ladder, ranked by FBQualityLabel, highest first, one row per rung. The
/// progressive pair takes its place only when there is no usable ladder: no MPD
/// on the item, a renamed getter, audio listed but refused, or nothing that
/// survived FBPDashManifest's gates.
///
/// Reads -DashPlaylist and parses it on every call. That is deliberate: the
/// <BaseURL>s inside carry the same short-lived `oe=` signature as every other
/// Facebook media URL, so a cached ladder is a ladder of dead links.
extern NSArray<FBPDownloadVariant *> *
FBPDownloadVariantsForItem(id _Nullable item,
                           NSString *_Nullable *_Nullable videoIDOut);

/// Resolve a whole tap context from a playback controller (reads
/// -currentVideoPlaybackItem itself).
extern FBPDownloadSource *
FBPDownloadSourceFromPlaybackController(id _Nullable playbackController);

/// Re-reads the variants at the moment of the pick. Returns nil when a fresh
/// list cannot be obtained, in which case the picked variant is used as-is.
typedef NSArray<FBPDownloadVariant *> *_Nullable (^FBPDownloadVariantRefresher)(void);

/// Offer the variants and call @c chosen with the pick.
///
/// With a single variant — a photo story, a single-quality video, or the picker
/// preference turned off — no sheet is shown and @c chosen runs synchronously,
/// exactly as the downloaders behaved before the picker existed. On that path
/// the best variant that does *not* need muxing is preferred, so nothing is
/// downloaded more slowly than it has to be; when a DASH ladder is present every
/// row needs muxing and the best rung goes through as-is, which both callers can
/// now fetch and merge (FBPDashDownload).
///
/// @param refresh Optional. Facebook's media URLs are short-lived signed URLs
///   (they carry an @c oe= expiry and the app has FNFURLRefreshManager to renew
///   them), so a sheet left open while the user deliberates can outlive the URL
///   that was resolved to build it. When given, this is called on the pick and
///   the matching entry of the fresh list is preferred, so the download starts
///   from a URL resolved seconds ago rather than minutes ago. Matching is by
///   title, then by pixel height; an entry that no longer appears falls back to
///   the original. Not called at all on the no-sheet fast path, where the
///   variants were resolved in the same turn of the run loop.
extern void FBPDownloadPresentPicker(NSArray<FBPDownloadVariant *> *variants,
                                     UIViewController *_Nullable presenter,
                                     UIView *_Nullable sourceView,
                                     FBPDownloadVariantRefresher _Nullable refresh,
                                     void (^chosen)(FBPDownloadVariant *variant));

/// Build a one-entry variant list for media that has exactly one rendition
/// (photo stories), so those callers share the picker path without special
/// cases.
extern NSArray<FBPDownloadVariant *> *
FBPDownloadSingleVariant(NSURL *url, NSString *_Nullable title);

/// Record what Facebook is actually serving for this video, when the
/// "Log Download Qualities" diagnostic is on. A no-op — one relaxed atomic load
/// — when it is off.
extern void FBPDownloadLogQualities(id _Nullable item,
                                    id _Nullable playbackController,
                                    NSArray<FBPDownloadVariant *> *variants);

/// Seed the diagnostic's cached flag and keep it in step with the settings
/// panel. Called once from FBPInitReelsDownloader.
extern void FBPDownloadInstallDiagnostic(void);

/// Whether "Log Download Qualities" is on, as one relaxed atomic load.
///
/// Exposed so the rest of the download flow — FBPDashDownload, which records the
/// two streams' content types and byte counts and whether the merge worked — can
/// gate its own os_log calls on the same switch, kept in step by the same
/// notification, and stay just as free when it is off.
extern BOOL FBPDownloadQualityLoggingEnabled(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
