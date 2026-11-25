// OLED Dark Mode: deepen Facebook's dark theme to true-black.
//
// An enhancement of dark mode, not a light→dark forcer. OLED follows the iOS
// system appearance: while the toggle is on it engages when iOS is in Dark Mode
// and disengages in Light Mode. In light mode it is inert and leaves every
// surface alone. The gate is FBPOLEDActiveFor(view): the toggle AND the
// appearance that view is actually drawn with. The per-colour darkness tests
// still run, so even in Dark Mode only genuinely dark surfaces are blackened.
//
// "The iOS system appearance" is a narrower thing than it sounds, and getting it
// from the wrong place is what kept issue #10 open. It is not any window's
// appearance and not the screen's: it is the window *scene's*, the one trait
// environment Facebook's own Dark Mode setting cannot override. See
// FBPSystemStyleFromScenes for the measurements.
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
// won't turn off". On a live Light↔Dark switch FBPTrackWindowStyle re-runs the
// layout logic over every mounted view itself rather than waiting for each one to
// lay out again, and a relayout nudge does the same when the toggle changes.
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

/// Whether the faint post separators stay visible in OLED mode. On (default) the
/// hairlines are kept so cards stay visually separated on black; off blacks them
/// out too, for a seamless all-black feed. Only meaningful while OLED is active.
static BOOL gOLEDDividers = YES;

static void FBPRefreshOLED(void) {
    gOLEDEnabled = FBPEnabled(FBPKeyOLED);
    gOLEDDividers = FBPEnabled(FBPKeyOLEDDividers);
}

/// One of Facebook's own windows — never one of ours — preferring the key one.
///
/// Ours follow iOS; Facebook's carry whatever theme Facebook has chosen, which
/// is the appearance OLED has to agree with.
static UIWindow *FBPAppKeyWindow(void) {
    UIWindow *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if ([NSStringFromClass(window.class) hasPrefix:@"FBP"]) continue;
            if (window.isKeyWindow) return window;
            if (!fallback) fallback = window;
        }
    }
    return fallback;
}

/// The iOS system appearance, read from a window *scene*.
///
/// This is the whole of issue #10. A window's traitCollection.userInterfaceStyle
/// is the *effective* style, which is to say the style after any
/// overrideUserInterfaceStyle the app has set on it. Facebook has its own in-app
/// Dark Mode setting (System / On / Off), and for On or Off it pins
/// overrideUserInterfaceStyle on its windows — so such a window answers with
/// Facebook's forced theme however iOS is set, and never changes its answer when
/// iOS does. Reading the style from a window therefore cached Facebook's theme as
/// if it were the system's: with Facebook on "Dark: On" the cache sat on Dark
/// forever, FBPOLEDActive kept saying YES after iOS went to Light, and the app
/// stayed black. Measured on the SE (iOS 18.6.1) with the window pinned the way
/// Facebook pins it: system Light, scene=light, window override=dark,
/// window effective=dark.
///
/// Worse than merely wrong, it flip-flopped. The app has several windows at once
/// and only some carry an override — the text-effects and keyboard windows, the
/// style-transition snapshot window and our own toast window follow the system —
/// so whichever window laid out last decided the answer. A user's log shows the
/// two answers arriving within the same second, which is the reported "some areas
/// light, others pure black".
///
/// A UIWindowScene is the one trait environment in the process the app cannot
/// override: overrideUserInterfaceStyle lives on UIView and UIViewController, not
/// on a scene, so a scene's trait collection is the unmodified system appearance.
/// Verified on device across a live Control-Centre flip in both directions while a
/// window was pinned Dark: the scene reported light then dark then light, tracking
/// iOS, while the pinned window stayed dark throughout.
///
/// Also NOT UIScreen.mainScreen.traitCollection: on an iPhone 17 Pro Max that
/// reports a stale "dark" after the system switches to Light (a captured log has
/// `screen=dark` on every line, including lines where everything else says light).
static UIUserInterfaceStyle FBPSystemStyleFromScenes(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            // UITraitEnvironment is declared on UIWindowScene, not on UIScene.
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            UIUserInterfaceStyle style =
                windowScene.traitCollection.userInterfaceStyle;
            if (style != UIUserInterfaceStyleUnspecified) return style;
        }
    }
    return UIUserInterfaceStyleUnspecified;
}

