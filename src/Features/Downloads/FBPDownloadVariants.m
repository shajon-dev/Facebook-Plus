// Shared download-variant resolver, quality picker and DASH diagnostic.
// See FBPDownloadVariants.h for what this file is for.

#import "FBPDownloadVariants.h"

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPResources.h"
#import "FBPSheet.h"

#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>
#import <stdatomic.h>
#import <math.h>

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

@implementation FBPDownloadVariant

- (instancetype)initWithURL:(NSURL *)url
                      title:(NSString *)title
                     detail:(NSString *)detail
                pixelHeight:(NSInteger)pixelHeight
                    bitRate:(long long)bitRate
                   byteSize:(long long)byteSize {
    if ((self = [super init])) {
        _url = [url copy];
        _title = [title copy];
        _detail = [detail copy];
        _pixelHeight = pixelHeight;
        _bitRate = bitRate;
        _byteSize = byteSize;
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ %@ h=%ld bitrate=%lld bytes=%lld>",
            NSStringFromClass(self.class), self.title, (long)self.pixelHeight,
            self.bitRate, self.byteSize];
}

@end

/// "1080p · 12.4 MB", or whichever half of that we actually know.
///
/// The byte count is formatted by NSByteCountFormatter, so it follows the
/// *system* locale rather than the tweak's own language setting — a number and a
/// unit, which reads correctly either way.
static NSString *FBPDownloadDetailString(NSInteger pixelHeight, long long byteSize) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];

    if (pixelHeight > 0) {
        [parts addObject:[NSString stringWithFormat:@"%ldp", (long)pixelHeight]];
    }
    if (byteSize > 0) {
        [parts addObject:[NSByteCountFormatter
                             stringFromByteCount:byteSize
                                          countStyle:NSByteCountFormatterCountStyleFile]];
    }

    if (parts.count == 0) return nil;
    return [parts componentsJoinedByString:@" · "];
}

static FBPDownloadVariant *FBPDownloadMakeVariant(id rawURL,
                                                  NSString *title,
                                                  NSString *detailOverride,
                                                  NSInteger pixelHeight,
                                                  double bitRate,
                                                  double byteSize) {
    NSURL *url = FBPDownloadURLFromObject(rawURL);
    if (!url) return nil;

    long long bytes = (byteSize > 0) ? (long long)llround(byteSize) : 0;
    long long bits = (bitRate > 0) ? (long long)llround(bitRate) : 0;

    NSString *detail = detailOverride ?: FBPDownloadDetailString(pixelHeight, bytes);

    return [[FBPDownloadVariant alloc] initWithURL:url
                                             title:title
                                            detail:detail
                                       pixelHeight:pixelHeight
                                           bitRate:bits
                                          byteSize:bytes];
}

#pragma mark - Resolver

NSArray<FBPDownloadVariant *> *FBPDownloadSingleVariant(NSURL *url, NSString *title) {
    FBPDownloadVariant *variant =
        FBPDownloadMakeVariant(url, title ?: FBPL(@"download.quality.original"), nil, 0, 0, 0);
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

    // Paired metrics. -atomSize is the MP4's byte length, which is why the
    // picker can show a real size rather than an estimate.
    double sdBitRate = 0, sdSize = 0, hdBitRate = 0, hdSize = 0, height = 0;
    FBPDownloadScalarGetter(item, @"bitRate", &sdBitRate);
    FBPDownloadScalarGetter(item, @"atomSize", &sdSize);
    FBPDownloadScalarGetter(item, @"hdBitRate", &hdBitRate);
    FBPDownloadScalarGetter(item, @"hdAtomSize", &hdSize);
    FBPDownloadScalarGetter(item, @"videoHeight", &height);

    // -videoHeight is a single number for the whole item, so it is attributed to
    // the best progressive rendition and to nothing else: when both HD and SD
    // exist it describes the HD stream, and when only SD exists it describes
    // that. Guessing a second resolution from it would be inventing a label.
    NSInteger bestHeight = (height > 0 && height < 100000) ? (NSInteger)llround(height) : 0;

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
                                   FBPL(@"download.quality.spherical.detail"), 0, 0, 0));
        add(FBPDownloadMakeVariant(FBPDownloadSafeObjectGetter(item, @"sphericalPlaybackURL"),
                                   FBPL(@"download.quality.spherical.sd"),
                                   FBPL(@"download.quality.spherical.detail"), 0, 0, 0));
    }

    NSUInteger beforeProgressive = variants.count;

    add(FBPDownloadMakeVariant(FBPDownloadSafeObjectGetter(item, @"HDPlaybackURL"),
                               FBPL(@"download.quality.hd"), nil,
                               bestHeight, hdBitRate, hdSize));

    // SD only gets the item's height when HD did not take it.
    NSInteger sdHeight = (variants.count > beforeProgressive) ? 0 : bestHeight;
    add(FBPDownloadMakeVariant(FBPDownloadSafeObjectGetter(item, @"SDPlaybackURL"),
                               FBPL(@"download.quality.sd"), nil,
                               sdHeight, sdBitRate, sdSize));

    return [variants copy];
}

