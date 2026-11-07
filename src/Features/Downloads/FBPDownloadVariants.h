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
//     this tier alone can only ever offer two rows.
//   * DASH — the representations listed in the MPD that -DashPlaylist inlines on
//     the playback item, read by FBPDashManifest. This is where 360p, 480p,
//     1080p and anything above it live. Video and audio are separate
//     representations there, so such a variant carries two URLs (see -audioURL)
//     and has to be muxed into one file after both are fetched.
//
// A DASH variant's byte size is an estimate (bandwidth x duration), never an
// exact length, and its detail string says so.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

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

/// Already-localized row title, e.g. "High quality".
@property (nonatomic, copy, readonly) NSString *title;

/// Already-localized row detail, e.g. "1080p · 12.4 MB". Nil when neither a
/// resolution nor a size is known.
@property (nonatomic, copy, readonly, nullable) NSString *detail;

/// The rung this rendition sits on: the number in Facebook's own FBQualityLabel
/// for a DASH variant, and the shorter frame edge for a progressive one (so a
/// portrait 720x1280 stream reads 720, not 1280). Also the key the two tiers are
/// deduped against each other on. 0 when Facebook never told us.
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
/// Both tiers are resolved here. The spherical pair, when the item is a 360°
/// video, stays pinned to the front — for those the spherical streams *are* the
/// content. Everything else is ranked by height, highest first, with the
/// progressive stream winning any height the DASH ladder also offers (it needs
/// no muxing and its size is exact). Rows whose height Facebook never told us —
/// the SD progressive stream when HD exists — go last, since we cannot claim a
/// rank for them.
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
/// the best variant that does *not* need muxing is chosen, so a caller that
/// only knows how to GET one URL is never silently handed a video-only DASH
/// rung; with the picker off the result is the progressive stream, exactly as
/// before the DASH tier existed.
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