/// The live system appearance, cached so the hot path (every
/// setBackgroundColor:/layoutSubviews) never walks the scene list.
static UIUserInterfaceStyle gFBPSystemStyle = UIUserInterfaceStyleUnspecified;

static void FBPUpdateSystemStyle(UIUserInterfaceStyle style) {
    if (@available(iOS 13.0, *)) {
        if (style != UIUserInterfaceStyleUnspecified) gFBPSystemStyle = style;
    }
}

/// YES when iOS itself is in Dark Mode, whatever theme Facebook has forced on its
/// own windows. Reads the cache, falling back to a live scene until the first
/// layout pass seeds it.
static BOOL FBPSystemIsDark(void) {
    if (@available(iOS 13.0, *)) {
        if (gFBPSystemStyle != UIUserInterfaceStyleUnspecified) {
            return gFBPSystemStyle == UIUserInterfaceStyleDark;
        }
        // Nothing has laid out yet. The scene is the best guess available, and
        // it is right whenever Facebook has not pinned a theme of its own.
        return FBPSystemStyleFromScenes() == UIUserInterfaceStyleDark;
    }
    return NO;
}

/// OLED follows the iOS system appearance: engaged only when the toggle is on AND
/// iOS is in Dark Mode, disengaged the moment iOS switches to Light. Keying on the
/// system appearance (not one view's trait) is what makes "iOS Light → OLED off,
/// iOS Dark → OLED on" hold. The downstream FBPColorIsDark checks still mean only
/// genuinely dark surfaces are blackened.
/// Is OLED engaged right now?
///
/// ONE ANSWER FOR THE WHOLE APP, NOT ONE PER VIEW.
///
/// This took the view's own trait collection for a while, on the theory that
/// the appearance a view is drawn with is the most honest thing to ask. The
/// device disproved it: a minute after a switch to Light the sweep still read
/// `listed=39 left=39`, meaning all thirty-nine painted views were still
/// answering Dark while the header and tab bar around them were plainly Light.
/// Views detached from a window keep their last traits, and Facebook's
/// hierarchy is not of one mind during a switch. Asking each view therefore
/// produces exactly the half-light, half-black screen this feature keeps being
/// reported for.
///
/// Both tweaks that have this feature working avoid the question entirely.
/// iQFace gates every hook on a single cached byte. Nexus gates on the colour
/// Facebook is handing it, and consults a trait collection only once, as a
/// tie-break, before latching. Neither asks a view what appearance it is in.
///
/// So this is one decision for the process: the toggle, and whether iOS is in
/// Dark. A single answer cannot disagree with itself, which is what makes the
/// mixed state impossible rather than merely unlikely. The per-view judgement
/// that remains is a different question and still worth asking — whether *this*
/// surface is drawn light, so a light-locked card inside a dark app keeps its
/// own colour — and that lives in FBPApplyView, not here.
static BOOL FBPOLEDActiveFor(__unused UIView *view) {
    return gOLEDEnabled && FBPSystemIsDark();
}

static BOOL FBPOLEDActive(void) {
    return gOLEDEnabled && FBPSystemIsDark();
}

/// Defined below, beside the relayout it drives: a window's layout pass is
/// where a Light<->Dark switch is noticed.
static void FBPTrackWindowStyle(UIWindow *window);

#pragma mark - Diagnostics

/// Human name for an interface style, for the diagnostic log.
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

