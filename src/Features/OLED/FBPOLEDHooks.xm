// OLED Dark Mode: deepen Facebook's dark theme to true-black.
//
// An enhancement of dark mode, not a light to dark forcer. OLED engages while
// the toggle is on and iOS is in Dark Mode, and disengages in Light. The
// per-colour darkness test still runs, so only Facebook's own dark surface
// greys are blackened.
//
// Three surfaces need more than a -setBackgroundColor: hook, because Facebook
// never sets a colour on the view itself:
//
//   * FBMovableNavigationBarView paints its grey onto child views, a hosted
//     UINavigationBar's appearance objects, a blur and gradient sublayers.
//   * ComponentKit cards paint onto a CAGradientLayer, CAShapeLayer or plain
//     CALayer added as a sublayer.
//   * Dynamic colours must be resolved against a dark trait collection before
//     being judged, or the answer depends on when the hook happened to run.
//
// Each surface's original value is stashed in an associated object before it is
// darkened and put back when OLED disengages.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPHeaders.h"

#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <stdatomic.h>

/// Cached, refreshed on the settings-changed notification: the hot path must
/// not touch NSUserDefaults.
static BOOL gOLEDEnabled = NO;

/// Whether the faint post separators stay visible: on keeps cards separated on
/// black, off blacks the hairlines out too.
static BOOL gOLEDDividers = YES;

#if FBP_DIAG
static void FBPGreyDiagSwitch(BOOL on);
#endif

static void FBPRefreshOLED(void) {
    gOLEDEnabled = FBPEnabled(FBPKeyOLED);
    gOLEDDividers = FBPEnabled(FBPKeyOLEDDividers);
#if FBP_DIAG
    FBPGreyDiagSwitch(FBPEnabled(FBPKeyOLEDGreyDiag));
#endif
}

/// Facebook ships over six thousand names beginning FBP, views among them, so a
/// prefix cannot say whose a class is. The Mach-O image can. One answer per
/// Class in a direct-mapped table: a hit is a hash and an atomic load.
static BOOL FBPClassIsOurs(Class cls) {
    static _Atomic uintptr_t cache[256];
    static const char *ourPath;
    static void *ourBase;
    static dispatch_once_t once;
    if (!cls) return NO;
    dispatch_once(&once, ^{
        Dl_info info;
        if (dladdr((const void *)&FBPClassIsOurs, &info)) {
            ourPath = info.dli_fname;
            ourBase = info.dli_fbase;
        }
    });
    uintptr_t key = (uintptr_t)(__bridge void *)cls;
    _Atomic uintptr_t *slot = &cache[(key >> 4) & 255];
    uintptr_t seen = atomic_load_explicit(slot, memory_order_relaxed);
    if ((seen & ~(uintptr_t)1) == key) return (BOOL)(seen & 1);
    // The load address first: the two paths for one image can differ by a
    // /private prefix, and answering NO for our own views would black them out.
    Dl_info where;
    BOOL mine = ourBase && dladdr((__bridge const void *)cls, &where) &&
                where.dli_fbase == ourBase;
    if (!mine) {
        const char *image = class_getImageName(cls);
        mine = ourPath && image && strcmp(image, ourPath) == 0;
    }
    atomic_store_explicit(slot, key | (uintptr_t)mine, memory_order_relaxed);
    return mine;
}

/// One of Facebook's own windows, never ours, preferring the key one: ours
/// follow iOS, while Facebook's carry the theme OLED has to agree with.
static UIWindow *FBPAppKeyWindow(void) {
    UIWindow *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (FBPClassIsOurs(window.class)) continue;
            if (window.isKeyWindow) return window;
            if (!fallback) fallback = window;
        }
    }
    return fallback;
}

/// The iOS system appearance, from a window scene. Not from a window, whose
/// traitCollection reports the effective style after any
/// overrideUserInterfaceStyle — which Facebook pins when its own Dark Mode
/// setting is On or Off — and not from UIScreen, which has been seen reporting
/// a stale Dark. A UIWindowScene carries no override.
static UIUserInterfaceStyle FBPSystemStyleFromScenes(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            UIUserInterfaceStyle style =
                windowScene.traitCollection.userInterfaceStyle;
            if (style != UIUserInterfaceStyleUnspecified) return style;
        }
    }
    return UIUserInterfaceStyleUnspecified;
}

/// Cached so the hot path never walks the scene list.
static UIUserInterfaceStyle gFBPSystemStyle = UIUserInterfaceStyleUnspecified;

static void FBPUpdateSystemStyle(UIUserInterfaceStyle style) {
    if (@available(iOS 13.0, *)) {
        if (style != UIUserInterfaceStyleUnspecified) gFBPSystemStyle = style;
    }
}

/// YES when iOS itself is in Dark Mode, whatever Facebook forced on its own
/// windows. Falls back to a live scene until the first layout pass seeds it.
static BOOL FBPSystemIsDark(void) {
    if (@available(iOS 13.0, *)) {
        if (gFBPSystemStyle != UIUserInterfaceStyleUnspecified) {
            return gFBPSystemStyle == UIUserInterfaceStyleDark;
        }
        // Nothing has laid out yet; the scene is right unless Facebook pinned.
        return FBPSystemStyleFromScenes() == UIUserInterfaceStyleDark;
    }
    return NO;
}

/// Is OLED engaged right now? One answer for the whole process, keyed on the
/// system appearance rather than a view's trait: views detached from a window
/// keep their last traits and the hierarchy is not of one mind during a switch,
/// so asking per view gives a screen part light and part black. Whether a
/// particular surface is drawn light is a separate question, in FBPApplyView.
static BOOL FBPOLEDActiveFor(__unused UIView *view) {
    return gOLEDEnabled && FBPSystemIsDark();
}

static BOOL FBPOLEDActive(void) {
    return gOLEDEnabled && FBPSystemIsDark();
}

/// Defined below, beside the relayout it drives.
static void FBPTrackWindowStyle(UIWindow *window);

#pragma mark - Diagnostics

static NSString *FBPStyleName(UIUserInterfaceStyle style) {
    if (@available(iOS 13.0, *)) {
        switch (style) {
            case UIUserInterfaceStyleDark:  return @"dark";
            case UIUserInterfaceStyleLight: return @"light";
            default: break;
        }
    }
    return @"unspec";
}

/// One diagnostic line of what OLED sees. `scene` against `keyWin`/`override`
/// is the pair that matters: when they disagree Facebook is forcing a theme,
/// and only `scene` is iOS.
static void FBPOLEDLogState(const char *when) {
    if (@available(iOS 13.0, *)) {
        UIUserInterfaceStyle scene = FBPSystemStyleFromScenes();
        UIUserInterfaceStyle screen = UIScreen.mainScreen.traitCollection.userInterfaceStyle;
        UIUserInterfaceStyle current =
            UITraitCollection.currentTraitCollection.userInterfaceStyle;
        UIWindow *key = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (FBPClassIsOurs(window.class)) continue;
                if (window.isKeyWindow) { key = window; break; }
                if (!key) key = window;
            }
            if (key.isKeyWindow) break;
        }
        FBPDiag(@"oled",
                @"%s toggle=%d scene=%@ screen=%@ current=%@ keyWin=%@ override=%@ "
                @"systemDark=%d active=%d",
                when, gOLEDEnabled, FBPStyleName(scene), FBPStyleName(screen),
                FBPStyleName(current),
                FBPStyleName(key.traitCollection.userInterfaceStyle),
                FBPStyleName(key.overrideUserInterfaceStyle),
                FBPSystemIsDark(), FBPOLEDActive());
    }
}

#pragma mark - Colour judgement

/// Facebook's backgrounds are dynamic UIColors, and resolving them explicitly
/// rather than against the ambient trait environment is what makes the header
/// deterministic rather than intermittently dark.
static UITraitCollection *FBPDarkTraits(void) {
    static UITraitCollection *traits = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (@available(iOS 13.0, *)) {
            traits = [UITraitCollection
                traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleDark];
        }
    });
    return traits;
}