#pragma mark - Source

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

static void FBPDownloadShowSheet(NSArray<FBPDownloadVariant *> *variants,
                                 UIViewController *presenter,
                                 UIView *sourceView,
                                 void (^chosen)(FBPDownloadVariant *)) {
    NSMutableArray<FBPSheetAction *> *actions =
        [NSMutableArray arrayWithCapacity:variants.count];

    for (FBPDownloadVariant *variant in variants) {
        FBPDownloadVariant *pick = variant;
        [actions addObject:[FBPSheetAction actionWithTitle:pick.title
                                                   detail:pick.detail
                                                 iconName:@"arrow.down.circle"
                                                  handler:^{ chosen(pick); }]];
    }

    [FBPSheetPresenter presentActions:actions
                               title:FBPL(@"download.quality.title")
                  fromViewController:presenter
                          sourceView:sourceView];
}

void FBPDownloadPresentPicker(NSArray<FBPDownloadVariant *> *variants,
                              UIViewController *presenter,
                              UIView *sourceView,
                              void (^chosen)(FBPDownloadVariant *variant)) {
    if (!chosen) return;

    FBPDownloadVariant *best = variants.firstObject;
    if (!best) return;

    // One option, or the picker switched off: behave exactly as the downloaders
    // did before this existed — start immediately, no sheet, no extra tap. This
    // is what keeps photo stories and single-quality videos unchanged.
    if (variants.count < 2 || !FBPEnabled(FBPKeyDownloadQualityPicker)) {
        chosen(best);
        return;
    }

    if (NSThread.isMainThread) {
        FBPDownloadShowSheet(variants, presenter, sourceView, chosen);
        return;
    }

    NSArray<FBPDownloadVariant *> *snapshot = [variants copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        FBPDownloadShowSheet(snapshot, presenter, sourceView, chosen);
    });
}

#pragma mark - Quality diagnostic

// Why this exists.
//
// The picker above ships only the progressive tier — the HD/SD (and spherical)
// MP4s, which are complete files with audio already muxed in and so need no
// muxer and no DASH parser. Facebook also serves a DASH ladder, and
// -DashPlaylist hands us its MPD inline as a string, but whether a richer tier
// is worth building depends on three things nobody can settle without a device:
//
//   1. Is -DashPlaylist actually populated on the Reels and Stories surfaces, or
//      only on the watch tab?
//   2. How many representations does it list, and what are their labels? If the
//      ladder is "720p, 1080p" and the progressive pair already covers both,
//      there is nothing to gain.
//   3. Does any single <Representation> carry both a video and an audio codec in
//      its codecs="…" attribute? A muxed representation could be fetched and
//      saved as-is. If every representation is video-only or audio-only, a DASH
//      tier means muxing two streams — a much larger piece of work, and the only
//      thing that would justify it is finding qualities the progressive pair
//      genuinely does not offer.
//
// So this logs the answers instead of guessing them. Turn "Log Download
// Qualities" on in Settings, tap download on a Reel and on a Story, then read it
// back in Console.app filtered on subsystem com.shajon.fbplus, category
// DownloadQualities. This is a plain substring scan over the MPD on purpose —
// building an XML parser to decide whether to build an XML parser would be
// absurd.

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
    id playlist = FBPDownloadSafeObjectGetter(item, @"DashPlaylist");

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
        os_log(log, "variants    %{public}@ · height=%ld bitrate=%lld bytes=%lld",
               variant.title, (long)variant.pixelHeight, variant.bitRate, variant.byteSize);
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
