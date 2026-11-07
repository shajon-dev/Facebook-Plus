// Shared download-variant resolver, quality picker and DASH diagnostic.
// See FBPDownloadVariants.h for what this file is for.

#import "FBPDownloadVariants.h"

#import "FBPDashManifest.h"
#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPResources.h"
#import "FBPSheet.h"

#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>
#import <stdatomic.h>
#import <math.h>

/// From FBPMediaConverter, declared rather than imported.
///
/// Same arrangement FBPDashManifest.m already uses for
/// FBPMediaConversionIsAvailable, and for the same reason: that header pulls in
/// AVFoundation, and nothing else in this file needs it. One plain C function,
/// the size a converted rung will produce, which is the only thing the picker
/// has to borrow from the encoder.
extern long long FBPConverterExpectedOutputBytes(long long sourceBitsPerSecond,
                                                 CGSize frameSize,
                                                 float framesPerSecond,
                                                 long long audioBitsPerSecond,
                                                 double durationSeconds);

#pragma mark - Guarded runtime reads

// Every read below goes through one of these three. Facebook renames things
// between releases, so the contract is: a getter that is missing, takes
// arguments, or returns something other than what we are about to treat it as,
// reads as "absent" — never as a crash. The worst a rename can do here is
// collapse the picker to one option.

