// Custom app font.
//
// Every visible label asks UIFont for a face, either a system font or a named
// one (the bundled "Optimistic" family), so those factory methods are the
// single chokepoint: they are hooked and re-pointed at the user's font at the
// same size and nearest weight.
//
// Only *text* is swapped. Facebook draws its tab-bar and button glyphs from a
// private "Facebook-Icons" font, and replacing that turns every icon into
// garbage, so a face is replaced only when its name is a known Facebook text
// family or a system font; icon, emoji, symbol and unknown third-party faces
// pass through.
//
// The tweak's own UI and the replacement-building below both create UIFont
// objects, so a thread-local latch (FBPFontScopeActive) makes those fall
// through to the original — the tweak UI keeps its look and the hooks never
// recurse.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPResources.h"
#import "FBPTrace.h"

#import <CoreText/CoreText.h>
#import <objc/runtime.h>

#pragma mark - Registered custom fonts

// Every available family, in load order; rebuilt on import or delete.
static NSArray<NSString *> *gFamilies = nil;

// The user-imported families (the only deletable ones) and their files.
static NSMutableArray<NSString *> *gUserFamilies = nil;
static NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *gUserFiles = nil;

/// A writable folder the tweak owns, where fonts the user imports from Files are
/// kept so they survive relaunches and sit beside the bundled ones.
extern "C" NSString *FBPUserFontsDirectoryPath(void) {
    NSString *base = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [base stringByAppendingPathComponent:@"FacebookPlusFonts"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES attributes:nil error:NULL];
    return dir;
}

/// Registers every .ttf/.otf/.ttc under a directory with Core Text and appends
/// their family names, de-duplicated. Re-registering is harmless. With
/// @c isUser the family and its file are also recorded as deletable.
static void FBPRegisterFontsIn(NSString *path, BOOL isUser,
                              NSMutableArray<NSString *> *families) {
    NSArray<NSString *> *names =
        [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:NULL];
    for (NSString *name in [names sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
        NSString *ext = name.pathExtension.lowercaseString;
        if (!([ext isEqualToString:@"ttf"] || [ext isEqualToString:@"otf"] ||
              [ext isEqualToString:@"ttc"])) continue;

        NSString *filePath = [path stringByAppendingPathComponent:name];
        NSURL *url = [NSURL fileURLWithPath:filePath];
        CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url,
                                         kCTFontManagerScopeProcess, NULL);

        // From the file, not the filename, so it lists under its real family.
        NSArray *descriptors = (__bridge_transfer NSArray *)
            CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)url);
        for (id d in descriptors) {
            NSString *family = (__bridge_transfer NSString *)
                CTFontDescriptorCopyAttribute((__bridge CTFontDescriptorRef)d, kCTFontFamilyNameAttribute);
            if (family.length == 0) continue;
            if (![families containsObject:family]) [families addObject:family];
            if (isUser) {
                if (![gUserFamilies containsObject:family]) [gUserFamilies addObject:family];
                NSMutableArray *paths = gUserFiles[family] ?: [NSMutableArray array];
                if (![paths containsObject:filePath]) [paths addObject:filePath];
                gUserFiles[family] = paths;
            }
        }
    }
}

/// (Re)scans the bundled fonts and the user-imported ones into gFamilies.
extern "C" void FBPReloadFonts(void) {
    gUserFamilies = [NSMutableArray array];
    gUserFiles = [NSMutableDictionary dictionary];

    NSMutableArray<NSString *> *families = [NSMutableArray array];
    NSBundle *bundle = NSBundle.fbp_resourceBundle;
    if (bundle) FBPRegisterFontsIn(bundle.bundlePath, NO, families);
    FBPRegisterFontsIn(FBPUserFontsDirectoryPath(), YES, families);
    gFamilies = [families copy];
}

// Exposed to the Fonts picker (plain C linkage so the ObjC controller links).
extern "C" NSArray<NSString *> *FBPRegisteredFontFamilies(void) {
    return gFamilies ?: @[];
}

/// The subset of families the user imported — the only ones that may be deleted.
extern "C" NSArray<NSString *> *FBPUserFontFamilies(void) {
    return gUserFamilies ?: @[];
}