/// Resolves a (possibly dynamic) colour to its concrete dark-mode value.
static UIColor *FBPResolve(UIColor *color) {
    if (!color) return color;
    if (@available(iOS 13.0, *)) {
        UITraitCollection *traits = FBPDarkTraits();
        if (traits) {
            @try {
                UIColor *resolved = [color resolvedColorWithTraitCollection:traits];
                if (resolved) return resolved;
            } @catch (__unused NSException *e) {}
        }
    }
    return color;
}

/// YES only for one of Facebook's own dark *background* greys. Its dark palette
/// paints every surface from a small ladder of near-neutral greys topping out
/// around #3A3B3C (base #18191A, card #242526), so the test matches exactly
/// that band. Deliberately tight: a loose "is it darkish" luma test also caught
/// dividers, pressed states, chips and placeholders and painted them as solid
/// black rectangles.
static const CGFloat kFBPBgMaxLuma    = 0.26;   // just above #3A3B3C (luma ~0.231)
static const CGFloat kFBPBgMaxChroma  = 0.05;   // near-neutral only (FB greys are ~neutral)

static BOOL FBPColorIsDark(UIColor *color) {
    if (!color) return NO;
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if ([color getRed:&r green:&g blue:&b alpha:&a]) {
        if (a < 0.2) return NO;
        CGFloat mx = MAX(r, MAX(g, b)), mn = MIN(r, MIN(g, b));
        CGFloat luma = 0.299 * r + 0.587 * g + 0.114 * b;
        return (mx - mn) < kFBPBgMaxChroma && luma < kFBPBgMaxLuma;
    }
    CGFloat w = 0, wa = 0;
    if ([color getWhite:&w alpha:&wa]) {
        if (wa < 0.2) return NO;
        return w < kFBPBgMaxLuma;
    }
    return NO;
}

/// Layer colours are always CGColor and already concrete.
static BOOL FBPCGColorIsDark(CGColorRef cg) {
    if (!cg) return NO;
    return FBPColorIsDark([UIColor colorWithCGColor:cg]);
}

/// The tweak's own UI keeps its own colours.
static BOOL FBPOLEDSkip(UIView *view) {
    return FBPClassIsOurs([view class]);
}

/// YES when this view is shown in LIGHT appearance whatever the window is
/// doing. Facebook renders some cards with their own overrideUserInterfaceStyle
/// = Light, and because OLED resolves backgrounds against a forced-dark trait
/// collection such a card's dark-mode colour reads as dark — blackening a light
/// background and stranding its dark text. Those views are left alone.
static BOOL FBPViewIsLight(UIView *view) {
    if (@available(iOS 13.0, *)) {
        return view.traitCollection.userInterfaceStyle == UIUserInterfaceStyleLight;
    }
    return NO;
}

#pragma mark - Black that keeps alpha

/// Black that keeps the source alpha: a translucent scrim must stay
/// translucent, or it becomes a solid curtain behind every popup.
static UIColor *FBPBlackKeepingAlpha(UIColor *color) {
    CGFloat alpha = color ? CGColorGetAlpha(color.CGColor) : 1.0;
    return [UIColor colorWithWhite:0.0 alpha:alpha];
}
static CGColorRef FBPBlackCGKeepingAlpha(CGColorRef cg) {
    CGFloat alpha = cg ? CGColorGetAlpha(cg) : 1.0;
    return [UIColor colorWithWhite:0.0 alpha:alpha].CGColor;
}

/// Black while the appearance is Dark, @c original the moment it is not.
///
/// A dynamic colour needs no bookkeeping, no restore pass and no notification:
/// it is the same object either side of a switch and only its answer changes.
/// A flat black throws that away, and a container Facebook believes unchanged
/// is never repainted.
// Set on every colour this file paints with. Wrapping one again nests a
// provider whose block captures the last one, and a layout pass does that on
// every painted view: the chain grows without bound, resolving it recurses
// through every level, and releasing a deep one overruns the stack.
static const void *kFBPOurPaint = &kFBPOurPaint;

static BOOL FBPIsOurPaint(UIColor *color) {
    return color && objc_getAssociatedObject(color, kFBPOurPaint) != nil;
}

static UIColor *FBPBlackFollowingAppearance(UIColor *original) {
    if (FBPIsOurPaint(original)) return original;
    UIColor *paint;
    if (@available(iOS 13.0, *)) {
        paint = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            if (!gOLEDEnabled || traits.userInterfaceStyle != UIUserInterfaceStyleDark) {
                return original ?: UIColor.clearColor;
            }
            UIColor *resolved = original;
            @try {
                resolved = [original resolvedColorWithTraitCollection:traits] ?: original;
            } @catch (__unused NSException *e) {}
            // The same test the caller made: a light-locked card keeps its own.
            return FBPColorIsDark(resolved) ? FBPBlackKeepingAlpha(resolved) : resolved;
        }];
    } else {
        paint = FBPBlackKeepingAlpha(original);
    }
    objc_setAssociatedObject(paint, kFBPOurPaint, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return paint;
}

#pragma mark - Save / restore

// Each surface Facebook will not repaint itself is stashed before darkening and
// put back when OLED disengages. A "touched" flag lets a relayout while OLED is
// off skip the views that were never modified.
static const void *kFBPTouched     = &kFBPTouched;     // UIView: OLED modified it
static const void *kFBPSavedViewBG = &kFBPSavedViewBG; // UIView: original backgroundColor
static const void *kFBPSavedLayerBG = &kFBPSavedLayerBG;// CALayer: original backgroundColor
static const void *kFBPSavedColors = &kFBPSavedColors; // CAGradientLayer: original colors
static const void *kFBPSavedFill   = &kFBPSavedFill;   // CAShapeLayer: original fillColor
static const void *kFBPSavedNav    = &kFBPSavedNav;    // UINavigationBar: original appearance

/// Every view OLED has painted, weakly. A revert driven by a tree walk reaches
/// only what is still mounted, and a view painted through its layer cannot
/// recover on its own, because a CGColor carries no appearance. Listing them
/// means the revert has nothing to find.
static NSHashTable<UIView *> *FBPTouchedViews(void) {
    static NSHashTable<UIView *> *views;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ views = [NSHashTable weakObjectsHashTable]; });
    return views;
}