id FBPDownloadSafeObjectGetter(id object, NSString *getterName) {
    if (!object || getterName.length == 0) return nil;

    SEL selector = NSSelectorFromString(getterName);
    Method method = class_getInstanceMethod(object_getClass(object), selector);
    if (!method || method_getNumberOfArguments(method) != 2) return nil;

    char returnType[64] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    if (returnType[0] != _C_ID) return nil;

    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

/// The first of several spellings the object actually answers to.
///
/// Facebook ships two playback-item classes with two naming conventions for the
/// same fields: FBVideoPlaybackItem capitalises the acronym (-HDPlaybackURL,
/// -SDPlaybackURL, -DashPlaylist) while FNFVideoPlaybackItem lower-cases the
/// first letter (-hdPlaybackURL, -sdPlaybackURL, -dashPlaylist). Both reach the
/// download button, so asking for one spelling silently loses whichever surface
/// uses the other — which is exactly how the DASH ladder went missing on Reels:
/// -DashPlaylist does not exist there, the guarded getter returned nil, and the
/// picker fell back to the progressive pair with no sign anything had failed.
static id FBPDownloadFirstGetter(id object, NSArray<NSString *> *getterNames) {
    for (NSString *name in getterNames) {
        id value = FBPDownloadSafeObjectGetter(object, name);
        if (value) return value;
    }
    return nil;
}

/// Every spelling of the fields that differ between the two item classes.
static NSArray<NSString *> *FBPDownloadDashPlaylistNames(void) {
    return @[@"dashPlaylist", @"DashPlaylist"];
}

static NSArray<NSString *> *FBPDownloadHDURLNames(void) {
    return @[@"HDPlaybackURL", @"hdPlaybackURL"];
}

static NSArray<NSString *> *FBPDownloadSDURLNames(void) {
    return @[@"SDPlaybackURL", @"sdPlaybackURL"];
}

/// Reads a zero-argument getter whose value is a number, whatever width or
/// signedness Facebook declared it with, into a double.
///
/// arm64 only (see Makefile ARCHS), where objc_msgSend covers every scalar
/// return — there is no _fpret / _stret split to get wrong. An NSNumber-backed
/// getter is accepted too, because -atomSize has no guaranteed encoding across
/// releases.
static BOOL FBPDownloadScalarGetter(id object, NSString *getterName, double *out) {
    if (!object || getterName.length == 0) return NO;

    SEL selector = NSSelectorFromString(getterName);
    Method method = class_getInstanceMethod(object_getClass(object), selector);
    if (!method || method_getNumberOfArguments(method) != 2) return NO;

    char type[64] = {0};
    method_getReturnType(method, type, sizeof(type));

    double value = 0;
    @try {
        switch (type[0]) {
            case _C_DBL:   value = ((double (*)(id, SEL))objc_msgSend)(object, selector); break;
            case _C_FLT:   value = ((float (*)(id, SEL))objc_msgSend)(object, selector); break;
            case _C_INT:   value = ((int (*)(id, SEL))objc_msgSend)(object, selector); break;
            case _C_UINT:  value = ((unsigned int (*)(id, SEL))objc_msgSend)(object, selector); break;
            case _C_SHT:   value = ((short (*)(id, SEL))objc_msgSend)(object, selector); break;
            case _C_USHT:  value = ((unsigned short (*)(id, SEL))objc_msgSend)(object, selector); break;
            case _C_LNG:   value = ((int32_t (*)(id, SEL))objc_msgSend)(object, selector); break;
            case _C_ULNG:  value = ((uint32_t (*)(id, SEL))objc_msgSend)(object, selector); break;
            case _C_LNG_LNG:  value = (double)((long long (*)(id, SEL))objc_msgSend)(object, selector); break;
            case _C_ULNG_LNG: value = (double)((unsigned long long (*)(id, SEL))objc_msgSend)(object, selector); break;
            case _C_CHR:   value = ((char (*)(id, SEL))objc_msgSend)(object, selector); break;
            case _C_UCHR:  value = ((unsigned char (*)(id, SEL))objc_msgSend)(object, selector); break;
            case _C_BOOL:  value = ((BOOL (*)(id, SEL))objc_msgSend)(object, selector) ? 1 : 0; break;
            case _C_ID: {
                id boxed = ((id (*)(id, SEL))objc_msgSend)(object, selector);
                if (![boxed isKindOfClass:NSNumber.class]) return NO;
                value = [(NSNumber *)boxed doubleValue];
                break;
            }
            default:
                return NO;
        }
    } @catch (__unused NSException *exception) {
        return NO;
    }

    if (!isfinite(value)) return NO;
    if (out) *out = value;
    return YES;
}

/// Reads a CGSize-returning getter (-videoSize on FNFDashRepresentationMetadata).
/// Refused unless the declared return type really is a CGSize, so we never
/// reinterpret some other struct's bytes as one.
static BOOL FBPDownloadSizeGetter(id object, NSString *getterName, CGSize *out) {
    if (!object || getterName.length == 0) return NO;

    SEL selector = NSSelectorFromString(getterName);
    Method method = class_getInstanceMethod(object_getClass(object), selector);
    if (!method || method_getNumberOfArguments(method) != 2) return NO;

    char type[128] = {0};
    method_getReturnType(method, type, sizeof(type));
    if (type[0] != _C_STRUCT_B || !strstr(type, "CGSize")) return NO;

    @try {
        CGSize size = ((CGSize (*)(id, SEL))objc_msgSend)(object, selector);
        if (out) *out = size;
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

/// Guarded instance-variable read: only object-typed ivars, only ones the class
/// (or a superclass) actually declares. Used for `_videoAssetMetadata`, which
/// has no public getter on some builds.
static id FBPDownloadObjectIvar(id object, const char *name) {
    if (!object || !name) return nil;

    for (Class cls = object_getClass(object); cls; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (!ivar) continue;

        const char *type = ivar_getTypeEncoding(ivar);
        if (!type || type[0] != _C_ID) return nil;

        @try {
            return object_getIvar(object, ivar);
        } @catch (__unused NSException *exception) {
            return nil;
        }
    }
    return nil;
}

/// KVC read wrapped so an absent key (NSUndefinedKeyException) is just "absent".
static id FBPDownloadKVC(id object, NSString *key) {
    if (!object || key.length == 0) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSURL *FBPDownloadURLFromObject(id object) {
    NSURL *url = nil;
    if ([object isKindOfClass:NSURL.class]) {
        url = object;
    } else if ([object isKindOfClass:NSString.class]) {
        url = [NSURL URLWithString:(NSString *)object];
    }
    // The transport is a plain HTTP GET, so anything that is not an http(s) URL
    // is not a variant we can offer.
    if (![url.scheme.lowercaseString hasPrefix:@"http"]) return nil;
    return url;
}

#pragma mark - Variant

@interface FBPDownloadVariant ()
@property (nonatomic, assign) BOOL needsConversion;
- (instancetype)initWithURL:(NSURL *)url
                   audioURL:(nullable NSURL *)audioURL
                      title:(NSString *)title
                     detail:(nullable NSString *)detail
                pixelHeight:(NSInteger)pixelHeight
                    bitRate:(long long)bitRate
                   byteSize:(long long)byteSize
                       tier:(FBPDownloadVariantTier)tier;
@end

@implementation FBPDownloadVariant

- (instancetype)initWithURL:(NSURL *)url
                   audioURL:(NSURL *)audioURL
                      title:(NSString *)title
                     detail:(NSString *)detail
                pixelHeight:(NSInteger)pixelHeight
                    bitRate:(long long)bitRate
                   byteSize:(long long)byteSize
                       tier:(FBPDownloadVariantTier)tier {
    if ((self = [super init])) {
        _url = [url copy];
        _audioURL = [audioURL copy];
        _title = [title copy];
        _detail = [detail copy];
        _pixelHeight = pixelHeight;
        _bitRate = bitRate;
        _byteSize = byteSize;
        _tier = tier;
    }
    return self;
}

- (BOOL)needsMux {
    return _audioURL != nil;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ %@ h=%ld bitrate=%lld bytes=%lld%@%@>",
            NSStringFromClass(self.class), self.title, (long)self.pixelHeight,
            self.bitRate, self.byteSize, self.needsMux ? @" +audio" : @"",
            self.needsConversion ? @" needs-conversion" : @""];
}

@end


static NSString *FBPDownloadByteString(long long bytes) {
    if (bytes <= 0) return nil;
    return [NSByteCountFormatter stringFromByteCount:bytes
                                          countStyle:NSByteCountFormatterCountStyleFile];
}

/// The whole of a row's second line: how big the saved file will be, and nothing
/// else.
///
/// Twice removed, and this is the third attempt — so what changed is the part
/// worth reading.
///
/// It first said too much ("~24.8 MB · estimated size · needs merging", beside a
/// title that had already said "1080p"). Then it was removed outright (69c4b73),
/// because a row must never state a number the result contradicts and this one
/// did: once a rung had to be re-encoded from AV1 to be saveable at all, the
/// source's bandwidth x duration was wrong by a large multiple — a 4.55 MB AV1
/// rung came out of AVAssetExportSession at 88.95 MB. That is the same class of
/// failure as a row labelled 1080p that downloaded 720p, and it is the
/// maintainer's standing objection to this picker.
///
/// What makes a number safe to show again is that the converter's output bitrate
/// is now a measured multiple of the rung's own bandwidth rather than a preset's
/// opinion, so the converted file's size is predictable — see
/// FBPConverterExpectedOutputBytes, which is what a converting row is sized
/// from. Predictable was checked rather than assumed: fourteen real rungs from
/// five of the six captured manifests were fetched and converted, and the
/// prediction against the bytes that came out is mean 3.4% off, median 2.8%,
/// worst 8.3%, with nothing outside 10%. The bias is a slight under-prediction
/// (+2.3% on average): the encoder overshoots its average-bitrate target a
/// little and the container has overhead, so the file usually lands just above
/// the figure rather than just below. Either way it is a few percent, which is
/// what the "~" is promising — not the multiple that got this column removed.
///
/// So every row shows what *that row* will produce:
///
///   * a progressive row — its MP4's own -atomSize, exact, no "~";
///   * a DASH rung that is copied — bandwidth x duration, an estimate, "~";
///   * a DASH rung that is converted — the *post-conversion* prediction, an
///     estimate, "~". Never the source's size, which is what it costs to
///     download and not what lands in Photos.
///
/// The "~" is the entire distinction between an estimate and an exact figure,
/// said in one character, which is as subtle as it can be while still being
/// said.
///
/// Nil when there is no size at all — the row then shows its resolution alone,
/// which is honest, rather than a word standing in for a number we do not have.
///
/// The byte count is formatted by NSByteCountFormatter, so it follows the
/// *system* locale rather than the tweak's own language setting — a number and a
/// unit, which reads correctly either way, and which is why this needs no
/// localized string. Its one decimal place is kept rather than rounded away to a
/// coarser figure: the exact progressive rows use the same formatter, and a
/// second convention on the estimated rows would be read as a second meaning.
/// The "~" is what says how much to trust the last digit.
static NSString *FBPDownloadSizeDetail(long long byteSize, BOOL estimated) {
    NSString *size = FBPDownloadByteString(byteSize);
    if (size.length == 0) return nil;
    return estimated ? [@"~" stringByAppendingString:size] : size;
}

static FBPDownloadVariant *FBPDownloadMakeVariant(id rawURL,
                                                  NSString *title,
                                                  NSString *detailOverride,
                                                  NSInteger pixelHeight,
                                                  double bitRate,
                                                  double byteSize,
                                                  FBPDownloadVariantTier tier) {
    NSURL *url = FBPDownloadURLFromObject(rawURL);
    if (!url) return nil;

    long long bytes = (byteSize > 0) ? (long long)llround(byteSize) : 0;
    long long bits = (bitRate > 0) ? (long long)llround(bitRate) : 0;

    // Progressive sizes come straight from the MP4's atom, so no "~".
    NSString *detail = detailOverride ?: FBPDownloadSizeDetail(bytes, NO);

    return [[FBPDownloadVariant alloc] initWithURL:url
                                          audioURL:nil
                                             title:title
                                            detail:detail
                                       pixelHeight:pixelHeight
                                           bitRate:bits
                                          byteSize:bytes
                                              tier:tier];
}

#pragma mark - DASH ladder

/// Bytes a DASH rung is likely to cost to *download*: (video + audio) bits per
/// second x seconds, over 8.
///
/// This is the only number DASH gives us, and it is an estimate — @c bandwidth
/// is an average over a variable-bitrate encode, so the real file routinely
/// lands either side of it. The progressive tier's -atomSize is the MP4's true
/// length; this is not, which is why every row built from it wears a "~". Audio
/// is counted in because the file the user ends up with is the mux of both
/// streams.
///
/// For a rung that will be *converted* this is still the right number for the
/// download — and so for the progress weighting — but the wrong one to show: the
/// re-encode changes the size. FBPConverterExpectedOutputBytes is what a
/// converting row is sized from instead.
static long long FBPDownloadEstimatedBytes(FBPDashRepresentation *video,
                                           FBPDashRepresentation *audio,
                                           NSTimeInterval duration) {
    if (!video || duration <= 0 || video.bandwidth <= 0) return 0;

    double bitsPerSecond = (double)video.bandwidth;
    if (audio.bandwidth > 0) bitsPerSecond += (double)audio.bandwidth;

    double bytes = bitsPerSecond * duration / 8.0;
    // 1 TB is not a Reel; a number that big means we misread something.
    if (!isfinite(bytes) || bytes <= 0 || bytes > 1e12) return 0;
    return (long long)llround(bytes);
}

/// The last-resort name for a rung the manifest never labelled and gave no
/// dimensions for: its bitrate.
///
/// It exists so that such a rung can be *offered* rather than skipped, which is
/// what used to happen. Not localized, and does not need to be — it is a number
/// and an SI-prefixed unit, which reads the same in every language the tweak
/// ships, and NSByteCountFormatter beside it already follows the system locale
/// rather than the tweak's. Nil when there is no bitrate either, in which case
/// the caller falls back to a real localized string.
static NSString *FBPDownloadBitRateTitle(long long bitsPerSecond) {
    if (bitsPerSecond <= 0) return nil;
    if (bitsPerSecond >= 1000000) {
        return [NSString stringWithFormat:@"%.1f Mbps", bitsPerSecond / 1000000.0];
    }
    if (bitsPerSecond >= 1000) {
        return [NSString stringWithFormat:@"%lld kbps", bitsPerSecond / 1000];
    }
    return [NSString stringWithFormat:@"%lld bps", bitsPerSecond];
}

/// Merge the DASH ladder into the progressive rows.
///
/// @param progressive The variants built from -HDPlaybackURL / -SDPlaybackURL
///   and the spherical pair, in the order they were added.
/// @param flatStart Index at which the non-spherical rows begin. Everything
///   before it is pinned to the front of the result untouched: on a 360° video
///   the spherical streams are the content, not a quality choice.
///
/// Returns @c progressive unchanged — same objects, same order, same titles —
/// whenever there is no usable ladder, which is what keeps a Facebook build
/// without DASH, or with a renamed getter, behaving exactly as it did before
/// this tier existed.
static NSArray<FBPDownloadVariant *> *
FBPDownloadMergeDashLadder(id item,
                           NSArray<FBPDownloadVariant *> *progressive,
                           NSUInteger flatStart) {
    id playlist = FBPDownloadFirstGetter(item, FBPDownloadDashPlaylistNames());
    if (![playlist isKindOfClass:NSString.class]) return progressive;

    FBPDashManifest *manifest =
        [FBPDashManifest manifestFromXMLString:(NSString *)playlist];
    if (manifest.videoRepresentations.count == 0) return progressive;

    // Audio, which can no longer abandon the ladder.
    //
    // This used to be: `if (!audio && manifest.hasUnusableAudio) return
    // progressive;` — the reasoning being that pairing nothing with a video
    // that has sound hands the user a silent copy. The reasoning was sound and
    // the trade was wrong. It fired whenever the reader had refused every audio
    // track it saw, and the reader refused a lot: any non-AAC codec, any
    // AudioChannelConfiguration scheme it did not recognise. The cost was the
    // entire 360p…1080p ladder, replaced by two progressive rows, because of
    // the soundtrack. The reader now refuses no audio at all, so there is
    // nothing left here to react to: nil means the video is genuinely silent
    // and its rungs are the complete content.
    FBPDashRepresentation *audio = manifest.audioRepresentation;

    // Everything before `flatStart` is the spherical pair on a 360° video, and
    // it stays: those are not a quality choice, they are a different rendering
    // of the content, and the ladder is the flat one.
    NSArray<FBPDownloadVariant *> *pinned = (flatStart > 0)
        ? [progressive subarrayWithRange:NSMakeRange(0, flatStart)]
        : @[];

    NSMutableArray<FBPDownloadVariant *> *ranked = [NSMutableArray array];
    NSMutableSet<NSString *> *covered = [NSMutableSet set];

    // The progressive pair — `progressive` from `flatStart` on — is deliberately
    // not carried into the result below, and this is the one place that decision
    // lives.
    //
    // Every row in this picker is a resolution: "1080p", "720p", one rung per
    // row. A progressive row cannot be one. Facebook publishes exactly one
    // resolution per item (-videoWidth / -videoHeight, and the
    // -videoOriginal* pair beside them), and it describes the SOURCE UPLOAD,
    // not the rendition behind -HDPlaybackURL — a 1440p upload's HD progressive
    // is typically 720p. Labelling the HD row from it is how "1080p download
    // korleo 720p download hocche" happened: the row said 1080p, covered rung
    // 1080 so the manifest's real 1080p representation was dropped as a
    // duplicate, and delivered the 720p file. 09c3120 stopped it claiming the
    // rung; neither item class carries a per-rendition height to name it with
    // instead, so there is no honest number to put on it at all.
    //
    // So when the ladder is here, the ladder is the whole picker. It covers the
    // same ground, every rung names itself from Facebook's own FBQualityLabel,
    // and nothing in the list can promise a resolution it will not deliver.
    // When it is not here — no MPD, a renamed getter, audio we had to refuse,
    // or nothing that survived the gates — `progressive` is returned untouched
    // and those two rows carry the download under their own names (see
    // FBPDownloadVariantsForItem), which is what keeps every Facebook build
    // without a usable DASH ladder working exactly as it did.
    for (FBPDashRepresentation *representation in manifest.videoRepresentations) {
        // The rung's own number: its shorter frame edge, falling back to
        // FBQualityLabel. Used for ordering and for the refresher's fallback
        // match, never for deciding whether two rungs are the same one.
        NSInteger rank = representation.qualityRank;

        // A rung the manifest never named, with no dimensions either. This
        // used to `continue` — a row the user cannot read is no row at all —
        // and that was one more way a rung went missing. It is named by its
        // bitrate instead, which is the only number left that tells it apart
        // from its neighbours, and only falls back to "Original" when even
        // that is absent.
        NSString *label = representation.displayLabel;
        if (label.length == 0) label = FBPDownloadBitRateTitle(representation.bandwidth);
        if (label.length == 0) label = FBPL(@"download.quality.original");

        // Second guard against showing one rung twice, keyed on the row's text
        // and NOT on `rank`. Facebook encodes several rungs at one resolution
        // — 480p, 540p, 640p and 720p are all 1280x720 in a real feed manifest,
        // so all four now rank 720 — and keying this on the number would throw
        // three of them away right here, which is the collapse the ladder
        // exists to avoid. The parser already dedupes on the same label, so
        // this only fires if a manifest repeats a row across adaptation sets.
        // Only DASH rows are ever entered into `covered` — a progressive row
        // deliberately claims no rung, so it can never hide a representation.
        NSString *key = label.lowercaseString;
        if ([covered containsObject:key]) continue;
        [covered addObject:key];

        // Two different numbers, and conflating them is what made the size a
        // liability in the first place.
        //
        // `bytes` is what the download costs — bandwidth x duration for both
        // streams — and it is what `byteSize` carries, because that is what the
        // progress bar is weighted by and what the CDN's Content-Length will
        // later replace.
        //
        // `shown` is what the *file* will be. For a rung that is copied they are
        // the same thing. For a rung that is converted they are not: the picture
        // is re-encoded at a measured multiple of the rung's bandwidth, so the
        // saved file is about twice the download. Showing `bytes` on such a row
        // would understate the result by that whole multiple, which is the exact
        // failure that got the size removed from this picker.
        long long bytes =
            FBPDownloadEstimatedBytes(representation, audio, manifest.duration);
        long long shown = bytes;
        if (representation.needsConversion) {
            shown = FBPConverterExpectedOutputBytes(
                representation.bandwidth,
                CGSizeMake((CGFloat)representation.width,
                           (CGFloat)representation.height),
                (float)representation.frameRate,
                audio.bandwidth,
                manifest.duration);
        }
        // Always an estimate here — a bitrate x a duration either way, never a
        // real length — so every one of these rows wears the "~".
        NSString *detail = FBPDownloadSizeDetail(shown, YES);

        FBPDownloadVariant *variant =
            [[FBPDownloadVariant alloc] initWithURL:representation.url
                                           audioURL:audio.url
                                              title:label
                                             detail:detail
                                        pixelHeight:rank
                                            bitRate:representation.bandwidth
                                           byteSize:bytes
                                               tier:FBPDownloadVariantTierDash];
        // Carried straight through from the representation. The reader has
        // already decided, per device, whether an AV1 rung is offerable at all,
        // so there is nothing left to judge here — only to pass along.
        variant.needsConversion = representation.needsConversion;
        [ranked addObject:variant];
    }

    // Deliberately not re-sorted. -videoRepresentations arrives best-first by
    // (rank, label number, bitrate), which is more than this loop knows — a
    // sort on `pixelHeight` alone would tie Meta's four 1280x720 CRF rungs and
    // then reorder them by bitrate, losing the label ordering the manifest had
    // already worked out.

    // Not one rung survived — an all-VP9 manifest, or nothing with a fetchable
    // BaseURL. Dropping the progressive pair for a ladder that turned out empty
    // would leave nothing to download at all, so this is the last place the old
    // behaviour is handed back intact.
    if (ranked.count == 0) return progressive;

    NSMutableArray<FBPDownloadVariant *> *merged =
        [NSMutableArray arrayWithCapacity:pinned.count + ranked.count];
    [merged addObjectsFromArray:pinned];
    [merged addObjectsFromArray:ranked];
    return [merged copy];
}

#pragma mark - Resolver

NSArray<FBPDownloadVariant *> *FBPDownloadSingleVariant(NSURL *url, NSString *title) {
    FBPDownloadVariant *variant =
        FBPDownloadMakeVariant(url, title ?: FBPL(@"download.quality.original"), nil, 0, 0, 0,
                               FBPDownloadVariantTierProgressive);
    return variant ? @[variant] : @[];
}

NSArray<FBPDownloadVariant *> *FBPDownloadVariantsForItem(id item,
                                                          NSString **videoIDOut) {
    if (videoIDOut) *videoIDOut = nil;
    if (!item) return @[];

    if (videoIDOut) {
        id rawID = FBPDownloadSafeObjectGetter(item, @"videoID");
        if ([rawID isKindOfClass:NSString.class]) {
            *videoIDOut = [(NSString *)rawID copy];
        } else if (rawID) {
            *videoIDOut = [[rawID description] copy];
        }
    }

    // Paired metrics. -atomSize is the MP4's byte length, which is why these two
    // rows can show a real size rather than an estimate.
    //
    // -videoWidth / -videoHeight are deliberately NOT read. They are the only
    // resolution Facebook publishes per item and they describe the source
    // upload, not either progressive rendition: a 1440p upload's -HDPlaybackURL
    // is typically a 720p transcode. Reading them here is what put "1440p" on a
    // row that delivered 720p. There is no per-rendition height on either item
    // class to replace them with — see FBPDownloadMergeDashLadder — so these two
    // rows carry no resolution at all, and `pixelHeight` stays 0 so no later
    // pass can mistake one for a rung.
    double sdBitRate = 0, sdSize = 0, hdBitRate = 0, hdSize = 0;
    FBPDownloadScalarGetter(item, @"bitRate", &sdBitRate);
    FBPDownloadScalarGetter(item, @"atomSize", &sdSize);
    FBPDownloadScalarGetter(item, @"hdBitRate", &hdBitRate);
    FBPDownloadScalarGetter(item, @"hdAtomSize", &hdSize);

    double spherical = 0;
    BOOL isSpherical = FBPDownloadScalarGetter(item, @"isSpherical", &spherical) &&
                       spherical != 0;

    NSMutableArray<FBPDownloadVariant *> *variants = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    void (^add)(FBPDownloadVariant *) = ^(FBPDownloadVariant *variant) {
        if (!variant) return;
        NSString *key = variant.url.absoluteString;
        if (key.length == 0 || [seen containsObject:key]) return;
        [seen addObject:key];
        [variants addObject:variant];
    };

    // 360° videos first: for those, the spherical pair *is* the content, and the
    // flat pair (when present) is a reprojection. Their byte sizes are not
    // published anywhere we have confirmed, so they carry a plain descriptive
    // detail rather than a size we would be guessing at.
    if (isSpherical) {
        add(FBPDownloadMakeVariant(FBPDownloadSafeObjectGetter(item, @"sphericalPlaybackHDURL"),
                                   FBPL(@"download.quality.spherical.hd"),
                                   FBPL(@"download.quality.spherical.detail"), 0, 0, 0,
                                   FBPDownloadVariantTierSpherical));
        add(FBPDownloadMakeVariant(FBPDownloadSafeObjectGetter(item, @"sphericalPlaybackURL"),
                                   FBPL(@"download.quality.spherical.sd"),
                                   FBPL(@"download.quality.spherical.detail"), 0, 0, 0,
                                   FBPDownloadVariantTierSpherical));
    }

    NSUInteger beforeProgressive = variants.count;

    // The fallback pair, for the builds and the items that have no usable DASH
    // ladder. They are named by Facebook's own name for the stream — "HD" is
    // literally the H and D of -HDPlaybackURL — and never by a number, because
    // the only number available describes the upload rather than the file these
    // URLs serve. "HD" claims a class, which these do deliver; "1440p" would
    // claim a frame height, which they do not. The exact byte size beside it is
    // what actually separates the two rows, and that one is exact — straight
    // from the MP4's atom.
    add(FBPDownloadMakeVariant(FBPDownloadFirstGetter(item, FBPDownloadHDURLNames()),
                               FBPL(@"download.quality.progressive.hd"), nil,
                               0, hdBitRate, hdSize,
                               FBPDownloadVariantTierProgressive));
    add(FBPDownloadMakeVariant(FBPDownloadFirstGetter(item, FBPDownloadSDURLNames()),
                               FBPL(@"download.quality.progressive.sd"), nil,
                               0, sdBitRate, sdSize,
                               FBPDownloadVariantTierProgressive));

    // Everything above is the progressive tier. The ladder replaces it when
    // there is one, and leaves this list untouched when there is not.
    return FBPDownloadMergeDashLadder(item, [variants copy], beforeProgressive);
}

#pragma mark - Source

/// The item's own title, trimmed and capped, or nil.
///
/// Guarded the same way as every other read here: the getter has to exist,
/// take no arguments and return an object, and what comes back has to actually
/// be a string. A rename, or a build where the title is a model object rather
/// than text, leaves this nil and the download manager falls back to "Reel" or
/// "Story" — which is what every row said before this existed.
static NSString *FBPDownloadItemTitle(id item) {
    id raw = FBPDownloadSafeObjectGetter(item, @"title");
    if (![raw isKindOfClass:NSString.class]) return nil;

    NSString *title = [(NSString *)raw
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (title.length == 0) return nil;

    // Facebook puts the whole caption here on some surfaces. One row's worth is
    // all a list can show, and holding the rest would be holding a paragraph per
    // job for the session.
    static const NSUInteger kMaxTitleLength = 80;
    if (title.length > kMaxTitleLength) {
        title = [[title substringToIndex:kMaxTitleLength] stringByAppendingString:@"…"];
    }
    return [title copy];
}

@implementation FBPDownloadSource

- (instancetype)initWithItem:(id)item
          playbackController:(id)playbackController
                     videoID:(NSString *)videoID
                    variants:(NSArray<FBPDownloadVariant *> *)variants {
    if ((self = [super init])) {
        _item = item;
        _playbackController = playbackController;
        _videoID = [videoID copy];
        _variants = [variants copy] ?: @[];
        _mediaTitle = FBPDownloadItemTitle(item);
        // -firstFrameThumbnailURL does not exist on either item class in v585;
        // -thumbnailURL does. Both are tried so a build that has either one
        // still shows a poster frame in the manager, and a build with neither
        // just shows a row without one.
        _thumbnailURL =
            FBPDownloadURLFromObject(
                FBPDownloadFirstGetter(item, @[@"thumbnailURL",
                                               @"firstFrameThumbnailURL"]));
    }
    return self;
}

@end

FBPDownloadSource *FBPDownloadSourceFromPlaybackController(id playbackController) {
    id item = FBPDownloadSafeObjectGetter(playbackController, @"currentVideoPlaybackItem");

    NSString *videoID = nil;
    NSArray<FBPDownloadVariant *> *variants = FBPDownloadVariantsForItem(item, &videoID);

    return [[FBPDownloadSource alloc] initWithItem:item
                                playbackController:playbackController
                                           videoID:videoID
                                          variants:variants];
}

#pragma mark - Picker

/// The same rendition from a freshly resolved list, or @c picked unchanged.
///
/// The fresh entry is taken whole, so a DASH variant's audio URL is renewed
/// along with its video URL — both carry the same `oe=` signature and expire
/// together, and half a refreshed pair is worse than none. The entry is matched
/// by title first, which is stable because both lists are built by the same
/// code from the same labels, so a refresh cannot make the download disagree
/// with the row that was tapped.
static FBPDownloadVariant *FBPDownloadFreshenVariant(
    FBPDownloadVariant *picked, FBPDownloadVariantRefresher refresh) {
    if (!refresh || !picked) return picked;

    NSArray<FBPDownloadVariant *> *fresh = nil;
    @try {
        fresh = refresh();
    } @catch (__unused NSException *exception) {
        return picked;
    }
    if (fresh.count == 0) return picked;

    FBPDownloadVariant *match = nil;
    for (FBPDownloadVariant *candidate in fresh) {
        if (candidate.title.length && [candidate.title isEqualToString:picked.title]) {
            match = candidate;
            break;
        }
    }
    // Fallback for a title that moved: the rung number, but only when exactly
    // one fresh row carries it. Several rows legitimately share a `pixelHeight`
    // now — Meta's 480p/540p/640p/720p rungs are all 1280x720, so all four rank
    // 720 — and taking the first of those would refresh the tapped row's URL
    // with a *different* rung's, which is worse than letting it expire.
    if (!match && picked.pixelHeight > 0) {
        FBPDownloadVariant *only = nil;
        NSUInteger hits = 0;
        for (FBPDownloadVariant *candidate in fresh) {
            if (candidate.pixelHeight != picked.pixelHeight) continue;
            only = candidate;
            hits++;
        }
        if (hits == 1) match = only;
    }
    if (!match || !match.url) return picked;

    BOOL sameAudio = (match.audioURL == picked.audioURL) ||
                     [match.audioURL.absoluteString
                         isEqualToString:picked.audioURL.absoluteString];
    if ([match.url.absoluteString isEqualToString:picked.url.absoluteString] && sameAudio) {
        return picked;
    }

    FBPLog(@"refreshed %@ URL at pick time", picked.title);
    return match;
}

/// The leading glyph for a row.
///
/// Every resolution row gets the same one — a camcorder. The rows are a ladder
/// of one thing, a video at N pixels, and the glyph's job here is to say "video"
/// and then get out of the way so the eye lands on the number. It used to vary
/// per row (a bolt for a single file, a merge arrow for a pair) which made the
/// picker read as a list of mechanisms rather than a list of qualities; that
/// distinction now lives in the "~" on the size and in the diagnostic log, where
/// it belongs.
///
/// A spherical row keeps the globe, because it is the one row that is not a
/// resolution: for a 360° video those two streams are the content, and the badge
/// beside the title says so too.
///
/// A symbol the running iOS does not have resolves to nil and the row simply has
/// no glyph, which is why none of this is gated on a version check.
/// "video.fill" has shipped since iOS 13.
static NSString *FBPDownloadIconForVariant(FBPDownloadVariant *variant) {
    if (variant.tier == FBPDownloadVariantTierSpherical) return @"globe";
    return @"video.fill";
}

/// Index of the cheapest row worth pointing at, or NSNotFound.
///
/// Only sizes we actually have count, and only when there is something to
/// compare: badging the sole row that happens to publish a size as "Smallest"
/// would be comparing it against nothing. Index 0 is excluded because it already
/// carries "Best" — one row, one badge.
static NSUInteger FBPDownloadSmallestIndex(NSArray<FBPDownloadVariant *> *variants) {
    NSUInteger sized = 0;
    NSUInteger best = NSNotFound;
    long long bestBytes = 0;

    for (NSUInteger i = 0; i < variants.count; i++) {
        FBPDownloadVariant *variant = variants[i];
        if (variant.byteSize <= 0) continue;
        sized++;
        if (i == 0) continue;
        if (best == NSNotFound || variant.byteSize < bestBytes) {
            best = i;
            bestBytes = variant.byteSize;
        }
    }

    return (sized >= 2) ? best : NSNotFound;
}

static void FBPDownloadShowSheet(NSArray<FBPDownloadVariant *> *variants,
                                 UIViewController *presenter,
                                 UIView *sourceView,
                                 FBPDownloadVariantRefresher refresh,
                                 void (^chosen)(FBPDownloadVariant *)) {
    NSMutableArray<FBPSheetAction *> *actions =
        [NSMutableArray arrayWithCapacity:variants.count];

    // The list is best-first by construction (see FBPDownloadVariantsForItem),
    // so the top row is the recommendation and needs no second ranking pass.
    NSUInteger smallest = FBPDownloadSmallestIndex(variants);

    for (NSUInteger i = 0; i < variants.count; i++) {
        FBPDownloadVariant *pick = variants[i];

        // At most one badge per row, in this order: a spherical row is a
        // different *kind* of download rather than a better one, so saying so
        // matters more than ranking it; then the recommendation; then the
        // cheapest alternative to it.
        NSString *badge = nil;
        if (pick.tier == FBPDownloadVariantTierSpherical) {
            badge = FBPL(@"download.quality.badge.spherical");
        } else if (i == 0) {
            badge = FBPL(@"download.quality.badge.best");
        } else if (i == smallest) {
            badge = FBPL(@"download.quality.badge.smallest");
        }

        FBPSheetAction *action =
            [FBPSheetAction actionWithTitle:pick.title
                                    detail:pick.detail
                                  iconName:FBPDownloadIconForVariant(pick)
                                   handler:^{
                chosen(FBPDownloadFreshenVariant(pick, refresh));
            }];
        // The resolution is the decision; the size only qualifies it, so the
        // title goes on the first line. The sheet's default order puts the grey
        // detail on top, which had a row reading "~12.4 MB" before it said
        // "1080p".
        action.titleFirst = YES;
        action.badge = badge;
        [actions addObject:action];
    }

    [FBPSheetPresenter presentActions:actions
                               title:FBPL(@"download.quality.select.title")
                  fromViewController:presenter
                          sourceView:sourceView];
}

void FBPDownloadPresentPicker(NSArray<FBPDownloadVariant *> *variants,
                              UIViewController *presenter,
                              UIView *sourceView,
                              FBPDownloadVariantRefresher refresh,
                              void (^chosen)(FBPDownloadVariant *variant)) {
    if (!chosen) return;

    FBPDownloadVariant *best = variants.firstObject;
    if (!best) return;

    // One option, or the picker switched off: behave exactly as the downloaders
    // did before this existed — start immediately, no sheet, no extra tap. This
    // is what keeps photo stories and single-quality videos unchanged.
    //
    // The best variant that needs no extra work is taken here rather than the
    // best variant outright. Both callers can now fetch two streams and merge
    // them (FBPDashDownload), so this is no longer a limitation — it is the
    // policy for "don't ask me, just save it": one GET and no post-processing
    // step that can fail, which is what the picker being off asks for. The list
    // is best-first, so the first such variant is the best one.
    //
    // A conversion is weighed much more heavily than a merge, and that is the
    // one judgement here: a merge is a second of I/O, while a conversion is
    // minutes of encoding and a battery cost that a user who switched the picker
    // *off* has certainly not agreed to. So the search is for a variant that
    // needs neither, then — failing that — one that at least needs no
    // conversion, before falling back to the top rung.
    //
    // With an all-AV1 DASH ladder present, which is the common case on real
    // content, every row needs converting and the progressive pair is not in the
    // list at all (see FBPDownloadMergeDashLadder), so there is nothing cheaper
    // to prefer and the top rung goes through and is converted properly.
    if (variants.count < 2 || !FBPEnabled(FBPKeyDownloadQualityPicker)) {
        FBPDownloadVariant *direct = best;
        if (direct.needsMux || direct.needsConversion) {
            for (FBPDownloadVariant *candidate in variants) {
                if (!candidate.needsMux && !candidate.needsConversion) {
                    direct = candidate;
                    break;
                }
            }
        }
        if (direct.needsConversion) {
            for (FBPDownloadVariant *candidate in variants) {
                if (!candidate.needsConversion) {
                    direct = candidate;
                    break;
                }
            }
        }
        chosen(direct);
        return;
    }

    if (NSThread.isMainThread) {
        FBPDownloadShowSheet(variants, presenter, sourceView, refresh, chosen);
        return;
    }

    NSArray<FBPDownloadVariant *> *snapshot = [variants copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        FBPDownloadShowSheet(snapshot, presenter, sourceView, refresh, chosen);
    });
}

#pragma mark - Quality diagnostic

// Why this exists.
//
// The picker now offers both tiers, so this is no longer deciding whether to
// build a DASH reader — it is checking what the one we have actually saw. The
// questions it answers on a real device, which nothing here can settle without
// one:
//
//   1. Is -DashPlaylist populated on the Reels and Stories surfaces, or only on
//      the watch tab? An empty string there means the ladder silently never
//      appears and the picker stays at two rows.
//   2. How many representations does a real manifest carry, and what are their
//      FBQualityLabels? This is what tells us whether the ladder the user sees
//      is the whole ladder Facebook sent.
//   3. What did the reader drop, and why? FBPDashManifest collects a note per
//      refused representation — wrong codec, no SegmentBase, encrypted — and
//      they are printed below, so a ladder that comes out shorter than expected
//      can be explained without another build.
//
// Turn "Log Download Qualities" on in Settings, tap download on a Reel and on a
// Story, then read it back in Console.app filtered on subsystem
// com.shajon.fbplus, category DownloadQualities.
//
// The raw substring scans below are kept alongside the parsed view on purpose:
// they see the document as it arrived, so a disagreement between "the MPD
// mentions these FBQualityLabels" and "the reader produced these rungs" is
// exactly the signal worth having.

static os_log_t FBPDownloadQualityLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.shajon.fbplus", "DownloadQualities");
    });
    return log;
}

