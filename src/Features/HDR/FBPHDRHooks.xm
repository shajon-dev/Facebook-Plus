// "Disable HDR" - force SDR rendering app-wide, so HDR photos and video stop
// over-brightening the app (issues #4, #7 and #14).
//
// The brightness is not UIScreen.brightness. It is the display's EDR headroom:
// an HDR layer asks the compositor for luminance above SDR white, and Facebook's
// own shaders and CoreImage filters scale their output by the headroom the
// screen reports. So there are two things to take away, and both matter: the
// layers' request for EDR, and the headroom the app is told it has.
//
// The levers, all public or stable system API, none tied to a Facebook class:
//
//   Layer, asking for EDR
//     * CALayer.preferredDynamicRange - the iOS 26 control. ABSENT on iOS 18,
//       which is why it now installs on its own and not beside the others:
//       hooking a selector the platform does not have ADDS it, and an app that
//       asks -respondsToSelector: would then take a path that does not exist.
//     * CALayer.wantsExtendedDynamicRangeContent - the older control, still set
//       on several paths; forced to NO through both setter and getter.
//     * CALayer.contentsMaximumDesiredEDR / displayMaximumDesiredEDR - the
//       per-layer EDR ceiling, in multiples of SDR white. Clamped to 1.0, which
//       is "no headroom", and the value every SDR layer already carries. Live
//       on this build: a single feed scroll sets it 397 times.
//     * CALayer.contentsEDRStrength - how much of that ceiling to use. Zero.
//     * CALayer.toneMapToStandardDynamicRange - the opposite direction, and the
//       one that catches content nobody configured: instead of refusing EDR it
//       asks the compositor to map HDR down into SDR. Forced on, and set on
//       AVPlayerLayer and AVSampleBufferDisplayLayer as they are created, since
//       a player layer that is never configured never reaches a setter.
//     * CAMetalLayer.EDRMetadata - the HLG / HDR10 description attached to a
//       Metal layer. Dropped.
//
//   Screen, reporting headroom
//     * UIScreen.currentEDRHeadroom / potentialEDRHeadroom, and the newer
//       maximumDynamicRangeHeadroom / currentDynamicRangeHeadroom on UIScreen
//       and UIView - all answer 1.0, so shader and filter code that scales by
//       headroom scales by nothing.
//
//   Images
//     * UIImageView.preferredImageDynamicRange / imageDynamicRange and the
//       private -_maximumEDRForDynamicRange:, plus Facebook's own image views,
//       which are UIView subclasses with their own copy of the property.
//
// contentsFormat is deliberately left alone. Downgrading RGBA16Float to 8-bit
// removes precision from ordinary wide-gamut content (FBRichTextLayer is one of
// the callers here) and buys nothing: a float layer whose EDR ceiling is 1.0 and
// whose EDR request is NO does not drive the panel brighter.
//
// Every forced value is one the system already accepts - Standard, NO, 1.0, 0.0
// - so none of this can crash the host. Each group installs only when every
// selector it hooks is present, because a hook on a missing selector would
// create it. A one-time trace per lever records that the hook is live without
// logging on every frame.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPTrace.h"

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdatomic.h>

// CADynamicRangeStandard / UIImageDynamicRangeStandard are both 0. Declared as a
// plain constant so this builds against an SDK that predates either enum.
static const NSInteger kFBPDynamicRangeStandard = 0;

/// EDR headroom, as a multiple of SDR white. 1.0 is what a display with no
/// headroom reports, and what every SDR layer already carries.
static const CGFloat kFBPNoHeadroom = 1.0;

/// Mirror of the "Disable HDR" preference.
///
/// Not read through FBPEnabled() here, and that is not an optimisation. These
/// hooks sit on Core Animation's own paths: a single feed scroll calls
/// -setContentsMaximumDesiredEDR: 397 times, and UIKit resolves the headroom
/// properties while it builds every view. Asking NSUserDefaults each time put a
/// cfprefsd round trip inside those paths and the app stopped launching at all,
/// killed by the 20 second launch watchdog with the CPU almost idle. A relaxed
/// load of this flag costs two instructions and cannot block.
///
/// The mirror is seeded at install and refreshed from the notification the
/// settings panel posts on commit, so the switch still takes effect without a
/// relaunch.
static atomic_bool gFBPHDRDisabled = false;

