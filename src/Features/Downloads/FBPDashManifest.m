// DASH MPD reader. See FBPDashManifest.h for intent and the short refusal list.
//
// Two readers. NSXMLParser first (NSXMLDocument does not exist on iOS), which
// decodes the `&amp;` in a signed <BaseURL> and inherits attributes from
// AdaptationSet to Representation, as Facebook uses either level. Then a regex
// scraper, run only when the first produced no video rung: NSXMLParser abandons
// the document at its first well-formedness error, so one unescaped `&` loses
// the whole ladder. Scraper patterns: see THIRD_PARTY_NOTICES.md.
//
// Structural oddities are noted in -droppedNotes rather than refused. Still
// refused: a <BaseURL> that is not an absolute http(s) URL. AV1 and VP9 survive
// only where a conversion path exists at runtime, marked -needsConversion.
//
// External entity resolution is off and there is no base URI to resolve against,
// since the document arrived as a string. Free of every FBP header, so it
// compiles against desktop Foundation.

#import "FBPDashManifest.h"

#import <math.h>

// Declared here rather than imported from FBPMediaConverter.h, which pulls in
// AVFoundation and would break desktop-Foundation compilation. The canonical
// declaration is there; keep the signature in step.
extern BOOL FBPMediaConversionIsAvailable(void);

// Same arrangement for the VP9 tier: canonical declaration in FBPVP9Bridge.h,
// which pulls in CoreVideo. YES when Facebook's own libavcodec can be borrowed
// to decode VP9 (see FBPVP9Bridge.h). A host harness supplies its own.
extern BOOL FBPVP9ConversionIsAvailable(void);

#pragma mark - Bounds
//
// Bounds on work, not judgements about content: the MPD arrives as a string of
// unknown length on the main thread during a tap, so the parse has to
// terminate. Exceeding one keeps what was already collected.

/// Largest MPD we will look at. Facebook's are a few kilobytes; a megabyte of
/// XML is not a manifest.
static const NSUInteger kFBPDashMaxXMLLength = 2u * 1024u * 1024u;
/// Shortest MPD worth looking at. Anything shorter cannot hold an <MPD> plus a
/// <BaseURL> plus a closing tag, so it is a stub, a placeholder or empty.
static const NSUInteger kFBPDashMinXMLLength = 33;
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

/// The AudioChannelConfiguration scheme we recognise; Facebook also emits a
/// spatial one for ambisonic tracks. Not a gate — an unrecognised scheme only
/// loses a tie-break.
static NSString *const kFBPDashStandardChannelScheme =
    @"urn:mpeg:dash:23003:3:audio_channel_configuration:2011";

#pragma mark - Small helpers

/// "mpd:Representation" -> "Representation". Namespace processing is left off
/// because it would also rewrite attribute names, and FBQualityLabel is
/// unprefixed and non-standard.
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

/// @frameRate, in all three spellings DASH allows: "30", "29.97" and "15360/512".
/// Facebook uses the ratio form, which parses to 0 as a plain number, so that
/// case is the one that matters. 0 when absent or nonsense, and the one caller
/// then assumes 30, which is what the converter does anyway.
static double FBPDashFrameRateAttr(NSDictionary<NSString *, NSString *> *attributes,
                                   NSString *name) {
    NSString *raw = FBPDashTrim(FBPDashAttr(attributes, name));
    if (raw.length == 0 || raw.length > 24) return 0;

    double value = 0;
    NSRange slash = [raw rangeOfString:@"/"];
    if (slash.location == NSNotFound) {
        value = raw.doubleValue;
    } else {
        double numerator = [raw substringToIndex:slash.location].doubleValue;
        double denominator =
            [raw substringFromIndex:slash.location + 1].doubleValue;
        if (!(denominator > 0)) return 0;
        value = numerator / denominator;
    }

    // Anything outside this is a misparse rather than a video.
    if (!isfinite(value) || value <= 0.5 || value > 240.0) return 0;
    return value;
}

