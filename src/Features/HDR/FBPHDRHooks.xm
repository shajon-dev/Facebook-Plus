// "Disable HDR": force SDR rendering app-wide, so HDR photos and video stop
// over-brightening the app.
//
// The brightness is not UIScreen.brightness but the display's EDR headroom: an
// HDR layer asks the compositor for luminance above SDR white, and Facebook's
// own shaders and CoreImage filters scale their output by the headroom the
// screen reports. Both have to go — the layers' request for EDR, and the
// headroom the app is told it has.
//
// The levers are all public or stable system API, none tied to a Facebook
// class, grouped below as layers asking for EDR (preferredDynamicRange,
// wantsExtendedDynamicRangeContent, the EDR ceiling and strength,
// toneMapToStandardDynamicRange, CAMetalLayer.EDRMetadata), the screen and view
// headroom properties, and the image dynamic-range properties — including
// Facebook's own image views, which are UIView subclasses carrying their own
// copy and so are missed entirely by the UIImageView hooks.
//
// contentsFormat is deliberately left alone. Downgrading RGBA16Float to 8-bit
// strips precision from ordinary wide-gamut content and buys nothing: a float
// layer whose EDR ceiling is 1.0 and whose EDR request is NO does not drive the
// panel brighter.
//
// Every forced value is one the system already accepts, so none of this can
// crash the host. Each group installs only when every selector it hooks is
// present, because hooking a missing selector creates it.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPTrace.h"

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdatomic.h>

// Both are 0; a plain constant so this builds against an older SDK.
static const NSInteger kFBPDynamicRangeStandard = 0;

/// EDR headroom as a multiple of SDR white; 1.0 is "none".
static const CGFloat kFBPNoHeadroom = 1.0;

/// Mirror of the "Disable HDR" preference, and not FBPEnabled(), which is not
/// an optimisation: these hooks sit on Core Animation's own paths (a feed
/// scroll sets the EDR ceiling hundreds of times, and UIKit resolves the
/// headroom properties for every view). An NSUserDefaults read there puts a
/// cfprefsd round trip inside them and the app never launches at all, killed by
/// the watchdog. Seeded at install, refreshed from the settings notification.
static atomic_bool gFBPHDRDisabled = false;

static inline BOOL FBPHDRDisabled(void) {
    return atomic_load_explicit(&gFBPHDRDisabled, memory_order_relaxed);
}

static void FBPRefreshHDRFlag(void) {
    atomic_store_explicit(&gFBPHDRDisabled, FBPEnabled(FBPKeyDisableHDR) ? true : false,
                          memory_order_relaxed);
}

// Not in the public SDK. These declarations only tell the compiler the shapes;
// the per-selector guards in FBPInitHDRHooks are what check the platform.
@interface CALayer (FBPHDRPrivate)
- (void)setToneMapToStandardDynamicRange:(BOOL)toneMap;
- (void)setContentsMaximumDesiredEDR:(CGFloat)value;
- (void)setDisplayMaximumDesiredEDR:(CGFloat)value;
- (void)setContentsEDRStrength:(CGFloat)value;
@end

/// Puts a freshly created player layer on the SDR path, using properties the
/// layer already has, so a layer that would never show HDR is unaffected.
static void FBPToneMapLayerToSDR(CALayer *layer, const char *trace) {
    if (!layer || !FBPHDRDisabled()) {
        return;
    }
    if ([layer respondsToSelector:@selector(setToneMapToStandardDynamicRange:)]) {
        [layer setToneMapToStandardDynamicRange:YES];
    }
    // Sent, not called: the SDK marks this iOS 17+ and the deployment target
    // is older. -respondsToSelector: above asks the device, which is stricter.
    SEL wantsEDR = NSSelectorFromString(@"setWantsExtendedDynamicRangeContent:");
    if ([layer respondsToSelector:wantsEDR]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(layer, wantsEDR, NO);
    }
    static BOOL traced = NO;
    if (!traced) { traced = YES; FBPTraceFire(trace); }
}

#pragma mark - Images

%group FBPHDRImage

%hook UIImageView