/// Cached mirror of FBPKeyLogDownloadQualities, refreshed from the notification
/// the settings panel posts on commit, so the switch takes effect without a
/// relaunch. When it is off a download tap costs one relaxed load and a
/// not-taken branch.
static atomic_bool gFBPLogDownloadQualities = false;

static void FBPDownloadRefreshQualityLogging(void) {
    atomic_store_explicit(&gFBPLogDownloadQualities,
                          FBPEnabled(FBPKeyLogDownloadQualities) ? true : false,
                          memory_order_relaxed);
}

BOOL FBPDownloadQualityLoggingEnabled(void) {
    return atomic_load_explicit(&gFBPLogDownloadQualities, memory_order_relaxed)
               ? YES
               : NO;
}

void FBPDownloadInstallDiagnostic(void) {
    FBPDownloadRefreshQualityLogging();
    [NSNotificationCenter.defaultCenter
        addObserverForName:FBPSettingsDidChangeNotification
                    object:nil
                     queue:nil
                usingBlock:^(__unused NSNotification *note) {
        FBPDownloadRefreshQualityLogging();
    }];
}

static NSInteger FBPDownloadCountOccurrences(NSString *haystack, NSString *needle) {
    NSInteger count = 0;
    NSRange search = NSMakeRange(0, haystack.length);

    while (search.length > 0) {
        NSRange hit = [haystack rangeOfString:needle
                                      options:NSLiteralSearch
                                        range:search];
        if (hit.location == NSNotFound) break;
        count++;
        NSUInteger next = hit.location + MAX((NSUInteger)1, hit.length);
        if (next >= haystack.length) break;
        search = NSMakeRange(next, haystack.length - next);
    }
    return count;
}

