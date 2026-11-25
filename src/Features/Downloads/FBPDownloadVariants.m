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

/// From FBPMediaConverter, declared rather than imported: that header pulls in
/// AVFoundation and nothing else here needs it. Keep the signature in step.
extern long long FBPConverterExpectedOutputBytes(long long sourceBitsPerSecond,
                                                 CGSize frameSize,
                                                 float framesPerSecond,
                                                 long long audioBitsPerSecond,
                                                 double durationSeconds);

#pragma mark - Guarded runtime reads

// Every read below goes through one of these three. Facebook renames things
// between releases, so the contract is: a getter that is missing, takes
// arguments, or returns the wrong type reads as "absent", never as a crash. The
// worst a rename can do here is collapse the picker to one option.

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

/// The first of several spellings the object actually answers to. Facebook ships
/// two playback-item classes with two conventions for the same fields
/// (-HDPlaybackURL vs -hdPlaybackURL, -DashPlaylist vs -dashPlaylist) and both
/// reach the download button, so one spelling alone loses the other surface.
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

/// Reads a zero-argument numeric getter, whatever width or signedness Facebook
/// declared it with, into a double. arm64 only (see Makefile ARCHS), where
/// objc_msgSend covers every scalar return with no _fpret / _stret split to get
/// wrong. An NSNumber-backed getter is accepted too, since -atomSize has no
/// guaranteed encoding across releases.
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
/// Refused unless the declared return type really is a CGSize, so some other
/// struct's bytes are never reinterpreted as one.
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
    // is not an offerable variant.
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

/// A row's second line: the size of the saved file, and nothing else. It must
/// never state a number the result contradicts, so each row is sized from what
/// that row produces — a progressive MP4's own -atomSize (exact, no "~"),
/// bandwidth x duration for a copied DASH rung, FBPConverterExpectedOutputBytes
/// for a converted one, never the source's size, which is the download cost
/// rather than what lands in Photos. Nil when no size is known, and
/// NSByteCountFormatter follows the system locale, so none of this is localized.
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
/// second x seconds, over 8. An estimate, since @c bandwidth averages a
/// variable-bitrate encode, which is why rows built from it wear a "~". Still
/// the right number for a converted rung's download and progress weighting, but
/// the wrong one to show — FBPConverterExpectedOutputBytes sizes that row.
static long long FBPDownloadEstimatedBytes(FBPDashRepresentation *video,
                                           FBPDashRepresentation *audio,
                                           NSTimeInterval duration) {
    if (!video || duration <= 0 || video.bandwidth <= 0) return 0;

    double bitsPerSecond = (double)video.bandwidth;
    if (audio.bandwidth > 0) bitsPerSecond += (double)audio.bandwidth;

    double bytes = bitsPerSecond * duration / 8.0;
    // 1 TB is not a Reel; a number that big means something was misread.
    if (!isfinite(bytes) || bytes <= 0 || bytes > 1e12) return 0;
    return (long long)llround(bytes);
}