- (void)setPreferredImageDynamicRange:(NSInteger)range {
    NSInteger effective = range;
    if (FBPHDRDisabled()) {
        effective = kFBPDynamicRangeStandard;
        static BOOL traced = NO;
        if (!traced) { traced = YES; FBPTraceFire("hdr.UIImageView.setPreferredImageDynamicRange.forcedStandard"); }
    }
    %orig(effective);
}

- (NSInteger)preferredImageDynamicRange {
    if (FBPHDRDisabled()) {
        static BOOL traced = NO;
        if (!traced) { traced = YES; FBPTraceFire("hdr.UIImageView.preferredImageDynamicRange.clamped"); }
        return kFBPDynamicRangeStandard;
    }
    return %orig;
}

%end

%end // FBPHDRImage

// Private, so kept apart from the group above: they may not survive a release.
%group FBPHDRImageInternals

%hook UIImageView

- (NSInteger)imageDynamicRange {
    if (FBPHDRDisabled()) return kFBPDynamicRangeStandard;
    return %orig;
}

- (CGFloat)_maximumEDRForDynamicRange:(NSInteger)range {
    if (FBPHDRDisabled()) return kFBPNoHeadroom;
    return %orig;
}

%end

%end // FBPHDRImageInternals

#pragma mark - Layers (EDR: HDR video + Metal)

// The iOS 26 lever, on its own: it does not exist on iOS 18, and hooking a
// selector the platform lacks would add it.
%group FBPHDRLayerPreferredRange

%hook CALayer

// Setter and getter both: the setter so the stored value is SDR however Core
// Animation reads it, the getter for layers the app never set it on.
- (void)setPreferredDynamicRange:(NSInteger)range {
    NSInteger effective = range;
    if (FBPHDRDisabled() && range != kFBPDynamicRangeStandard) {
        effective = kFBPDynamicRangeStandard;
        static BOOL traced = NO;
        if (!traced) { traced = YES; FBPTraceFire("hdr.CALayer.setPreferredDynamicRange.forcedStandard"); }
    }
    %orig(effective);
}

- (NSInteger)preferredDynamicRange {
    if (FBPHDRDisabled()) {
        static BOOL traced = NO;
        if (!traced) { traced = YES; FBPTraceFire("hdr.CALayer.preferredDynamicRange.clamped"); }
        return kFBPDynamicRangeStandard;
    }
    return %orig;
}

%end

%end // FBPHDRLayerPreferredRange

// The older lever, present on every build this tweak supports.
%group FBPHDRLayerWantsEDR

%hook CALayer

- (void)setWantsExtendedDynamicRangeContent:(BOOL)wants {
    BOOL effective = wants;
    if (FBPHDRDisabled() && wants) {
        effective = NO;
        static BOOL traced = NO;
        if (!traced) { traced = YES; FBPTraceFire("hdr.CALayer.wantsExtendedDynamicRangeContent.forcedOff"); }
    }
    %orig(effective);
}

- (BOOL)wantsExtendedDynamicRangeContent {
    if (FBPHDRDisabled()) return NO;
    return %orig;
}

%end

%end // FBPHDRLayerWantsEDR

// The EDR ceiling and how much of it to use; 1.0 and 0.0 are plain SDR.
%group FBPHDRLayerEDRCeiling

%hook CALayer

- (void)setContentsMaximumDesiredEDR:(CGFloat)value {
    CGFloat effective = value;
    if (FBPHDRDisabled() && value > kFBPNoHeadroom) {
        effective = kFBPNoHeadroom;
        static BOOL traced = NO;
        if (!traced) { traced = YES; FBPTraceFire("hdr.CALayer.setContentsMaximumDesiredEDR.clamped"); }
    }
    %orig(effective);
}

- (void)setDisplayMaximumDesiredEDR:(CGFloat)value {
    CGFloat effective = value;
    if (FBPHDRDisabled() && value > kFBPNoHeadroom) effective = kFBPNoHeadroom;
    %orig(effective);
}

- (void)setContentsEDRStrength:(CGFloat)value {
    CGFloat effective = value;
    if (FBPHDRDisabled()) effective = 0.0;
    %orig(effective);
}

%end

%end // FBPHDRLayerEDRCeiling