NSInteger FBPDashRankFromQualityLabel(NSString *label) {
    NSString *value = FBPDashTrim(label);
    if (value.length == 0 || value.length > 12) return 0;

    // Leading digit run is the rung. Anything that does not start with digits
    // ("4K", "hd") cannot be compared numerically, so it reads as unknown and
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

/// Video codecs kept: H.264 and HEVC in every spelling either gets written with,
/// plus a representation that declares no codec at all, which is treated as the
/// H.264 Facebook has always served rather than as a disqualification.
///
/// Still a whitelist rather than "accept everything": a codec with nothing on
/// the other end gives the worst outcome available, where the rung is offered
/// and the save fails after a full download. The wall is Photos, not the muxer —
/// PHAssetCreationRequest answers a remuxed AV1 file with PHPhotosErrorDomain
/// 3302 while AVAssetWriter passes AV1 through fine.
///
/// AV1 and VP9 therefore survive only where this process can re-encode them,
/// which is a runtime question about the device and not about the document.
///
/// Runs before dedupe, or a convertible entry could win a label and take the
/// place of an H.264 rung that needs no conversion at all.
static BOOL FBPDashVideoCodecIsAV1(NSString *codecs) {
    if (codecs.length == 0) return NO;
    NSString *lower = codecs.lowercaseString;
    return [lower hasPrefix:@"av01"] || [lower hasPrefix:@"av1"];
}

static BOOL FBPDashVideoCodecIsVP9(NSString *codecs) {
    if (codecs.length == 0) return NO;
    NSString *lower = codecs.lowercaseString;
    return [lower hasPrefix:@"vp09"] || [lower hasPrefix:@"vp9"];
}

static BOOL FBPDashVideoCodecIsSupported(NSString *codecs) {
    if (codecs.length == 0) return YES;
    NSString *lower = codecs.lowercaseString;
    for (NSString *needle in @[@"avc1", @"avc3", @"h264", @"hvc1", @"hev1", @"hevc"]) {
        if ([lower hasPrefix:needle]) return YES;
    }
    if (FBPDashVideoCodecIsAV1(codecs)) return FBPMediaConversionIsAvailable();
    // VP9 is re-encoded like AV1, but decoded by the borrowed libavcodec since
    // VideoToolbox has none. Offered only where that borrow has resolved.
    if (FBPDashVideoCodecIsVP9(codecs)) return FBPVP9ConversionIsAvailable();
    return NO;
}

/// The families we refuse on purpose and can name in a note, so a dropped rung
/// reads as "we have no decoder for this" rather than "unrecognised". AV1 is
/// both here and conditionally supported above: this answers "if it was refused,
/// was it for want of a decoder", and on such a device the answer is yes.
static BOOL FBPDashVideoCodecHasNoPassthrough(NSString *codecs) {
    if (codecs.length == 0) return NO;
    NSString *lower = codecs.lowercaseString;
    for (NSString *needle in @[@"av01", @"av1", @"vp09", @"vp9", @"vp08", @"vp8"]) {
        if ([lower hasPrefix:needle]) return YES;
    }
    return NO;
}

/// AAC, which is what Facebook serves (HE-AAC v1, mp4a.40.5). Not a gate: it
/// only orders the audio pick and sets -audioIsNotAAC, because finding Opus or
/// FLAC is never a reason to throw away a downloadable video ladder.
static BOOL FBPDashAudioCodecIsAAC(NSString *codecs) {
    if (codecs.length == 0) return NO;
    NSString *lower = codecs.lowercaseString;
    return [lower hasPrefix:@"mp4a"] || [lower hasPrefix:@"aac"];
}

/// 0 = H.264 (or unstated), 1 = HEVC, 2 = AV1. Only ever breaks a tie between
/// two representations carrying the same FBQualityLabel; the lowest rank wins.
///
/// The placement is load-bearing: where a mixed manifest offers both an `avc1`
/// and an `av01` lane at one label, the user gets the rung that is copied in a
/// second rather than re-encoded over minutes and lossier.
static NSInteger FBPDashVideoCodecRank(NSString *codecs) {
    NSString *lower = codecs.lowercaseString;
    // VP9 last: it re-encodes like AV1 but through a borrowed decoder, so when a
    // manifest offers the same label in another lane, prefer that one.
    if (FBPDashVideoCodecIsVP9(codecs)) return 3;
    if (FBPDashVideoCodecIsAV1(codecs)) return 2;
    for (NSString *needle in @[@"hvc1", @"hev1", @"hevc"]) {
        if ([lower hasPrefix:needle]) return 1;
    }
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
/// Video only, from @frameRate at either level. Set after construction rather
/// than taken in the initializer, which already has six arguments and which
/// every audio representation runs through too.
@property (nonatomic, assign) double frameRate;
/// Set for an audio representation the document marked as its default.
@property (nonatomic, assign) BOOL isDefaultQuality;
/// Audio only: whether the codec is AAC, and whether the channel layout came
/// from a recognised scheme. Neither refuses anything any more; they only order
/// the audio pick and feed -audioIsNotAAC.
@property (nonatomic, assign) BOOL isAAC;
@property (nonatomic, assign) BOOL hasKnownChannelLayout;
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
        // Safe from the codecs string alone, because an AV1 or VP9 rung only
        // gets this far on a device the gate has established can decode it.
        // Audio representations run through here too and never match.
        _needsConversion = FBPDashVideoCodecIsAV1(codecs ?: @"") ||
                           FBPDashVideoCodecIsVP9(codecs ?: @"");
        _hasKnownChannelLayout = YES;
    }
    return self;
}

