// DASH MPD reader. See FBPDashManifest.h for what this is for, what it refuses,
// and why quality is keyed on FBQualityLabel rather than @height.
//
// NSXMLParser, not a substring scanner and not NSXMLDocument (which does not
// exist on iOS). The parser is worth its weight for three specific reasons:
//
//   * <BaseURL> text is XML content, so a signed URL arrives with its `&`
//     escaped as `&amp;`. NSXMLParser decodes entities; a scanner would hand us
//     a URL with a literal "&amp;" in the query string and the GET would fail.
//   * The gates are all structural — "has a <SegmentBase> child", "has no
//     <ContentProtection>", "which AdaptationSet is this Representation in" —
//     and structure is what an event parser gives you for free.
//   * Attributes inherit from AdaptationSet down to Representation, and
//     Facebook puts contentType/mimeType on either one depending on the track.
//
// It is an event parser over a string we already hold, so there is no I/O and
// no network: external entity resolution is left off and there is no base URI
// to resolve one against anyway.
//
// Deliberately free of every FBP header, so the whole thing can be compiled and
// exercised against desktop Foundation. Anything worth telling the maintainer
// about a parse comes back as -droppedNotes rather than being logged from here.

#import "FBPDashManifest.h"

#import <math.h>

#pragma mark - Bounds
//
// Everything here is a bound on work, not a judgement about content. The MPD
// arrives from Facebook's servers, but it arrives as a string of unknown length
// on the main thread during a download tap, so the parse has to be cheap and
// has to terminate. Exceeding a bound aborts the parse and keeps whatever was
// already collected, which degrades to "fewer qualities offered" rather than to
// a hang or a crash.

/// Largest MPD we will look at. Facebook's are a few kilobytes; a megabyte of
/// XML is not a manifest.
static const NSUInteger kFBPDashMaxXMLLength = 2u * 1024u * 1024u;
/// Total elements visited before we stop. A real ladder is a few dozen.
static const NSUInteger kFBPDashMaxElements = 20000;
/// Representations collected before we stop looking for more.
static const NSUInteger kFBPDashMaxRepresentations = 128;
/// Longest <BaseURL> text we will accumulate. Signed Facebook URLs run to a few
/// hundred characters.
static const NSUInteger kFBPDashMaxBaseURLLength = 4096;
/// Longest duration we will believe, as a guard on the size estimate.
static const NSTimeInterval kFBPDashMaxDuration = 7.0 * 24.0 * 60.0 * 60.0;
/// Dropped-representation notes kept for the diagnostic.
static const NSUInteger kFBPDashMaxDroppedNotes = 24;

/// The one AudioChannelConfiguration scheme we understand. Facebook also emits
/// a spatial scheme (fb360:audio:channel_layout) for ambisonic tracks, which
/// must not be muxed onto flat video.
static NSString *const kFBPDashStandardChannelScheme =
    @"urn:mpeg:dash:23003:3:audio_channel_configuration:2011";

#pragma mark - Small helpers

/// "mpd:Representation" -> "Representation". Facebook's MPD uses the default
/// namespace (urn:mpeg:dash:schema:mpd:2011) so names arrive unprefixed, but
/// namespace processing is left off (it would also rewrite attribute names, and
/// FBQualityLabel is unprefixed and non-standard) and a prefixed document is
/// cheap to tolerate.
static NSString *FBPDashLocalName(NSString *name) {
    if (name.length == 0) return name;
    NSRange colon = [name rangeOfString:@":" options:NSBackwardsSearch];
    if (colon.location == NSNotFound) return name;
    if (colon.location + 1 >= name.length) return name;
    return [name substringFromIndex:colon.location + 1];
}

/// Attribute lookup: exact first, then a case-insensitive sweep over local
/// names, so a document that writes `FBQualityLabel` as `fbqualitylabel` or
/// prefixes it still reads.
static NSString *FBPDashAttr(NSDictionary<NSString *, NSString *> *attributes,
                             NSString *name) {
    if (attributes.count == 0 || name.length == 0) return nil;

    id exact = attributes[name];
    if ([exact isKindOfClass:NSString.class]) return exact;

    for (NSString *key in attributes) {
        if (![key isKindOfClass:NSString.class]) continue;
        if ([FBPDashLocalName(key) caseInsensitiveCompare:name] != NSOrderedSame) continue;
        id value = attributes[key];
        if ([value isKindOfClass:NSString.class]) return value;
    }
    return nil;
}

