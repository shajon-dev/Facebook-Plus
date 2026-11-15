// OLED Dark Mode: deepen Facebook's dark theme to true-black.
//
// An enhancement of dark mode, not a light→dark forcer. OLED follows the iOS
// system appearance: while the toggle is on it engages when iOS is in Dark Mode
// and disengages in Light Mode. In light mode it is inert and leaves every
// surface alone. The gate is FBPOLEDActive(): the toggle AND the iOS system
// appearance (FBPSystemIsDark, read from the screen's trait collection). The
// per-colour darkness tests still run, so even in Dark Mode only genuinely dark
// surfaces are blackened.
//
// Reverting cleanly is as important as blackening. Facebook does not repaint
// several of the surfaces OLED touches — a view's own layer colour, a
// sublayer's gradient/shape/plain colour, and above all the top header's
// navigation-bar appearance (which replaces appearance objects outright and
// persists until something sets them again). So each surface's original value
// is stashed in an associated object the first time it is darkened and put back
// the moment OLED disengages — turning the toggle off, or switching iOS to Light.
// Facebook's own colours are dynamic and are saved unresolved, so a restored
// colour tracks the live appearance by itself. Without this the header (and any
// still-mounted card) stayed black after switching to Light, which read as "OLED
// won't turn off". A trait-change hook re-runs the layout logic on a live
// Light↔Dark switch, and a relayout nudge does the same when the toggle changes.
//
// The two surfaces that used to stay grey — the top app header and the profile's
// "Add to story / Edit profile" panel — are painted by mechanisms a plain
// -setBackgroundColor: hook never sees. Disassembly of FBSharedFramework showed
// why:
//
//   * FBMovableNavigationBarView (the app header) sets nothing on its own view.
//     Its grey lives on child views (_fakeNavigationBar, _replacementNavigationBar
//     which is a real UINavigationBar drawn through UINavigationBarAppearance /
//     a UIVisualEffectView blur), a fade CAGradientLayer (_extraGradientHeight),
//     and a raw CALayer (FBNavigationBar._statusBarBackground). None of these is
//     the view's own -backgroundColor, so a plain -backgroundColor hook caught it
//     only intermittently, which produced the flickering header.
//
//   * ComponentKit cards (the profile panel) paint their rounded background onto
//     a CAGradientLayer / CAShapeLayer / plain CALayer added as a *sublayer*, not
//     onto the view's -backgroundColor, so -setBackgroundColor: never fires.
//
// Beyond the -backgroundColor path: (1) resolve dynamic colours against a
// forced-dark trait collection before judging darkness, removing the timing
// dependence; (2) sweep each view's own sublayers (gradient/shape/plain) and
// blacken the dark ones; (3) hook FBMovableNavigationBarView directly to blacken
// its header sub-tree (blur, UINavigationBar, gradients) while leaving genuinely
// coloured accents and photos alone.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPHeaders.h"

#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

/// Cached toggle state, refreshed on the settings-changed notification so the hot
/// path never touches NSUserDefaults.
static BOOL gOLEDEnabled = NO;

static void FBPRefreshOLED(void) { gOLEDEnabled = FBPEnabled(FBPKeyOLED); }

/// YES when iOS itself is set to Dark Mode. Read from the screen's trait
/// collection, which reflects the *system* appearance and is not affected by any
/// per-window override, so it is the true "is iOS in Dark Mode" signal.
static BOOL FBPSystemIsDark(void) {
    if (@available(iOS 13.0, *)) {
        return UIScreen.mainScreen.traitCollection.userInterfaceStyle ==
               UIUserInterfaceStyleDark;
    }
    return NO;
}

/// OLED follows the iOS system appearance: engaged only when the toggle is on AND
/// iOS is in Dark Mode, disengaged the moment iOS switches to Light. Keying on the
/// system appearance (not one view's trait) is what makes "iOS Light → OLED off,
/// iOS Dark → OLED on" hold. The downstream FBPColorIsDark checks still mean only
/// genuinely dark surfaces are blackened.
static BOOL FBPOLEDActive(void) {
    return gOLEDEnabled && FBPSystemIsDark();
}