// Mapping HDR down into SDR, rather than refusing to show it.
%group FBPHDRLayerToneMap

%hook CALayer

- (void)setToneMapToStandardDynamicRange:(BOOL)toneMap {
    BOOL effective = toneMap;
    if (FBPHDRDisabled()) {
        effective = YES;
        static BOOL traced = NO;
        if (!traced) { traced = YES; FBPTraceFire("hdr.CALayer.setToneMapToStandardDynamicRange.forcedOn"); }
    }
    %orig(effective);
}

%end

%end // FBPHDRLayerToneMap

// A player layer that is never configured never reaches a setter, so both video
// layer classes are tone-mapped at creation. Both also override the property,
// so the CALayer hook above does not reach them.
%group FBPHDRPlayerLayerToneMap

%hook AVPlayerLayer

- (instancetype)init {
    CALayer *layer = %orig;
    FBPToneMapLayerToSDR(layer, "hdr.AVPlayerLayer.init.toneMapped");
    return (id)layer;
}

- (void)setToneMapToStandardDynamicRange:(BOOL)toneMap {
    BOOL effective = toneMap;
    if (FBPHDRDisabled()) effective = YES;
    %orig(effective);
}

%end

%end // FBPHDRPlayerLayerToneMap

%group FBPHDRSampleLayerToneMap

%hook AVSampleBufferDisplayLayer

- (instancetype)init {
    CALayer *layer = %orig;
    FBPToneMapLayerToSDR(layer, "hdr.AVSampleBufferDisplayLayer.init.toneMapped");
    return (id)layer;
}

- (void)setToneMapToStandardDynamicRange:(BOOL)toneMap {
    BOOL effective = toneMap;
    if (FBPHDRDisabled()) effective = YES;
    %orig(effective);
}

%end

%end // FBPHDRSampleLayerToneMap

// The HLG / HDR10 description attached to a Metal layer. Without it the
// compositor has nothing to expand.
%group FBPHDRMetalEDRMetadata

%hook CAMetalLayer

- (void)setEDRMetadata:(id)metadata {
    id effective = metadata;
    if (FBPHDRDisabled() && metadata) {
        effective = nil;
        static BOOL traced = NO;
        if (!traced) { traced = YES; FBPTraceFire("hdr.CAMetalLayer.setEDRMetadata.dropped"); }
    }
    %orig(effective);
}

%end

%end // FBPHDRMetalEDRMetadata

#pragma mark - Reported headroom

// Facebook's shaders and CoreImage filters scale their output by the headroom
// the screen reports, so a layer clamp alone still leaves content that was
// expanded before it ever reached a layer.
%group FBPHDRScreenHeadroom

%hook UIScreen

- (CGFloat)currentEDRHeadroom {
    if (FBPHDRDisabled()) {
        static BOOL traced = NO;
        if (!traced) { traced = YES; FBPTraceFire("hdr.UIScreen.currentEDRHeadroom.clamped"); }
        return kFBPNoHeadroom;
    }
    return %orig;
}

- (CGFloat)potentialEDRHeadroom {
    if (FBPHDRDisabled()) return kFBPNoHeadroom;
    return %orig;
}

%end

%end // FBPHDRScreenHeadroom

// The same thing under its newer names.
%group FBPHDRScreenDynamicRangeHeadroom

%hook UIScreen

- (CGFloat)maximumDynamicRangeHeadroom {
    if (FBPHDRDisabled()) return kFBPNoHeadroom;
    return %orig;
}

- (CGFloat)currentDynamicRangeHeadroom {
    if (FBPHDRDisabled()) return kFBPNoHeadroom;
    return %orig;
}

%end

%end // FBPHDRScreenDynamicRangeHeadroom

// And on the view, where it is answered from the trait collection rather than
// the screen.
%group FBPHDRViewHeadroom

%hook UIView

- (CGFloat)maximumDynamicRangeHeadroom {
    if (FBPHDRDisabled()) return kFBPNoHeadroom;
    return %orig;
}

- (CGFloat)currentDynamicRangeHeadroom {
    if (FBPHDRDisabled()) return kFBPNoHeadroom;
    return %orig;
}