/// Every distinct value of an `attribute="…"` pair, in document order.
static NSArray<NSString *> *FBPDownloadAttributeValues(NSString *xml,
                                                       NSString *attribute) {
    NSMutableArray<NSString *> *values = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSString *needle = [attribute stringByAppendingString:@"=\""];
    NSRange search = NSMakeRange(0, xml.length);

    while (search.length > 0 && values.count < 64) {
        NSRange hit = [xml rangeOfString:needle options:NSLiteralSearch range:search];
        if (hit.location == NSNotFound) break;

        NSUInteger start = hit.location + hit.length;
        if (start >= xml.length) break;

        NSRange tail = NSMakeRange(start, xml.length - start);
        NSRange close = [xml rangeOfString:@"\"" options:NSLiteralSearch range:tail];
        if (close.location == NSNotFound) break;

        NSString *value = [xml substringWithRange:
                              NSMakeRange(start, close.location - start)];
        if (value.length > 0 && ![seen containsObject:value]) {
            [seen addObject:value];
            [values addObject:value];
        }

        NSUInteger next = close.location + 1;
        if (next >= xml.length) break;
        search = NSMakeRange(next, xml.length - next);
    }
    return values;
}

/// The opening `<Representation …>` tag of each representation, capped so a
/// malformed document cannot make us walk the whole string per element.
static NSArray<NSString *> *FBPDownloadRepresentationTags(NSString *xml) {
    NSMutableArray<NSString *> *tags = [NSMutableArray array];
    NSRange search = NSMakeRange(0, xml.length);

    while (search.length > 0 && tags.count < 128) {
        NSRange hit = [xml rangeOfString:@"<Representation"
                                 options:NSLiteralSearch
                                   range:search];
        if (hit.location == NSNotFound) break;

        NSUInteger start = hit.location;
        NSUInteger limit = MIN(xml.length, start + 2048);
        NSRange window = NSMakeRange(start, limit - start);
        NSRange close = [xml rangeOfString:@">" options:NSLiteralSearch range:window];
        NSUInteger end = (close.location == NSNotFound) ? limit : close.location + 1;

        [tags addObject:[xml substringWithRange:NSMakeRange(start, end - start)]];

        if (end >= xml.length) break;
        search = NSMakeRange(end, xml.length - end);
    }
    return tags;
}

