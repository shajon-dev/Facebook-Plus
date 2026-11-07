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
// What this is NOT: a DASH client. There is no adaptation and no timeline. But
// it is also no longer fussy, and that is a deliberate reversal.
//
// It used to refuse MPD@type="dynamic", any representation without a
// <SegmentBase> child, anything under a <SegmentTemplate> / <SegmentList>,
// anything carrying <ContentProtection>, any document not rooted in <MPD>, any
// representation that declared no codec or could not be named, and any
// soundtrack that was not AAC with a channel layout it recognised — the last of
// which could take the whole video ladder with it. A rival tweak reading the
// same -DashPlaylist off the same -currentVideoPlaybackItem checks *none* of
// those and shows the full 360p…1080p ladder on the same videos, where ours
// showed two progressive rows. So every one of those gates was costing rungs
// rather than buying safety, and every one is now a -droppedNotes entry instead
// of a refusal.
//
// Two things are still refused, because both are still true: a <BaseURL> that
// does not resolve to an absolute http(s) URL is not fetchable at all, and
// AV1/VP9 cannot be passed through AVAssetWriter, so offering such a rung would
// mean a full download followed by a failed mux. Both say so in -droppedNotes.
//
// There are two readers. NSXMLParser first; when it yields no video rung from a
// document long enough to hold one, a regular-expression scraper re-reads the
// same string using the rival's own patterns. The reason is NSXMLParser's
// contract: it abandons the document at the first well-formedness error, so one
// unescaped `&` in a signed <BaseURL> loses the entire ladder, while a scraper
// is immune by construction. A document under 33 characters is not read at all.
//
// Quality is NAMED by Facebook's own non-standard FBQualityLabel and RANKED by
// the frame's shorter edge, and the split is on purpose. Meta encodes several
// CRFs per resolution — one real feed manifest carries 480p, 540p, 640p and 720p
// rungs that are all 1280x720 — so dimensions cannot name those four rows
// without printing "720p" four times, while the label cannot rank a rung the
// document never labelled. Each is used for the job it can do: see
// -qualityRank and -displayLabel. Dedupe is on the label text, so the CRF rungs
// survive as separate rows. On portrait video the rank tracks the short side,
// so a Reels rung is width="720" height="1280" and ranks 720.
//
// Mixed-codec manifests are normal: Meta ships AVC, VP9 and AV1 lanes in one
// MPD, in several video AdaptationSets, so the same label can appear two or
// three times. Only H.264/HEVC — or a representation that declares no codec at
// all — survives, and that filter runs before dedupe so a VP9 entry can never
// win a label.
//
// Video and audio are separate representations — a published capture census
// found 176 of 176 track-separated, and no representation has ever been
// observed carrying both codecs — so a chosen video quality has to be paired
// with an audio representation and the two muxed into one file. This reader
// therefore returns the video ladder *and* the single best audio
// representation. A silent video has no audio AdaptationSet at all, which is a
// success, not an error; audio that is there but awkward is also a success, and
// -audioIsNotAAC says so without withholding anything.
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

/// The number this rung is SORTED by: the *shorter* frame edge when both
/// dimensions are known (never the raw @height — a portrait 720x1280 Reels rung
/// ranks 720), else the raw height, else FBQualityLabel with its trailing "p"
/// stripped. 0 when the document gave none of the three, which no longer drops
/// the rung — it only means the picker has to name the row from its bitrate.
///
/// Not the dedupe key: several rungs legitimately share one rank. See
/// -displayLabel.
@property (nonatomic, assign, readonly) NSInteger qualityRank;

/// What to put in front of the user, and the key the ladder is deduped on:
/// FBQualityLabel first, else "720p" built from @c qualityRank, else nil.
///
/// The opposite order to @c qualityRank, deliberately — Meta's four CRF rungs
/// at one resolution can only be told apart by their labels.
@property (nonatomic, copy, readonly, nullable) NSString *displayLabel;

@end

/// A parsed manifest, reduced to what the picker needs.
@interface FBPDashManifest : NSObject

/// Video rungs, best first — by @c qualityRank, then by the label's own number,
/// then by bitrate — one row per @c displayLabel. Never empty on a non-nil
/// manifest, and already in picker order: do not re-sort it.
@property (nonatomic, copy, readonly) NSArray<FBPDashRepresentation *> *videoRepresentations;

/// The single audio representation to pair with any chosen video rung. Nil only
/// when the document lists no audio at all — a silent video, where pairing
/// nothing and saving the video rung as it is, is correct.
///
/// Audio is never refused any more, so this is no longer the place a soundtrack
/// can go missing. Ranked AAC first, then a channel layout we recognise, then
/// the document's FBDefaultQuality, then bitrate; when nothing AAC is on offer
/// the best of whatever is there comes back and @c audioIsNotAAC is set.
@property (nonatomic, strong, readonly, nullable) FBPDashRepresentation *audioRepresentation;

/// YES when @c audioRepresentation is present but is not AAC — Opus, Vorbis,
/// FLAC, anything that would have to be transcoded rather than remuxed to ride
/// in an MP4.
///
/// Purely advisory, and that is the point: it exists for mux time, so the muxer
/// can decide to drop the audio track rather than fail, and for the diagnostic.
/// It must never be read as a reason to withhold the video ladder — doing
/// exactly that is how a complete 360p…1080p ladder used to disappear because
/// of the soundtrack.
@property (nonatomic, assign, readonly) BOOL audioIsNotAAC;

/// MPD/@mediaPresentationDuration in seconds, 0 when absent or unparseable.
@property (nonatomic, assign, readonly) NSTimeInterval duration;

/// Human-readable notes about what was dropped and why, capped. Fed to the
/// "Log Download Qualities" diagnostic so a ladder that comes out shorter than
/// expected on a real device can be explained without another build.
@property (nonatomic, copy, readonly) NSArray<NSString *> *droppedNotes;

/// Parse an MPD.
///
/// Returns nil — never an empty shell — when @c xml is nil, shorter than 33
/// characters, longer than the bound this reader will accept, has no `<` in it
/// at all, or produced no video representation from either reader. Malformed
/// input is a nil return, never a crash.
///
/// A nil return now means something much narrower than it used to: not "we
/// disapproved of this manifest" but "neither the XML parser nor the scraper
/// found a single representation with a fetchable BaseURL and a codec this
/// device can remux". Whatever was decided along the way is in
/// @c droppedNotes on a non-nil result.
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