/// The frame's own number, preferred over the label: the shorter edge when both
/// are known (a portrait 720x1280 Reels rung is 720p, never 1280p), else the raw
/// height, else whatever FBQualityLabel says. Dimensions lead because they are
/// measured rather than asserted, and they rescue an unnamed rung.
- (NSInteger)qualityRank {
    if (_width > 0 && _height > 0) return MIN(_width, _height);
    if (_height > 0) return _height;
    return FBPDashRankFromQualityLabel(_qualityLabel);
}

/// What goes in front of the user; FBQualityLabel leads, the opposite order to
/// -qualityRank, because Meta's CRF ladder puts 480p, 540p, 640p and 720p rungs
/// all at 1280x720: naming those from dimensions would print "720p" four times.
- (NSString *)displayLabel {
    if (_qualityLabel.length > 0) return _qualityLabel;
    NSInteger rank = self.qualityRank;
    if (rank > 0) return [NSString stringWithFormat:@"%ldp", (long)rank];
    return nil;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ %@ rank=%ld %ldx%ld bw=%lld codecs=%@%@>",
            NSStringFromClass(self.class), self.displayLabel ?: @"(unlabelled)",
            (long)self.qualityRank, (long)self.width, (long)self.height,
            self.bandwidth, self.codecs ?: @"?",
            self.needsConversion ? @" needs-conversion" : @""];
}

@end

#pragma mark - Parser

/// Everything the delegate accumulates. One instance per parse; nothing static,
/// so two parses on two threads cannot see each other.
@interface FBPDashManifestParser : NSObject <NSXMLParserDelegate>

@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, assign) BOOL sawMPD;
/// MPD@type as written, kept only so a note can say what it was.
@property (nonatomic, copy) NSString *mpdType;
@property (nonatomic, strong) NSMutableArray<FBPDashRepresentation *> *videoCandidates;
@property (nonatomic, strong) NSMutableArray<FBPDashRepresentation *> *audioCandidates;
@property (nonatomic, strong) NSMutableArray<NSString *> *droppedNotes;

// Counted, not refused, and summarised into -droppedNotes once per document
// rather than one line per rung, which would flood the note cap.
@property (nonatomic, assign) NSUInteger keptWithoutSegmentBase;
@property (nonatomic, assign) NSUInteger keptWithFBRangeAttributes;
@property (nonatomic, assign) NSUInteger keptWithSegmentTemplate;
@property (nonatomic, assign) NSUInteger keptWithContentProtection;
@property (nonatomic, assign) NSUInteger keptWithUnknownChannelScheme;

/// One line for -droppedNotes, capped. Declared here rather than left private
/// to the implementation so the regex fallback below can use it too.
- (void)note:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);

@end