static BOOL FBPDownloadStringHasAny(NSString *haystack, NSArray<NSString *> *needles) {
    for (NSString *needle in needles) {
        if ([haystack rangeOfString:needle
                            options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

static BOOL FBPDownloadCodecsHaveVideo(NSString *codecs) {
    return FBPDownloadStringHasAny(codecs, @[
        @"avc1", @"avc3", @"hev1", @"hvc1", @"vp09", @"vp9", @"av01", @"mp4v",
    ]);
}

static BOOL FBPDownloadCodecsHaveAudio(NSString *codecs) {
    return FBPDownloadStringHasAny(codecs, @[
        @"mp4a", @"opus", @"ac-3", @"ec-3", @"vorbis", @"aac", @"alac", @"flac",
    ]);
}

/// One line describing an FNFDashRepresentationMetadata-shaped object.
static NSString *FBPDownloadQualityEntryDescription(id entry) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];

    for (NSString *key in @[@"qualityLabel", @"codecFormat", @"representationId"]) {
        id value = FBPDownloadSafeObjectGetter(entry, key) ?: FBPDownloadKVC(entry, key);
        if ([value isKindOfClass:NSString.class]) {
            [parts addObject:[NSString stringWithFormat:@"%@=%@", key, value]];
        } else if (value) {
            [parts addObject:[NSString stringWithFormat:@"%@=<%@>", key,
                              NSStringFromClass([value class])]];
        }
    }

    double number = 0;
    if (FBPDownloadScalarGetter(entry, @"contentLength", &number)) {
        [parts addObject:[NSString stringWithFormat:@"contentLength=%.0f", number]];
    }
    if (FBPDownloadScalarGetter(entry, @"bandwidth", &number)) {
        [parts addObject:[NSString stringWithFormat:@"bandwidth=%.0f", number]];
    }

    CGSize size = CGSizeZero;
    if (FBPDownloadSizeGetter(entry, @"videoSize", &size)) {
        [parts addObject:[NSString stringWithFormat:@"videoSize=%.0fx%.0f",
                          size.width, size.height]];
    }

    if (parts.count == 0) {
        return [NSString stringWithFormat:@"<%@> no readable fields",
                NSStringFromClass([entry class])];
    }

    return [NSString stringWithFormat:@"<%@> %@", NSStringFromClass([entry class]),
            [parts componentsJoinedByString:@" "]];
}

static void FBPDownloadLogDashPlaylist(os_log_t log, id item) {
    id playlist = FBPDownloadFirstGetter(item, FBPDownloadDashPlaylistNames());

    if (![playlist isKindOfClass:NSString.class]) {
        os_log(log, "mpd       %{public}@",
               playlist ? [NSString stringWithFormat:@"not a string <%@>",
                           NSStringFromClass([playlist class])]
                        : @"DashPlaylist is nil");
        return;
    }

    NSString *mpd = (NSString *)playlist;
    if (mpd.length == 0) {
        os_log(log, "mpd       DashPlaylist is empty (0 chars)");
        return;
    }

    NSInteger representations = FBPDownloadCountOccurrences(mpd, @"<Representation");
    os_log(log, "mpd       %lu chars, %ld <Representation",
           (unsigned long)mpd.length, (long)representations);

    NSArray<NSString *> *labels = FBPDownloadAttributeValues(mpd, @"FBQualityLabel");
    if (labels.count > 0) {
        os_log(log, "mpd       FBQualityLabel = %{public}@",
               [labels componentsJoinedByString:@", "]);
    } else {
        os_log(log, "mpd       no FBQualityLabel attributes found");
    }

    // The question that decides whether a DASH tier needs a muxer at all.
    NSArray<NSString *> *tags = FBPDownloadRepresentationTags(mpd);
    NSInteger muxed = 0;
    for (NSString *tag in tags) {
        NSArray<NSString *> *codecsValues = FBPDownloadAttributeValues(tag, @"codecs");
        NSString *codecs = codecsValues.firstObject;
        if (codecs.length == 0) continue;

        BOOL hasVideo = FBPDownloadCodecsHaveVideo(codecs);
        BOOL hasAudio = FBPDownloadCodecsHaveAudio(codecs);
        if (hasVideo && hasAudio) {
            muxed++;
            os_log(log, "mpd       MUXED representation codecs=\"%{public}@\"", codecs);
        } else {
            os_log(log, "mpd       representation codecs=\"%{public}@\" (%{public}@)",
                   codecs, hasVideo ? @"video only" : (hasAudio ? @"audio only" : @"unknown"));
        }
    }
    os_log(log, "mpd       muxed representations = %ld of %lu tags inspected",
           (long)muxed, (unsigned long)tags.count);

    // What the reader actually made of the same document.
    //
    // A nil manifest now means something much narrower than it used to, and the
    // message says so, because "no usable ladder" was exactly the answer that
    // left the last device run guessing. There are only four ways to get here
    // with a non-empty MPD, and each one is separately checkable from the
    // raw-scan lines printed above:
    //
    //   * the document has no <BaseURL> at all — compare against the
    //     "<Representation" count above;
    //   * every <BaseURL> is relative, or not http(s), so nothing resolved;
    //   * every representation is AV1/VP9 — the codecs lines above say so;
    //   * the document is under 33 characters, or over 2 MB (the length is
    //     printed above).
    //
    // Nothing else can produce nil any more: no gate on SegmentBase,
    // SegmentTemplate, ContentProtection, MPD@type, a missing <MPD>, a missing
    // codecs attribute, an unnameable rung or any property of the audio. If the
    // ladder is empty on the next run, it is one of those four, and the lines
    // below name which.
    FBPDashManifest *manifest = [FBPDashManifest manifestFromXMLString:mpd];
    if (!manifest) {
        os_log(log, "parsed    NO LADDER. Both readers (NSXMLParser, then the regex "
                    "scraper) found no representation with a fetchable BaseURL and a "
                    "remuxable codec. Remaining causes, in order of likelihood: no "
                    "<BaseURL> element at all; every BaseURL relative or non-http(s); "
                    "every representation AV1/VP9; document under 33 or over 2097152 "
                    "chars. Compare the mpd lines above.");
        os_log(log, "parsed    mpd has <BaseURL> = %{public}@, length = %lu",
               FBPDownloadCountOccurrences(mpd, @"<BaseURL") > 0 ? @"yes" : @"NO",
               (unsigned long)mpd.length);
        return;
    }

    os_log(log, "parsed    %lu rungs, duration=%.3fs, audio=%{public}@%{public}@",
           (unsigned long)manifest.videoRepresentations.count, manifest.duration,
           manifest.audioRepresentation
               ? (manifest.audioRepresentation.codecs ?: @"present")
               : @"none (silent)",
           manifest.audioIsNotAAC ? @" [not AAC — mux may drop it]" : @"");

    for (FBPDashRepresentation *representation in manifest.videoRepresentations) {
        os_log(log, "parsed      %{public}@", [representation description]);
    }
    // Every note the reader left: what it refused, and — now that most of the
    // old gates only observe — what shape the document turned out to be. A
    // ladder that is non-empty but shorter than the FBQualityLabel list above
    // is explained here.
    for (NSString *note in manifest.droppedNotes) {
        os_log(log, "parsed    note: %{public}@", note);
    }
    if (manifest.droppedNotes.count == 0) {
        os_log(log, "parsed    note: nothing refused or remarked on — the ladder above "
                    "is everything the document offered");
    }
}

static void FBPDownloadLogAssetMetadata(os_log_t log, id playbackController) {
    if (!playbackController) {
        os_log(log, "metadata  no playback controller at tap time");
        return;
    }

    id metadata = FBPDownloadSafeObjectGetter(playbackController, @"videoAssetMetadata");
    if (!metadata) metadata = FBPDownloadObjectIvar(playbackController, "_videoAssetMetadata");
    if (!metadata) metadata = FBPDownloadKVC(playbackController, @"videoAssetMetadata");

    if (!metadata) {
        os_log(log, "metadata  unreachable on <%{public}@>",
               NSStringFromClass([playbackController class]));
        return;
    }

    os_log(log, "metadata  <%{public}@>", NSStringFromClass([metadata class]));

    // -availableVideoQualities / -fetchAvailableQualities live on the controller
    // and are logged for their shape only; they carry no URL, which is exactly
    // why they cannot drive the picker.
    id controllerQualities =
        FBPDownloadSafeObjectGetter(playbackController, @"availableVideoQualities");
    if (controllerQualities) {
        os_log(log, "metadata  availableVideoQualities = %{public}@",
               [controllerQualities description]);
    }

    for (NSString *key in @[@"availableQualities", @"allQualities", @"currentQuality"]) {
        id value = FBPDownloadSafeObjectGetter(metadata, key) ?: FBPDownloadKVC(metadata, key);
        if (!value) {
            os_log(log, "metadata  %{public}@: absent", key);
            continue;
        }

        NSArray *entries = [value isKindOfClass:NSArray.class] ? value : @[value];
        os_log(log, "metadata  %{public}@: %lu entr%{public}@", key,
               (unsigned long)entries.count, entries.count == 1 ? @"y" : @"ies");

        NSUInteger index = 0;
        for (id entry in entries) {
            if (index++ >= 32) break;
            os_log(log, "metadata    %{public}@[%lu] %{public}@", key,
                   (unsigned long)(index - 1), FBPDownloadQualityEntryDescription(entry));
        }
    }
}

/// Kept out of line so the disabled path in FBPDownloadLogQualities stays a flag
/// test and a not-taken branch.
__attribute__((noinline))
static void FBPDownloadLogQualitiesNow(id item,
                                       id playbackController,
                                       NSArray<FBPDownloadVariant *> *variants) {
    os_log_t log = FBPDownloadQualityLog();

    os_log(log, "---- download tap ----");

    if (!item) {
        os_log(log, "item      no FBVideoPlaybackItem at tap time");
    } else {
        os_log(log, "item      <%{public}@>", NSStringFromClass([item class]));
    }

    os_log(log, "variants  %lu offered by the picker", (unsigned long)variants.count);
    for (FBPDownloadVariant *variant in variants) {
        // Which of the three save paths this row will take, because that is the
        // difference between a row that saves in a second and one that occupies
        // the encoder for minutes — and it is the first thing worth knowing when
        // a maintainer asks why a download was slow.
        NSString *path = variant.needsConversion ? @"(dash, AV1 re-encoded)"
                       : variant.needsMux        ? @"(dash, needs mux)"
                                                 : @"(single file)";
        // `bytes` is the download; `shows` is the second line the user reads,
        // which for a converting row is the post-conversion prediction. Logging
        // both is what makes an "it said 9 MB and I got 14" report answerable.
        os_log(log, "variants    %{public}@ · rung=%ld bitrate=%lld bytes=%lld "
                    "shows=%{public}@ %{public}@",
               variant.title, (long)variant.pixelHeight, variant.bitRate,
               variant.byteSize, variant.detail ?: @"(no size)", path);
    }

    // Presence of the adaptive manifests, which the progressive tier ignores.
    for (NSString *key in @[@"DashPlaybackURL", @"HLSPlaybackURL"]) {
        id value = FBPDownloadSafeObjectGetter(item, key);
        os_log(log, "manifest  %{public}@: %{public}@", key,
               value ? @"present" : @"nil");
    }

    FBPDownloadLogDashPlaylist(log, item);
    FBPDownloadLogAssetMetadata(log, playbackController);
}

void FBPDownloadLogQualities(id item,
                             id playbackController,
                             NSArray<FBPDownloadVariant *> *variants) {
    if (!atomic_load_explicit(&gFBPLogDownloadQualities, memory_order_relaxed)) return;
    FBPDownloadLogQualitiesNow(item, playbackController, variants ?: @[]);
}