/// One diagnostic line describing exactly what OLED sees at a given moment — the
/// toggle, the *scene* appearance (our detection source), the screen's and the
/// current environment's answers, the key window's own effective appearance, any
/// forced window override, and the two derived gates.
///
/// `scene` against `keyWin`/`override` is the pair that matters: when they
/// disagree, Facebook is forcing a theme, and only `scene` is iOS. A log where
/// `scene` and `systemDark` ever contradict each other would mean the cache is
/// being seeded from somewhere it should not be.
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
                if ([NSStringFromClass(window.class) hasPrefix:@"FBP"]) continue;
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

/// YES when this view is actually being shown in LIGHT appearance, whatever the
/// app window is doing. Facebook renders some cards with their own
/// overrideUserInterfaceStyle = Light (a link/preview card, a light-locked unit):
/// a light background with dark text. OLED resolves every background against a
/// forced-dark trait collection, so such a card's *dark-mode* colour is judged
/// dark and the real (light) background gets blackened — leaving the dark text
/// stranded on black, which is the "some posts turn black on re-entry" report.
/// OLED is meant to be inert in light appearance, so a view shown light is left
/// entirely alone (keeping its light background and its readable dark text).
static BOOL FBPViewIsLight(UIView *view) {
    if (@available(iOS 13.0, *)) {
        return view.traitCollection.userInterfaceStyle == UIUserInterfaceStyleLight;
    }
    return NO;
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

/// Black while the appearance is Dark, and @c original again the moment it is
/// not.
///
/// This is the difference between a surface that comes back and one that does
/// not. Facebook hands its views a dynamic colour, which resolves itself per
/// appearance; writing a flat black over it threw that away, and when iOS went
/// back to Light the view had nothing left to resolve. Facebook does not repaint
/// a container it believes is unchanged, so the black stayed, and on a device
/// where UIKit no longer calls -traitCollectionDidChange: nothing else put it
/// right either. That is issue #10: part of the app light, part still black.
///
/// A dynamic colour needs no bookkeeping, no restore pass and no notification.
/// It is the same object before and after the switch; only its answer changes.
/// @c original is captured as given, so a colour Facebook had already resolved
/// to a flat value still comes back as that value rather than as black.
///
/// The gate here is the toggle and the traits handed to the provider — nothing
/// cached. The traits are the view's own, resolved by UIKit at the moment it
/// draws, so this colour answers black exactly while that view is being drawn
/// dark and answers the app's own colour the instant it is not. That is what
/// makes a switch need no detecting: the colour has already changed its mind
/// before anything of ours has run.
static UIColor *FBPBlackFollowingAppearance(UIColor *original) {
    if (@available(iOS 13.0, *)) {
        return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            if (!gOLEDEnabled || traits.userInterfaceStyle != UIUserInterfaceStyleDark) {
                return original ?: UIColor.clearColor;
            }
            UIColor *resolved = original;
            @try {
                resolved = [original resolvedColorWithTraitCollection:traits] ?: original;
            } @catch (__unused NSException *e) {}
            // Only a genuinely dark surface is blackened, the same test the
            // caller made: a light-locked card keeps its own colour.
            return FBPColorIsDark(resolved) ? FBPBlackKeepingAlpha(resolved) : resolved;
        }];
    }
    return FBPBlackKeepingAlpha(original);
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

/// Every view OLED has painted, held weakly.
///
/// THE REVERT DOES NOT SEARCH FOR THEM ANY MORE.
///
/// It used to: a switch to Light walked down from each window and called
/// FBPApplyView on everything it met, and a view it did not meet kept its black.
/// Views go missing from that walk for reasons the walk cannot do anything about
/// — a card that is not mounted at the moment of the flip, a cell recycled
/// afterwards, anything the app rebuilds while the appearance is changing — and a
/// view painted through its *layer* cannot recover on its own either, because a
/// CGColor is flat and has no idea the appearance moved. Those are the surfaces
/// that stayed #000000 in Light while the header and tab bar came back.
///
/// So each painted view is put on this list as it is painted, and the revert
/// walks the list instead. Nothing has to be found, nothing has to be on screen,
/// and the depth of the hierarchy stops mattering. The table holds its views
/// weakly, so a view that goes away takes its entry with it.
///
/// It is small by construction: only views OLED actually darkened are on it, and
/// each one comes off again when it is restored.
static NSHashTable<UIView *> *FBPTouchedViews(void) {
    static NSHashTable<UIView *> *views;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ views = [NSHashTable weakObjectsHashTable]; });
    return views;
}

