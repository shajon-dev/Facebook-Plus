// "Disable HDR" — force SDR rendering app-wide, so HDR photos and video stop
// over-brightening the app (https://github.com/shajon-dev/Facebook-Plus/issues/4).
//
// Two public, app-wide, version-stable levers, neither tied to a Facebook class
// name, so there is nothing to rename and break:
//
//   * UIImageView.preferredImageDynamicRange (iOS 17+). Facebook decodes HDR
//     photos with gain maps and lets the image view render them above SDR;
//     answering UIImageDynamicRangeStandard (0) from the getter clamps every
//     image view to SDR regardless of what Facebook set on it.
//   * CALayer.wantsExtendedDynamicRangeContent. Any layer that opts into the
//     display's extended range — AVPlayerLayer for HDR video, CAMetalLayer for
//     HDR-rendered content — is forced back to SDR by rewriting every set to NO.
//
// WHY A GETTER AND A SETTER, NOT PER-CALL TRACING
// ------------------------------------------------------------------------
// Both are hot paths (the layer setter runs constantly while scrolling), so they
// do no work and emit no trace when the toggle is off, and never log per call —
// only the one-time install line below. The override only ever yields a value
// the system already accepts (Standard / NO), so it cannot crash the host, and
// each group installs only when its selector exists, so a platform without the
// API is left untouched.

#import "FBPlus.h"
#import "FBPPrefs.h"

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#pragma mark - Images

%group FBPHDRImage

%hook UIImageView

// Declared NSInteger rather than UIImageDynamicRange so it builds against an SDK
// older than iOS 17; the enum is NSInteger-backed and Standard == 0.
- (NSInteger)preferredImageDynamicRange {
    if (FBPEnabled(FBPKeyDisableHDR)) return 0; // UIImageDynamicRangeStandard
    return %orig;
}

%end

%end // FBPHDRImage

#pragma mark - Layers (EDR: HDR video + Metal)

%group FBPHDRLayer

%hook CALayer

- (void)setWantsExtendedDynamicRangeContent:(BOOL)wants {
    // A local, not %orig(NO) inline: Logos mis-parses a literal argument to %orig
    // ("Invalid argument structure"), but a plain identifier it forwards cleanly.
    BOOL effective = wants;
    if (FBPEnabled(FBPKeyDisableHDR)) effective = NO;
    %orig(effective);
}

%end

%end // FBPHDRLayer

#pragma mark - Init

void FBPInitHDRHooks(void) {
    if ([UIImageView instancesRespondToSelector:@selector(preferredImageDynamicRange)]) {
        FBP_ONCE(gHDRImage) {
            %init(FBPHDRImage);
            FBPLog(@"hdr: image dynamic-range clamp installed");
        }
    }
    if ([CALayer instancesRespondToSelector:@selector(setWantsExtendedDynamicRangeContent:)]) {
        FBP_ONCE(gHDRLayer) {
            %init(FBPHDRLayer);
            FBPLog(@"hdr: layer EDR clamp installed");
        }
    }
}