static NSInteger FBPDashIntAttr(NSDictionary<NSString *, NSString *> *attributes,
                                NSString *name) {
    NSString *raw = FBPDashAttr(attributes, name);
    if (raw.length == 0 || raw.length > 20) return 0;
    long long value = raw.longLongValue;
    if (value <= 0 || value > 1000000) return 0;
    return (NSInteger)value;
}

static long long FBPDashLongLongAttr(NSDictionary<NSString *, NSString *> *attributes,
                                     NSString *name) {
    NSString *raw = FBPDashAttr(attributes, name);
    if (raw.length == 0 || raw.length > 20) return 0;
    long long value = raw.longLongValue;
    // A bandwidth above 1 Gbit/s is a parse accident, not a video.
    if (value <= 0 || value > 1000000000LL) return 0;
    return value;
}

static NSString *FBPDashTrim(NSString *text) {
    return [text stringByTrimmingCharactersInSet:
               NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

NSInteger FBPDashRankFromQualityLabel(NSString *label) {
    NSString *value = FBPDashTrim(label);
    if (value.length == 0 || value.length > 12) return 0;

    // Leading digit run is the rung: "720p", "1080p60", "540". Anything that
    // does not start with digits ("4K", "hd", "auto") cannot be compared
    // numerically against the rest of the ladder, so it reads as unknown and
    // the caller falls back to the frame's short edge.
    NSInteger rank = 0;
    NSUInteger index = 0;
    for (; index < value.length; index++) {
        unichar character = [value characterAtIndex:index];
        if (character < '0' || character > '9') break;
        if (index >= 5) return 0;
        rank = rank * 10 + (character - '0');
    }
    if (index == 0 || rank <= 0 || rank > 20000) return 0;

    // What follows must be nothing, or the "p" designator with an optional
    // frame rate after it ("1080p60").
    if (index < value.length) {
        unichar designator = [value characterAtIndex:index];
        if (designator != 'p' && designator != 'P') return 0;
        for (NSUInteger tail = index + 1; tail < value.length; tail++) {
            unichar character = [value characterAtIndex:tail];
            if (character < '0' || character > '9') return 0;
        }
    }
    return rank;
}

NSTimeInterval FBPDashParseISODuration(NSString *text) {
    NSString *value = FBPDashTrim(text);
    if (value.length < 2 || value.length > 64) return 0;
    if (![value hasPrefix:@"P"] && ![value hasPrefix:@"p"]) return 0;

    BOOL inTimePart = NO;
    double total = 0;
    NSMutableString *digits = [NSMutableString stringWithCapacity:8];

    for (NSUInteger index = 1; index < value.length; index++) {
        unichar character = [value characterAtIndex:index];

        if (character == 'T' || character == 't') {
            inTimePart = YES;
            [digits setString:@""];
            continue;
        }
        if ((character >= '0' && character <= '9') || character == '.') {
            if (digits.length >= 24) return 0;
            [digits appendFormat:@"%C", character];
            continue;
        }

        // A designator with no number in front of it is malformed.
        if (digits.length == 0) return 0;
        double number = digits.doubleValue;
        [digits setString:@""];
        if (!isfinite(number) || number < 0) return 0;

        switch (character) {
            case 'Y': case 'y': total += number * 365.0 * 86400.0; break;
            case 'D': case 'd': total += number * 86400.0; break;
            case 'H': case 'h': total += number * 3600.0; break;
            // 'M' is months before the T and minutes after it.
            case 'M': case 'm': total += inTimePart ? number * 60.0 : number * 30.0 * 86400.0; break;
            case 'S': case 's': total += number; break;
            default: return 0;
        }
    }

    if (!isfinite(total) || total <= 0 || total > kFBPDashMaxDuration) return 0;
    return total;
}

#pragma mark - Codec policy

/// Video codecs we keep: H.264 and HEVC, the two AVFoundation can carry in an
/// MP4 on iOS without a decoder of our own.
///
/// Meta ships mixed-codec manifests — AVC, VP9 and AV1 lanes in one MPD, in
/// separate AdaptationSets — so the same FBQualityLabel routinely appears two or
/// three times. This is a whitelist rather than an AV1/VP9 blacklist because
/// the consequence of letting an unknown codec through is the worst outcome
/// available: the rung is offered, the user waits for a full download, and then
/// the mux fails because AVFoundation cannot demux what it was handed. It also
/// has to run *before* dedupe, or a VP9 entry can win a label and take the
/// H.264 rung's place.
static BOOL FBPDashVideoCodecIsSupported(NSString *codecs) {
    if (codecs.length == 0) return NO;
    NSString *lower = codecs.lowercaseString;
    for (NSString *needle in @[@"avc1", @"avc3", @"hvc1", @"hev1"]) {
        if ([lower hasPrefix:needle]) return YES;
    }
    return NO;
}

/// Audio we keep: AAC, which is what Facebook serves (HE-AAC v1, mp4a.40.5).
/// Opus/Vorbis/FLAC would have to be transcoded to ride in an MP4, which is the
/// same "we are not shipping a decoder" line as above.
static BOOL FBPDashAudioCodecIsSupported(NSString *codecs) {
    if (codecs.length == 0) return NO;
    NSString *lower = codecs.lowercaseString;
    return [lower hasPrefix:@"mp4a"] || [lower hasPrefix:@"aac"];
}

/// 0 = H.264, 1 = HEVC. Only ever breaks a tie between two representations
/// carrying the same FBQualityLabel; H.264 wins, because it is the family every
/// iOS build remuxes without surprises.
static NSInteger FBPDashVideoCodecRank(NSString *codecs) {
    NSString *lower = codecs.lowercaseString;
    if ([lower hasPrefix:@"hvc1"] || [lower hasPrefix:@"hev1"]) return 1;
    return 0;
}

static BOOL FBPDashCodecsLookLikeVideo(NSString *codecs) {
    if (codecs.length == 0) return NO;
    NSString *lower = codecs.lowercaseString;
    for (NSString *needle in @[@"avc1", @"avc3", @"hvc1", @"hev1", @"av01", @"vp09",
                               @"vp9", @"vp08", @"vp8", @"mp4v"]) {
        if ([lower hasPrefix:needle]) return YES;
    }
    return NO;
}

static BOOL FBPDashCodecsLookLikeAudio(NSString *codecs) {
    if (codecs.length == 0) return NO;
    NSString *lower = codecs.lowercaseString;
    for (NSString *needle in @[@"mp4a", @"aac", @"opus", @"vorbis", @"ac-3", @"ec-3",
                               @"flac", @"alac"]) {
        if ([lower hasPrefix:needle]) return YES;
    }
    return NO;
}

#pragma mark - Representation

@interface FBPDashRepresentation ()
@property (nonatomic, assign) NSInteger codecRank;
/// Set for an audio representation the document marked as its default.
@property (nonatomic, assign) BOOL isDefaultQuality;
@end

@implementation FBPDashRepresentation

- (instancetype)initWithURL:(NSURL *)url
               qualityLabel:(NSString *)qualityLabel
                     codecs:(NSString *)codecs
                      width:(NSInteger)width
                     height:(NSInteger)height
                  bandwidth:(long long)bandwidth {
    if ((self = [super init])) {
        _url = [url copy];
        _qualityLabel = [qualityLabel copy];
        _codecs = [codecs copy];
        _width = width;
        _height = height;
        _bandwidth = bandwidth;
        _codecRank = FBPDashVideoCodecRank(codecs ?: @"");
    }
    return self;
}

- (NSInteger)qualityRank {
    NSInteger labelled = FBPDashRankFromQualityLabel(_qualityLabel);
    if (labelled > 0) return labelled;
    // No usable label: the shorter edge, which is the number the label would
    // have carried. Never the raw height — a portrait 720x1280 rung is 720p.
    if (_width > 0 && _height > 0) return MIN(_width, _height);
    if (_height > 0) return _height;
    return 0;
}

- (NSString *)displayLabel {
    if (_qualityLabel.length > 0) return _qualityLabel;
    NSInteger rank = self.qualityRank;
    if (rank > 0) return [NSString stringWithFormat:@"%ldp", (long)rank];
    return nil;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ %@ rank=%ld %ldx%ld bw=%lld codecs=%@>",
            NSStringFromClass(self.class), self.displayLabel ?: @"(unlabelled)",
            (long)self.qualityRank, (long)self.width, (long)self.height,
            self.bandwidth, self.codecs ?: @"?"];
}

@end

#pragma mark - Parser

/// Everything the delegate accumulates. One instance per parse; nothing static,
/// so two parses on two threads cannot see each other.
@interface FBPDashManifestParser : NSObject <NSXMLParserDelegate>

@property (nonatomic, assign) NSTimeInterval duration;
/// Set when MPD@type says "dynamic": a live manifest, which we refuse whole.
@property (nonatomic, assign) BOOL isDynamic;
@property (nonatomic, assign) BOOL sawMPD;
@property (nonatomic, assign) BOOL hasUnusableAudio;
@property (nonatomic, strong) NSMutableArray<FBPDashRepresentation *> *videoCandidates;
@property (nonatomic, strong) NSMutableArray<FBPDashRepresentation *> *audioCandidates;
@property (nonatomic, strong) NSMutableArray<NSString *> *droppedNotes;

@end

@implementation FBPDashManifestParser {
    NSMutableArray<NSString *> *_stack;          // local element names, outermost first
    NSUInteger _elementCount;

    // <BaseURL> inherits down the document (MPD -> Period -> AdaptationSet ->
    // Representation). Facebook emits exactly one, absolute, on each
    // Representation, so the ancestor levels are normally unused — but keeping
    // them costs four strings and means a spec-shaped relative BaseURL under an
    // absolute ancestor resolves instead of being thrown away. A relative
    // BaseURL with no absolute ancestor is refused: there is no document URI to
    // resolve it against, since the MPD arrived as a string.
    NSString *_mpdBase;
    NSString *_periodBase;
    NSString *_adaptationBase;
    NSString *_representationBase;

    NSDictionary<NSString *, NSString *> *_adaptationAttributes;
    NSDictionary<NSString *, NSString *> *_representationAttributes;

    // Structural gates, tracked per scope. The AdaptationSet's value is
    // inherited by every Representation inside it.
    BOOL _adaptationHasSegmentTemplate;
    BOOL _adaptationHasContentProtection;
    NSString *_adaptationChannelScheme;
    BOOL _adaptationSawChannelConfig;

    BOOL _representationHasSegmentBase;
    BOOL _representationHasSegmentTemplate;
    BOOL _representationHasContentProtection;
    NSString *_representationChannelScheme;
    BOOL _representationSawChannelConfig;

    BOOL _collectingBaseURL;
    NSMutableString *_text;
}

- (instancetype)init {
    if ((self = [super init])) {
        _stack = [NSMutableArray arrayWithCapacity:8];
        _text = [NSMutableString stringWithCapacity:256];
        _videoCandidates = [NSMutableArray array];
        _audioCandidates = [NSMutableArray array];
        _droppedNotes = [NSMutableArray array];
    }
    return self;
}

- (void)note:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2) {
    if (_droppedNotes.count >= kFBPDashMaxDroppedNotes) return;
    va_list arguments;
    va_start(arguments, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    [_droppedNotes addObject:line];
}

#pragma mark Element events

- (void)parser:(NSXMLParser *)parser
    didStartElement:(NSString *)elementName
       namespaceURI:(NSString *)namespaceURI
      qualifiedName:(NSString *)qualifiedName
         attributes:(NSDictionary<NSString *, NSString *> *)attributes {
    if (++_elementCount > kFBPDashMaxElements) {
        [self note:@"stopped after %lu elements", (unsigned long)kFBPDashMaxElements];
        [parser abortParsing];
        return;
    }

    NSString *name = FBPDashLocalName(elementName);
    [_stack addObject:name];

    // Any element nested inside a <BaseURL> ends its text.
    _collectingBaseURL = NO;

    if ([name isEqualToString:@"MPD"]) {
        _sawMPD = YES;
        NSString *type = FBPDashTrim(FBPDashAttr(attributes, @"type")).lowercaseString;
        // Absent @type means "static" per the DASH spec; only an explicit
        // "dynamic" is a live manifest.
        if (type.length > 0 && ![type isEqualToString:@"static"]) {
            _isDynamic = YES;
            [self note:@"refused: MPD@type=\"%@\" (live manifest)", type];
            [parser abortParsing];
            return;
        }
        if (_duration <= 0) {
            _duration = FBPDashParseISODuration(
                FBPDashAttr(attributes, @"mediaPresentationDuration"));
        }
        return;
    }

    if ([name isEqualToString:@"AdaptationSet"]) {
        _adaptationAttributes = attributes;
        _adaptationBase = nil;
        _adaptationHasSegmentTemplate = NO;
        _adaptationHasContentProtection = NO;
        _adaptationChannelScheme = nil;
        _adaptationSawChannelConfig = NO;
        return;
    }

    if ([name isEqualToString:@"Representation"]) {
        // Attributes inherit from the AdaptationSet; the Representation's own
        // win where both declare one. Facebook puts contentType/mimeType on
        // either level depending on the track — in one real manifest the video
        // AdaptationSet has neither and the Representation has both, while the
        // audio AdaptationSet carries contentType and its Representation
        // carries mimeType — so both placements have to work.
        NSMutableDictionary *merged =
            [NSMutableDictionary dictionaryWithCapacity:
                 _adaptationAttributes.count + attributes.count];
        if (_adaptationAttributes.count > 0) [merged addEntriesFromDictionary:_adaptationAttributes];
        if (attributes.count > 0) [merged addEntriesFromDictionary:attributes];
        _representationAttributes = merged;
        _representationBase = nil;
        _representationHasSegmentBase = NO;
        _representationHasSegmentTemplate = NO;
        _representationHasContentProtection = NO;
        _representationChannelScheme = nil;
        _representationSawChannelConfig = NO;
        return;
    }

    if ([name isEqualToString:@"BaseURL"]) {
        _collectingBaseURL = YES;
        [_text setString:@""];
        return;
    }

    // Structural markers. Which scope they land in is decided by the element
    // that encloses them, which is one below the top of the stack.
    NSString *parent = (_stack.count >= 2) ? _stack[_stack.count - 2] : @"";
    BOOL inRepresentation = [parent isEqualToString:@"Representation"];
    BOOL inAdaptationSet = [parent isEqualToString:@"AdaptationSet"];

    if ([name isEqualToString:@"SegmentBase"]) {
        // The gate that says "this <BaseURL> is one complete file". Its
        // @indexRange and child Initialization/@range are not read: they
        // describe where the sidx and moov sit *inside* that file, and we fetch
        // the whole thing in one unranged GET.
        if (inRepresentation) _representationHasSegmentBase = YES;
        return;
    }
    if ([name isEqualToString:@"SegmentTemplate"] ||
        [name isEqualToString:@"SegmentList"]) {
        if (inRepresentation) _representationHasSegmentTemplate = YES;
        if (inAdaptationSet) _adaptationHasSegmentTemplate = YES;
        return;
    }
    if ([name isEqualToString:@"ContentProtection"]) {
        if (inRepresentation) _representationHasContentProtection = YES;
        if (inAdaptationSet) _adaptationHasContentProtection = YES;
        return;
    }
    if ([name isEqualToString:@"AudioChannelConfiguration"]) {
        NSString *scheme = FBPDashTrim(FBPDashAttr(attributes, @"schemeIdUri"));
        if (inRepresentation) {
            _representationSawChannelConfig = YES;
            _representationChannelScheme = scheme;
        } else if (inAdaptationSet) {
            _adaptationSawChannelConfig = YES;
            _adaptationChannelScheme = scheme;
        }
        return;
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    if (!_collectingBaseURL || string.length == 0) return;
    if (_text.length + string.length > kFBPDashMaxBaseURLLength) {
        _collectingBaseURL = NO;
        [_text setString:@""];
        return;
    }
    [_text appendString:string];
}

- (void)parser:(NSXMLParser *)parser
    didEndElement:(NSString *)elementName
     namespaceURI:(NSString *)namespaceURI
    qualifiedName:(NSString *)qualifiedName {
    NSString *name = FBPDashLocalName(elementName);

    if ([name isEqualToString:@"BaseURL"]) {
        // Attribute the text to the level that encloses it. The stack still has
        // BaseURL on top at this point, so the parent is one below.
        NSString *parent = (_stack.count >= 2) ? _stack[_stack.count - 2] : @"";
        NSString *text = FBPDashTrim(_text);
        [_text setString:@""];
        _collectingBaseURL = NO;

        if (text.length > 0) {
            if ([parent isEqualToString:@"Representation"]) {
                _representationBase = text;
            } else if ([parent isEqualToString:@"AdaptationSet"]) {
                _adaptationBase = text;
            } else if ([parent isEqualToString:@"Period"]) {
                _periodBase = text;
            } else if ([parent isEqualToString:@"MPD"]) {
                _mpdBase = text;
            }
        }
    } else if ([name isEqualToString:@"Representation"]) {
        [self finishRepresentation];
        if (self.videoCandidates.count + self.audioCandidates.count >=
            kFBPDashMaxRepresentations) {
            [self note:@"stopped after %lu representations",
                       (unsigned long)kFBPDashMaxRepresentations];
            [parser abortParsing];
        }
    } else if ([name isEqualToString:@"AdaptationSet"]) {
        _adaptationAttributes = nil;
        _adaptationBase = nil;
        _adaptationHasSegmentTemplate = NO;
        _adaptationHasContentProtection = NO;
        _adaptationChannelScheme = nil;
        _adaptationSawChannelConfig = NO;
    }

    // One pop per end event. NSXMLParser pairs start and end for us and stops
    // at the first well-formedness error, so the stack cannot drift.
    if (_stack.count > 0) [_stack removeLastObject];
}

#pragma mark Representation assembly

/// Resolve the BaseURL chain into one absolute http(s) URL, or nil.
- (NSURL *)resolvedURL {
    if (_representationBase.length == 0) return nil;

    NSURL *resolved = nil;
    for (NSString *part in @[_mpdBase ?: @"", _periodBase ?: @"",
                             _adaptationBase ?: @"", _representationBase]) {
        if (part.length == 0) continue;
        NSURL *next = resolved ? [NSURL URLWithString:part relativeToURL:resolved]
                               : [NSURL URLWithString:part];
        if (next) resolved = next.absoluteURL;
    }

    NSString *scheme = resolved.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
        return nil;
    }
    return resolved;
}

- (void)finishRepresentation {
    NSDictionary<NSString *, NSString *> *attributes = _representationAttributes;
    _representationAttributes = nil;

    NSString *identifier = FBPDashAttr(attributes, @"id") ?: @"?";
    NSURL *url = [self resolvedURL];
    NSString *rawBase = _representationBase;
    _representationBase = nil;

    if (!url) {
        if (rawBase.length > 0) {
            // A relative BaseURL under no absolute ancestor. Nothing to resolve
            // it against: the manifest arrived as a string, not from a URI.
            [self note:@"rep %@: BaseURL is not an absolute http(s) URL", identifier];
        }
        return;
    }
    if (attributes.count == 0) return;

    NSString *codecs = FBPDashTrim(FBPDashAttr(attributes, @"codecs"));
    NSString *contentType = FBPDashTrim(FBPDashAttr(attributes, @"contentType")).lowercaseString;
    NSString *mimeType = FBPDashTrim(FBPDashAttr(attributes, @"mimeType")).lowercaseString;
    NSInteger height = FBPDashIntAttr(attributes, @"height");
    NSInteger width = FBPDashIntAttr(attributes, @"width");

    BOOL isVideo = [contentType isEqualToString:@"video"] || [mimeType hasPrefix:@"video/"];
    BOOL isAudio = [contentType isEqualToString:@"audio"] || [mimeType hasPrefix:@"audio/"];

    // Neither attribute present at either level: fall back to the codec string,
    // then to the presence of a frame height. A representation we cannot
    // classify is skipped, not guessed at.
    if (!isVideo && !isAudio) {
        if (FBPDashCodecsLookLikeVideo(codecs)) {
            isVideo = YES;
        } else if (FBPDashCodecsLookLikeAudio(codecs)) {
            isAudio = YES;
        } else if (height > 0) {
            isVideo = YES;
        } else {
            [self note:@"rep %@: no contentType/mimeType/codecs to classify it", identifier];
            return;
        }
    }

    // Structural gates, in the order that produces the most useful note.
    if (_representationHasContentProtection || _adaptationHasContentProtection) {
        [self note:@"rep %@: ContentProtection (encrypted)", identifier];
        if (isAudio) self.hasUnusableAudio = YES;
        return;
    }
    if (_representationHasSegmentTemplate || _adaptationHasSegmentTemplate) {
        [self note:@"rep %@: SegmentTemplate/SegmentList (not a single file)", identifier];
        if (isAudio) self.hasUnusableAudio = YES;
        return;
    }
    if (!_representationHasSegmentBase) {
        // Without SegmentBase the <BaseURL> is not promised to be a complete
        // file, and we have no way to stitch what it would point at.
        [self note:@"rep %@: no SegmentBase child", identifier];
        if (isAudio) self.hasUnusableAudio = YES;
        return;
    }

    long long bandwidth = FBPDashLongLongAttr(attributes, @"bandwidth");
    NSString *qualityLabel = FBPDashTrim(FBPDashAttr(attributes, @"FBQualityLabel"));
    if (qualityLabel.length > 32) qualityLabel = nil;

    if (isVideo) {
        if (!FBPDashVideoCodecIsSupported(codecs)) {
            [self note:@"rep %@ (%@): codecs=\"%@\" cannot be muxed into MP4",
                       identifier, qualityLabel.length ? qualityLabel : @"?",
                       codecs.length ? codecs : @"(none)"];
            return;
        }

        FBPDashRepresentation *representation =
            [[FBPDashRepresentation alloc] initWithURL:url
                                          qualityLabel:qualityLabel.length ? qualityLabel : nil
                                                codecs:codecs.length ? codecs : nil
                                                 width:width
                                                height:height
                                             bandwidth:bandwidth];
        // A rung we cannot name is a row the user cannot read.
        if (representation.qualityRank <= 0) {
            [self note:@"rep %@: no FBQualityLabel and no dimensions", identifier];
            return;
        }
        [self.videoCandidates addObject:representation];
        return;
    }

    // --- audio ---
    if (!FBPDashAudioCodecIsSupported(codecs)) {
        [self note:@"audio rep %@: codecs=\"%@\" is not AAC", identifier,
                   codecs.length ? codecs : @"(none)"];
        self.hasUnusableAudio = YES;
        return;
    }

    // An AudioChannelConfiguration we do not recognise means a layout we must
    // not flatten onto video — Facebook's fb360 spatial scheme in particular.
    // An absent configuration is fine; it is the unknown *scheme* we refuse.
    BOOL sawConfig = _representationSawChannelConfig || _adaptationSawChannelConfig;
    NSString *scheme = _representationSawChannelConfig ? _representationChannelScheme
                                                       : _adaptationChannelScheme;
    if (sawConfig && scheme.length > 0 &&
        [scheme caseInsensitiveCompare:kFBPDashStandardChannelScheme] != NSOrderedSame) {
        [self note:@"audio rep %@: unknown channel scheme \"%@\"", identifier, scheme];
        self.hasUnusableAudio = YES;
        return;
    }

    FBPDashRepresentation *audio =
        [[FBPDashRepresentation alloc] initWithURL:url
                                      qualityLabel:qualityLabel.length ? qualityLabel : nil
                                            codecs:codecs.length ? codecs : nil
                                             width:0
                                            height:0
                                         bandwidth:bandwidth];
    audio.isDefaultQuality =
        [FBPDashTrim(FBPDashAttr(attributes, @"FBDefaultQuality")) isEqualToString:@"1"];
    [self.audioCandidates addObject:audio];
}

@end

#pragma mark - Manifest

@implementation FBPDashManifest

- (instancetype)initWithVideo:(NSArray<FBPDashRepresentation *> *)video
                        audio:(FBPDashRepresentation *)audio
             hasUnusableAudio:(BOOL)hasUnusableAudio
                     duration:(NSTimeInterval)duration
                 droppedNotes:(NSArray<NSString *> *)droppedNotes {
    if ((self = [super init])) {
        _videoRepresentations = [video copy];
        _audioRepresentation = audio;
        _hasUnusableAudio = hasUnusableAudio;
        _duration = duration;
        _droppedNotes = [droppedNotes copy] ?: @[];
    }
    return self;
}

/// One row per FBQualityLabel, highest bandwidth wins, H.264 wins a tie.
///
/// Keyed on the label and not on @height, because Meta encodes several CRFs per
/// resolution: one real feed manifest carries 480p, 540p, 640p and 720p rungs
/// that are *all* 1280x720. Deduping those on height would leave a three-row
/// picker, which is the bug this tier exists to fix.
static NSArray<FBPDashRepresentation *> *
FBPDashDedupeVideo(NSArray<FBPDashRepresentation *> *candidates) {
    NSMutableDictionary<NSString *, FBPDashRepresentation *> *best =
        [NSMutableDictionary dictionaryWithCapacity:candidates.count];

    for (FBPDashRepresentation *candidate in candidates) {
        // The label as written is the key, so two spellings of the same rung
        // ("720p" twice, in an AVC and an HEVC AdaptationSet) collapse; an
        // unlabelled rung keys on the rank its dimensions imply.
        NSString *key = candidate.qualityLabel.length > 0
            ? [@"q" stringByAppendingString:candidate.qualityLabel.lowercaseString]
            : [NSString stringWithFormat:@"r%ld", (long)candidate.qualityRank];

        FBPDashRepresentation *incumbent = best[key];
        if (!incumbent) {
            best[key] = candidate;
            continue;
        }
        if (candidate.codecRank < incumbent.codecRank) {
            best[key] = candidate;
        } else if (candidate.codecRank == incumbent.codecRank &&
                   candidate.bandwidth > incumbent.bandwidth) {
            best[key] = candidate;
        }
    }

    // Best first, by rung. Codec is deliberately *not* a sort key: after dedupe
    // each rung appears once, and grouping by codec would scramble the ladder
    // whenever one rung happens to be HEVC-only.
    return [best.allValues sortedArrayUsingComparator:
        ^NSComparisonResult(FBPDashRepresentation *a, FBPDashRepresentation *b) {
            if (a.qualityRank != b.qualityRank) {
                return a.qualityRank > b.qualityRank ? NSOrderedAscending : NSOrderedDescending;
            }
            if (a.bandwidth != b.bandwidth) {
                return a.bandwidth > b.bandwidth ? NSOrderedAscending : NSOrderedDescending;
            }
            return NSOrderedSame;
        }];
}

/// The audio track to pair with every video rung: the one the document marks as
/// default, else the highest bandwidth. Everything that reached this point is
/// already AAC with a channel layout we understand.
static FBPDashRepresentation *
FBPDashPickAudio(NSArray<FBPDashRepresentation *> *candidates) {
    FBPDashRepresentation *best = nil;
    for (FBPDashRepresentation *candidate in candidates) {
        if (!best) { best = candidate; continue; }
        if (candidate.isDefaultQuality != best.isDefaultQuality) {
            if (candidate.isDefaultQuality) best = candidate;
            continue;
        }
        if (candidate.bandwidth > best.bandwidth) best = candidate;
    }
    return best;
}

+ (FBPDashManifest *)manifestFromXMLString:(NSString *)xml {
    if (![xml isKindOfClass:NSString.class]) return nil;
    if (xml.length == 0 || xml.length > kFBPDashMaxXMLLength) return nil;

    NSString *source = xml;

    // -DashPlaylist hands us raw XML, and raw XML must NOT be percent-decoded:
    // that would turn every `+` in a signed URL into a space and decode every
    // %xx inside it. The web GraphQL payload *is* percent-encoded, which is why
    // yt-dlp unquotes it, so decode only when the document plainly is not XML
    // yet and plainly is an encoded one.
    if (![FBPDashTrim(source) hasPrefix:@"<"] &&
        [source rangeOfString:@"%3C" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        NSString *decoded = source.stringByRemovingPercentEncoding;
        if (decoded.length > 0) source = decoded;
    }

    // Cheapest possible rejection of "not XML at all" — a plain string, an
    // error page, JSON — before NSXMLParser allocates anything.
    if ([source rangeOfString:@"<" options:NSLiteralSearch].location == NSNotFound) return nil;

    NSData *data = [source dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0) return nil;

    FBPDashManifestParser *delegate = [[FBPDashManifestParser alloc] init];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
    parser.delegate = delegate;
    parser.shouldProcessNamespaces = NO;
    parser.shouldResolveExternalEntities = NO;
    parser.shouldReportNamespacePrefixes = NO;

    @try {
        // The return value is deliberately ignored. Truncated XML — the common
        // real failure — reports an error *after* the elements that did parse
        // have already been handed to the delegate, and those are usable. A
        // document that produced nothing usable falls out below anyway.
        [parser parse];
    } @catch (__unused NSException *exception) {
        return nil;
    }

    if (!delegate.sawMPD || delegate.isDynamic) return nil;

    NSArray<FBPDashRepresentation *> *video = FBPDashDedupeVideo(delegate.videoCandidates);
    if (video.count == 0) return nil;

    return [[FBPDashManifest alloc] initWithVideo:video
                                            audio:FBPDashPickAudio(delegate.audioCandidates)
                                 hasUnusableAudio:delegate.hasUnusableAudio
                                         duration:delegate.duration
                                     droppedNotes:delegate.droppedNotes];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ %lu video, audio=%@%@, %.3fs, %lu dropped>",
            NSStringFromClass(self.class),
            (unsigned long)self.videoRepresentations.count,
            self.audioRepresentation ? self.audioRepresentation.codecs ?: @"yes" : @"none",
            self.hasUnusableAudio ? @" (some refused)" : @"",
            self.duration, (unsigned long)self.droppedNotes.count];
}

@end