#pragma mark - Colour judgement

/// A dark trait collection every dynamic colour is resolved against. Facebook's
/// backgrounds are dynamic UIColors; resolving them explicitly (instead of relying
/// on whatever the current trait environment happens to be) is what makes the
/// header deterministic rather than intermittently dark.
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

/// YES only for one of Facebook's own dark *background* greys — the surfaces that
/// should go true-black. Facebook's dark palette (FDSColor / FBColorPaletteConfig
/// -greyColorWithShade:) paints every surface from a small ladder of near-neutral
/// greys that tops out around #3A3B3C (base #18191A, card #242526, elevated
/// #3A3B3C). Matches exactly that band — near-neutral and no lighter than
/// ~#3A3B3C — rather than a loose "is it darkish" luma test.
///
/// Deliberately tight: the old test blackened anything up to a mid-grey
/// (luma < 0.48), which also caught dividers, pressed/hover states, elevated
/// chips and placeholders and painted them as solid black rectangles — the
/// "square box" artefacts. Lighter greys, tinted surfaces, accents and photos are
/// now left untouched, so only real backgrounds deepen to black.
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

/// Darkness test for a CGColorRef (layer colours are always CGColor and already
/// concrete, so no dynamic resolution is needed).
static BOOL FBPCGColorIsDark(CGColorRef cg) {
    if (!cg) return NO;
    return FBPColorIsDark([UIColor colorWithCGColor:cg]);
}

/// The tweak's own UI keeps its own colours.
static BOOL FBPOLEDSkip(UIView *view) {
    return [NSStringFromClass([view class]) hasPrefix:@"FBP"];
}

#pragma mark - Black that keeps alpha

/// Black that keeps the source colour's alpha. A translucent scrim — an alert's
/// dimming view, a bottom-sheet backdrop — must stay translucent; forcing it to
/// opaque black would turn it into a solid curtain, hiding everything behind a
/// popup in OLED mode. Opaque surfaces (alpha 1) still become solid black, so the
/// rest of the app is unchanged.
static UIColor *FBPBlackKeepingAlpha(UIColor *color) {
    CGFloat alpha = color ? CGColorGetAlpha(color.CGColor) : 1.0;
    return [UIColor colorWithWhite:0.0 alpha:alpha];
}
static CGColorRef FBPBlackCGKeepingAlpha(CGColorRef cg) {
    CGFloat alpha = cg ? CGColorGetAlpha(cg) : 1.0;
    return [UIColor colorWithWhite:0.0 alpha:alpha].CGColor;
}

#pragma mark - Save / restore

// OLED paints surfaces Facebook will not repaint on its own, so each is stashed
// before it is darkened and put back when OLED disengages. A view is flagged as
// "touched" so a relayout while OLED is off can skip the vast majority of views
// that were never modified.
static const void *kFBPTouched     = &kFBPTouched;     // UIView: OLED modified it
static const void *kFBPSavedViewBG = &kFBPSavedViewBG; // UIView: original backgroundColor
static const void *kFBPSavedLayerBG = &kFBPSavedLayerBG;// CALayer: original backgroundColor
static const void *kFBPSavedColors = &kFBPSavedColors; // CAGradientLayer: original colors
static const void *kFBPSavedFill   = &kFBPSavedFill;   // CAShapeLayer: original fillColor
static const void *kFBPSavedNav    = &kFBPSavedNav;    // UINavigationBar: original appearance