static inline BOOL FBPHDRDisabled(void) {
    return atomic_load_explicit(&gFBPHDRDisabled, memory_order_relaxed);
}

static void FBPRefreshHDRFlag(void) {
    atomic_store_explicit(&gFBPHDRDisabled, FBPEnabled(FBPKeyDisableHDR) ? true : false,
                          memory_order_relaxed);
}

// Core Animation's EDR controls are not in the public SDK. Declaring them here
// only tells the compiler their shapes; it does not make -respondsToSelector:
// answer YES for a platform that lacks them, which is what the per-selector
// install guards in FBPInitHDRHooks are for.
@interface CALayer (FBPHDRPrivate)
- (void)setToneMapToStandardDynamicRange:(BOOL)toneMap;
- (void)setContentsMaximumDesiredEDR:(CGFloat)value;
- (void)setDisplayMaximumDesiredEDR:(CGFloat)value;
- (void)setContentsEDRStrength:(CGFloat)value;
@end

/// Puts a freshly created player layer on the SDR path.
///
/// Both of the levers it uses are properties the layer already has, set to the
/// value an SDR layer carries, so a layer that was never going to show HDR is
/// unaffected.
static void FBPToneMapLayerToSDR(CALayer *layer, const char *trace) {
    if (!layer || !FBPHDRDisabled()) {
        return;
    }
    if ([layer respondsToSelector:@selector(setToneMapToStandardDynamicRange:)]) {
        [layer setToneMapToStandardDynamicRange:YES];
    }
    // Sent rather than called: the SDK this builds against marks
    // -setWantsExtendedDynamicRangeContent: as iOS 17 and up, and the
    // deployment target is older. -respondsToSelector: above is the stricter
    // check anyway, since it asks the device rather than the SDK.
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

// What the view decided the image itself is, and the headroom it will allow for
// a given range. Separate from the group above because these two are private
// and may not survive an OS release.
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

// Both the setter and the getter are forced to Standard: the setter so the
// stored value is SDR whether Core Animation later reads it via the ivar or the
// accessor, the getter as a backstop for layers the app never set it on.
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

// The EDR ceiling and how much of it to use, in multiples of SDR white. 1.0 and
// 0.0 are what an ordinary SDR layer already carries.
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

// A player layer that is never configured never reaches a setter, so the two
// video layer classes are tone-mapped as they are created. Both override the
// property, so the CALayer hook above does not reach them either.
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
// the screen reports (##HDR_HEADROOM## is a shader placeholder in its own
// binary), so a layer clamp alone still leaves content that was expanded before
// it ever reached a layer. 1.0 means "no headroom", which is what every SDR
// display reports.
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

/// YES when @c cls has every one of these selectors.
///
/// Two reasons this goes through the runtime's C API rather than
/// -instancesRespondToSelector:.
///
/// The first is correctness: hooking a selector a class does not have ADDS it,
/// so a group installed blind would make -respondsToSelector: answer YES for an
/// API the platform lacks and send the app down a path that is not there.
/// CALayer.preferredDynamicRange is exactly that case, absent on iOS 18 and
/// present on 26, which is why it installs on its own.
///
/// The second is that this runs from a dyld initializer, before main. Asking a
/// class anything with a message send triggers its +initialize, and
/// +[UIScreen initialize] waits on UIKit's application configuration, which
/// does not exist yet: the app hung there until the 20 second launch watchdog
/// killed it. class_getInstanceMethod realizes the class without running
/// +initialize, and objc_getClass looks a class up without messaging it.
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
    // Seed the mirror and keep it in step with the settings panel. The
    // installer is re-run on every dyld image load, so this needs its own latch.
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

    // Facebook's own image views are UIView subclasses with their own
    // dynamic-range property, so the UIImageView hook never reaches them (the
    // real cause of HDR photos still glaring). Install when any is present; a
    // class the build lacks is simply not swizzled.
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

    // Facebook's video inverse-tonemap (SDR->HDR EDR boost) is independent of
    // the layer dynamic-range clamp. Install when any player class is present.
    if (objc_getClass("FNFCAMetalLayer") || objc_getClass("FBVideoPlaybackController")) {
        FBP_ONCE(gHDRTonemap) {
            %init(FBPHDRVideoTonemap);
            FBPLogOnce(@"hdr: video inverse-tonemap clamp installed");
        }
    }
}
