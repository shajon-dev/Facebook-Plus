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

#pragma mark - Facebook image views (photos)

// Facebook's own image views are UIView subclasses — NOT UIImageView — each with
// its own preferredImageDynamicRange property backed by a private ivar, so the
// UIImageView hook above never reaches them. That is why HDR photos still
// over-brightened. Force the setter (the value Facebook actually writes) and the
// getter to Standard on each; FB also asks -_isImageHDR: before boosting, so
// answering NO keeps the image on the SDR path.
%group FBPHDRFBImageViews

%hook FBWebImageView
- (void)setPreferredImageDynamicRange:(NSInteger)range {
    NSInteger effective = range;
    if (FBPEnabled(FBPKeyDisableHDR)) {
        effective = kFBPDynamicRangeStandard;
        static BOOL traced = NO;
        if (!traced) { traced = YES; FBPTraceFire("hdr.FBWebImageView.setPreferredImageDynamicRange.forcedStandard"); }
    }
    %orig(effective);
}
- (NSInteger)preferredImageDynamicRange {
    if (FBPEnabled(FBPKeyDisableHDR)) return kFBPDynamicRangeStandard;
    return %orig;
}
- (BOOL)_isImageHDR:(id)arg {
    if (FBPEnabled(FBPKeyDisableHDR)) return NO;
    return %orig;
}
%end

%hook FBNetworkImageView
- (void)setPreferredImageDynamicRange:(NSInteger)range {
    NSInteger effective = range;
    if (FBPEnabled(FBPKeyDisableHDR)) effective = kFBPDynamicRangeStandard;
    %orig(effective);
}
- (NSInteger)preferredImageDynamicRange {
    if (FBPEnabled(FBPKeyDisableHDR)) return kFBPDynamicRangeStandard;
    return %orig;
}
%end

%hook FBWebImageCoreAnimatedImageView
- (void)setPreferredImageDynamicRange:(NSInteger)range {
    NSInteger effective = range;
    if (FBPEnabled(FBPKeyDisableHDR)) effective = kFBPDynamicRangeStandard;
    %orig(effective);
}
- (NSInteger)preferredImageDynamicRange {
    if (FBPEnabled(FBPKeyDisableHDR)) return kFBPDynamicRangeStandard;
    return %orig;
}
%end

%end // FBPHDRFBImageViews

// The animated-image view in the main Facebook binary, same private property.
%group FBPHDRMRCImageView

%hook MRCAnimatedImageView
- (void)setPreferredImageDynamicRange:(NSInteger)range {
    NSInteger effective = range;
    if (FBPEnabled(FBPKeyDisableHDR)) {
        effective = kFBPDynamicRangeStandard;
        static BOOL traced = NO;
        if (!traced) { traced = YES; FBPTraceFire("hdr.MRCAnimatedImageView.setPreferredImageDynamicRange.forcedStandard"); }
    }
    %orig(effective);
}
- (NSInteger)preferredImageDynamicRange {
    if (FBPEnabled(FBPKeyDisableHDR)) return kFBPDynamicRangeStandard;
    return %orig;
}
%end

%end // FBPHDRMRCImageView

#pragma mark - Video inverse-tonemap (the EDR boost on playback)

// HDR video and Reels glare rides Facebook's own inverse-tonemap path — an
// SDR->HDR expansion on its Metal / sample-buffer player layers — which is
// INDEPENDENT of CALayer.preferredDynamicRange, so clamping the layer alone left
// video glaring. Force every inverse-tonemap enable to NO. Each takes a BOOL and
// the forced value is the app's own SDR default, so it is crash-safe. (A literal
// is routed through a local to avoid logos' "%orig(NO)" argument gotcha.)
%group FBPHDRVideoTonemap

%hook FNFCAMetalLayer
- (void)setEnableInverseTonemap:(BOOL)on {
    BOOL effective = on;
    if (FBPEnabled(FBPKeyDisableHDR)) {
        effective = NO;
        static BOOL traced = NO;
        if (!traced) { traced = YES; FBPTraceFire("hdr.FNFCAMetalLayer.setEnableInverseTonemap.forcedOff"); }
    }
    %orig(effective);
}
- (void)setInverseTonemappingEnabled:(BOOL)on {
    BOOL effective = on;
    if (FBPEnabled(FBPKeyDisableHDR)) effective = NO;
    %orig(effective);
}
%end

%hook FBVideoPlaybackController
- (void)setPrecomputedEnableCAMetalLayerInverseTonemap:(BOOL)on {
    BOOL effective = on;
    if (FBPEnabled(FBPKeyDisableHDR)) effective = NO;
    %orig(effective);
}
- (void)_setEnableInverseTonemap:(BOOL)on {
    BOOL effective = on;
    if (FBPEnabled(FBPKeyDisableHDR)) effective = NO;
    %orig(effective);
}
%end

%hook FNFVideoPlaybackController
- (void)setEnableInverseTonemap:(BOOL)on {
    BOOL effective = on;
    if (FBPEnabled(FBPKeyDisableHDR)) effective = NO;
    %orig(effective);
}
%end

%hook FNFPlayerDisplayRendering
- (void)setEnableInverseTonemap:(BOOL)on {
    BOOL effective = on;
    if (FBPEnabled(FBPKeyDisableHDR)) effective = NO;
    %orig(effective);
}
%end

%hook FNFAVSampleBufferDisplayLayer
- (void)setInverseTonemappingEnabled:(BOOL)on {
    BOOL effective = on;
    if (FBPEnabled(FBPKeyDisableHDR)) effective = NO;
    %orig(effective);
}
%end

%hook FNFIOSurfacePlayerLayer
- (void)setInverseTonemappingEnabled:(BOOL)on {
    BOOL effective = on;
    if (FBPEnabled(FBPKeyDisableHDR)) effective = NO;
    %orig(effective);
}
%end

%hook FNFPlayerMetalLayer
- (void)setInverseTonemappingEnabled:(BOOL)on {
    BOOL effective = on;
    if (FBPEnabled(FBPKeyDisableHDR)) effective = NO;
    %orig(effective);
}
%end

%end // FBPHDRVideoTonemap

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

    // Facebook's own image views are UIView subclasses with their own
    // dynamic-range property, so the UIImageView hook never reaches them (the
    // real cause of HDR photos still glaring). Install when any is present; a
    // class the build lacks is simply not swizzled.
    if (objc_getClass("FBWebImageView") || objc_getClass("FBNetworkImageView") ||
        objc_getClass("FBWebImageCoreAnimatedImageView")) {
        FBP_ONCE(gHDRFBImages) {
            %init(FBPHDRFBImageViews);
            FBPLog(@"hdr: Facebook image-view dynamic-range clamp installed");
        }
    }
    if (objc_getClass("MRCAnimatedImageView")) {
        FBP_ONCE(gHDRMRC) { %init(FBPHDRMRCImageView); }
    }

    // Facebook's video inverse-tonemap (SDR->HDR EDR boost) is independent of the
    // layer dynamic-range clamp — the real cause of HDR video/Reels still
    // glaring. Install when any player class is present.
    if (objc_getClass("FNFCAMetalLayer") || objc_getClass("FBVideoPlaybackController")) {
        FBP_ONCE(gHDRTonemap) {
            %init(FBPHDRVideoTonemap);
            FBPLog(@"hdr: video inverse-tonemap clamp installed");
        }
    }
}