%end

%end // FBPHDRViewHeadroom

#pragma mark - Facebook image views (photos)

// Facebook's own image views are UIView subclasses, NOT UIImageView, each with
// its own preferredImageDynamicRange backed by a private ivar, so the hooks
// above never reach them — the reason HDR photos still over-brightened. Force
// setter and getter on each, and answer -_isImageHDR: NO, which FB asks before
// boosting.
%group FBPHDRFBImageViews

%hook FBWebImageView
- (void)setPreferredImageDynamicRange:(NSInteger)range {
    NSInteger effective = range;
    if (FBPHDRDisabled()) {
        effective = kFBPDynamicRangeStandard;
        static BOOL traced = NO;
        if (!traced) { traced = YES; FBPTraceFire("hdr.FBWebImageView.setPreferredImageDynamicRange.forcedStandard"); }
    }
    %orig(effective);
}
- (NSInteger)preferredImageDynamicRange {
    if (FBPHDRDisabled()) return kFBPDynamicRangeStandard;
    return %orig;
}
- (BOOL)_isImageHDR:(id)arg {
    if (FBPHDRDisabled()) return NO;
    return %orig;
}
%end

%hook FBNetworkImageView
- (void)setPreferredImageDynamicRange:(NSInteger)range {
    NSInteger effective = range;
    if (FBPHDRDisabled()) effective = kFBPDynamicRangeStandard;
    %orig(effective);
}
- (NSInteger)preferredImageDynamicRange {
    if (FBPHDRDisabled()) return kFBPDynamicRangeStandard;
    return %orig;
}
%end

%hook FBWebImageCoreAnimatedImageView
- (void)setPreferredImageDynamicRange:(NSInteger)range {
    NSInteger effective = range;
    if (FBPHDRDisabled()) effective = kFBPDynamicRangeStandard;
    %orig(effective);
}
- (NSInteger)preferredImageDynamicRange {
    if (FBPHDRDisabled()) return kFBPDynamicRangeStandard;
    return %orig;
}
%end

%end // FBPHDRFBImageViews

// The animated-image view in the main Facebook binary, same private property.
%group FBPHDRMRCImageView

%hook MRCAnimatedImageView
- (void)setPreferredImageDynamicRange:(NSInteger)range {
    NSInteger effective = range;
    if (FBPHDRDisabled()) {
        effective = kFBPDynamicRangeStandard;
        static BOOL traced = NO;
        if (!traced) { traced = YES; FBPTraceFire("hdr.MRCAnimatedImageView.setPreferredImageDynamicRange.forcedStandard"); }
    }
    %orig(effective);
}
- (NSInteger)preferredImageDynamicRange {
    if (FBPHDRDisabled()) return kFBPDynamicRangeStandard;
    return %orig;
}
%end

%end // FBPHDRMRCImageView

#pragma mark - Video inverse-tonemap (the EDR boost on playback)

// HDR video and Reels glare rides Facebook's own inverse-tonemap path, an
// SDR->HDR expansion on its player layers that is independent of
// CALayer.preferredDynamicRange, so clamping the layer alone leaves video
// glaring. Every inverse-tonemap enable is forced NO. (A literal goes through a
// local to avoid logos' "%orig(NO)" argument gotcha.)
%group FBPHDRVideoTonemap

%hook FNFCAMetalLayer
- (void)setEnableInverseTonemap:(BOOL)on {
    BOOL effective = on;
    if (FBPHDRDisabled()) {
        effective = NO;
        static BOOL traced = NO;
        if (!traced) { traced = YES; FBPTraceFire("hdr.FNFCAMetalLayer.setEnableInverseTonemap.forcedOff"); }
    }
    %orig(effective);
}
- (void)setInverseTonemappingEnabled:(BOOL)on {
    BOOL effective = on;
    if (FBPHDRDisabled()) effective = NO;
    %orig(effective);
}
%end

%hook FBVideoPlaybackController
- (void)setPrecomputedEnableCAMetalLayerInverseTonemap:(BOOL)on {
    BOOL effective = on;
    if (FBPHDRDisabled()) effective = NO;
    %orig(effective);
}
- (void)_setEnableInverseTonemap:(BOOL)on {
    BOOL effective = on;
    if (FBPHDRDisabled()) effective = NO;
    %orig(effective);
}
%end