@implementation FBPDashManifestParser {
    NSMutableArray<NSString *> *_stack;          // local element names, outermost first
    NSUInteger _elementCount;

    // <BaseURL> inherits down the document. Facebook emits exactly one,
    // absolute, per Representation, but keeping the ancestor levels lets a
    // spec-shaped relative BaseURL resolve. A relative one with no absolute
    // ancestor is refused: the MPD arrived as a string, so there is no
    // document URI to resolve it against.
    NSString *_mpdBase;
    NSString *_periodBase;
    NSString *_adaptationBase;
    NSString *_representationBase;

    NSDictionary<NSString *, NSString *> *_adaptationAttributes;
    NSDictionary<NSString *, NSString *> *_representationAttributes;

    // Tracked per scope, and inherited by every Representation in the set.
    // None of these refuses anything; they are only for the diagnostic.
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
        // Read for the note and nothing else: a BaseURL that is not a fetchable
        // file falls out on its own rather than taking the static rungs with it.
        NSString *type = FBPDashTrim(FBPDashAttr(attributes, @"type")).lowercaseString;
        if (type.length > 0 && type.length <= 32) _mpdType = type;
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
        // win where both declare one. Facebook uses either placement depending
        // on the track, so both have to work.
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
        // Read for the note only. @indexRange and Initialization/@range
        // describe where the sidx and moov sit inside the file that one
        // unranged GET fetches whole, so their absence is not fatal.
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
        } else if (height > 0 || width > 0) {
            isVideo = YES;
        } else {
            [self note:@"rep %@: no contentType/mimeType/codecs/dimensions to "
                        "classify it", identifier];
            return;
        }
    }

    // Structural observations. Every one of these used to `return` here; they
    // are counted now and summarised once per document. None refuses a
    // representation any more — they were throwing away readable ladders.
    if (_representationHasContentProtection || _adaptationHasContentProtection) {
        self.keptWithContentProtection++;
    }
    if (_representationHasSegmentTemplate || _adaptationHasSegmentTemplate) {
        self.keptWithSegmentTemplate++;
    }
    if (!_representationHasSegmentBase) {
        self.keptWithoutSegmentBase++;
        // What a Reels manifest carries instead. Worth separating in the note:
        // "no SegmentBase but byte ranges as attributes" is a healthy single-file
        // representation, while "neither" is one of unknown shape.
        if (FBPDashAttr(attributes, @"FBInitializationRange").length > 0 ||
            FBPDashAttr(attributes, @"FBIndexRange").length > 0 ||
            FBPDashAttr(attributes, @"FBFirstSegmentRange").length > 0) {
            self.keptWithFBRangeAttributes++;
        }
    }

    long long bandwidth = FBPDashLongLongAttr(attributes, @"bandwidth");
    NSString *qualityLabel = FBPDashTrim(FBPDashAttr(attributes, @"FBQualityLabel"));
    if (qualityLabel.length > 32) qualityLabel = nil;

    if (isVideo) {
        if (!FBPDashVideoCodecIsSupported(codecs)) {
            NSString *why;
            if (FBPDashVideoCodecIsAV1(codecs)) {
                // The one refusal about the device rather than the codec, and
                // so the note that explains a two-row picker on a real phone:
                // the ladder was there and this handset could not decode it.
                why = @"is AV1 and this device has no AV1 decoder, so it cannot "
                      @"be converted for Photos";
            } else if (FBPDashVideoCodecHasNoPassthrough(codecs)) {
                why = @"cannot be passed through to Photos and has no conversion "
                      @"path here";
            } else {
                why = @"is not an H.264/HEVC spelling we recognise";
            }
            [self note:@"rep %@ (%@): codecs=\"%@\" %@", identifier,
                       qualityLabel.length ? qualityLabel : @"?", codecs, why];
            return;
        }

        // Nothing below this line can refuse the rung. An unnameable one is
        // named from its bitrate by the picker instead of being dropped.
        FBPDashRepresentation *representation =
            [[FBPDashRepresentation alloc] initWithURL:url
                                          qualityLabel:qualityLabel.length ? qualityLabel : nil
                                                codecs:codecs.length ? codecs : nil
                                                 width:width
                                                height:height
                                             bandwidth:bandwidth];
        // Only the picker uses this, and only for a rung that will be
        // converted: the promised size is bounded per pixel per frame, which
        // needs the frame rate. @frameRate is inherited into `attributes`.
        representation.frameRate = FBPDashFrameRateAttr(attributes, @"frameRate");
        if (representation.qualityRank <= 0) {
            [self note:@"rep %@: no FBQualityLabel and no dimensions — kept, "
                        "named by bitrate", identifier];
        }
        [self.videoCandidates addObject:representation];
        return;
    }

    // --- audio ---
    //
    // Nothing here refuses anything, and that is the point: audio used to be
    // able to veto the entire video ladder. Both observations survive as
    // preferences on the pick and as a flag for mux time.
    BOOL sawConfig = _representationSawChannelConfig || _adaptationSawChannelConfig;
    NSString *scheme = _representationSawChannelConfig ? _representationChannelScheme
                                                       : _adaptationChannelScheme;
    BOOL knownLayout = !(sawConfig && scheme.length > 0 &&
                         [scheme caseInsensitiveCompare:kFBPDashStandardChannelScheme]
                             != NSOrderedSame);
    if (!knownLayout) {
        self.keptWithUnknownChannelScheme++;
        [self note:@"audio rep %@: channel scheme \"%@\" is not the standard one — "
                    "kept, but ranked below any track that is", identifier, scheme];
    }
    if (!FBPDashAudioCodecIsAAC(codecs)) {
        [self note:@"audio rep %@: codecs=\"%@\" is not AAC — kept; the mux may "
                    "have to drop the audio track", identifier,
                   codecs.length ? codecs : @"(none)"];
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
    audio.isAAC = FBPDashAudioCodecIsAAC(codecs);
    audio.hasKnownChannelLayout = knownLayout;
    [self.audioCandidates addObject:audio];
}