static void FBPMarkTouched(UIView *view) {
    objc_setAssociatedObject(view, kFBPTouched, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSHashTable<UIView *> *touched = FBPTouchedViews();
    // Painting is rare next to laying out, so the lock is never on a hot path.
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

/// What to paint a separator in OLED mode: the faint white when the "Show post
/// dividers" toggle is on (cards stay separated), or solid black when it is off
/// (the hairlines disappear into a seamless all-black feed). Either way the
/// original is saved first, so turning OLED off restores Facebook's own line.
static UIColor *FBPDividerPaint(void) {
    return gOLEDDividers ? FBPDividerColor() : UIColor.blackColor;
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

    // A surface shown in LIGHT appearance (a light-locked card: light background,
    // dark text) is left alone — blackening its background would strand the dark
    // text on black. If it was darkened before it became light, put it back.
    if (FBPViewIsLight(view)) {
        if (FBPWasTouched(view)) {
            FBPRestoreViewBG(view);
            FBPRestoreLayerBG(view.layer);
            FBPApplySublayers(view.layer, NO);
            FBPClearTouched(view);
        }
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
            view.backgroundColor = FBPBlackFollowingAppearance(bg);
        }
    } else if (FBPCGColorIsDark(view.layer.backgroundColor)) {
        // ComponentKit cards that paint straight onto their own layer.
        //
        // Written as a DYNAMIC colour through the view, not as a flat CGColor on
        // the layer. -[UIView backgroundColor] *is* the layer's background, so
        // this reaches exactly the same pixels; the difference is that a CGColor
        // has no idea an appearance exists and can never answer differently,
        // while this colour is re-resolved by UIKit the moment the view is drawn
        // in the other appearance.
        //
        // That difference was the whole of the remaining bug. Probed on device
        // after a switch to Light, the composer row answered
        // `style=1  bg=UIExtendedGrayColorSpace 0 1` — a view being drawn Light
        // holding flat opaque black, with no way back. The restore bookkeeping
        // could not save it either: those views came back as `stray` in the
        // sweep, painted black with nothing recorded against them. Making the
        // colour dynamic removes the need for any of that: there is nothing to
        // notice, nothing to remember and nothing to put back.
        UIColor *original = [UIColor colorWithCGColor:view.layer.backgroundColor];
        FBPSaveViewBG(view, original);
        FBPMarkTouched(view);
        view.backgroundColor = FBPBlackFollowingAppearance(original);
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
    if (FBPOLEDActiveFor(self) && !FBPOLEDSkip(self)) {
        if (FBPColorIsDark(FBPResolve(color))) {
            // Still saved and flagged, because the layer and sublayer paths
            // below have no dynamic equivalent and the restore pass walks both.
            FBPSaveViewBG(self, color);
            FBPMarkTouched(self);
            return FBPBlackFollowingAppearance(color);
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
    FBPTraceFire("oled.UIView.setBackgroundColor");
    if (FBPOLEDActiveFor(self) && !FBPOLEDSkip(self) &&
        [NSStringFromClass(self.class) containsString:@"LineComponent"]) {
        // A separator line keeps a faint white (toggle on) or is blacked out
        // (toggle off) instead of taking Facebook's own colour.
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
            // A window-level style flip is a hint that the system appearance may
            // have moved, so re-read it from the window's scene and reapply. Not
            // from the window itself: that is Facebook's theme (see
            // FBPSystemStyleFromScenes). This path is a bonus rather than the
            // mechanism — when Facebook pins its windows the window's own style
            // never changes and this never fires, which is why the window layout
            // pass carries the same check.
            if ([self isKindOfClass:UIWindow.class]) {
                FBPTrackWindowStyle((UIWindow *)self);
            }
            // Re-run the layout logic so OLED engages for Dark and fully reverts
            // for Light on this view.
            [self setNeedsLayout];
        }
    }
}

%end

// UIWindow overrides -layoutSubviews, so the UIView hook above never runs for
// one: this is the only place a window's own layout is seen. Every pass after
// a change costs one integer comparison.
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

// The app header. It paints nothing on its own view; the grey lives on child
// views, a hosted UINavigationBar, a blur and gradients — so blacken the sub-tree
// on every layout pass while OLED is on, and restore it when OLED is off. This is
// what stops the header flickering between grey and black, and what makes the
// header follow iOS back to Light instead of staying black.
%hook FBMovableNavigationBarView
- (void)layoutSubviews {
    %orig;
    FBPTraceFire("oled.FBMovableNavigationBarView.layoutSubviews");
    BOOL active = FBPOLEDActiveFor(self);
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
    FBPTraceFire("oled.FBMovableNavigationBarViewController.preferredStatusBarStyle");
    // No view of its own to ask, so the app's own window answers.
    if (FBPOLEDActiveFor(FBPAppKeyWindow())) return UIStatusBarStyleLightContent;
    return %orig;
}
%end

%end // FBPOLEDGlobal

/// How deep the reapply and nudge walks go. Headroom, nothing more.
///
/// It was 40, and raising it was once written up here as the fix for half the app
/// staying black. That was wrong and the measurement that disproved it is worth
/// keeping: instrumented on the SE, the whole of Facebook's window tree came to
/// **77 views at maximum depth 27**, and the walk reported `deepest=33 capped=0`.
/// The old cap was never reached, so it cannot have been what stopped the revert.
///
/// The number stays well past anything real only so a hierarchy that is somehow
/// cyclic cannot run away with the stack. What actually makes the revert complete
/// is FBPTouchedViews below, which does not depend on a walk finding anything.
static const int kFBPWalkMaxDepth = 200;

/// What a walk had to do, for the diagnostic line: how many views it visited, the
/// deepest it went, whether the cap stopped it short (which would mean the revert
/// is incomplete again), how many views it actually put back, and how many it left
/// sitting on pure black without OLED having a record of touching them.
///
/// That last count is the one that matters on a revert. OLED only restores a view
/// it flagged, so a view painted black without being flagged is invisible to the
/// revert and stays black forever. `stray` being anything but 0 after a switch to
/// Light says exactly that is happening.
typedef struct {
    int visited;
    int deepest;
    BOOL capped;
    int restored;
    int stray;
} FBPWalkStats;

/// YES when this view is painted a flat, opaque-ish pure black right now, as the
/// screen would draw it. Deliberately narrower than FBPColorIsDark, which also
/// matches Facebook's own near-black base grey (#18191A): the question here is
/// "is this one of ours that never came back", not "is this dark".
static BOOL FBPSurfaceIsPureBlack(UIView *view) {
    UIColor *color = view.backgroundColor;
    CGColorRef cg = color ? color.CGColor : view.layer.backgroundColor;
    if (!cg) return NO;
    if (@available(iOS 13.0, *)) {
        if (color && view.traitCollection) {
            @try {
                UIColor *shown = [color resolvedColorWithTraitCollection:view.traitCollection];
                if (shown) cg = shown.CGColor;
            } @catch (__unused NSException *e) {}
        }
    }
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

/// Re-applies the current appearance to a whole view tree.
///
/// FBPApplyView is normally reached from each view's own -layoutSubviews, which
/// covers everything that is about to be drawn. It does not cover a view that
/// is mounted and settled, and after a Light<->Dark switch those are exactly
/// the ones holding the wrong colour.
static void FBPApplyTree(UIView *view, int depth, FBPWalkStats *stats) {
    if (!view) return;
    if (depth > kFBPWalkMaxDepth) { stats->capped = YES; return; }
    stats->visited++;
    if (depth > stats->deepest) stats->deepest = depth;

    // Per view, for the same reason the paint paths are: a subtree pinned to
    // the other appearance sits inside the same window as everything else, and
    // one flag for the whole walk would get it wrong.
    BOOL active = FBPOLEDActiveFor(view);
    BOOL wasTouched = FBPWasTouched(view);
    FBPApplyView(view, active);
    if (!active && !FBPOLEDSkip(view)) {
        if (wasTouched) stats->restored++;
        else if (FBPSurfaceIsPureBlack(view)) stats->stray++;
    }
    for (UIView *sub in [view.subviews copy]) {
        FBPApplyTree(sub, depth + 1, stats);
    }
}

/// Marks a whole view tree for relayout so the layout hooks re-run and
/// blacken/revert for the current state right away — used when the toggle changes
/// (no trait change fires then) and on returning from the background.
static void FBPNudgeLayout(UIView *view, int depth) {
    if (!view || depth > kFBPWalkMaxDepth) return;
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

/// Brings every surface OLED cares about into line with the appearance it is
/// being drawn in right now.
///
/// Idempotent by construction: each view is asked what appearance it is drawn
/// with and is painted or restored to match, so running it twice costs a few
/// hundred cheap questions and changes nothing the first run already settled.
///
/// Two populations, because neither covers the other. The register holds every
/// view OLED has painted, mounted or not, which is what makes a revert complete
/// — a card that is no longer in any window will never lay out again and can
/// only be reached from a list. The tree walk covers the other direction, where
/// the register is empty and the surfaces about to be blackened have to be
/// found.
static void FBPSweepAppearance(void) {
    NSHashTable<UIView *> *table = FBPTouchedViews();
    NSArray<UIView *> *painted;
    // A snapshot: FBPApplyView takes a restored view off the list as it goes,
    // which would mutate the table underneath the enumeration.
    @synchronized (table) { painted = table.allObjects; }
    NSUInteger listed = painted.count;
    for (UIView *view in painted) FBPApplyView(view, FBPOLEDActiveFor(view));

    FBPWalkStats stats = (FBPWalkStats){0, 0, NO, 0, 0};
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *each in ((UIWindowScene *)scene).windows) {
            if ([NSStringFromClass(each.class) hasPrefix:@"FBP"]) continue;
            FBPApplyTree(each, 0, &stats);
        }
    }
    FBPNudgeOLEDRelayout();

    NSUInteger remaining;
    @synchronized (table) { remaining = table.count; }
    // `listed` against `left`: after a switch to Light everything OLED painted
    // should have come back, so `left` should be 0. `stray` counts pure-black
    // views OLED never painted, which no revert of ours can reach.
    if (listed || remaining || stats.stray) {
        FBPDiag(@"oled",
                @"sweep listed=%lu left=%lu views=%d deepest=%d capped=%d "
                @"restored=%d stray=%d",
                (unsigned long)listed, (unsigned long)remaining,
                stats.visited, stats.deepest, stats.capped,
                stats.restored, stats.stray);
    }
}

/// Runs the sweep on a slow repeat, for the whole life of the process.
///
/// THIS IS WHY IT NO LONGER MATTERS WHETHER WE NOTICE THE SWITCH.
///
/// Every attempt to catch the moment of an appearance change failed in its own
/// way, and the device said so each time: -traitCollectionDidChange: is never
/// called on iOS 18, a window's own style is whatever Facebook pinned it to, and
/// a sweep run from the window's layout pass asks views a question UIKit has not
/// finished answering — the log read `listed=34 left=34` after a switch to
/// Light, every painted view still insisting it was Dark, while a hit test
/// through the same views twenty seconds later said Light on all of them.
///
/// Reversing Nexus, which has this feature and does not have this bug, settled
/// it: that tweak observes no appearance change at all. It runs its pass on a
/// repeating 0.75 second timer in NSRunLoopCommonModes and re-decides from
/// scratch every time. Being right about *when* stops being a requirement if
/// you are simply right again shortly afterwards. The worst staleness is under a
/// second, which reads as instant, and the cost is a tree walk over a few
/// hundred views that does nothing when nothing has changed.
///
/// Common modes on purpose: a timer in the default mode stops while the user
/// drags or scrolls, which is exactly when Facebook is mounting new cards.
static void FBPStartAppearanceSweep(void) {
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.75 repeats:YES
                                              block:^(__unused NSTimer *t) {
        FBPSweepAppearance();
    }];
    timer.tolerance = 0.15;
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}

/// Catches a Light<->Dark switch from a window's layout pass.
///
/// -traitCollectionDidChange: cannot be relied on to carry this: iOS 17
/// deprecated it, on some builds UIKit never calls it at all, and even where it
/// does fire it fires on the window's *effective* style, which does not move when
/// Facebook has pinned the window. The scene's own -traitCollectionDidChange:
/// looked like the obvious answer and is dead: an interceptor on it counted zero
/// calls across two live appearance flips on the SE, while -[UIWindow
/// layoutSubviews] was entered four times on each.
///
/// So the window layout pass is the trigger and the scene is the source. A window
/// lays out when the appearance changes even if its own style was pinned (that is
/// what those four calls are), so comparing the scene's style on the way through
/// costs one integer read and needs no registration, no deprecated callback and
/// nothing version-specific.
static void FBPTrackWindowStyle(UIWindow *window) {
    if (@available(iOS 13.0, *)) {
        if (!window) return;

        // THE SCENE, BECAUSE THE WINDOW IS NOW OURS.
        //
        // A window's own style is the effective one, after any override — and
        // while OLED is engaged that override is one WE set (see
        // FBPPinAppearance). Asking the window would therefore mean asking our
        // own answer back, and the system could go Light without us ever
        // hearing about it. A UIWindowScene carries no override: it is the iOS
        // setting, full stop.
        //
        // Our own windows still do not get to speak. They follow iOS directly
        // and would answer for the system while Facebook's windows are pinned,
        // which is a different question.
        if ([NSStringFromClass(window.class) hasPrefix:@"FBP"]) return;
        UIUserInterfaceStyle style = FBPSystemStyleFromScenes();
        if (style == UIUserInterfaceStyleUnspecified || style == gFBPSystemStyle) return;

        FBPUpdateSystemStyle(style);
        FBPOLEDLogState("window-style-changed");

        FBPSweepAppearance();
    }
}

void FBPInitOLEDHooks(void) {
    FBPRefreshOLED();

    // Everything below registers process-wide state exactly once. FBPInitOLEDHooks
    // is re-run on every dyld image load (see FBPEntry.xm), so without this latch the
    // notification observers would be added again for each image — a became-active
    // would then fire the block dozens of times and storm the log and the relayout.
    FBP_ONCE(gOLED) {
        // Keep the cached toggle in sync when settings change, then nudge a relayout
        // so turning OLED on/off takes effect promptly. OLED no longer forces any
        // appearance; it follows the iOS Light/Dark setting (FBPOLEDActive).
        [NSNotificationCenter.defaultCenter
            addObserverForName:FBPSettingsDidChangeNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
            FBPRefreshOLED();
            FBPOLEDLogState("settings-changed");
            FBPNudgeOLEDRelayout();
        }];

        // A live iOS Light↔Dark switch is caught by the window layout pass
        // (FBPTrackWindowStyle). Returning from the background is the one case
        // that can miss, so re-apply for the current appearance on foreground.
        [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
            // Re-seed the cached style in case the appearance changed while the app
            // was backgrounded (no trait change fires then).
            if (@available(iOS 13.0, *)) {
                // The app's own appearance, for the same reason as
                // FBPTrackWindowStyle; the scene only stands in if there is no
                // window of Facebook's to ask yet.
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
}