%hook FNFVideoPlaybackController
- (void)setEnableInverseTonemap:(BOOL)on {
    BOOL effective = on;
    if (FBPHDRDisabled()) effective = NO;
    %orig(effective);
}
%end

%hook FNFPlayerDisplayRendering
- (void)setEnableInverseTonemap:(BOOL)on {
    BOOL effective = on;
    if (FBPHDRDisabled()) effective = NO;
    %orig(effective);
}
%end

%hook FNFAVSampleBufferDisplayLayer
- (void)setInverseTonemappingEnabled:(BOOL)on {
    BOOL effective = on;
    if (FBPHDRDisabled()) effective = NO;
    %orig(effective);
}
%end

%hook FNFIOSurfacePlayerLayer
- (void)setInverseTonemappingEnabled:(BOOL)on {
    BOOL effective = on;
    if (FBPHDRDisabled()) effective = NO;
    %orig(effective);
}
%end

%hook FNFPlayerMetalLayer
- (void)setInverseTonemappingEnabled:(BOOL)on {
    BOOL effective = on;
    if (FBPHDRDisabled()) effective = NO;
    %orig(effective);
}
%end

%end // FBPHDRVideoTonemap

#pragma mark - Init

/// YES when @c cls has every one of these selectors. Through the runtime's C
/// API, not -instancesRespondToSelector:, for two reasons.
///
/// Correctness: hooking a selector a class lacks ADDS it, so a blind install
/// makes -respondsToSelector: answer YES for an API the platform does not have.
/// CALayer.preferredDynamicRange is that case, absent on iOS 18.
///
/// And this runs from a dyld initializer, before main, where a message send
/// triggers +initialize — and +[UIScreen initialize] waits on UIKit's
/// application configuration, which does not exist yet, so the app hangs until
/// the launch watchdog kills it. class_getInstanceMethod realizes a class
/// without running +initialize; objc_getClass looks one up without messaging.
static BOOL FBPHDRHasAll(const char *className, NSArray<NSString *> *selectorNames) {
    Class cls = objc_getClass(className);
    if (!cls) {
        return NO;
    }
    for (NSString *name in selectorNames) {
        if (!class_getInstanceMethod(cls, NSSelectorFromString(name))) {
            return NO;
        }
    }
    return YES;
}