@end

#pragma mark - Regex fallback

// The second reader, run only when the first produced no video rung.
//
// NSXMLParser ends the document at its first well-formedness error, so one
// unescaped `&` in a signed <BaseURL> drops every representation after it —
// indistinguishable, from the picker's side, from a manifest with no ladder.
// A scraper cannot fail that way; see THIRD_PARTY_NOTICES.md.
//
// A representation exists if and only if a non-empty <BaseURL> matched inside
// it, and is kept if that resolves to a URL. The codec policy still applies on
// top, since it is a fact about this device rather than about the document.

/// First capture group of the first match, or nil.
static NSString *FBPDashFirstCapture(NSRegularExpression *expression, NSString *text) {
    if (!expression || text.length == 0) return nil;

    NSTextCheckingResult *match =
        [expression firstMatchInString:text
                              options:0
                                range:NSMakeRange(0, text.length)];
    if (!match || match.numberOfRanges < 2) return nil;

    NSRange range = [match rangeAtIndex:1];
    if (range.location == NSNotFound || range.length == 0) return nil;
    if (NSMaxRange(range) > text.length) return nil;
    return [text substringWithRange:range];
}

static NSRegularExpression *FBPDashExpression(NSString *pattern,
                                              NSRegularExpressionOptions options) {
    return [NSRegularExpression regularExpressionWithPattern:pattern
                                                    options:options
                                                      error:NULL];
}

/// Everything the scrape needs, compiled once per fallback. Patterns derived
/// from a third-party source; see THIRD_PARTY_NOTICES.md.
@interface FBPDashScrapePatterns : NSObject
@property (nonatomic, strong) NSRegularExpression *adaptationSet;
@property (nonatomic, strong) NSRegularExpression *contentType;
@property (nonatomic, strong) NSRegularExpression *mimeType;
@property (nonatomic, strong) NSRegularExpression *representation;
@property (nonatomic, strong) NSRegularExpression *representationTag;
@property (nonatomic, strong) NSRegularExpression *baseURL;
@property (nonatomic, strong) NSRegularExpression *bandwidth;
@property (nonatomic, strong) NSRegularExpression *width;
@property (nonatomic, strong) NSRegularExpression *height;
@property (nonatomic, strong) NSRegularExpression *qualityLabel;
@property (nonatomic, strong) NSRegularExpression *codecs;
@property (nonatomic, strong) NSRegularExpression *duration;
@end

@implementation FBPDashScrapePatterns

- (instancetype)init {
    if ((self = [super init])) {
        _adaptationSet = FBPDashExpression(
            @"(<AdaptationSet[^>]*>)(.*?)</AdaptationSet>",
            NSRegularExpressionDotMatchesLineSeparators);
        _contentType = FBPDashExpression(@"contentType=\"(video|audio)\"",
                                         NSRegularExpressionCaseInsensitive);
        _mimeType = FBPDashExpression(@"mimeType=\"(video|audio)/[^\"]*\"",
                                      NSRegularExpressionCaseInsensitive);
        _representation = FBPDashExpression(
            @"<Representation\\b[^>]*/>|<Representation\\b[^>]*>.*?</Representation>",
            NSRegularExpressionDotMatchesLineSeparators);
        _representationTag = FBPDashExpression(@"<Representation\\b[^>]*>", 0);
        _baseURL = FBPDashExpression(@"<BaseURL[^>]*>(.*?)</BaseURL>",
                                     NSRegularExpressionDotMatchesLineSeparators);
        _bandwidth = FBPDashExpression(@"bandwidth=\"(\\d+)\"", 0);
        _width = FBPDashExpression(@"(?:^|\\s)width=\"(\\d+)\"", 0);
        _height = FBPDashExpression(@"(?:^|\\s)height=\"(\\d+)\"", 0);
        _qualityLabel = FBPDashExpression(@"FBQualityLabel=\"([^\"]+)\"", 0);
        _codecs = FBPDashExpression(@"codecs=\"([^\"]+)\"", 0);
        _duration = FBPDashExpression(@"mediaPresentationDuration=\"([^\"]+)\"", 0);
    }
    return self;
}

@end

/// The second reader. Replaces whatever the XML pass collected rather than
/// adding to it.
@interface FBPDashManifestParser (Scrape)
- (void)scrapeDocument:(NSString *)source;
@end

@implementation FBPDashManifestParser (Scrape)

