// Single constructor. Each hook group confirms its target class and selector
// exist in this build first, so a missing target costs one feature, not the tweak.

#import "FBPlus.h"
#import "FBPPrefs.h"

#import <mach-o/dyld.h>

extern void FBPInitFeedHooks(void);
extern void FBPInitLanguagePackHooks(void);
extern void FBPInitFeedSurveyHooks(void);
extern void FBPInitAdsHooks(void);
extern void FBPInitCommentHooks(void);
extern void FBPInitReelsSurveyHooks(void);
extern void FBPInitReelsMidCardHooks(void);
extern void FBPInitStoryHooks(void);
extern void FBPInitConfirmHooks(void);
extern void FBPInitActionConfirm(void);
extern void FBPInitChromeHooks(void);
extern void FBPInitOLEDHooks(void);
extern void FBPInitHDRHooks(void);
extern void FBPInitPlusHooks(void);
extern void FBPInitFontHooks(void);
extern void FBPInitReelsDownloader(void);
extern void FBPInitLinkHooks(void);
extern void FBPInitLinkBridge(void);
extern void FBPInitCallBlocker(void);
extern void FBPInitSidebarHooks(void);

/// Settles off the main thread whether this device can decode AV1, so the first
/// caller is not the DASH reader on the main thread. `extern "C"`, unlike the
/// installers above: logos compiles this file as Objective-C++ and this symbol
/// lives in a plain .m, so a bare `extern` would look for a mangled name.
extern "C" void FBPMediaConversionPrewarm(void);

/// Same, for borrowing Facebook's own libavcodec to decode VP9.
extern "C" void FBPVP9BridgePrewarm(void);

/// Each group latches with FBP_ONCE, so repeat calls install each hook once.
static void FBPInstallHooks(void) {
    FBPInitFeedHooks();
    FBPInitLanguagePackHooks();
    FBPInitFeedSurveyHooks();
    FBPInitAdsHooks();
    FBPInitCommentHooks();
    FBPInitReelsSurveyHooks();
    FBPInitReelsMidCardHooks();
    FBPInitStoryHooks();
    FBPInitConfirmHooks();
    FBPInitActionConfirm();
    FBPInitChromeHooks();
    FBPInitOLEDHooks();
    FBPInitHDRHooks();
    FBPInitPlusHooks();
    FBPInitFontHooks();
    FBPInitReelsDownloader();
    FBPInitLinkHooks();
    FBPInitLinkBridge();
    FBPInitCallBlocker();
    FBPInitSidebarHooks();
}

/// Facebook links only FBSharedFramework at launch and dlopens the rest, so a
/// one-shot %ctor would see only a fraction of its classes.
static void FBPImageDidLoad(const struct mach_header *header, intptr_t slide) {
    FBPInstallHooks();
}

/// Re-injecting a newer build into an already-injected IPA leaves the older
/// dylib in Frameworks/ and in the load commands, and dyld loads both. The older
/// copy cannot report itself, so this one names every copy at launch.
static void FBPReportDuplicateLoads(void) {
    NSMutableArray<NSString *> *copies = [NSMutableArray array];
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        NSString *path = @(name);
        // By file name, not path prefix: a stale copy in an IPA's Frameworks/
        // keeps the same name under a different directory.
        if ([path.lastPathComponent rangeOfString:@"FacebookPlus"
                                          options:NSCaseInsensitiveSearch].location != NSNotFound) {
            [copies addObject:path];
        }
    }
    if (copies.count < 2) return;

    FBPTraceLine(@"%lu copies of the tweak are loaded — the oldest one wins "
                 @"wherever they disagree, and both log",
                 (unsigned long)copies.count);
    for (NSString *path in copies) FBPTraceLine(@"  loaded · %@", path);
}

%ctor {
    @autoreleasepool {
        // Registers defaults before any hook can read a preference.
        (void)FBPPrefs.shared;

        FBPLogClearIfDue();
        FBPResolveDeviceName();
        FBPTraceLine(@"launch · on %@ into %@", FBPDeviceDisplayName(),
                     NSBundle.mainBundle.bundleIdentifier);

        FBPReportDuplicateLoads();

        FBPInstallHooks();
        _dyld_register_func_for_add_image(&FBPImageDidLoad);

        // Outside FBPInstallHooks, which dyld repeats for every image.
        FBPMediaConversionPrewarm();
        FBPVP9BridgePrewarm();

        // Inlined, not a local: in release FBPLog is a no-op and a local would
        // be unused.
        FBPLog(@"loaded into %@", NSBundle.mainBundle.bundleIdentifier);
    }
}