static void FBPMarkTouched(UIView *view) {
    objc_setAssociatedObject(view, kFBPTouched, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static BOOL FBPWasTouched(UIView *view) {
    return objc_getAssociatedObject(view, kFBPTouched) != nil;
}
static void FBPClearTouched(UIView *view) {
    objc_setAssociatedObject(view, kFBPTouched, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// -- view background (Facebook's dynamic colour, saved unresolved) --
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
    view.backgroundColor = (saved == NSNull.null) ? nil : saved;
    FBPForgetViewBG(view);
    return YES;
}

// -- layer background (concrete CGColor, boxed as UIColor) --
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

// -- gradient colours --
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

// -- shape fill --
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

// -- navigation bar appearance (dynamic colours, restored by reference) --
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
    objc_setAssociatedObject(bar, kFBPSavedNav, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Dividers

// Pure black merges Facebook's cards into their background, so the hairline
// separators between posts, list rows and sections vanish. Facebook draws them
// with FBLineComponentInternalView (and plain ~1–2pt hairline views); in OLED
// mode those are painted a faint white instead of black, keeping the structure
// of the native dark theme readable — a true-black look that still has lines.
static const CGFloat kFBPDividerAlpha = 0.22;   // faint white on black

static UIColor *FBPDividerColor(void) {
    static UIColor *color = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ color = [UIColor colorWithWhite:1.0 alpha:kFBPDividerAlpha]; });
    return color;
}

/// YES for a separator line to lighten rather than blacken: Facebook's
/// FBLineComponentInternalView, or a thin (≤2pt) neutral/near-black hairline. A
/// *coloured* thin bar — a selected-tab underline, a progress bar — is not a
/// divider (its colour isn't dark), so it is left alone.
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

/// Paints a divider faint-white across the ways Facebook draws its line — the
/// view's background, its own layer, and any line-drawing sublayer — saving the
/// original of each so it is restored when OLED turns off.
static void FBPLightenDivider(UIView *view) {
    UIColor *light = FBPDividerColor();
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

// A profile avatar stacks an unmasked square image — a low-res placeholder /
// backing — behind the circular photo. On Facebook's grey cards its grey corners
// blend in, but on the OLED-black background they poke past the circle as a
// visible grey "box". Clipping it to the circle is harmless in Light mode (the
// photo is circular either way), so this is applied while OLED is active and not
// reverted.
//
// Facebook builds avatars several different ways, but the box always comes from
// a square image that isn't being clipped to the avatar circle. Two shapes cover
// every case seen (feed headers, comments, video/AI posts):
//
//   A. A circular container (cornerRadius ~= half its square size) whose
//      masksToBounds is OFF, so the square image/placeholder inside bleeds out to
//      the corners. Turning masksToBounds on clips everything inside to the
//      circle. The online-status dot lives OUTSIDE this container, so it stays.
//   B. A container holding a *masked* MRCImageComponentView (the circular photo)
//      next to a bare, unmasked square UIImageView (a placeholder behind it).
//      Rounding that bare image to a circle removes its corners.
//
// Scoped to small, square-ish containers so rectangular post photos (which also
// use MRCImageComponentView) and larger media are never touched.
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

    // Case A: a circular container holding image content but not clipping it.
    CGFloat cr = container.layer.cornerRadius;
    CGFloat crDiff = cr > size.width / 2.0 ? cr - size.width / 2.0
                                           : size.width / 2.0 - cr;
    if (hasImageContent && crDiff < 3.0 && !container.layer.masksToBounds) {
        container.layer.masksToBounds = YES;
        container.clipsToBounds = YES;
    }

    // Case B: a masked avatar next to bare square placeholder image(s).
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

/// Blackens (active) or restores (inactive) the colours a view paints *directly
/// onto its own layer's sublayers* — the gradient/shape/plain CALayers ComponentKit
/// uses for rounded card backgrounds and Facebook uses for the header fade and
/// status-bar strip. Layers that merely back a subview are skipped: that subview
/// repaints itself. On active it flags the owning view touched so a later relayout
/// while OLED is off knows to visit it.
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

/// Opaque black appearance for the real UINavigationBar the header hosts
/// (_replacementNavigationBar). Its background is drawn through
/// UINavigationBarAppearance / _UIBarBackground (a blur), not -backgroundColor,
/// so the appearance objects must be reconfigured and the blur flattened. The
/// original appearance and the blur colours are saved first so FBPRestoreNavBar
/// (and the header restore walk) can put the live-appearance header back.
static void FBPBlackNavigationBar(UINavigationBar *bar) {
    if (!bar) return;
    FBPSaveNavBar(bar);
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
    // Flatten the _UIBarBackground blur that sits behind the bar's content.
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

/// Walks the header's sub-tree and blackens (active) or restores (inactive) every
/// grey surface — dark view backgrounds, dark layer/gradient/shape colours, the
/// hosted UINavigationBar and any blur — while leaving photos (nil/clear
/// backgrounds) and coloured accents untouched, so the profile cover and the blue
/// "Add to story" button keep their look. The restore pass runs regardless of the
/// per-view touched flag because the header itself is a single, long-lived view
/// whose children must be put back the moment OLED turns off.
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
                // A blur in the header reads as grey; cover it flat black.
                FBPSaveViewBG(sub, sub.backgroundColor);
                FBPSaveViewBG(content, content.backgroundColor);
                FBPMarkTouched(sub);
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
                }
                if (FBPCGColorIsDark(sub.layer.backgroundColor)) {
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

#pragma mark - Per-view apply

/// The body of UIView -layoutSubviews under OLED. Active: blacken this view's
/// background / layer / sublayers and (for avatars) clip the placeholder box.
/// Inactive: put back everything OLED saved, then drop the touched flag. Views
/// OLED never modified short-circuit immediately, so an off/Light relayout stays
/// cheap across the whole hierarchy.
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

    // Dividers are lightened, not blackened, so posts/rows stay visually separated.
    if (FBPViewLooksLikeDivider(view)) {
        FBPLightenDivider(view);
        return;
    }

    // Round the square placeholder stacked behind a circular profile avatar, so
    // its grey corners don't show as a box against the OLED-black background.
    // Trigger both when the avatar container lays out and, more reliably, when
    // the masked image component itself mounts (then fix its siblings).
    FBPFixAvatarBox(view);
    if ([NSStringFromClass(view.class) containsString:@"MRCImageComponent"] &&
        view.layer.masksToBounds) {
        FBPFixAvatarBox(view.superview);
    }

    UIColor *bg = view.backgroundColor;
    if (bg) {
        // Views that paint through -backgroundColor (dynamic colours resolved).
        if (FBPColorIsDark(FBPResolve(bg))) {
            FBPSaveViewBG(view, bg);
            FBPMarkTouched(view);
            view.backgroundColor = FBPBlackKeepingAlpha(bg);
        }
    } else if (FBPCGColorIsDark(view.layer.backgroundColor)) {
        // ComponentKit cards that paint straight onto their own layer.
        FBPSaveLayerBG(view.layer);
        FBPMarkTouched(view);
        view.layer.backgroundColor = FBPBlackCGKeepingAlpha(view.layer.backgroundColor);
    }

    // Cards / fades that paint onto a sublayer (gradient, shape or plain CALayer)
    // rather than the view or its own layer background — the profile panel and the
    // header fade. Cheap: most views have no sublayers.
    FBPApplySublayers(view.layer, YES);
}

/// The value to hand the original -setBackgroundColor:, saving/forgetting state so
/// OLED reverts cleanly. Active + dark → black (original stashed). Inactive → the
/// app's own colour passes through and any stash is dropped, so a later relayout
/// does not put the black-era colour back over a freshly repainted view.
static UIColor *FBPBGForSet(UIView *self, UIColor *color) {
    if (FBPOLEDActive() && !FBPOLEDSkip(self)) {
        if (FBPColorIsDark(FBPResolve(color))) {
            FBPSaveViewBG(self, color);
            FBPMarkTouched(self);
            return FBPBlackKeepingAlpha(color);
        }
        return color;
    }
    if (!FBPOLEDSkip(self) && objc_getAssociatedObject(self, kFBPSavedViewBG)) {
        FBPForgetViewBG(self);
    }
    return color;
}

#pragma mark - Hooks

%group FBPOLEDGlobal

%hook UIView

- (void)setBackgroundColor:(UIColor *)color {
    if (FBPOLEDActive() && !FBPOLEDSkip(self) &&
        [NSStringFromClass(self.class) containsString:@"LineComponent"]) {
        // A separator line keeps a faint white instead of vanishing into black.
        FBPSaveViewBG(self, color);
        FBPMarkTouched(self);
        %orig(FBPDividerColor());
        return;
    }
    UIColor *resolved = FBPBGForSet(self, color);
    %orig(resolved);
}

- (void)layoutSubviews {
    %orig;
    FBPApplyView(self, FBPOLEDActive());
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    %orig;
    if (@available(iOS 13.0, *)) {
        if (previous &&
            previous.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
            // iOS switched Light↔Dark: re-run the layout logic so OLED engages for
            // Dark and fully reverts for Light on this view.
            [self setNeedsLayout];
        }
    }
}

%end

%hook UITableView
- (void)setBackgroundColor:(UIColor *)color {
    UIColor *resolved = FBPBGForSet(self, color);
    %orig(resolved);
}
%end

%hook UITableViewCell
- (void)setBackgroundColor:(UIColor *)color {
    UIColor *resolved = FBPBGForSet(self, color);
    %orig(resolved);
}
%end

%hook UICollectionView
- (void)setBackgroundColor:(UIColor *)color {
    UIColor *resolved = FBPBGForSet(self, color);
    %orig(resolved);
}
%end

// The app header. It paints nothing on its own view; the grey lives on child
// views, a hosted UINavigationBar, a blur and gradients — so blacken the sub-tree
// on every layout pass while OLED is on, and restore it when OLED is off. This is
// what stops the header flickering between grey and black, and what makes the
// header follow iOS back to Light instead of staying black.
%hook FBMovableNavigationBarView
- (void)layoutSubviews {
    %orig;
    BOOL active = FBPOLEDActive();
    if (active) {
        if (FBPColorIsDark(FBPResolve(self.backgroundColor))) {
            FBPSaveViewBG(self, self.backgroundColor);
            self.backgroundColor = FBPBlackKeepingAlpha(self.backgroundColor);
        }
        if (FBPCGColorIsDark(self.layer.backgroundColor)) {
            FBPSaveLayerBG(self.layer);
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

// The navigation-bar view controller drives the status bar, and it returns
// darkContent (black time / battery / signal) because Facebook's header is
// normally light. OLED paints that header black, so black status-bar glyphs
// vanish. Force light content (white glyphs) while OLED is on.
%hook FBMovableNavigationBarViewController
- (UIStatusBarStyle)preferredStatusBarStyle {
    if (FBPOLEDActive()) return UIStatusBarStyleLightContent;
    return %orig;
}
%end

%end // FBPOLEDGlobal

/// Marks the whole FB window tree for relayout so the layout hooks re-run and
/// blacken/revert for the current state right away — used when the toggle changes
/// (no trait change fires then) and on returning from the background.
static void FBPNudgeLayout(UIView *view, int depth) {
    if (!view || depth > 40) return;
    [view setNeedsLayout];
    for (UIView *sub in [view.subviews copy]) FBPNudgeLayout(sub, depth + 1);
}

static void FBPNudgeOLEDRelayout(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if ([NSStringFromClass(window.class) hasPrefix:@"FBP"]) continue;
            FBPNudgeLayout(window, 0);
        }
    }
}

void FBPInitOLEDHooks(void) {
    FBPRefreshOLED();

    // Keep the cached toggle in sync when settings change, then nudge a relayout
    // so turning OLED on/off takes effect promptly. OLED no longer forces any
    // appearance; it follows the iOS Light/Dark setting (FBPOLEDActive).
    [NSNotificationCenter.defaultCenter
        addObserverForName:FBPSettingsDidChangeNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) {
        FBPRefreshOLED();
        FBPNudgeOLEDRelayout();
    }];

    // A live iOS Light↔Dark switch is handled per-view by the traitCollectionDidChange
    // hook. Returning from the background is the one case that can miss, so re-apply
    // for the current system appearance on foreground.
    [NSNotificationCenter.defaultCenter
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) { FBPNudgeOLEDRelayout(); }];

    FBP_ONCE(gOLED) { %init(FBPOLEDGlobal); }
}