/// Unregisters and deletes every file backing an imported family, then
/// rebuilds. Bundled families match nothing and are ignored.
extern "C" void FBPDeleteUserFont(NSString *family) {
    NSArray<NSString *> *paths = gUserFiles[family];
    for (NSString *path in paths) {
        NSURL *url = [NSURL fileURLWithPath:path];
        CTFontManagerUnregisterFontsForURL((__bridge CFURLRef)url,
                                           kCTFontManagerScopeProcess, NULL);
        [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
    }
    FBPReloadFonts();
}

#pragma mark - Selection

/// The chosen family, or nil when the user is on the original font.
static NSString *FBPSelectedFontFamily(void) {
    NSString *family = [FBPPrefs.shared stringForKey:FBPKeyFont];
    return family.length ? family : nil;
}

/// Custom-font size multiplier. Custom faces often render smaller than the app's
/// own font at the same point size, so the Fonts page lets the user scale them.
/// 1.0 (unset) leaves sizes exactly as the app asked; clamped to a sane range.
static CGFloat FBPFontScale(void) {
    NSString *raw = [FBPPrefs.shared stringForKey:FBPKeyFontScale];
    if (raw.length == 0) return 1.0;
    CGFloat scale = raw.doubleValue;
    if (scale < 1.0) return 1.0;
    if (scale > 3.0) return 3.0;
    return scale;
}

/// Sizes already emitted as scaled. The comment composer reads back its text
/// view's already-scaled point size and asks for a font at that size on every
/// keystroke, so without this the scale compounds and the text grows per
/// character. Keyed to 0.1pt so a float round-trip matches, bounded, reset when
/// the scale changes, and consulted only while a scale is in effect. A label
/// whose design size equals one already emitted renders unscaled: cosmetic.
static NSMutableSet<NSNumber *> *gFBPScaledSizes;
static CGFloat gFBPScaledForScale = 1.0;
static dispatch_once_t gFBPScaledOnce;

static inline NSNumber *FBPScaledSizeKey(CGFloat s) { return @(llround(s * 10.0)); }

/// Builds the replacement face at the requested size and weight. Guarded by the
/// scope latch so the UIFont calls here are not themselves replaced.
static UIFont *FBPReplacementFont(CGFloat size, UIFontWeight weight) {
    NSString *family = FBPSelectedFontFamily();
    if (!family || size <= 0) return nil;

    CGFloat scale = FBPFontScale();
    CGFloat outSize = size;
    if (scale != 1.0) {
        dispatch_once(&gFBPScaledOnce, ^{ gFBPScaledSizes = [NSMutableSet set]; });
        @synchronized (gFBPScaledSizes) {
            if (gFBPScaledForScale != scale) {   // scale changed — old sizes are stale
                [gFBPScaledSizes removeAllObjects];
                gFBPScaledForScale = scale;
            }
            if ([gFBPScaledSizes containsObject:FBPScaledSizeKey(size)]) {
                outSize = size;                  // already scaled once — do not scale again
            } else {
                outSize = size * scale;
                if (gFBPScaledSizes.count < 512) [gFBPScaledSizes addObject:FBPScaledSizeKey(outSize)];
            }
        }
    }

    FBPSetFontScopeActive(YES);
    UIFontDescriptor *descriptor =
        [UIFontDescriptor fontDescriptorWithFontAttributes:@{
            UIFontDescriptorFamilyAttribute : family,
            UIFontDescriptorTraitsAttribute : @{ UIFontWeightTrait : @(weight) },
        }];
    UIFont *font = [UIFont fontWithDescriptor:descriptor size:outSize];
    FBPSetFontScopeActive(NO);
    return font;
}

#pragma mark - Which faces to replace

/// A weight parsed out of a font name ("…-Semibold", "…Bold…"), or regular.
static UIFontWeight FBPWeightFromName(NSString *lower) {
    if ([lower containsString:@"black"] || [lower containsString:@"heavy"]) return UIFontWeightHeavy;
    if ([lower containsString:@"semibold"])  return UIFontWeightSemibold;  // before "bold"
    if ([lower containsString:@"bold"])      return UIFontWeightBold;
    if ([lower containsString:@"medium"])    return UIFontWeightMedium;
    if ([lower containsString:@"light"])     return UIFontWeightLight;
    if ([lower containsString:@"thin"])      return UIFontWeightThin;
    return UIFontWeightRegular;
}

/// YES when @c name is Facebook body/UI text that may be swapped. Icon, emoji,
/// symbol and unknown third-party faces return NO.
static BOOL FBPShouldReplaceName(NSString *name) {
    if (name.length == 0) return NO;
    NSString *lower = name.lowercaseString;

    // Never the icon / emoji / symbol faces.
    if ([lower containsString:@"icon"])   return NO;   // Facebook-Icons
    if ([lower containsString:@"emoji"])  return NO;
    if ([lower containsString:@"symbol"]) return NO;

    // The system font is often created by its private dotted name.
    if ([name hasPrefix:@"."]) return YES;

    // Facebook's own text families.
    return [lower containsString:@"optimistic"] ||
           [lower containsString:@"facebooksans"] || [lower containsString:@"facebook sans"] ||
           [lower containsString:@"facebooknarrow"] || [lower containsString:@"facebook narrow"] ||
           [lower containsString:@"aveny"];
}

#pragma mark - Hooks

%group FBPFonts

%hook UIFont

+ (UIFont *)systemFontOfSize:(CGFloat)fontSize {
    FBPTraceFire("fonts.UIFont.systemFontOfSize");
    if (FBPFontScopeActive()) return %orig;
    return FBPReplacementFont(fontSize, UIFontWeightRegular) ?: %orig;
}

+ (UIFont *)boldSystemFontOfSize:(CGFloat)fontSize {
    FBPTraceFire("fonts.UIFont.boldSystemFontOfSize");
    if (FBPFontScopeActive()) return %orig;
    return FBPReplacementFont(fontSize, UIFontWeightBold) ?: %orig;
}

+ (UIFont *)italicSystemFontOfSize:(CGFloat)fontSize {
    FBPTraceFire("fonts.UIFont.italicSystemFontOfSize");
    if (FBPFontScopeActive()) return %orig;
    return FBPReplacementFont(fontSize, UIFontWeightRegular) ?: %orig;
}

+ (UIFont *)systemFontOfSize:(CGFloat)fontSize weight:(UIFontWeight)weight {
    FBPTraceFire("fonts.UIFont.systemFontOfSizeWeight");
    if (FBPFontScopeActive()) return %orig;
    return FBPReplacementFont(fontSize, weight) ?: %orig;
}

+ (UIFont *)preferredFontForTextStyle:(UIFontTextStyle)style {
    FBPTraceFire("fonts.UIFont.preferredFontForTextStyle");
    UIFont *original = %orig;
    if (FBPFontScopeActive()) return original;
    return FBPReplacementFont(original.pointSize, UIFontWeightRegular) ?: original;
}

+ (UIFont *)fontWithName:(NSString *)name size:(CGFloat)fontSize {
    FBPTraceFire("fonts.UIFont.fontWithName");
    if (FBPFontScopeActive() || !FBPShouldReplaceName(name)) return %orig;
    return FBPReplacementFont(fontSize, FBPWeightFromName(name.lowercaseString)) ?: %orig;
}

+ (UIFont *)fontWithDescriptor:(UIFontDescriptor *)descriptor size:(CGFloat)fontSize {
    FBPTraceFire("fonts.UIFont.fontWithDescriptor");
    if (FBPFontScopeActive()) return %orig;

    NSString *family = descriptor.fontAttributes[UIFontDescriptorFamilyAttribute]
        ?: descriptor.fontAttributes[UIFontDescriptorNameAttribute];
    if (!FBPShouldReplaceName(family)) return %orig;

    CGFloat size = fontSize > 0 ? fontSize : descriptor.pointSize;
    NSDictionary *traits = descriptor.fontAttributes[UIFontDescriptorTraitsAttribute];
    UIFontWeight weight = UIFontWeightRegular;
    NSNumber *w = traits[UIFontWeightTrait];
    if ([w isKindOfClass:NSNumber.class]) weight = w.doubleValue;

    return FBPReplacementFont(size, weight) ?: %orig;
}

%end

%end // FBPFonts

void FBPInitFontHooks(void) {
    FBP_ONCE(gFontsInstalled) {
        FBPReloadFonts();
        %init(FBPFonts);
    }
}