static void FBPMarkTouched(UIView *view) {
    objc_setAssociatedObject(view, kFBPTouched, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSHashTable<UIView *> *touched = FBPTouchedViews();
    @synchronized (touched) { [touched addObject:view]; }
}
static BOOL FBPWasTouched(UIView *view) {
    return objc_getAssociatedObject(view, kFBPTouched) != nil;
}
static void FBPClearTouched(UIView *view) {
    objc_setAssociatedObject(view, kFBPTouched, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSHashTable<UIView *> *touched = FBPTouchedViews();
    @synchronized (touched) { [touched removeObject:view]; }
}

/// Set while a restore is putting Facebook's own colour back. Otherwise the
/// hooked -setBackgroundColor: judges the restored colour dark, saves it and
/// paints it black again while the restore clears its record on the way out.
/// Logos gives no handle on %orig from outside a hook, so the hook stands
/// aside. Main thread only.
static BOOL gFBPRestoring = NO;

// Saved unresolved, so it is still Facebook's dynamic colour.
static void FBPSaveViewBG(UIView *view, UIColor *orig) {
    if (!objc_getAssociatedObject(view, kFBPSavedViewBG)) {
        objc_setAssociatedObject(view, kFBPSavedViewBG, orig ?: (id)NSNull.null,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
static void FBPForgetViewBG(UIView *view) {
    objc_setAssociatedObject(view, kFBPSavedViewBG, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static BOOL FBPRestoreViewBG(UIView *view) {
    id saved = objc_getAssociatedObject(view, kFBPSavedViewBG);
    if (!saved) return NO;
    BOOL was = gFBPRestoring;
    gFBPRestoring = YES;
    view.backgroundColor = (saved == NSNull.null) ? nil : saved;
    gFBPRestoring = was;
    FBPForgetViewBG(view);
    return YES;
}

// A concrete CGColor, boxed as UIColor.
static void FBPSaveLayerBG(CALayer *layer) {
    if (objc_getAssociatedObject(layer, kFBPSavedLayerBG)) return;
    id box = layer.backgroundColor ? (id)[UIColor colorWithCGColor:layer.backgroundColor]
                                   : (id)NSNull.null;
    objc_setAssociatedObject(layer, kFBPSavedLayerBG, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void FBPRestoreLayerBG(CALayer *layer) {
    id saved = objc_getAssociatedObject(layer, kFBPSavedLayerBG);
    if (!saved) return;
    layer.backgroundColor = (saved == NSNull.null) ? NULL : ((UIColor *)saved).CGColor;
    objc_setAssociatedObject(layer, kFBPSavedLayerBG, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void FBPSaveGradient(CAGradientLayer *g) {
    if (objc_getAssociatedObject(g, kFBPSavedColors)) return;
    NSMutableArray *orig = [NSMutableArray arrayWithCapacity:g.colors.count];
    for (id entry in g.colors) {
        [orig addObject:[UIColor colorWithCGColor:(__bridge CGColorRef)entry]];
    }
    objc_setAssociatedObject(g, kFBPSavedColors, orig, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void FBPRestoreGradient(CAGradientLayer *g) {
    NSArray<UIColor *> *saved = objc_getAssociatedObject(g, kFBPSavedColors);
    if (!saved) return;
    NSMutableArray *cg = [NSMutableArray arrayWithCapacity:saved.count];
    for (UIColor *c in saved) [cg addObject:(__bridge id)c.CGColor];
    g.colors = cg;
    objc_setAssociatedObject(g, kFBPSavedColors, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void FBPSaveFill(CAShapeLayer *s) {
    if (objc_getAssociatedObject(s, kFBPSavedFill)) return;
    id box = s.fillColor ? (id)[UIColor colorWithCGColor:s.fillColor] : (id)NSNull.null;
    objc_setAssociatedObject(s, kFBPSavedFill, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void FBPRestoreFill(CAShapeLayer *s) {
    id saved = objc_getAssociatedObject(s, kFBPSavedFill);
    if (!saved) return;
    s.fillColor = (saved == NSNull.null) ? NULL : ((UIColor *)saved).CGColor;
    objc_setAssociatedObject(s, kFBPSavedFill, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Dynamic colours, restored by reference.
static void FBPSaveNavBar(UINavigationBar *bar) {
    if (objc_getAssociatedObject(bar, kFBPSavedNav)) return;
    NSMutableDictionary *s = [NSMutableDictionary dictionary];
    s[@"translucent"] = @(bar.translucent);
    s[@"barTint"]     = bar.barTintColor ?: NSNull.null;
    s[@"bg"]          = bar.backgroundColor ?: NSNull.null;
    if (@available(iOS 13.0, *)) {
        s[@"standard"] = bar.standardAppearance ?: NSNull.null;
        s[@"compact"]  = bar.compactAppearance ?: NSNull.null;
        s[@"scroll"]   = bar.scrollEdgeAppearance ?: NSNull.null;
        if (@available(iOS 15.0, *)) {
            s[@"compactScroll"] = bar.compactScrollEdgeAppearance ?: NSNull.null;
        }
    }
    objc_setAssociatedObject(bar, kFBPSavedNav, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void FBPRestoreNavBar(UINavigationBar *bar) {
    NSDictionary *s = objc_getAssociatedObject(bar, kFBPSavedNav);
    if (!s) return;
    BOOL was = gFBPRestoring;
    gFBPRestoring = YES;
    bar.translucent  = [s[@"translucent"] boolValue];
    bar.barTintColor = s[@"barTint"] == NSNull.null ? nil : s[@"barTint"];
    bar.backgroundColor = s[@"bg"] == NSNull.null ? nil : s[@"bg"];
    if (@available(iOS 13.0, *)) {
        bar.standardAppearance = s[@"standard"] == NSNull.null ? nil : s[@"standard"];
        bar.compactAppearance  = s[@"compact"] == NSNull.null ? nil : s[@"compact"];
        bar.scrollEdgeAppearance = s[@"scroll"] == NSNull.null ? nil : s[@"scroll"];
        if (@available(iOS 15.0, *)) {
            bar.compactScrollEdgeAppearance =
                s[@"compactScroll"] == NSNull.null ? nil : s[@"compactScroll"];
        }
    }
    gFBPRestoring = was;
    objc_setAssociatedObject(bar, kFBPSavedNav, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Dividers

// Pure black merges cards into their background, so the hairline separators
// vanish. Facebook draws them with FBLineComponentInternalView and plain ~1-2pt
// hairline views; those are painted a faint white instead of black.
static const CGFloat kFBPDividerAlpha = 0.22;   // faint white on black

static UIColor *FBPDividerColor(void) {
    static UIColor *color = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ color = [UIColor colorWithWhite:1.0 alpha:kFBPDividerAlpha]; });
    return color;
}

/// Faint white with the dividers toggle on, solid black with it off. Either way
/// the original is saved first.
static UIColor *FBPDividerPaint(void) {
    return gOLEDDividers ? FBPDividerColor() : UIColor.blackColor;
}

/// YES for a separator to lighten rather than blacken: FBLineComponentInternal
/// View, or a thin (<=2pt) neutral hairline. A *coloured* thin bar — a tab
/// underline, a progress bar — fails the dark test and is left alone.
static BOOL FBPViewLooksLikeDivider(UIView *view) {
    if ([NSStringFromClass(view.class) containsString:@"LineComponent"]) return YES;
    CGSize size = view.bounds.size;
    BOOL thin = (size.height > 0 && size.height <= 2.0 && size.width  >= 40) ||
                (size.width  > 0 && size.width  <= 2.0 && size.height >= 40);
    if (!thin) return NO;
    UIColor *bg = view.backgroundColor;
    if (bg) return FBPColorIsDark(FBPResolve(bg));
    if (view.layer.backgroundColor) return FBPCGColorIsDark(view.layer.backgroundColor);
    return view.layer.sublayers.count > 0;   // line drawn on a sublayer
}

/// All three ways Facebook draws a line — the view background, its own layer,
/// any line-drawing sublayer — saving each original.
static void FBPLightenDivider(UIView *view) {
    UIColor *light = FBPDividerPaint();
    FBPSaveViewBG(view, view.backgroundColor);
    FBPSaveLayerBG(view.layer);
    view.backgroundColor = light;
    view.layer.backgroundColor = light.CGColor;
    for (CALayer *sub in [view.layer.sublayers copy]) {
        if ([sub.delegate isKindOfClass:UIView.class]) continue;
        if ([sub isKindOfClass:CAShapeLayer.class]) {
            FBPSaveFill((CAShapeLayer *)sub);
            ((CAShapeLayer *)sub).fillColor = light.CGColor;
        }
        FBPSaveLayerBG(sub);
        sub.backgroundColor = light.CGColor;
    }
    FBPMarkTouched(view);
}

#pragma mark - Profile avatars

// A profile avatar stacks an unmasked square placeholder behind the circular
// photo. Its grey corners blend into Facebook's cards but poke past the circle
// on black, so they are clipped while OLED is active (harmless in Light, so not
// reverted). Two shapes cover every case seen, and both are scoped to small
// square-ish containers so post photos are never touched.
static void FBPFixAvatarBox(UIView *container) {
    CGSize size = container.bounds.size;
    if (size.width < 16.0 || size.width > 72.0) return;        // avatar-sized only
    CGFloat boxDiff = size.width > size.height ? size.width - size.height
                                               : size.height - size.width;
    if (boxDiff > 6.0) return;                                  // square-ish only

    UIView *maskedAvatar = nil;
    UIImageView *bareImages[8];
    NSUInteger bareCount = 0;
    BOOL hasImageContent = NO;

    for (UIView *sub in container.subviews) {
        if ([NSStringFromClass([sub class]) containsString:@"MRCImageComponent"]) {
            hasImageContent = YES;
            if (sub.layer.masksToBounds) maskedAvatar = sub;
            continue;
        }
        if (![sub isKindOfClass:UIImageView.class]) continue;
        hasImageContent = YES;
        if (sub.layer.cornerRadius > 0.5 || sub.layer.masksToBounds) continue;
        CGFloat w = sub.bounds.size.width, h = sub.bounds.size.height;
        CGFloat d = w > h ? w - h : h - w;
        if (w < 16.0 || d > 6.0) continue;                      // square-ish image
        if (bareCount < 8) bareImages[bareCount++] = (UIImageView *)sub;
    }

    CGFloat cr = container.layer.cornerRadius;
    CGFloat crDiff = cr > size.width / 2.0 ? cr - size.width / 2.0
                                           : size.width / 2.0 - cr;
    if (hasImageContent && crDiff < 3.0 && !container.layer.masksToBounds) {
        container.layer.masksToBounds = YES;
        container.clipsToBounds = YES;
    }

    if (maskedAvatar) {
        for (NSUInteger i = 0; i < bareCount; i++) {
            UIImageView *img = bareImages[i];
            img.layer.cornerRadius = img.bounds.size.width / 2.0;
            img.layer.masksToBounds = YES;
            img.clipsToBounds = YES;
        }
    }
}

#pragma mark - Sublayer sweep

/// The colours a view paints directly onto its own layer's sublayers: the
/// CALayers ComponentKit uses for rounded card backgrounds and Facebook for the
/// header fade. Layers that merely back a subview are skipped, since that
/// subview repaints itself.
static void FBPApplySublayers(CALayer *layer, BOOL active) {
    NSArray<CALayer *> *sublayers = layer.sublayers;
    if (sublayers.count == 0) return;
    BOOL changed = NO;
    for (CALayer *sub in [sublayers copy]) {
        if ([sub.delegate isKindOfClass:UIView.class]) continue;   // subview's own layer

        if ([sub isKindOfClass:CAGradientLayer.class]) {
            CAGradientLayer *gradient = (CAGradientLayer *)sub;
            if (active) {
                NSArray *colors = gradient.colors;
                BOOL anyDark = NO;
                for (id entry in colors) {
                    if (FBPCGColorIsDark((__bridge CGColorRef)entry)) { anyDark = YES; break; }
                }
                if (anyDark && colors.count) {
                    FBPSaveGradient(gradient);
                    NSMutableArray *black = [NSMutableArray arrayWithCapacity:colors.count];
                    for (id entry in colors) {
                        [black addObject:(__bridge id)FBPBlackCGKeepingAlpha(
                                             (__bridge CGColorRef)entry)];
                    }
                    gradient.colors = black;
                    changed = YES;
                }
            } else {
                FBPRestoreGradient(gradient);
            }
            continue;
        }
        if ([sub isKindOfClass:CAShapeLayer.class]) {
            CAShapeLayer *shape = (CAShapeLayer *)sub;
            if (active) {
                if (FBPCGColorIsDark(shape.fillColor)) {
                    FBPSaveFill(shape);
                    shape.fillColor = FBPBlackCGKeepingAlpha(shape.fillColor);
                    changed = YES;
                }
                if (FBPCGColorIsDark(shape.backgroundColor)) {
                    FBPSaveLayerBG(shape);
                    shape.backgroundColor = FBPBlackCGKeepingAlpha(shape.backgroundColor);
                    changed = YES;
                }
            } else {
                FBPRestoreFill(shape);
                FBPRestoreLayerBG(shape);
            }
            continue;
        }
        if (active) {
            if (FBPCGColorIsDark(sub.backgroundColor)) {
                FBPSaveLayerBG(sub);
                sub.backgroundColor = FBPBlackCGKeepingAlpha(sub.backgroundColor);
                changed = YES;
            }
        } else {
            FBPRestoreLayerBG(sub);
        }
    }
    if (active && changed && [layer.delegate isKindOfClass:UIView.class]) {
        FBPMarkTouched((UIView *)layer.delegate);
    }
}

#pragma mark - Header (FBMovableNavigationBarView) helpers

/// The real UINavigationBar the header hosts draws its background through
/// UINavigationBarAppearance / _UIBarBackground (a blur), not -backgroundColor,
/// so the appearance objects must be reconfigured and the blur flattened. Both
/// originals are saved for FBPRestoreNavBar.
static void FBPBlackNavigationBar(UINavigationBar *bar) {
    if (!bar) return;
    // On the register like everything else: its appearance is saved separately,
    // but without the flag FBPApplyView returns before restoring anything.
    FBPSaveNavBar(bar);
    FBPMarkTouched(bar);
    bar.translucent = NO;
    bar.barTintColor = UIColor.blackColor;
    bar.backgroundColor = UIColor.blackColor;
    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
        [appearance configureWithOpaqueBackground];
        appearance.backgroundColor = UIColor.blackColor;
        appearance.backgroundEffect = nil;
        appearance.shadowColor = UIColor.clearColor;
        appearance.shadowImage = [[UIImage alloc] init];
        bar.standardAppearance = appearance;
        bar.compactAppearance = appearance;
        bar.scrollEdgeAppearance = appearance;
        if (@available(iOS 15.0, *)) bar.compactScrollEdgeAppearance = appearance;
    }
    for (UIView *sub in bar.subviews) {
        if ([NSStringFromClass(sub.class) containsString:@"BarBackground"]) {
            FBPSaveViewBG(sub, sub.backgroundColor);
            FBPMarkTouched(sub);
            sub.backgroundColor = UIColor.blackColor;
            for (UIView *inner in sub.subviews) {
                FBPSaveViewBG(inner, inner.backgroundColor);
                FBPMarkTouched(inner);
                inner.backgroundColor = UIColor.blackColor;
                if ([inner isKindOfClass:UIVisualEffectView.class]) {
                    UIView *content = ((UIVisualEffectView *)inner).contentView;
                    FBPSaveViewBG(content, content.backgroundColor);
                    FBPMarkTouched(content);
                    content.backgroundColor = UIColor.blackColor;
                }
            }
        }
    }
}

/// Walks the header's sub-tree over every grey surface — view backgrounds,
/// layer/gradient/shape colours, the hosted UINavigationBar and any blur —
/// leaving nil/clear backgrounds and coloured accents alone. The restore pass
/// ignores the touched flag: the header is one long-lived view whose children
/// must come back the moment OLED turns off.
static void FBPApplyHeaderTree(UIView *view, int depth, BOOL active) {
    if (!view || depth > 12) return;
    for (UIView *sub in [view.subviews copy]) {
        if (FBPOLEDSkip(sub)) continue;

        if ([sub isKindOfClass:UINavigationBar.class]) {
            if (active) FBPBlackNavigationBar((UINavigationBar *)sub);
            else        FBPRestoreNavBar((UINavigationBar *)sub);
        } else if ([sub isKindOfClass:UIVisualEffectView.class]) {
            UIView *content = ((UIVisualEffectView *)sub).contentView;
            if (active) {
                FBPSaveViewBG(sub, sub.backgroundColor);
                FBPSaveViewBG(content, content.backgroundColor);
                FBPMarkTouched(sub);
                // Reverted as a view of its own, so it needs its own flag;
                // marking only its host makes the revert return early.
                FBPMarkTouched(content);
                sub.backgroundColor = UIColor.blackColor;
                content.backgroundColor = UIColor.blackColor;
                FBPApplySublayers(sub.layer, YES);
            } else {
                FBPRestoreViewBG(sub);
                FBPRestoreViewBG(content);
                FBPApplySublayers(sub.layer, NO);
            }
            continue;   // don't recurse into the effect view's content
        } else {
            if (active) {
                if (FBPColorIsDark(FBPResolve(sub.backgroundColor))) {
                    FBPSaveViewBG(sub, sub.backgroundColor);
                    FBPMarkTouched(sub);
                    sub.backgroundColor = FBPBlackKeepingAlpha(sub.backgroundColor);
                } else if (FBPCGColorIsDark(sub.layer.backgroundColor)) {
                    FBPSaveLayerBG(sub.layer);
                    FBPMarkTouched(sub);
                    sub.layer.backgroundColor =
                        FBPBlackCGKeepingAlpha(sub.layer.backgroundColor);
                }
            } else {
                FBPRestoreViewBG(sub);
                FBPRestoreLayerBG(sub.layer);
            }
        }
        FBPApplySublayers(sub.layer, active);
        FBPApplyHeaderTree(sub, depth + 1, active);
    }
}

static BOOL FBPCGIsPureBlack(CGColorRef cg);

#pragma mark - Why-still-grey diagnostic

#if FBP_DIAG
// Main thread only: layoutSubviews and the settings notification.
static BOOL gFBPGreyDiag = NO;
static NSMutableSet<NSString *> *gFBPGreySeen;
static NSUInteger gFBPGreyLines;
static const NSUInteger kFBPGreyMaxLines = 80;
static const CGFloat kFBPGreyMinW = 150, kFBPGreyMinH = 100;

static void FBPGreyDiagSwitch(BOOL on) {
    if (on == gFBPGreyDiag) return;
    gFBPGreyDiag = on;
    if (!on) {
        FBPDiag(@"oledgrey", @"stop lines=%lu", (unsigned long)gFBPGreyLines);
        gFBPGreySeen = nil;
        return;
    }
    gFBPGreySeen = [NSMutableSet set];
    gFBPGreyLines = 0;
    FBPDiag(@"oledgrey",
            @"start luma<%.2f chroma<%.2f alpha>=0.20 gate>=%.0fx%.0f cap=%lu",
            kFBPBgMaxLuma, kFBPBgMaxChroma, kFBPGreyMinW, kFBPGreyMinH,
            (unsigned long)kFBPGreyMaxLines);
}

static BOOL FBPGreySRGB(CGColorRef cg, CGFloat out[4]) {
    if (!cg) return NO;
    static CGColorSpaceRef srgb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB); });
    CGColorRef c = CGColorCreateCopyByMatchingToColorSpace(
        srgb, kCGRenderingIntentDefault, cg, NULL);
    if (!c) return NO;
    BOOL ok = CGColorGetNumberOfComponents(c) == 4;
    if (ok) memcpy(out, CGColorGetComponents(c), 4 * sizeof(CGFloat));
    CGColorRelease(c);
    return ok;
}

static NSString *FBPGreyText(CGColorRef cg) {
    CGFloat c[4];
    if (!cg) return @"nil";
    if (!FBPGreySRGB(cg, c)) return @"?";
    return [NSString stringWithFormat:@"%.3f,%.3f,%.3f,%.2f", c[0], c[1], c[2], c[3]];
}

/// Visible and not already black.
static BOOL FBPGreyPaints(CGColorRef cg) {
    CGFloat c[4];
    return FBPGreySRGB(cg, c) && c[3] >= 0.2 && MAX(c[0], MAX(c[1], c[2])) >= 0.02;
}

/// Sublayers that paint on their own, not a subview's backing layer.
static NSUInteger FBPGreyPaintingSublayers(CALayer *layer, NSUInteger *total) {
    NSUInteger n = 0, seen = 0;
    *total = layer.sublayers.count;
    for (CALayer *sub in layer.sublayers) {
        if (++seen > 16) break;
        if ([sub.delegate isKindOfClass:UIView.class]) continue;
        BOOL paints = FBPGreyPaints(sub.backgroundColor);
        if (!paints && [sub isKindOfClass:CAShapeLayer.class]) {
            paints = FBPGreyPaints(((CAShapeLayer *)sub).fillColor);
        }
        if (!paints && [sub isKindOfClass:CAGradientLayer.class]) {
            paints = ((CAGradientLayer *)sub).colors.count > 0;
        }
        if (paints) n++;
    }
    return n;
}

static NSString *FBPGreyNearestVC(UIView *view) {
    UIResponder *r = view;
    for (int i = 0; r && i < 64; i++, r = r.nextResponder) {
        if ([r isKindOfClass:UIViewController.class]) return NSStringFromClass(r.class);
    }
    return @"-";
}

/// One line per surface OLED looked at and left grey.
static void FBPGreyReport(UIView *view, BOOL light) {
    if (!gFBPGreySeen || gFBPGreyLines >= kFBPGreyMaxLines) return;
    UIWindow *window = view.window;
    CGRect box = view.bounds;
    if (!window || box.size.width < kFBPGreyMinW || box.size.height < kFBPGreyMinH) return;

    UIColor *bg = view.backgroundColor;
    CGColorRef layerCG = view.layer.backgroundColor;
    if (!light) {
        BOOL wouldDarken = bg ? (!FBPIsOurPaint(bg) && FBPColorIsDark(FBPResolve(bg)))
                              : FBPCGColorIsDark(layerCG);
        if (wouldDarken) return;
    }

    UIColor *own = bg;
    if (bg) {
        @try {
            own = [bg resolvedColorWithTraitCollection:view.traitCollection] ?: bg;
        } @catch (__unused NSException *e) {}
    }
    NSString *liveText = FBPGreyText(own.CGColor);
    BOOL ownPaints = FBPGreyPaints(own.CGColor);
    NSUInteger subTotal = 0;
    NSUInteger subPaint = FBPGreyPaintingSublayers(view.layer, &subTotal);
    if (!ownPaints && !FBPGreyPaints(layerCG) && subPaint == 0) return;

    NSString *cls = NSStringFromClass(view.class);
    NSString *vc = FBPGreyNearestVC(view);
    NSString *key = [NSString stringWithFormat:@"%@|%@", cls, vc];
    if ([gFBPGreySeen containsObject:key]) return;
    [gFBPGreySeen addObject:key];
    gFBPGreyLines++;

    UIColor *tested = bg ? FBPResolve(bg) : (layerCG ? [UIColor colorWithCGColor:layerCG] : nil);
    NSString *darkText = FBPGreyText(tested.CGColor);
    CGFloat r = 0, g = 0, b = 0, a = 0, luma = -1, chroma = -1;
    if ([tested getRed:&r green:&g blue:&b alpha:&a]) {
        luma = 0.299 * r + 0.587 * g + 0.114 * b;
        chroma = MAX(r, MAX(g, b)) - MIN(r, MIN(g, b));
    } else if ([tested getWhite:&r alpha:&a]) {
        luma = r;
        chroma = 0;
    }

    CGRect f = [view convertRect:box toView:window];
    FBPDiag(@"oledgrey",
            @"view why=%s cls=%@ vc=%@ frame=%.0f,%.0f,%.0f,%.0f src=%s "
            @"bgLive=%@ bgDark=%@ layer=%@ luma=%.3f chroma=%.3f alpha=%.2f "
            @"paintSub=%lu/%lu light=%d ovr=%ld ours=%d colorCls=%@ n=%lu",
            light ? "light" : "notdark", cls, vc, f.origin.x, f.origin.y,
            f.size.width, f.size.height, bg ? "view" : (layerCG ? "layer" : "none"),
            liveText, darkText, FBPGreyText(layerCG), luma, chroma, a,
            (unsigned long)subPaint, (unsigned long)subTotal, FBPViewIsLight(view),
            (long)view.overrideUserInterfaceStyle, FBPIsOurPaint(bg),
            bg ? NSStringFromClass(bg.class) : @"nil", (unsigned long)gFBPGreyLines);
}
#endif

#pragma mark - Per-view apply

/// YES when the layer colour is just the view colour resolved, one storage. A
/// view that overrides its colour accessor answers NO, and an unreadable colour
/// answers YES so nothing is touched.
static BOOL FBPLayerMirrorsView(UIView *view, UIColor *bg) {
    UIColor *shown = bg;
    if (@available(iOS 13.0, *)) {
        shown = [bg resolvedColorWithTraitCollection:view.traitCollection] ?: bg;
    }
    UIColor *layerColor = [UIColor colorWithCGColor:view.layer.backgroundColor];
    CGFloat a[4] = {0}, b[4] = {0};
    if (![shown getRed:&a[0] green:&a[1] blue:&a[2] alpha:&a[3]] ||
        ![layerColor getRed:&b[0] green:&b[1] blue:&b[2] alpha:&b[3]]) return YES;
    for (int i = 0; i < 4; i++) {
        if (fabs(a[i] - b[i]) > 0.02) return NO;
    }
    return YES;
}

/// The body of UIView -layoutSubviews under OLED: blacken this view's
/// background, layer and sublayers, or put back everything OLED saved and drop
/// the touched flag. Untouched views short-circuit immediately.
static void FBPApplyView(UIView *view, BOOL active) {
    if (FBPOLEDSkip(view)) return;

    if (!active) {
        if (!FBPWasTouched(view)) return;
        FBPRestoreViewBG(view);
        FBPRestoreLayerBG(view.layer);
        FBPApplySublayers(view.layer, NO);
        FBPClearTouched(view);
        return;
    }

    // A light-locked card is left alone: blackening it strands its dark text.
    // If it was darkened before it became light, put it back.
    if (FBPViewIsLight(view)) {
        if (FBPWasTouched(view)) {
            FBPRestoreViewBG(view);
            FBPRestoreLayerBG(view.layer);
            FBPApplySublayers(view.layer, NO);
            FBPClearTouched(view);
        }
#if FBP_DIAG
        if (gFBPGreyDiag) FBPGreyReport(view, YES);
#endif
        return;
    }

    if (FBPViewLooksLikeDivider(view)) {
        FBPLightenDivider(view);
        return;
    }

    // Round the square placeholder behind a circular avatar. Triggered both
    // when the container lays out and, more reliably, when the masked image
    // component mounts (which then fixes its siblings).
    FBPFixAvatarBox(view);
    if ([NSStringFromClass(view.class) containsString:@"MRCImageComponent"] &&
        view.layer.masksToBounds) {
        FBPFixAvatarBox(view.superview);
    }

    UIColor *bg = view.backgroundColor;
    if (bg) {
        if (!FBPIsOurPaint(bg) && FBPColorIsDark(FBPResolve(bg))) {
            FBPSaveViewBG(view, bg);
            FBPMarkTouched(view);
            view.backgroundColor = FBPBlackFollowingAppearance(bg);
        }
    } else if (FBPCGColorIsDark(view.layer.backgroundColor)) {
        // ComponentKit cards that paint straight onto their own layer, written
        // as a dynamic colour through the view rather than a flat CGColor:
        // -[UIView backgroundColor] IS the layer's background, so it reaches
        // the same pixels but is re-resolved in the other appearance.
        UIColor *original = [UIColor colorWithCGColor:view.layer.backgroundColor];
        FBPSaveViewBG(view, original);
        FBPMarkTouched(view);
        view.backgroundColor = FBPBlackFollowingAppearance(original);
    }

    // Both colours are read again here. For a plain view they are one storage,
    // so the write above already blackened the layer and it is skipped. React
    // Native keeps its colour in an ivar and paints the layer itself, so there
    // the layer is still grey and this is the only pass that reaches it. The
    // write repeats for the same reason: React Native repaints on every update.
    UIColor *current = view.backgroundColor;
    CGColorRef layerBG = view.layer.backgroundColor;
    if (current && layerBG && FBPCGColorIsDark(layerBG) &&
        !FBPCGIsPureBlack(layerBG) &&
        (FBPIsOurPaint(current) || !FBPLayerMirrorsView(view, current))) {
        FBPSaveLayerBG(view.layer);
        FBPMarkTouched(view);
        view.layer.backgroundColor = FBPBlackCGKeepingAlpha(layerBG);
    }

    // Cards and fades that paint onto a sublayer rather than the view or its own
    // layer background. Cheap: most views have no sublayers.
    FBPApplySublayers(view.layer, YES);
#if FBP_DIAG
    if (gFBPGreyDiag) FBPGreyReport(view, NO);
#endif
}

/// The value to hand the original -setBackgroundColor:. Inactive drops any
/// stash, so a later relayout cannot put the black-era colour back over a
/// freshly repainted view.
static UIColor *FBPBGForSet(UIView *self, UIColor *color) {
    // A colour on its way back from a restore passes straight through; judging
    // it again is how a restored view ends up black and unrecorded.
    if (gFBPRestoring) return color;
    if (FBPOLEDActiveFor(self) && !FBPOLEDSkip(self)) {
        // Already ours: it is saved, flagged and black on its own.
        if (FBPIsOurPaint(color)) return color;
        if (FBPColorIsDark(FBPResolve(color))) {
            // Still saved and flagged: the layer and sublayer paths have no
            // dynamic equivalent and the restore pass walks both.
            FBPSaveViewBG(self, color);
            FBPMarkTouched(self);
            return FBPBlackFollowingAppearance(color);
        }
        return color;
    }
    // Facebook repainted while OLED is disengaged, so every record is stale.
    // Dropping the colour but keeping the flag leaves the layer save behind,
    // and the next revert writes it over what Facebook just set.
    if (!FBPOLEDSkip(self) && FBPWasTouched(self)) {
        FBPForgetViewBG(self);
        objc_setAssociatedObject(self.layer, kFBPSavedLayerBG, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        FBPClearTouched(self);
    }
    return color;
}

#pragma mark - Hooks

%group FBPOLEDGlobal

%hook UIView

- (void)setBackgroundColor:(UIColor *)color {
    FBPTraceFire("oled.UIView.setBackgroundColor");
    if (FBPOLEDActiveFor(self) && !FBPOLEDSkip(self) &&
        [NSStringFromClass(self.class) containsString:@"LineComponent"]) {
        FBPSaveViewBG(self, color);
        FBPMarkTouched(self);
        %orig(FBPDividerPaint());
        return;
    }
    UIColor *resolved = FBPBGForSet(self, color);
    %orig(resolved);
}

- (void)layoutSubviews {
    %orig;
    FBPTraceFire("oled.UIView.layoutSubviews");
    FBPApplyView(self, FBPOLEDActiveFor(self));
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    %orig;
    FBPTraceFire("oled.UIView.traitCollectionDidChange");
    if (@available(iOS 13.0, *)) {
        if (previous &&
            previous.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
            // A hint that the system appearance moved, so re-read it from the
            // window's *scene*, not the window, which carries Facebook's theme.
            // A bonus, not the mechanism: when Facebook pins its windows this
            // never fires, which is why the window layout pass checks too.
            if ([self isKindOfClass:UIWindow.class]) {
                FBPTrackWindowStyle((UIWindow *)self);
            }
            [self setNeedsLayout];
        }
    }
}

%end

// UIWindow overrides -layoutSubviews, so the UIView hook never runs for one and
// this is the only place a window's own layout is seen.
%hook UIWindow
- (void)layoutSubviews {
    %orig;
    FBPTrackWindowStyle(self);
}
%end

%hook UITableView
- (void)setBackgroundColor:(UIColor *)color {
    FBPTraceFire("oled.UITableView.setBackgroundColor");
    UIColor *resolved = FBPBGForSet(self, color);
    %orig(resolved);
}
%end

%hook UITableViewCell
- (void)setBackgroundColor:(UIColor *)color {
    FBPTraceFire("oled.UITableViewCell.setBackgroundColor");
    UIColor *resolved = FBPBGForSet(self, color);
    %orig(resolved);
}
%end

%hook UICollectionView
- (void)setBackgroundColor:(UIColor *)color {
    FBPTraceFire("oled.UICollectionView.setBackgroundColor");
    UIColor *resolved = FBPBGForSet(self, color);
    %orig(resolved);
}
%end

// The app header paints nothing on its own view: the grey lives on child views,
// a hosted UINavigationBar, a blur and gradients, so the sub-tree is walked on
// every layout pass. That is what stops it flickering between grey and black.
%hook FBMovableNavigationBarView
- (void)layoutSubviews {
    %orig;
    FBPTraceFire("oled.FBMovableNavigationBarView.layoutSubviews");
    BOOL active = FBPOLEDActiveFor(self);
    if (active) {
        // Marked like every other painted surface, or the revert returns at the
        // flag and the most visible view in the app stays black. Painted with
        // the dynamic colour, so it follows the appearance by itself.
        if (FBPColorIsDark(FBPResolve(self.backgroundColor))) {
            FBPSaveViewBG(self, self.backgroundColor);
            FBPMarkTouched(self);
            self.backgroundColor = FBPBlackFollowingAppearance(self.backgroundColor);
        } else if (FBPCGColorIsDark(self.layer.backgroundColor)) {
            // Only when the view has no colour of its own: the two are the same
            // storage, so writing both saves the first's black as the original.
            FBPSaveLayerBG(self.layer);
            FBPMarkTouched(self);
            self.layer.backgroundColor = FBPBlackCGKeepingAlpha(self.layer.backgroundColor);
        }
    } else {
        FBPRestoreViewBG(self);
        FBPRestoreLayerBG(self.layer);
    }
    FBPApplySublayers(self.layer, active);
    FBPApplyHeaderTree(self, 0, active);
}
%end

// This controller drives the status bar and returns darkContent, because
// Facebook's header is normally light. OLED paints it black, so the glyphs
// vanish; force light content while OLED is on.
%hook FBMovableNavigationBarViewController
- (UIStatusBarStyle)preferredStatusBarStyle {
    FBPTraceFire("oled.FBMovableNavigationBarViewController.preferredStatusBarStyle");
    if (FBPOLEDActiveFor(FBPAppKeyWindow())) return UIStatusBarStyleLightContent;
    return %orig;
}
%end

%end // FBPOLEDGlobal

/// How deep the reapply and nudge walks go. Headroom only: what makes the
/// revert complete is FBPTouchedViews, not a walk reaching far enough.
static const int kFBPWalkMaxDepth = 200;

/// What a walk had to do, for the diagnostic line. `stray` is the count that
/// matters: OLED only restores a view it flagged, so a view painted black
/// without a flag is invisible to the revert and stays black forever. Anything
/// but 0 after a switch to Light says that is happening.
typedef struct {
    int visited;
    int deepest;
    BOOL capped;
    int restored;
    int stray;
} FBPWalkStats;

/// YES when this view is painted a flat, opaque-ish pure black right now.
/// Narrower than FBPColorIsDark, which also matches Facebook's own near-black
/// base grey: the question is "is this one of ours that never came back".
static BOOL FBPCGIsPureBlack(CGColorRef cg) {
    if (!cg) return NO;
    if (CGColorGetAlpha(cg) < 0.2) return NO;
    CGFloat r = 0, g = 0, b = 0, a = 0;
    UIColor *flat = [UIColor colorWithCGColor:cg];
    if ([flat getRed:&r green:&g blue:&b alpha:&a]) {
        return r < 0.02 && g < 0.02 && b < 0.02;
    }
    CGFloat w = 0, wa = 0;
    if ([flat getWhite:&w alpha:&wa]) return w < 0.02;
    return NO;
}

/// As above, and it asks BOTH places. Stopping at a non-nil -backgroundColor
/// hides the case it most needs to catch: a view whose colour was restored
/// while its layer was left holding black. The two are usually the same
/// storage, but not while a restore has written one and not the other.
static BOOL FBPSurfaceIsPureBlack(UIView *view) {
    UIColor *color = view.backgroundColor;
    if (color) {
        CGColorRef cg = color.CGColor;
        if (@available(iOS 13.0, *)) {
            if (view.traitCollection) {
                @try {
                    UIColor *shown =
                        [color resolvedColorWithTraitCollection:view.traitCollection];
                    if (shown) cg = shown.CGColor;
                } @catch (__unused NSException *e) {}
            }
        }
        if (FBPCGIsPureBlack(cg)) return YES;
    }
    return FBPCGIsPureBlack(view.layer.backgroundColor);
}

/// Re-applies the current appearance to a whole view tree. FBPApplyView is
/// normally reached from each view's -layoutSubviews, which covers what is
/// about to be drawn but not a view already mounted and settled — exactly the
/// ones holding the wrong colour after a switch.
static void FBPApplyTree(UIView *view, int depth, FBPWalkStats *stats) {
    if (!view) return;
    if (depth > kFBPWalkMaxDepth) { stats->capped = YES; return; }
    stats->visited++;
    if (depth > stats->deepest) stats->deepest = depth;

    // Per view: a subtree pinned to the other appearance sits inside the same
    // window, so one flag for the whole walk would get it wrong.
    BOOL active = FBPOLEDActiveFor(view);
    BOOL wasTouched = FBPWasTouched(view);
    FBPApplyView(view, active);
    if (!active && !FBPOLEDSkip(view)) {
        if (wasTouched) stats->restored++;
        else if (FBPSurfaceIsPureBlack(view)) {
            stats->stray++;
            // A stray is a surface painted through a path that does not record
            // it, and the class name is the shortest route to which path.
            if (stats->stray <= 6) {
                FBPDiag(@"oled", @"  stray %@ frame=%@ bg=%@ layer=%@",
                        NSStringFromClass(view.class),
                        NSStringFromCGRect(view.frame),
                        view.backgroundColor ? @"set" : @"nil",
                        view.layer.backgroundColor ? @"set" : @"nil");
            }
        }
    }
    for (UIView *sub in [view.subviews copy]) {
        FBPApplyTree(sub, depth + 1, stats);
    }
}

/// Marks a whole view tree for relayout so the layout hooks re-run at once:
/// used when the toggle changes, since no trait change fires then, and on
/// returning from the background.
static void FBPNudgeLayout(UIView *view, int depth) {
    if (!view || depth > kFBPWalkMaxDepth) return;
    [view setNeedsLayout];
    for (UIView *sub in [view.subviews copy]) FBPNudgeLayout(sub, depth + 1);
}

static void FBPNudgeOLEDRelayout(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (FBPClassIsOurs(window.class)) continue;
            FBPNudgeLayout(window, 0);
        }
    }
}

/// Hands the app back to its own appearance so Facebook repaints. Restoring
/// saved colours reaches only surfaces OLED recorded; pinning every Facebook
/// window to the style the system moved to is a real UIKit trait change, so it
/// propagates, re-resolves Facebook's dynamic colours and repaints over
/// anything left behind. Released shortly after, so the window follows iOS.
static void FBPAdoptAppearance(UIUserInterfaceStyle style) {
    if (@available(iOS 13.0, *)) {
        if (style == UIUserInterfaceStyleUnspecified) return;

        NSMutableArray<UIWindow *> *pinned = [NSMutableArray array];
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (FBPClassIsOurs(window.class)) continue;
                window.overrideUserInterfaceStyle = style;
                [window setNeedsLayout];
                [pinned addObject:window];
            }
        }
        if (!pinned.count) return;

        FBPDiag(@"oled", @"handed %lu window(s) to the app's own %@ appearance",
                (unsigned long)pinned.count, FBPStyleName(style));

        // Long enough to repaint against the forced trait, short enough that
        // Facebook's own Dark Mode setting is never visibly ignored.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            for (UIWindow *window in pinned) {
                window.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
                [window setNeedsLayout];
            }
        });
    }
}

/// Brings every surface OLED touches into line with the current appearance.
/// Idempotent. Two populations, because neither covers the other: the register
/// holds every painted view, mounted or not, while the tree walk finds surfaces
/// about to be blackened, which are not on the register yet.
// A sweep is only ever useful when the answer has moved: the layout hooks
// already paint whatever mounts while it stays put. The budget covers the ticks
// after a switch, because UIKit has not finished answering on the first one.
static BOOL gFBPLastSweptActive = NO;
static int gFBPSweepBudget = 0;

static void FBPSweepAppearance(void) {
    // The scene is the only honest answer: Facebook pins its windows' own
    // style, so a window cannot be asked. One read per tick is what makes this
    // reliable without a trait callback, which iOS 18 never sends.
    if (@available(iOS 13.0, *)) {
        UIUserInterfaceStyle style = FBPSystemStyleFromScenes();
        if (style != UIUserInterfaceStyleUnspecified && style != gFBPSystemStyle) {
            FBPUpdateSystemStyle(style);
            FBPOLEDLogState("sweep-style-changed");
            FBPAdoptAppearance(style);
        }
    }

    BOOL active = FBPOLEDActive();
    if (active != gFBPLastSweptActive) {
        gFBPLastSweptActive = active;
        gFBPSweepBudget = 3;
    }
    // The common case, twice a second for the life of the process: two global
    // loads and a branch. Walking the app here is what made scrolling stutter.
    if (gFBPSweepBudget <= 0) return;
    gFBPSweepBudget--;

    NSHashTable<UIView *> *table = FBPTouchedViews();
    NSArray<UIView *> *painted;
    // A snapshot: FBPApplyView takes a restored view off the list as it goes.
    @synchronized (table) { painted = table.allObjects; }
    NSUInteger listed = painted.count;
    for (UIView *view in painted) FBPApplyView(view, FBPOLEDActiveFor(view));

    FBPWalkStats stats = (FBPWalkStats){0, 0, NO, 0, 0};
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *each in ((UIWindowScene *)scene).windows) {
            if (FBPClassIsOurs(each.class)) continue;
            FBPApplyTree(each, 0, &stats);
        }
    }
    FBPNudgeOLEDRelayout();

#if FBP_DIAG
    NSUInteger remaining;
    @synchronized (table) { remaining = table.count; }
    // After a switch to Light everything painted should have come back, so
    // `left` should be 0; `stray` counts black views no revert can reach.
    if (listed || remaining || stats.stray) {
        FBPDiag(@"oled",
                @"sweep listed=%lu left=%lu views=%d deepest=%d capped=%d "
                @"restored=%d stray=%d",
                (unsigned long)listed, (unsigned long)remaining,
                stats.visited, stats.deepest, stats.capped,
                stats.restored, stats.stray);
    }
#else
    (void)listed;
#endif
}

/// Runs the sweep on a slow repeat for the life of the process, because
/// catching the moment of a switch is not reliable: -traitCollectionDidChange:
/// is never called on iOS 18, a window's own style may be pinned, and a pass
/// from the window's layout asks views a question UIKit has not finished
/// answering. Common run loop modes, so it survives scrolling.
static void FBPStartAppearanceSweep(void) {
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.75 repeats:YES
                                              block:^(__unused NSTimer *t) {
        FBPSweepAppearance();
    }];
    timer.tolerance = 0.15;
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}

/// Catches a Light to Dark switch from a window's layout pass, which is the
/// trigger, with the scene as the source: a window lays out when the appearance
/// changes even if its own style is pinned, so this needs no deprecated
/// callback.
static void FBPTrackWindowStyle(UIWindow *window) {
    if (@available(iOS 13.0, *)) {
        if (!window) return;

        // Windows lay out constantly while scrolling, and the scene read below
        // is not free. The sweep catches a switch within a tick regardless, so
        // this path only has to be prompter than that, not run every pass.
        static CFTimeInterval last = 0;
        CFTimeInterval now = CACurrentMediaTime();
        if (now - last < 0.25) return;
        last = now;

        // Our own windows follow iOS directly, a different question.
        if (FBPClassIsOurs(window.class)) return;
        UIUserInterfaceStyle style = FBPSystemStyleFromScenes();
        if (style == UIUserInterfaceStyleUnspecified || style == gFBPSystemStyle) return;

        FBPUpdateSystemStyle(style);
        FBPOLEDLogState("window-style-changed");

        FBPSweepAppearance();
        FBPAdoptAppearance(style);
    }
}

/// Re-applies after React Native has painted. Guarded, because the write goes
/// back through the setter hook.
static BOOL gFBPReactReasserting = NO;

static void FBPReactReassert(UIView *view) {
    if (gFBPReactReasserting || !view) return;
    gFBPReactReasserting = YES;
    FBPApplyView(view, FBPOLEDActiveFor(view));
    gFBPReactReasserting = NO;
}

%group FBPOLEDReact

%hook RCTView
- (void)setBackgroundColor:(UIColor *)color {
    FBPTraceFire("oled.RCTView.setBackgroundColor");
    %orig(FBPBGForSet((UIView *)self, color));
}
- (void)displayLayer:(CALayer *)layer {
    %orig;
    FBPReactReassert((UIView *)self);
}
%end

%hook RCTViewComponentView
- (void)setBackgroundColor:(UIColor *)color {
    FBPTraceFire("oled.RCTViewComponentView.setBackgroundColor");
    %orig(FBPBGForSet((UIView *)self, color));
}
- (void)invalidateLayer {
    %orig;
    FBPReactReassert((UIView *)self);
}
%end

%end // FBPOLEDReact

/// React Native stores its own background instead of calling super, so the
/// UIView setter hook never sees a Marketplace surface. Only worth installing
/// where the class really does replace that setter, and the framework carrying
/// it is loaded late, so this runs on every image.
static void FBPInstallReactHooks(void) {
    SEL sel = @selector(setBackgroundColor:);
    Method base = class_getInstanceMethod(UIView.class, sel);
    Class rct = objc_getClass("RCTView");
    Class fabric = objc_getClass("RCTViewComponentView");
    BOOL overrides = (rct && class_getInstanceMethod(rct, sel) != base) ||
                     (fabric && class_getInstanceMethod(fabric, sel) != base);
    if (!overrides) return;
    FBP_ONCE(gOLEDReact) {
        %init(FBPOLEDReact);
        FBPLogOnce(@"oled: React Native background hook installed");
    }
}

void FBPInitOLEDHooks(void) {
    FBPRefreshOLED();

    // FBPInitOLEDHooks is re-run on every dyld image load, so without this latch
    // the observers would be added once per image and a became-active would
    // fire the block dozens of times.
    FBP_ONCE(gOLED) {
        // Keep the cached toggle in sync, then nudge a relayout so the switch
        // takes effect promptly.
        [NSNotificationCenter.defaultCenter
            addObserverForName:FBPSettingsDidChangeNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
            FBPRefreshOLED();
            FBPOLEDLogState("settings-changed");
            FBPNudgeOLEDRelayout();
        }];

        // FBPTrackWindowStyle catches a live switch; returning from the
        // background is the one case it can miss.
        [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
            // The appearance may have changed while backgrounded, and no trait
            // change fires then.
            if (@available(iOS 13.0, *)) {
                // The scene only stands in when there is no Facebook window yet.
                UIWindow *key = FBPAppKeyWindow();
                UIUserInterfaceStyle style =
                    key ? key.traitCollection.userInterfaceStyle
                        : FBPSystemStyleFromScenes();
                FBPUpdateSystemStyle(style);
            }
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:UIWindowScene.class]) continue;
                for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                    FBPTrackWindowStyle(window);
                }
            }
            FBPOLEDLogState("became-active");
            FBPNudgeOLEDRelayout();
        }];

        if (@available(iOS 13.0, *)) {
            FBPUpdateSystemStyle(FBPSystemStyleFromScenes());
        }
        %init(FBPOLEDGlobal);
        FBPStartAppearanceSweep();
        FBPDiag(@"oled", @"hooks installed, toggle=%d", gOLEDEnabled);
    }
    FBPInstallReactHooks();
}