/// The last-resort name for a rung the manifest never labelled and gave no
/// dimensions for: its bitrate, so it can be offered rather than skipped. Not
/// localized and does not need to be — a number and an SI-prefixed unit.
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
/// @param flatStart Index at which the non-spherical rows begin. Everything
///   before it is pinned to the front untouched: on a 360° video the spherical
///   streams are the content, not a quality choice.
///
/// Returns @c progressive unchanged — same objects, same order, same titles —
/// whenever there is no usable ladder.
static NSArray<FBPDownloadVariant *> *
FBPDownloadMergeDashLadder(id item,
                           NSArray<FBPDownloadVariant *> *progressive,
                           NSUInteger flatStart) {
    id playlist = FBPDownloadFirstGetter(item, FBPDownloadDashPlaylistNames());
    if (![playlist isKindOfClass:NSString.class]) return progressive;

    FBPDashManifest *manifest =
        [FBPDashManifest manifestFromXMLString:(NSString *)playlist];
    if (manifest.videoRepresentations.count == 0) return progressive;

    // Audio can no longer abandon the ladder. Returning the progressive pair
    // because no audio track survived cost the whole 360p…1080p ladder over a
    // soundtrack; the reader refuses no audio now, so nil means truly silent.
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
    // not carried into the result. This is the one place that decision lives.
    //
    // Every row here is a resolution, and a progressive row cannot be one: the
    // only resolution Facebook publishes per item describes the SOURCE UPLOAD,
    // not the rendition behind -HDPlaybackURL, so a 1440p upload's HD is
    // typically 720p. Labelling the HD row from it both lied and dropped the
    // manifest's real 1080p rung as a duplicate, and neither item class carries
    // a per-rendition height to name it with instead.
    for (FBPDashRepresentation *representation in manifest.videoRepresentations) {
        // The rung's own number: its shorter frame edge, falling back to
        // FBQualityLabel. Used for ordering and for the refresher's fallback
        // match, never for deciding whether two rungs are the same one.
        NSInteger rank = representation.qualityRank;

        // A rung the manifest never named, with no dimensions either, is named
        // by its bitrate rather than skipped, and falls back to "Original".
        NSString *label = representation.displayLabel;
        if (label.length == 0) label = FBPDownloadBitRateTitle(representation.bandwidth);
        if (label.length == 0) label = FBPL(@"download.quality.original");

        // Second guard against showing one rung twice, keyed on the row's text
        // and NOT on `rank`: Facebook encodes several rungs at one resolution,
        // so keying on the number would throw three of four away. Only DASH rows
        // enter `covered` — a progressive row claims no rung, so it can never
        // hide a representation.
        NSString *key = label.lowercaseString;
        if ([covered containsObject:key]) continue;
        [covered addObject:key];

        // Two different numbers. `bytes` is what the download costs and what
        // `byteSize` carries, because the progress bar is weighted by it and the
        // CDN's Content-Length will replace it. `shown` is what the file will
        // be: the same for a copied rung, about twice as much for a converted
        // one.
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

    // -atomSize is the MP4's byte length, which is why these two rows show a
    // real size. -videoWidth / -videoHeight are deliberately NOT read: they
    // describe the source upload, not either rendition, so reading them is what
    // put "1440p" on a row that delivered 720p. `pixelHeight` stays 0 so no
    // later pass mistakes one of these rows for a rung.
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
    // published anywhere confirmed, so they carry a plain descriptive detail
    // rather than a guessed size.
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

    // The fallback pair, named by Facebook's own name for the stream — "HD" is
    // the H and D of -HDPlaybackURL — and never by a number, because the only
    // number available describes the upload rather than these files. The exact
    // byte size beside it is what separates the two rows.
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

/// The item's own title, trimmed and capped, or nil. Guarded like every other
/// read here: a rename, or a build where the title is a model object rather than
/// text, leaves this nil and the manager falls back to "Reel" or "Story".
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

/// The same rendition from a freshly resolved list, or @c picked unchanged. The
/// fresh entry is taken whole, so a DASH variant's audio URL is renewed with its
/// video URL: both carry the same `oe=` signature, and half a refreshed pair is
/// worse than none. Matched by title first, which both lists build identically.
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

/// The leading glyph for a row. Every resolution row gets the same camcorder, so
/// the eye lands on the number rather than on a mechanism; a spherical row keeps
/// the globe, being the one row that is not a resolution. A symbol the running
/// iOS lacks resolves to nil and the row simply has no glyph, which is why none
/// of this is gated on a version check.
static NSString *FBPDownloadIconForVariant(FBPDownloadVariant *variant) {
    if (variant.tier == FBPDownloadVariantTierSpherical) return @"globe";
    return @"video.fill";
}

/// Index of the cheapest row worth pointing at, or NSNotFound. Only known sizes
/// count, and only when there is something to compare. Index 0 is excluded
/// because it already carries "Best".
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

    // One option, or the picker switched off: start immediately, no sheet, as
    // the downloaders did before this existed. The best variant that needs no
    // extra work is taken rather than the best outright, which is what "don't
    // ask me, just save it" asks for. A conversion weighs far more heavily than
    // a merge — minutes of encoding and a battery cost nobody agreed to — so the
    // search prefers neither, then no conversion, then the top rung. With an
    // all-AV1 ladder there is nothing cheaper and the top rung is converted.
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

// What this diagnostic answers on a real device, which nothing here can settle
// without one: whether -DashPlaylist is populated on the Reels and Stories
// surfaces rather than only the watch tab, how many representations a real
// manifest carries and with what FBQualityLabels, and what the reader dropped.
//
// Turn "Log Download Qualities" on in Settings, tap download, then read it back
// in Console filtered on subsystem com.shajon.fbplus, category
// DownloadQualities. The raw substring scans below see the document as it
// arrived, so a disagreement with the parsed view is the signal worth having.

static os_log_t FBPDownloadQualityLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.shajon.fbplus", "DownloadQualities");
    });
    return log;
}

/// Whether the DASH download-quality probe runs. Off (no user toggle); see
/// FBPDownloadRefreshQualityLogging. When off a download tap costs one relaxed
/// load and a not-taken branch.
static atomic_bool gFBPLogDownloadQualities = false;

static void FBPDownloadRefreshQualityLogging(void) {
    // The per-feature log toggle was removed; this DASH-manifest quality probe
    // stays off. Flip to true only for a local build when deciding whether a new
    // download-quality tier is worth adding.
    atomic_store_explicit(&gFBPLogDownloadQualities, false, memory_order_relaxed);
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
/// malformed document cannot force a walk of the whole string per element.
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

    // What the reader actually made of the same document. There are only four
    // ways to get a nil manifest from a non-empty MPD, each separately checkable
    // against the raw-scan lines above: no <BaseURL> at all; every <BaseURL>
    // relative or not http(s); every representation AV1/VP9 with no conversion
    // path; or a document under 33 characters or over 2 MB.
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
