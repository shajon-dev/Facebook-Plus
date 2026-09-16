// Single constructor. Each hook group installs itself only after checking that
// its target class and selector actually exist in this build of Facebook, so a
// missing target degrades that one feature instead of taking the tweak down.

#import "FBPlus.h"
#import "FBPPrefs.h"

#import <mach-o/dyld.h>

extern void FBPInitFeedHooks(void);
extern void FBPInitStoryHooks(void);
extern void FBPInitConfirmHooks(void);
extern void FBPInitChromeHooks(void);
extern void FBPInitOLEDHooks(void);
extern void FBPInitMenuHooks(void);

/// Runs every installer. Each group latches itself with FBP_ONCE, so calling
/// this repeatedly installs each hook exactly once.
static void FBPInstallHooks(void) {
    FBPInitFeedHooks();
    FBPInitStoryHooks();
    FBPInitConfirmHooks();
    FBPInitChromeHooks();
    FBPInitOLEDHooks();
    FBPInitMenuHooks();
}

/// dyld calls this for every image already loaded, then again for each new one.
///
/// This is why the deferred-install pattern is needed at all: Facebook links only
/// FBSharedFramework at launch and dlopens the rest on demand, so a one-shot %ctor
/// observes only a fraction of the app's classes.
static void FBPImageDidLoad(const struct mach_header *header, intptr_t slide) {
    FBPInstallHooks();
}

%ctor {
    @autoreleasepool {
        // Only ever inject into Facebook. The Filter plist already restricts
        // this, but an IPA-embedded build has no filter to rely on.
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        if (![bundleID isEqualToString:@"com.facebook.Facebook"]) return;

        // Registers defaults before any hook can read a preference.
        (void)FBPPrefs.shared;

        // Installs what is available now, and again as each framework arrives.
        FBPInstallHooks();
        _dyld_register_func_for_add_image(&FBPImageDidLoad);

        FBPLog(@"loaded into %@", bundleID);
    }
}