void FBPInitHDRHooks(void) {
    // The installer re-runs on every dyld image load, so this needs a latch.
    FBP_ONCE(gHDRFlag) {
        FBPRefreshHDRFlag();
        [NSNotificationCenter.defaultCenter
            addObserverForName:FBPSettingsDidChangeNotification
                        object:nil
                         queue:nil
                    usingBlock:^(__unused NSNotification *note) {
            FBPRefreshHDRFlag();
        }];
    }

    if (FBPHDRHasAll("UIImageView", @[ @"preferredImageDynamicRange",
                                           @"setPreferredImageDynamicRange:" ])) {
        FBP_ONCE(gHDRImage) {
            %init(FBPHDRImage);
            FBPLogOnce(@"hdr: image dynamic-range clamp installed");
        }
    }
    if (FBPHDRHasAll("UIImageView", @[ @"imageDynamicRange",
                                           @"_maximumEDRForDynamicRange:" ])) {
        FBP_ONCE(gHDRImageInternals) {
            %init(FBPHDRImageInternals);
            FBPLogOnce(@"hdr: image EDR internals clamp installed");
        }
    }

    if (FBPHDRHasAll("CALayer", @[ @"preferredDynamicRange",
                                       @"setPreferredDynamicRange:" ])) {
        FBP_ONCE(gHDRLayerRange) {
            %init(FBPHDRLayerPreferredRange);
            FBPLogOnce(@"hdr: layer preferredDynamicRange clamp installed");
        }
    }
    if (FBPHDRHasAll("CALayer", @[ @"wantsExtendedDynamicRangeContent",
                                       @"setWantsExtendedDynamicRangeContent:" ])) {
        FBP_ONCE(gHDRLayerWantsEDR) {
            %init(FBPHDRLayerWantsEDR);
            FBPLogOnce(@"hdr: layer wantsExtendedDynamicRangeContent clamp installed");
        }
    }
    if (FBPHDRHasAll("CALayer", @[ @"setContentsMaximumDesiredEDR:",
                                       @"setDisplayMaximumDesiredEDR:",
                                       @"setContentsEDRStrength:" ])) {
        FBP_ONCE(gHDRLayerCeiling) {
            %init(FBPHDRLayerEDRCeiling);
            FBPLogOnce(@"hdr: layer EDR ceiling clamp installed");
        }
    }
    if (FBPHDRHasAll("CALayer", @[ @"setToneMapToStandardDynamicRange:" ])) {
        FBP_ONCE(gHDRLayerToneMap) {
            %init(FBPHDRLayerToneMap);
            FBPLogOnce(@"hdr: layer tone-map-to-SDR installed");
        }
    }

    if (FBPHDRHasAll("AVPlayerLayer",
                 @[ @"setToneMapToStandardDynamicRange:" ])) {
        FBP_ONCE(gHDRPlayerToneMap) {
            %init(FBPHDRPlayerLayerToneMap);
            FBPLogOnce(@"hdr: AVPlayerLayer tone-map-to-SDR installed");
        }
    }
    if (FBPHDRHasAll("AVSampleBufferDisplayLayer",
                 @[ @"setToneMapToStandardDynamicRange:" ])) {
        FBP_ONCE(gHDRSampleToneMap) {
            %init(FBPHDRSampleLayerToneMap);
            FBPLogOnce(@"hdr: AVSampleBufferDisplayLayer tone-map-to-SDR installed");
        }
    }
    if (FBPHDRHasAll("CAMetalLayer", @[ @"setEDRMetadata:" ])) {
        FBP_ONCE(gHDRMetalMetadata) {
            %init(FBPHDRMetalEDRMetadata);
            FBPLogOnce(@"hdr: Metal EDR metadata drop installed");
        }
    }

    if (FBPHDRHasAll("UIScreen", @[ @"currentEDRHeadroom",
                                        @"potentialEDRHeadroom" ])) {
        FBP_ONCE(gHDRScreenHeadroom) {
            %init(FBPHDRScreenHeadroom);
            FBPLogOnce(@"hdr: screen EDR headroom clamp installed");
        }
    }
    if (FBPHDRHasAll("UIScreen", @[ @"maximumDynamicRangeHeadroom",
                                        @"currentDynamicRangeHeadroom" ])) {
        FBP_ONCE(gHDRScreenRange) {
            %init(FBPHDRScreenDynamicRangeHeadroom);
            FBPLogOnce(@"hdr: screen dynamic-range headroom clamp installed");
        }
    }
    if (FBPHDRHasAll("UIView", @[ @"maximumDynamicRangeHeadroom",
                                      @"currentDynamicRangeHeadroom" ])) {
        FBP_ONCE(gHDRViewRange) {
            %init(FBPHDRViewHeadroom);
            FBPLogOnce(@"hdr: view dynamic-range headroom clamp installed");
        }
    }

    // Install when any is present; a class the build lacks is not swizzled.
    if (objc_getClass("FBWebImageView") || objc_getClass("FBNetworkImageView") ||
        objc_getClass("FBWebImageCoreAnimatedImageView")) {
        FBP_ONCE(gHDRFBImages) {
            %init(FBPHDRFBImageViews);
            FBPLogOnce(@"hdr: Facebook image-view dynamic-range clamp installed");
        }
    }
    if (objc_getClass("MRCAnimatedImageView")) {
        FBP_ONCE(gHDRMRC) { %init(FBPHDRMRCImageView); }
    }

    // Install when any player class is present.
    if (objc_getClass("FNFCAMetalLayer") || objc_getClass("FBVideoPlaybackController")) {
        FBP_ONCE(gHDRTonemap) {
            %init(FBPHDRVideoTonemap);
            FBPLogOnce(@"hdr: video inverse-tonemap clamp installed");
        }
    }
}
