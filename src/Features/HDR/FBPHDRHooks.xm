// "Disable HDR" — force SDR rendering app-wide, so HDR photos and video stop
// over-brightening the app (https://github.com/shajon-dev/Facebook-Plus/issues/4).
//
// Three public, app-wide levers, none tied to a Facebook class name:
//
//   * CALayer.preferredDynamicRange — the current EDR control (iOS 17+). On
//     iOS 17-26 wantsExtendedDynamicRangeContent is deprecated and, once
//     preferredDynamicRange is set to anything other than Standard, no longer
//     clamps — so this is the lever that actually matters on a modern build,
//     and the one Facebook sets (setPreferredDynamicRange: is in its binary).
//     Answering CADynamicRangeStandard (0) from the getter clamps the layer to
//     SDR, which covers HDR video (AVPlayerLayer) and Metal content.
//   * CALayer.wantsExtendedDynamicRangeContent — the older control, still set on
//     some paths; every set is rewritten to NO as a backstop.
//   * UIImageView.preferredImageDynamicRange — clamps HDR gain-map photos to SDR.
//
// Each only ever yields a value the system already accepts (Standard / NO), so
// it cannot crash the host, and each group installs only when its selector is
// present. A one-time trace per lever (the first time it clamps) records that
// the hook is live without logging on every frame.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPTrace.h"

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// CADynamicRangeStandard / UIImageDynamicRangeStandard are both 0. Declared as a
// plain constant so this builds against an SDK that predates either enum.
static const NSInteger kFBPDynamicRangeStandard = 0;

#pragma mark - Images

%group FBPHDRImage

%hook UIImageView

- (NSInteger)preferredImageDynamicRange {
    if (FBPEnabled(FBPKeyDisableHDR)) {
        static BOOL traced = NO;
        if (!traced) { traced = YES; FBPTraceFire("hdr.UIImageView.preferredImageDynamicRange.clamped"); }
        return kFBPDynamicRangeStandard;
    }
    return %orig;
}

%end

%end // FBPHDRImage

#pragma mark - Layers (EDR: HDR video + Metal)

%group FBPHDRLayer

%hook CALayer

// The modern lever — overrides wantsExtendedDynamicRangeContent on iOS 17+.
// Both the setter and getter are forced to Standard: the setter so the stored
// value is SDR whether Core Animation later reads it via the ivar or the
// accessor, the getter as a backstop for layers the app never set it on.
- (void)setPreferredDynamicRange:(NSInteger)range {
    NSInteger effective = range;
    if (FBPEnabled(FBPKeyDisableHDR) && range != kFBPDynamicRangeStandard) {
        effective = kFBPDynamicRangeStandard;
        static BOOL traced = NO;
        if (!traced) { traced = YES; FBPTraceFire("hdr.CALayer.setPreferredDynamicRange.forcedStandard"); }
    }
    %orig(effective);
}

- (NSInteger)preferredDynamicRange {
    if (FBPEnabled(FBPKeyDisableHDR)) {
        static BOOL traced = NO;
        if (!traced) { traced = YES; FBPTraceFire("hdr.CALayer.preferredDynamicRange.clamped"); }
        return kFBPDynamicRangeStandard;
    }
    return %orig;
}

// The deprecated lever — kept as a backstop for any path still setting it.
- (void)setWantsExtendedDynamicRangeContent:(BOOL)wants {
    BOOL effective = wants;
    if (FBPEnabled(FBPKeyDisableHDR) && wants) {
        effective = NO;
        static BOOL traced = NO;
        if (!traced) { traced = YES; FBPTraceFire("hdr.CALayer.wantsExtendedDynamicRangeContent.forcedOff"); }
    }
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
    // Install when either layer lever exists; the group hooks both, and a method
    // the platform lacks is simply not swizzled.
    if ([CALayer instancesRespondToSelector:@selector(preferredDynamicRange)] ||
        [CALayer instancesRespondToSelector:@selector(setWantsExtendedDynamicRangeContent:)]) {
        FBP_ONCE(gHDRLayer) {
            %init(FBPHDRLayer);
            FBPLog(@"hdr: layer EDR clamp installed (preferredDynamicRange=%d, wantsEDR=%d)",
                   [CALayer instancesRespondToSelector:@selector(preferredDynamicRange)],
                   [CALayer instancesRespondToSelector:@selector(setWantsExtendedDynamicRangeContent:)]);
        }
    }
}
