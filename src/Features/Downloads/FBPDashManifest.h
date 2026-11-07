// Minimal DASH MPD reader, for exactly one job: turning the manifest Facebook
// inlines on an FBVideoPlaybackItem into a list of downloadable qualities.
//
// -[FBVideoPlaybackItem DashPlaylist] hands us the MPD as an NSString: the XML
// itself, not a URL, so there is no manifest fetch to do. Facebook's static
// manifests use SegmentBase with @indexRange and Initialization/@range —
// single-file byte-range DASH — which means each <Representation>'s <BaseURL>
// is one complete, self-contained fragmented MP4 on the CDN (corroborated by
// -[FNFDashPlaylist isSingleSegmentVideo], and by the ranges being contiguous
// from byte 0). So a representation is fetched with one plain unranged GET: no
// segment stitching, no Range requests, and every byte range in the document —
// @indexRange, Initialization/@range, FBFirstSegmentRange — is information we
// deliberately ignore.
//
// What this is NOT: a DASH client. There is no adaptation and no timeline. It
// reads only the shape it can act on and drops everything else:
//
//   * MPD@type="dynamic" (live) is refused outright. A live manifest is a
//     SegmentTemplate of ~2 s pieces covering the last few seconds, so its
//     <BaseURL> is a path prefix rather than a file — saving it would produce
//     a broken download, not a shorter one.
//   * A representation without a <SegmentBase> child, or with a
//     <SegmentTemplate> / <SegmentList>, is refused for the same reason.
//   * A representation (or whole AdaptationSet) carrying <ContentProtection> is
//     refused: an encrypted stream is not something we can save.
//
// Quality is named by Facebook's own non-standard FBQualityLabel, NOT by
// @height. Meta encodes several CRFs per resolution — one real feed manifest
// carries 480p, 540p, 640p and 720p rungs that are all 1280x720 — so @height is
// that encode's pixel count while FBQualityLabel is the perceptual rung. Keying
// a ladder on height would collapse four rungs into one row, which is the exact
// bug this tier exists to fix. On portrait video the label tracks the short
// side, so a Reels rung is width="720" height="1280" labelled "720p".
//
// Mixed-codec manifests are normal: Meta ships AVC, VP9 and AV1 lanes in one
// MPD, in several video AdaptationSets, so the same label can appear two or
// three times. Only H.264/HEVC survives, and that filter runs before dedupe so
// a VP9 entry can never win a label.
//
// Video and audio are separate representations — a published capture census
// found 176 of 176 track-separated, and no representation has ever been
// observed carrying both codecs — so a chosen video quality has to be paired
// with an audio representation and the two muxed into one file. This reader
// therefore returns the video ladder *and* the single best audio
// representation. A silent video has no audio AdaptationSet at all, which is a
// success, not an error: see -hasUnusableAudio for how to tell that apart from
// audio we refused.
//
// Lifetime: never cache a parsed manifest across a user interaction. The
// <BaseURL>s carry the same short-lived `oe=` signature as every other Facebook
// media URL, so a manifest parsed a minute ago may already be dead. Parse it
// again at the moment you need a URL — the existing pick-time refresher in
// FBPDownloadVariants.m exists for this reason.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One <Representation>: a single complete file plus what we know about it.
///
/// `width`, `height` and `bandwidth` are 0 when the document did not say. They
/// are presentation and ordering sugar — only `url` is load-bearing.
@interface FBPDashRepresentation : NSObject

/// The one URL to GET. Always absolute http(s); a representation whose BaseURL
/// could not be resolved to one is never produced.
@property (nonatomic, copy, readonly) NSURL *url;

/// Facebook's FBQualityLabel attribute ("360p", "540p", "1080p") when present,
/// else nil.
@property (nonatomic, copy, readonly, nullable) NSString *qualityLabel;

/// The codecs="…" string as written, e.g. "avc1.64001f" or "mp4a.40.5".
@property (nonatomic, copy, readonly, nullable) NSString *codecs;

@property (nonatomic, assign, readonly) NSInteger width;
@property (nonatomic, assign, readonly) NSInteger height;
/// Bits per second. Used both for ordering and — multiplied by the presentation
/// duration — for the only size estimate a DASH rung can offer.
@property (nonatomic, assign, readonly) long long bandwidth;

/// The number this rung is ranked and deduped by: FBQualityLabel with its
/// trailing "p" stripped, falling back to the *shorter* frame edge when there is
/// no label. Never the raw @height — see the file comment. 0 when neither is
/// readable, in which case the rung is dropped rather than offered.
@property (nonatomic, assign, readonly) NSInteger qualityRank;

/// What to put in front of the user: FBQualityLabel, else "720p" built from
/// @c qualityRank, else nil.
@property (nonatomic, copy, readonly, nullable) NSString *displayLabel;

@end

/// A parsed manifest, reduced to what the picker needs.
@interface FBPDashManifest : NSObject

/// Video rungs, best first (highest FBQualityLabel first), one row per label.
/// Never empty on a non-nil manifest.
@property (nonatomic, copy, readonly) NSArray<FBPDashRepresentation *> *videoRepresentations;

/// The single audio representation to pair with any chosen video rung. Nil when
/// the document lists no audio at all (a silent video — pair nothing and save
/// the video rung as it is) *and* when every audio track it listed was refused;
/// -hasUnusableAudio distinguishes the two.
@property (nonatomic, strong, readonly, nullable) FBPDashRepresentation *audioRepresentation;

/// YES when the document listed audio that we refused — an unsupported codec,
/// or an AudioChannelConfiguration scheme we do not recognise (Facebook has a
/// spatial `fb360:audio:channel_layout` scheme, and muxing an ambisonic track
/// onto flat video sounds wrong).
///
/// With @c audioRepresentation nil, this is the difference between "this video
/// is silent, saving video-only is correct" (NO) and "this video has sound we
/// cannot carry, so saving video-only would hand the user a silent copy of a
/// video that was not silent" (YES).
@property (nonatomic, assign, readonly) BOOL hasUnusableAudio;

/// MPD/@mediaPresentationDuration in seconds, 0 when absent or unparseable.
@property (nonatomic, assign, readonly) NSTimeInterval duration;

/// Human-readable notes about what was dropped and why, capped. Fed to the
/// "Log Download Qualities" diagnostic so a ladder that comes out shorter than
/// expected on a real device can be explained without another build.
@property (nonatomic, copy, readonly) NSArray<NSString *> *droppedNotes;

/// Parse an MPD.
///
/// Returns nil — never an empty shell — when @c xml is nil, empty, longer than
/// the bound this reader will accept, not XML at all, a live/dynamic manifest,
/// truncated past the point of usefulness, or carries no representation that
/// survives the gates above. Malformed input is a nil return, never a crash.
+ (nullable FBPDashManifest *)manifestFromXMLString:(nullable NSString *)xml;

@end

#ifdef __cplusplus
extern "C" {
#endif

/// ISO-8601 duration ("PT1M9.567S", "P1DT2H3M") in seconds. 0 when it cannot be
/// read or is outside a sane range. Exposed so it can be tested on its own.
extern NSTimeInterval FBPDashParseISODuration(NSString *_Nullable text);

/// "720p" -> 720, "1080p60" -> 1080, "4K" -> 0. Exposed for the same reason.
extern NSInteger FBPDashRankFromQualityLabel(NSString *_Nullable label);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
