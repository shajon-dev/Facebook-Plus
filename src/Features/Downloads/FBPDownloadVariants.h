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
// Scope note: every variant produced here is a *progressive* MP4 — one complete
// file, audio muxed in, fetched with a single GET. Nothing here parses DASH or
// muxes anything; the MPD is only read by the diagnostic, to tell the
// maintainer whether a richer tier would even be worth building.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One downloadable rendition of a video.
///
/// `pixelHeight`, `bitRate` and `byteSize` are 0 when Facebook did not give us
/// that number — they are presentation sugar, never a precondition for the
/// download itself.
@interface FBPDownloadVariant : NSObject

/// The progressive MP4 to GET. Always non-nil for a variant that exists.
@property (nonatomic, copy, readonly) NSURL *url;

/// Already-localized row title, e.g. "High quality".
@property (nonatomic, copy, readonly) NSString *title;

/// Already-localized row detail, e.g. "1080p · 12.4 MB". Nil when neither a
/// resolution nor a size is known.
@property (nonatomic, copy, readonly, nullable) NSString *detail;

@property (nonatomic, assign, readonly) NSInteger pixelHeight;
@property (nonatomic, assign, readonly) long long bitRate;
/// Exact MP4 length in bytes, straight from -atomSize / -hdAtomSize, so the
/// picker can promise a real size before a single byte is fetched.
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
/// exactly as the downloaders behaved before the picker existed.
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

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