/// One <Representation …>…</Representation> run. `kind` is "video", "audio" or
/// nil when the enclosing AdaptationSet did not say and the tag has to.
- (void)scrapeRepresentation:(NSString *)block
                        kind:(NSString *)kind
                    patterns:(FBPDashScrapePatterns *)patterns {
    if (block.length == 0) return;

    // The opening tag alone, so `width="…"` on the tag is not confused with one
    // inside a nested child element.
    NSRange tagRange = [patterns.representationTag
        rangeOfFirstMatchInString:block
                          options:0
                            range:NSMakeRange(0, block.length)];
    NSString *tag = (tagRange.location != NSNotFound)
        ? [block substringWithRange:tagRange]
        : block;

    // The whole acceptance rule: a non-empty <BaseURL> anywhere inside.
    NSString *base = FBPDashTrim(FBPDashFirstCapture(patterns.baseURL, block));
    if (base.length == 0 || base.length > kFBPDashMaxBaseURLLength) return;

    // The scraper sees the document's bytes, so XML entities are still escaped.
    // `&amp;` is the only one that matters: the only entity that appears in a
    // signed Facebook URL.
    base = [base stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];

    NSURL *url = [NSURL URLWithString:base];
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
        [self note:@"scrape: BaseURL is not an absolute http(s) URL"];
        return;
    }

    NSString *codecs = FBPDashTrim(FBPDashFirstCapture(patterns.codecs, tag));
    NSString *label = FBPDashTrim(FBPDashFirstCapture(patterns.qualityLabel, tag));
    if (label.length > 32) label = nil;
    NSInteger width = FBPDashFirstCapture(patterns.width, tag).integerValue;
    NSInteger height = FBPDashFirstCapture(patterns.height, tag).integerValue;
    long long bandwidth = FBPDashFirstCapture(patterns.bandwidth, tag).longLongValue;
    if (width < 0 || width > 1000000) width = 0;
    if (height < 0 || height > 1000000) height = 0;
    if (bandwidth < 0 || bandwidth > 1000000000LL) bandwidth = 0;

    // Classification, in the order the XML path uses: the AdaptationSet's own
    // word, then the tag's, then the codec, then "it has a frame size".
    BOOL isAudio = [kind isEqualToString:@"audio"];
    BOOL isVideo = [kind isEqualToString:@"video"];
    if (!isAudio && !isVideo) {
        NSString *own = FBPDashFirstCapture(patterns.contentType, tag)
                            ?: FBPDashFirstCapture(patterns.mimeType, tag);
        own = own.lowercaseString;
        if ([own isEqualToString:@"audio"]) {
            isAudio = YES;
        } else if ([own isEqualToString:@"video"]) {
            isVideo = YES;
        } else if (FBPDashCodecsLookLikeAudio(codecs)) {
            isAudio = YES;
        } else if (FBPDashCodecsLookLikeVideo(codecs) || width > 0 || height > 0) {
            isVideo = YES;
        } else {
            return;
        }
    }

    if (isVideo && !FBPDashVideoCodecIsSupported(codecs)) {
        NSString *why;
        if (FBPDashVideoCodecIsAV1(codecs)) {
            why = @"is AV1 and this device has no AV1 decoder";
        } else if (FBPDashVideoCodecHasNoPassthrough(codecs)) {
            why = @"cannot be passed through to Photos and has no conversion "
                  @"path here";
        } else {
            why = @"is not an H.264/HEVC spelling we recognise";
        }
        [self note:@"scrape: %@ codecs=\"%@\" %@", label.length ? label : @"rung",
                   codecs ?: @"", why];
        return;
    }

    FBPDashRepresentation *representation =
        [[FBPDashRepresentation alloc] initWithURL:url
                                      qualityLabel:label.length ? label : nil
                                            codecs:codecs.length ? codecs : nil
                                             width:isVideo ? width : 0
                                            height:isVideo ? height : 0
                                         bandwidth:bandwidth];
    if (isVideo) {
        [self.videoCandidates addObject:representation];
    } else {
        representation.isAAC = FBPDashAudioCodecIsAAC(codecs);
        [self.audioCandidates addObject:representation];
    }
}

/// Every representation inside `region`, which is either one AdaptationSet's
/// body or — when no AdaptationSet matched at all — the whole document.
- (void)scrapeRegion:(NSString *)region
                kind:(NSString *)kind
            patterns:(FBPDashScrapePatterns *)patterns {
    if (region.length == 0 || !patterns.representation) return;

    NSArray<NSTextCheckingResult *> *matches =
        [patterns.representation matchesInString:region
                                         options:0
                                           range:NSMakeRange(0, region.length)];
    for (NSTextCheckingResult *match in matches) {
        if (self.videoCandidates.count + self.audioCandidates.count >=
            kFBPDashMaxRepresentations) {
            [self note:@"scrape: stopped after %lu representations",
                       (unsigned long)kFBPDashMaxRepresentations];
            return;
        }
        NSRange range = match.range;
        if (range.location == NSNotFound || NSMaxRange(range) > region.length) continue;
        [self scrapeRepresentation:[region substringWithRange:range]
                              kind:kind
                          patterns:patterns];
    }
}

- (void)scrapeDocument:(NSString *)source {
    if (source.length < kFBPDashMinXMLLength) return;

    // Whatever the XML path collected is being replaced wholesale, not added
    // to: it came from a parse that ended early, and the scrape is about to
    // read the same representations again.
    [self.videoCandidates removeAllObjects];
    [self.audioCandidates removeAllObjects];

    FBPDashScrapePatterns *patterns = [[FBPDashScrapePatterns alloc] init];

    if (self.duration <= 0) {
        self.duration = FBPDashParseISODuration(
            FBPDashFirstCapture(patterns.duration, source));
    }

    NSUInteger sets = 0;
    if (patterns.adaptationSet) {
        NSArray<NSTextCheckingResult *> *matches =
            [patterns.adaptationSet matchesInString:source
                                            options:0
                                              range:NSMakeRange(0, source.length)];
        for (NSTextCheckingResult *match in matches) {
            if (match.numberOfRanges < 3) continue;
            NSRange openRange = [match rangeAtIndex:1];
            NSRange bodyRange = [match rangeAtIndex:2];
            if (openRange.location == NSNotFound || bodyRange.location == NSNotFound) continue;
            sets++;

            NSString *openTag = [source substringWithRange:openRange];
            NSString *kind = FBPDashFirstCapture(patterns.contentType, openTag)
                                 ?: FBPDashFirstCapture(patterns.mimeType, openTag);
            [self scrapeRegion:[source substringWithRange:bodyRange]
                          kind:kind.lowercaseString
                      patterns:patterns];
        }
    }

    // No AdaptationSet survived either, so scan the whole document: a
    // <Representation> with its own contentType is still readable here.
    if (self.videoCandidates.count == 0) {
        [self scrapeRegion:source kind:nil patterns:patterns];
    }

    [self note:@"scrape: %lu AdaptationSet(s), %lu video + %lu audio rep(s) recovered",
               (unsigned long)sets, (unsigned long)self.videoCandidates.count,
               (unsigned long)self.audioCandidates.count];
}

@end

#pragma mark - Manifest

@implementation FBPDashManifest

- (instancetype)initWithVideo:(NSArray<FBPDashRepresentation *> *)video
                        audio:(FBPDashRepresentation *)audio
                audioIsNotAAC:(BOOL)audioIsNotAAC
                     duration:(NSTimeInterval)duration
                 droppedNotes:(NSArray<NSString *> *)droppedNotes {
    if ((self = [super init])) {
        _videoRepresentations = [video copy];
        _audioRepresentation = audio;
        _audioIsNotAAC = audioIsNotAAC;
        _duration = duration;
        _droppedNotes = [droppedNotes copy] ?: @[];
    }
    return self;
}

/// One row per FBQualityLabel, highest bandwidth wins, H.264 wins a tie.
///
/// Keyed on the label text, not on @height or -qualityRank: Meta encodes several
/// CRFs per resolution, so that number collapses four rungs into one row.
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

    // Best first: frame size, then the label's own number, then bitrate. The
    // middle key keeps Meta's CRF ladder in a readable order, since those rungs
    // tie on -qualityRank. Codec is deliberately not a sort key: grouping by it
    // would scramble the ladder.
    return [best.allValues sortedArrayUsingComparator:
        ^NSComparisonResult(FBPDashRepresentation *a, FBPDashRepresentation *b) {
            if (a.qualityRank != b.qualityRank) {
                return a.qualityRank > b.qualityRank ? NSOrderedAscending : NSOrderedDescending;
            }
            NSInteger labelA = FBPDashRankFromQualityLabel(a.qualityLabel);
            NSInteger labelB = FBPDashRankFromQualityLabel(b.qualityLabel);
            if (labelA != labelB) {
                return labelA > labelB ? NSOrderedAscending : NSOrderedDescending;
            }
            if (a.bandwidth != b.bandwidth) {
                return a.bandwidth > b.bandwidth ? NSOrderedAscending : NSOrderedDescending;
            }
            return NSOrderedSame;
        }];
}

/// Ranked rather than filtered: AAC, then a standard channel layout (an fb360
/// ambisonic track loses to stereo even at a third of the bitrate, since
/// flattening it onto flat video sounds wrong), then FBDefaultQuality, then
/// bitrate. When no AAC track survives the best of whatever is there still comes
/// back, because audio is never a reason to withhold the video ladder.
static FBPDashRepresentation *
FBPDashPickAudio(NSArray<FBPDashRepresentation *> *candidates) {
    FBPDashRepresentation *best = nil;
    for (FBPDashRepresentation *candidate in candidates) {
        if (!best) { best = candidate; continue; }
        if (candidate.isAAC != best.isAAC) {
            if (candidate.isAAC) best = candidate;
            continue;
        }
        if (candidate.hasKnownChannelLayout != best.hasKnownChannelLayout) {
            if (candidate.hasKnownChannelLayout) best = candidate;
            continue;
        }
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
    // Under 33 characters there is no room for an <MPD>, a <BaseURL> and a
    // closing tag.
    if (xml.length < kFBPDashMinXMLLength || xml.length > kFBPDashMaxXMLLength) return nil;

    NSString *source = xml;

    // -DashPlaylist hands over raw XML, which must NOT be percent-decoded: that
    // would turn every `+` in a signed URL into a space. The web GraphQL payload
    // is encoded, so decode only when the document is plainly not XML yet.
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
        // The return value is deliberately ignored: truncated XML reports its
        // error after the elements that did parse have reached the delegate,
        // and those are usable.
        [parser parse];
    } @catch (__unused NSException *exception) {
        return nil;
    }

    // Neither document-level gate survives: not being rooted in <MPD>, and
    // MPD@type="dynamic", both cost real ladders. They are notes now.
    if (!delegate.sawMPD) {
        [delegate note:@"no <MPD> element — read anyway"];
    }
    if (delegate.mpdType.length > 0 && ![delegate.mpdType isEqualToString:@"static"]) {
        [delegate note:@"MPD@type=\"%@\" (not static) — read anyway; a live "
                        "manifest's BaseURL may be a path prefix rather than a file",
                       delegate.mpdType];
    }

    NSArray<FBPDashRepresentation *> *video = FBPDashDedupeVideo(delegate.videoCandidates);

    // The fallback. NSXMLParser produced nothing from a document long enough to
    // hold a manifest — what one unescaped `&` in the first <BaseURL> looks like
    // from here.
    if (video.count == 0) {
        [delegate note:@"XML pass produced no video rung — re-reading with the "
                        "regex scraper"];
        [delegate scrapeDocument:source];
        video = FBPDashDedupeVideo(delegate.videoCandidates);
    }

    // The structural shapes that used to be refusals, summarised once each
    // rather than once per representation, so the note cap is not spent saying
    // the same thing six times.
    if (delegate.keptWithoutSegmentBase > 0) {
        [delegate note:@"%lu rep(s) had no <SegmentBase> child (%lu carried "
                        "FBInitializationRange/FBIndexRange instead) — no longer refused",
                       (unsigned long)delegate.keptWithoutSegmentBase,
                       (unsigned long)delegate.keptWithFBRangeAttributes];
    }
    if (delegate.keptWithSegmentTemplate > 0) {
        [delegate note:@"%lu rep(s) under a <SegmentTemplate>/<SegmentList> — no "
                        "longer refused; if its BaseURL is a path prefix the GET will fail",
                       (unsigned long)delegate.keptWithSegmentTemplate];
    }
    if (delegate.keptWithContentProtection > 0) {
        [delegate note:@"%lu rep(s) carried <ContentProtection> — no longer refused; "
                        "if it really is encrypted the saved file will not play",
                       (unsigned long)delegate.keptWithContentProtection];
    }

    if (video.count == 0) return nil;

    FBPDashRepresentation *audio = FBPDashPickAudio(delegate.audioCandidates);
    return [[FBPDashManifest alloc] initWithVideo:video
                                            audio:audio
                                    audioIsNotAAC:(audio != nil && !audio.isAAC)
                                         duration:delegate.duration
                                     droppedNotes:delegate.droppedNotes];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ %lu video, audio=%@%@, %.3fs, %lu dropped>",
            NSStringFromClass(self.class),
            (unsigned long)self.videoRepresentations.count,
            self.audioRepresentation ? self.audioRepresentation.codecs ?: @"yes" : @"none",
            self.audioIsNotAAC ? @" (not AAC)" : @"",
            self.duration, (unsigned long)self.droppedNotes.count];
}

@end
