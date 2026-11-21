// Left side menu ("bookmarks"): hides the rows the user has switched off, and
// adds the tweak's own "Facebook Plus" row above log out.
//
// Facebook ships the menu in two renderings and a launch gets one or the other:
//
//   Bloks   FBBookmarksPanelNavigationController -> FBBloksScreenQueryViewController
//           -> BKBloksHostingView -> BKCollectionView / BKCollectionViewLayout,
//           rows are BKBloksCollectionCell_SyncUpdates.
//   CK      FBBookmarksViewController -> a ComponentKit surface whose list is a
//           plain UICollectionView on FBBookmarksMasonryGridCollectionViewLayout,
//           rows are FBComponentHostingCollectionViewCell.
//
// The tweak's own row is added to both. Hiding a row is done in the CK menu
// only: a hidden row is taken out of the layout, along with the hairline drawn
// at its top, and everything below it moves up. A row there is identified by
// its model rather than by its cell, because FBBookmarkDropdownButtonModel.identifier
// names each section in a string Facebook does not translate while a reused
// cell can still carry the previous row's content. See FBPBookmarksModelChain
// in FBPHeaders.h.
//
// The Bloks menu carries no such identifier, and the only per-row signal there
// was the accessibility label of the cell's Bloks content, which meant matching
// the English words "Upgrades" and "Also from Meta" and missing both in every
// other language. That is gone: the hide switches act on the CK menu and leave
// the Bloks one as Facebook draws it.
//
// Neither list's model is touched. The tweak's row is a plain UIControl added as
// a subview of the list, and the space for it is opened in the layout: it
// reports a content size one row taller and pushes everything from the log-out
// row down, so the collection view places Facebook's own cells around it.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPHeaders.h"
#import "FBPTrace.h"
#import "FBPResources.h"
#import "FBPSettingsController.h"

#import <objc/runtime.h>

#pragma mark - Facebook Plus row

// A menu row is a 1pt rule and a 24x24 glyph with the label beside it. Its
// height and leading inset differ between the two menus (60pt / 12pt in the
// ComponentKit one, 57pt / 16pt in Bloks), so both are measured off a row
// Facebook draws beside the tweak's; the constants here are the fallbacks for a
// menu that has not laid out yet. The glyph-to-label gap is 12pt in both.
static const CGFloat kFBPSidebarRule = 1.0;
static const CGFloat kFBPSidebarGlyph = 24.0;
static const CGFloat kFBPSidebarGlyphGap = 12.0;
static const CGFloat kFBPSidebarDefaultInset = 16.0;
static const CGFloat kFBPSidebarDefaultHeight = 57.0;

/// The tweak's row in the left menu, just above log out. Opens Facebook Plus
/// settings, and is always present.
///
/// Named with the FBP prefix on purpose: the OLED sweep and the font replacement
/// both skip FBP-prefixed views, so the row keeps the colours set here while the
/// rest of the menu is repainted.
@interface FBPSidebarEntryRow : UIControl
/// Where Facebook starts its own rows' glyphs, measured off a row beside it.
@property (nonatomic) CGFloat leadingInset;
@property (nonatomic) BOOL insetMeasured;
/// A move the row has made but not yet animated: see FBPSidebarMoveEntry.
@property (nonatomic) BOOL moveWaiting;
@property (nonatomic) CGPoint movedFrom;
@property (nonatomic) CGRect movedTo;
@end

@implementation FBPSidebarEntryRow {
    UIView *_rule;
    UIView *_bottomRule;
    UIImageView *_glyph;
    UILabel *_label;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    _leadingInset = kFBPSidebarDefaultInset;
    self.backgroundColor = UIColor.clearColor;
    // "Facebook Plus" is the product's name, so it reads the same in every
    // language and is not run through the string catalog.
    self.accessibilityLabel = @"Facebook Plus";
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.isAccessibilityElement = YES;

    _rule = [[UIView alloc] initWithFrame:CGRectZero];
    _rule.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.22];
    [self addSubview:_rule];

    // Facebook's own rows are each separated by a rule at their top, and the
    // log-out button below has none of its own, so the row draws the one that
    // closes it off.
    _bottomRule = [[UIView alloc] initWithFrame:CGRectZero];
    _bottomRule.backgroundColor = _rule.backgroundColor;
    [self addSubview:_bottomRule];

    _glyph = [[UIImageView alloc] initWithFrame:CGRectZero];
    _glyph.contentMode = UIViewContentModeScaleAspectFit;
    // The logo is a colour mark, so keep it original — fbp_imageNamed: would
    // render it as a flat template silhouette.
    _glyph.image = [[UIImage imageNamed:@"logo"
                              inBundle:NSBundle.fbp_resourceBundle
         compatibleWithTraitCollection:nil]
                       imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    _glyph.layer.cornerRadius = kFBPSidebarGlyph / 2.0;
    _glyph.layer.masksToBounds = YES;
    [self addSubview:_glyph];

    _label = [[UILabel alloc] initWithFrame:CGRectZero];
    _label.text = @"Facebook Plus";
    _label.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    // Facebook's own primary label colour: #050505 light, #E4E6EB dark. Set as a
    // dynamic colour so the row follows the app's theme, light or dark.
    _label.textColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithRed:0.894 green:0.902 blue:0.922 alpha:1.0]
            : [UIColor colorWithRed:0.020 green:0.020 blue:0.020 alpha:1.0];
    }];
    [self addSubview:_label];

    [self addTarget:self
             action:@selector(fbp_openSettings)
   forControlEvents:UIControlEventTouchUpInside];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width;
    CGFloat height = self.bounds.size.height;
    // Rules on the row's own edges and the contents centred between them, so the
    // row reads at the weight of its neighbours whatever height it is given.
    CGFloat inset = _leadingInset > 0.0 ? _leadingInset : kFBPSidebarDefaultInset;
    CGFloat labelX = inset + kFBPSidebarGlyph + kFBPSidebarGlyphGap;
    _rule.frame = CGRectMake(0, 0, width, kFBPSidebarRule);
    _bottomRule.frame = CGRectMake(0, height - kFBPSidebarRule, width, kFBPSidebarRule);
    _glyph.frame = CGRectMake(inset, (height - kFBPSidebarGlyph) / 2.0,
                              kFBPSidebarGlyph, kFBPSidebarGlyph);
    _label.frame = CGRectMake(labelX, 0, MAX(0.0, width - labelX - inset), height);
}

- (void)setLeadingInset:(CGFloat)leadingInset {
    if (fabs(_leadingInset - leadingInset) < 0.5) return;
    _leadingInset = leadingInset;
    [self setNeedsLayout];
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.backgroundColor = highlighted ? [UIColor colorWithWhite:0.5 alpha:0.18]
                                       : UIColor.clearColor;
}

- (void)fbp_openSettings {
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleLight];
    [feedback impactOccurred];
    FBPTraceLine(@"sidebar row opened settings");
    [FBPSettingsController presentFromViewController:self._viewControllerForAncestor];
}

@end

#pragma mark - Row injection

static const void *kFBPSidebarIsMenuKey = &kFBPSidebarIsMenuKey;

/// YES when @c list is the menu's own list rather than one of the many other
/// collections in the app.
///
/// Read from the live hierarchy rather than from a class name, because the two
/// menu renderings nest differently: walking out of the list reaches either
/// @c FBBookmarksPanelNavigationController (the Bloks panel — the
/// identically-classed container in the main app answers
/// @c FBNewNavigationController instead) or @c FBBookmarksViewController (the
/// ComponentKit surface). The menu's list is also the outer collection: the
/// horizontal shortcuts strip inside it has a collection view ancestor, and is
/// rejected by that test.
static BOOL FBPSidebarListIsMenu(UIView *list) {
    UIView *view = list.superview;
    NSInteger hops = 0;
    while (view && hops < 30) {
        if ([view isKindOfClass:UICollectionView.class]) return NO;
        NSString *owner = NSStringFromClass(view.nextResponder.class);
        if ([owner isEqualToString:@"FBBookmarksPanelNavigationController"] ||
            [owner isEqualToString:@"FBBookmarksViewController"]) {
            return YES;
        }
        view = view.superview;
        hops += 1;
    }
    return NO;
}

/// Cached answer for @c FBPSidebarListIsMenu, so the walk runs once per view
/// instead of on every layout pass. Nothing is cached before the view reaches a
/// window, because the chain it reads is not in place yet.
static BOOL FBPSidebarIsMenuList(UIView *list) {
    NSNumber *cached = objc_getAssociatedObject(list, kFBPSidebarIsMenuKey);
    if (cached) return cached.boolValue;
    if (!list.window) return NO;
    BOOL isMenu = FBPSidebarListIsMenu(list);
    objc_setAssociatedObject(list, kFBPSidebarIsMenuKey, @(isMenu),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return isMenu;
}

static FBPSidebarEntryRow *FBPSidebarExistingRow(UIScrollView *list) {
    for (UIView *sub in list.subviews) {
        if ([sub isKindOfClass:FBPSidebarEntryRow.class]) return (FBPSidebarEntryRow *)sub;
    }
    return nil;
}

#pragma mark - Making room for the row

// Items shorter than this are spacers and rules, not rows — including the two
// rows the hide switches above collapse to zero height.
static const CGFloat kFBPSidebarMinRowHeight = 24.0;

static const void *kFBPSidebarAnchorKey = &kFBPSidebarAnchorKey;
static const void *kFBPSidebarAnchorHeightKey = &kFBPSidebarAnchorHeightKey;

/// Set while the hooks below ask the layout what it would do on its own, so the
/// answer they get back is Facebook's, not the shifted one. Layout runs on the
/// main thread, so a plain flag is enough.
static BOOL gFBPSidebarAskingOriginal = NO;

/// YES when @c layout drives the left menu's list.
static BOOL FBPSidebarLayoutIsMenu(UICollectionViewLayout *layout) {
    UICollectionView *list = layout.collectionView;
    return list != nil && FBPSidebarIsMenuList(list);
}

/// The content size the layout reports on its own, without the row's height.
static CGSize FBPSidebarOriginalContentSize(UICollectionViewLayout *layout) {
    BOOL saved = gFBPSidebarAskingOriginal;
    gFBPSidebarAskingOriginal = YES;
    CGSize size = layout.collectionViewContentSize;
    gFBPSidebarAskingOriginal = saved;
    return size;
}

/// Where the tweak's row goes: the top of Facebook's own last row, which is the
/// log-out row, so the tweak sits directly above it.
///
/// Read from the layout rather than from any row's text, so it holds in every
/// language: the menu's last item is a short spacer, and the last one tall
/// enough to be a row is log out.
static const void *kFBPSidebarHeightKey = &kFBPSidebarHeightKey;

/// Items this tall or more are rows; anything taller than the maximum is a
/// header or a card, not something the tweak's row should be sized against.
static const CGFloat kFBPSidebarMaxRowHeight = 120.0;

/// Measures the menu once: where the tweak's row goes, and how tall it should be
/// to sit level with the row Facebook draws above it. Both answers are cached
/// against the content height they were read from.
static void FBPSidebarMeasure(UICollectionViewLayout *layout, CGSize content) {
    NSNumber *cachedFor = objc_getAssociatedObject(layout, kFBPSidebarAnchorHeightKey);
    if (cachedFor && fabs(cachedFor.doubleValue - content.height) < 0.5) return;

    BOOL saved = gFBPSidebarAskingOriginal;
    gFBPSidebarAskingOriginal = YES;
    NSArray<UICollectionViewLayoutAttributes *> *items =
        [layout layoutAttributesForElementsInRect:
            CGRectMake(0, 0, MAX(content.width, 1.0), MAX(content.height, 1.0))];
    gFBPSidebarAskingOriginal = saved;

    // The last row is where the tweak's row goes; the one before it is the row
    // to match, since that is what the tweak's row ends up sitting against.
    CGFloat anchor = -1.0, anchorHeight = 0.0;
    CGFloat beforeTop = -1.0, beforeHeight = 0.0;
    for (UICollectionViewLayoutAttributes *attributes in items) {
        if (attributes.representedElementCategory != UICollectionElementCategoryCell) continue;
        CGFloat height = CGRectGetHeight(attributes.frame);
        if (height < kFBPSidebarMinRowHeight) continue;
        CGFloat top = CGRectGetMinY(attributes.frame);
        if (top > anchor) {
            beforeTop = anchor;
            beforeHeight = anchorHeight;
            anchor = top;
            anchorHeight = height;
        } else if (top > beforeTop) {
            beforeTop = top;
            beforeHeight = height;
        }
    }
    // An empty or still-loading menu has no row to sit above; fall back to the
    // end of the content so the row is never placed over something.
    if (anchor < 0.0) anchor = content.height;
    if (beforeHeight < kFBPSidebarMinRowHeight || beforeHeight > kFBPSidebarMaxRowHeight) {
        beforeHeight = kFBPSidebarDefaultHeight;
    }

    objc_setAssociatedObject(layout, kFBPSidebarAnchorKey, @(anchor),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(layout, kFBPSidebarHeightKey, @(beforeHeight),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(layout, kFBPSidebarAnchorHeightKey, @(content.height),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static CGFloat FBPSidebarAnchorY(UICollectionViewLayout *layout, CGSize content) {
    FBPSidebarMeasure(layout, content);
    NSNumber *anchor = objc_getAssociatedObject(layout, kFBPSidebarAnchorKey);
    return anchor ? anchor.doubleValue : content.height;
}

/// How tall the tweak's row is in this menu: the height of Facebook's own row
/// above it.
static CGFloat FBPSidebarEntryHeight(UICollectionViewLayout *layout, CGSize content) {
    FBPSidebarMeasure(layout, content);
    NSNumber *height = objc_getAssociatedObject(layout, kFBPSidebarHeightKey);
    return height ? height.doubleValue : kFBPSidebarDefaultHeight;
}

/// A copy of @c attributes pushed down by the row's height when it sits at or
/// below the anchor. The layout hands out objects from its own cache, so the
/// originals are copied rather than moved.
static UICollectionViewLayoutAttributes *FBPSidebarShifted(
        UICollectionViewLayoutAttributes *attributes, CGFloat anchor, CGFloat entryHeight) {
    if (attributes.representedElementCategory != UICollectionElementCategoryCell) {
        return attributes;
    }
    if (CGRectGetMinY(attributes.frame) + 0.5 < anchor) return attributes;

    UICollectionViewLayoutAttributes *moved = [attributes copy];
    CGRect frame = moved.frame;
    frame.origin.y += entryHeight;
    moved.frame = frame;
    return moved;
}

#pragma mark - The ComponentKit menu's plan

/// @c FBBookmarksMasonryGridCollectionViewLayout, remembered once it exists.
///
/// Not a dispatch_once: the class ships in FBRarelyUsedFramework, which loads
/// long after the app's first cells lay out, so a single lookup would cache nil
/// and never find it. Only a hit is kept.
static Class FBPSidebarMasonryClass(void) {
    static Class masonry;
    if (!masonry) masonry = objc_getClass("FBBookmarksMasonryGridCollectionViewLayout");
    return masonry;
}

#pragma mark - Reading the ComponentKit menu's rows

// Facebook's own names for the two rows the hide switches cover. They come from
// FBBookmarkDropdownButtonModel.identifier, a developer string Facebook does not
// translate, so this holds whatever language the app is running in.
static NSString *const kFBPSidebarUpgradesID = @"dropdown_section_name-upsell";
static NSString *const kFBPSidebarAlsoFromMetaID =
    @"dropdown_section_name-products_from_facebook";

// Items shorter than this are rules and spacers, not rows.
static const CGFloat kFBPSidebarRuleMaxHeight = 2.0;

/// Which hide switches are on.
static NSUInteger FBPSidebarHideMask(void) {
    NSUInteger mask = 0;
    if (FBPEnabled(FBPKeyHideSidebarUpgrades)) mask |= 1 << 0;
    if (FBPEnabled(FBPKeyHideSidebarAlsoFromMeta)) mask |= 1 << 1;
    return mask;
}

/// What kind of row sits at @c indexPath.
///
/// Only two kinds need naming, because only two of them bound a section. Read
/// off a live menu, the list serves: BKModel for the profile block at the top,
/// FBBookmarksSettingsItemModel for each shortcut, _FBBookmarksFDSButtonModel
/// for "See more", _FBBookmarksSeparatorModel for the rules, one
/// FBBookmarkDropdownButtonModel per collapsible section, and a single
/// FBBookmarkModel at the very bottom, which is log out.
typedef NS_ENUM(NSUInteger, FBPSidebarRowKind) {
    /// Anything else: a shortcut, a rule, a promo card, an app row. Which
    /// section it belongs to, if any, is decided by what came before it.
    FBPSidebarRowOther = 0,
    /// A collapsible section's own header. @c identifier names which one.
    FBPSidebarRowSection,
    /// A plain bookmark, which in this menu means the log-out row. It is the
    /// one row known to come after every section, so it ends the last one.
    FBPSidebarRowBookmark,
};

/// Classifies the row at @c indexPath and, for a section header, hands back the
/// identifier Facebook gives it.
///
/// Read from the data source's model, never from the cell — see
/// FBPBookmarksModelChain for the chain and for why the cell cannot be trusted.
static FBPSidebarRowKind FBPSidebarRowKindAt(UICollectionView *list,
                                             NSIndexPath *indexPath,
                                             NSString **identifier) {
    if (identifier) *identifier = nil;

    FBPBookmarksModelChain *source = (FBPBookmarksModelChain *)list.dataSource;
    if (![source respondsToSelector:@selector(dataSourceState)]) return FBPSidebarRowOther;
    FBPBookmarksModelChain *state = [source dataSourceState];
    if (![state respondsToSelector:@selector(objectAtIndexPath:)]) return FBPSidebarRowOther;
    FBPBookmarksModelChain *item = [state objectAtIndexPath:indexPath];
    if (![item respondsToSelector:@selector(model)]) return FBPSidebarRowOther;
    FBPBookmarksModelChain *wrapper = [item model];
    if (![wrapper respondsToSelector:@selector(model)]) return FBPSidebarRowOther;
    FBPBookmarksModelChain *model = [wrapper model];
    if (!model) return FBPSidebarRowOther;

    Class dropdown = objc_getClass("FBBookmarkDropdownButtonModel");
    if (dropdown && [model isKindOfClass:dropdown]) {
        if (identifier && [model respondsToSelector:@selector(identifier)]) {
            NSString *name = [model identifier];
            if ([name isKindOfClass:NSString.class]) *identifier = name;
        }
        return FBPSidebarRowSection;
    }

    Class bookmark = objc_getClass("FBBookmarkModel");
    if (bookmark && [model isKindOfClass:bookmark]) return FBPSidebarRowBookmark;

    return FBPSidebarRowOther;
}

static BOOL FBPSidebarIdentifierIsHidden(NSString *identifier, NSUInteger mask) {
    if (!identifier.length) return NO;
    if ((mask & (1 << 0)) && [identifier isEqualToString:kFBPSidebarUpgradesID]) return YES;
    if ((mask & (1 << 1)) && [identifier isEqualToString:kFBPSidebarAlsoFromMetaID]) return YES;
    return NO;
}

#pragma mark - The ComponentKit menu's plan

/// What the ComponentKit menu's layout has to do differently: which rows come
/// out, how much height that removes above a given point, and where the tweak's
/// row goes. Built entirely from the data source's models, so it does not depend
/// on which cell happens to be holding a row at the time.
@interface FBPSidebarPlan : NSObject
/// {origin.y, height} of each item that comes out, in the layout's own
/// coordinates: a hidden row, and the rule drawn at its top.
@property (nonatomic, strong) NSArray<NSValue *> *cuts;
@property (nonatomic) CGFloat collapsed;
@property (nonatomic) CGFloat anchorY;
/// How tall the tweak's row is here: the height of the row above it.
@property (nonatomic) CGFloat entryHeight;
@property (nonatomic) CGFloat builtHeight;
@property (nonatomic) NSUInteger builtMask;
@end

@implementation FBPSidebarPlan
- (instancetype)init {
    self = [super init];
    if (self) {
        _cuts = @[];
        _entryHeight = kFBPSidebarDefaultHeight;
        _builtHeight = -1.0;
        _builtMask = NSUIntegerMax;
    }
    return self;
}
@end

static const void *kFBPSidebarPlanKey = &kFBPSidebarPlanKey;

static FBPSidebarPlan *FBPSidebarPlanFor(UICollectionViewLayout *layout) {
    FBPSidebarPlan *plan = objc_getAssociatedObject(layout, kFBPSidebarPlanKey);
    if (!plan) {
        plan = [[FBPSidebarPlan alloc] init];
        objc_setAssociatedObject(layout, kFBPSidebarPlanKey, plan,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return plan;
}

/// Works out the plan from the menu's own layout and models. Rebuilt only when
/// the menu's content or the hide switches change.
static void FBPSidebarRebuildPlan(UICollectionViewLayout *layout,
                                  FBPSidebarPlan *plan, CGSize content) {
    NSUInteger mask = FBPSidebarHideMask();
    if (plan.builtMask == mask && fabs(plan.builtHeight - content.height) < 0.5) return;

    UICollectionView *list = layout.collectionView;
    BOOL saved = gFBPSidebarAskingOriginal;
    gFBPSidebarAskingOriginal = YES;
    NSArray<UICollectionViewLayoutAttributes *> *items =
        [layout layoutAttributesForElementsInRect:
            CGRectMake(0, 0, MAX(content.width, 1.0), MAX(content.height, 1.0))];
    gFBPSidebarAskingOriginal = saved;

    NSMutableArray<NSValue *> *cuts = [NSMutableArray array];
    NSMutableArray<NSNumber *> *cutTops = [NSMutableArray array];
    CGFloat collapsed = 0.0;
    CGFloat anchor = -1.0;

    // In document order. The walk below carries a running state down the list,
    // and layoutAttributesForElementsInRect: promises no order at all.
    NSArray<UICollectionViewLayoutAttributes *> *ordered =
        [items sortedArrayUsingComparator:^NSComparisonResult(UICollectionViewLayoutAttributes *a,
                                                              UICollectionViewLayoutAttributes *b) {
        CGFloat left = CGRectGetMinY(a.frame), right = CGRectGetMinY(b.frame);
        if (left < right) return NSOrderedAscending;
        if (left > right) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    // A section is its header AND the rows under it, so both go.
    //
    // Cutting the header alone was enough for as long as the sections were
    // shut, which is how they come on a small screen. Open one and Facebook
    // puts its contents in the list as rows of their own: on an iPhone 16 Pro
    // Max with "Also from Meta" open, hiding the header left the Meta Verified
    // card and the Meta AI, Edits, Threads, Instagram and WhatsApp rows behind,
    // with no heading above them.
    //
    // Nothing on those rows says which section they belong to, so position
    // decides it: a section runs from its header to the next header, or to the
    // log-out row, and everything in between goes with it. The rules in between
    // go too, which is what keeps two of them from meeting where the section
    // used to be. A shut section has nothing in between, so this still cuts the
    // header alone and the menu looks exactly as it did.
    //
    // Collapsing the section instead, by answering NO from
    // FBBookmarkDropdownButtonModel.isExpanded, does not work: the contents are
    // already in the data source and that flag does not put them there.
    BOOL insideHidden = NO;
    for (UICollectionViewLayoutAttributes *attributes in ordered) {
        if (attributes.representedElementCategory != UICollectionElementCategoryCell) continue;
        CGFloat height = CGRectGetHeight(attributes.frame);
        CGFloat top = CGRectGetMinY(attributes.frame);
        if (height >= kFBPSidebarMinRowHeight && top > anchor) anchor = top;
        if (!list) continue;

        BOOL isRule = height <= kFBPSidebarRuleMaxHeight;
        if (!isRule) {
            NSString *identifier = nil;
            switch (FBPSidebarRowKindAt(list, attributes.indexPath, &identifier)) {
                case FBPSidebarRowSection:
                    insideHidden = FBPSidebarIdentifierIsHidden(identifier, mask);
                    break;
                case FBPSidebarRowBookmark:
                    // The log-out row: past the last section.
                    insideHidden = NO;
                    break;
                case FBPSidebarRowOther:
                    break;
            }
        }
        if (!insideHidden || height <= 0.0) continue;

        [cuts addObject:[NSValue valueWithCGPoint:CGPointMake(top, height)]];
        if (!isRule) [cutTops addObject:@(top)];
        collapsed += height;
    }

    // Each of Facebook's rows carries a hairline at its own top. Taking only the
    // row out would leave that line behind, stacked against the next one.
    for (UICollectionViewLayoutAttributes *attributes in items) {
        if (attributes.representedElementCategory != UICollectionElementCategoryCell) continue;
        CGFloat height = CGRectGetHeight(attributes.frame);
        if (height <= 0.0 || height > kFBPSidebarRuleMaxHeight) continue;
        CGFloat top = CGRectGetMinY(attributes.frame);
        // A rule inside a hidden section was taken by the walk above. Counting
        // it again here would subtract its height from the content size twice
        // and pull everything below the section up too far.
        BOOL already = NO;
        for (NSValue *cut in cuts) {
            if (fabs(cut.CGPointValue.x - top) < 0.5) { already = YES; break; }
        }
        if (already) continue;
        for (NSNumber *cutTop in cutTops) {
            if (fabs(top - cutTop.doubleValue) > kFBPSidebarRuleMaxHeight) continue;
            [cuts addObject:[NSValue valueWithCGPoint:CGPointMake(top, height)]];
            collapsed += height;
            break;
        }
    }

    [cuts sortUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
        CGFloat left = a.CGPointValue.x, right = b.CGPointValue.x;
        if (left < right) return NSOrderedAscending;
        if (left > right) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    plan.cuts = cuts;
    plan.collapsed = collapsed;
    plan.anchorY = anchor < 0.0 ? content.height : anchor;
    plan.entryHeight = FBPSidebarEntryHeight(layout, content);
    plan.builtHeight = content.height;
    plan.builtMask = mask;
}

/// How much removed height sits above @c y.
static CGFloat FBPSidebarDropAbove(FBPSidebarPlan *plan, CGFloat y) {
    CGFloat drop = 0.0;
    for (NSValue *value in plan.cuts) {
        CGPoint cut = value.CGPointValue;
        if (cut.x + 0.5 < y) drop += cut.y;
    }
    return drop;
}

/// A copy of @c attributes with the hidden rows taken out of its position and the
/// tweak's row allowed for. The layout hands out objects from its own cache, so
/// the originals are copied rather than moved.
static UICollectionViewLayoutAttributes *FBPSidebarAdjusted(
        UICollectionViewLayoutAttributes *attributes, FBPSidebarPlan *plan) {
    if (attributes.representedElementCategory != UICollectionElementCategoryCell) {
        return attributes;
    }
    CGFloat height = CGRectGetHeight(attributes.frame);
    CGFloat top = CGRectGetMinY(attributes.frame);

    BOOL cut = NO;
    for (NSValue *value in plan.cuts) {
        CGPoint entry = value.CGPointValue;
        if (fabs(entry.x - top) < 0.5 && fabs(entry.y - height) < 0.5) { cut = YES; break; }
    }

    CGFloat moved = top - FBPSidebarDropAbove(plan, top);
    if (top + 0.5 >= plan.anchorY) moved += plan.entryHeight;
    if (!cut && fabs(moved - top) < 0.5) return attributes;

    UICollectionViewLayoutAttributes *copy = [attributes copy];
    CGRect frame = copy.frame;
    frame.origin.y = moved;
    if (cut) frame.size.height = 0.0;
    copy.frame = frame;
    // A zero-height cell would still draw its content outside its bounds.
    if (cut) copy.hidden = YES;
    return copy;
}

/// Where the tweak's row is drawn: the log-out row's place, with any rows taken
/// out above it already accounted for.
static CGFloat FBPSidebarRowTop(UICollectionViewLayout *layout, CGSize content) {
    Class masonry = FBPSidebarMasonryClass();
    if (masonry && [layout isKindOfClass:masonry]) {
        FBPSidebarPlan *plan = FBPSidebarPlanFor(layout);
        FBPSidebarRebuildPlan(layout, plan, content);
        return plan.anchorY - FBPSidebarDropAbove(plan, plan.anchorY);
    }
    return FBPSidebarAnchorY(layout, content);
}

/// Asks the menu to work itself out again when the hide switches have moved
/// since the plan was made — the switches live on a screen presented over the
/// menu, so the menu itself is not told.
static void FBPSidebarRefreshForSwitches(UICollectionView *list) {
    UICollectionViewLayout *layout = list.collectionViewLayout;
    if (FBPSidebarPlanFor(layout).builtMask == FBPSidebarHideMask()) return;
    dispatch_async(dispatch_get_main_queue(), ^{ [layout invalidateLayout]; });
}

/// Where Facebook starts the glyph on its own rows: 12pt in the ComponentKit
/// menu, 16pt in the Bloks one. Returns 0 when there is nothing to read, and the
/// row keeps its default.
///
/// Measured off the nearest row of the same height, which is what picks out a
/// row of the same kind: the menu's shortcut rows are a different height and lay
/// their contents out differently. Any such row will do, because the list only
/// keeps the cells it is showing and the row directly above the tweak's is off
/// screen when the menu first opens.
static CGFloat FBPSidebarMeasuredInset(UIScrollView *list, CGRect rowFrame) {
    UIView *sibling = nil;
    CGFloat nearest = CGFLOAT_MAX;
    for (UIView *sub in list.subviews) {
        if ([sub isKindOfClass:FBPSidebarEntryRow.class]) continue;
        if (fabs(CGRectGetHeight(sub.frame) - CGRectGetHeight(rowFrame)) > 1.0) continue;
        CGFloat distance = fabs(CGRectGetMinY(sub.frame) - CGRectGetMinY(rowFrame));
        if (distance >= nearest) continue;
        nearest = distance;
        sibling = sub;
    }
    if (!sibling) return 0.0;

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:sibling];
    NSInteger visited = 0;
    while (queue.count && visited < 80) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited += 1;
        if ([view isKindOfClass:UIImageView.class]) {
            CGRect box = [view convertRect:view.bounds toView:sibling];
            CGFloat side = CGRectGetWidth(box);
            // The row's own glyph, not a badge or the chevron beside it.
            if (side >= 20.0 && side <= 32.0) return CGRectGetMinX(box);
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return 0.0;
}

#pragma mark - Placing the row

/// The animation the list has just put on its own cells, or nil when there is
/// none to join.
///
/// Opening "Settings and privacy" on the SE: the collection view puts the whole
/// change inside one performBatchUpdates and hands every cell a 0.3s
/// easeInEaseOut animation — the log-out cell's presentation layer was measured
/// gliding from y 809.6 to 1377.4 over that window. A zero beginTime is what
/// says those animations are still in the open transaction rather than already
/// running, and that is the only moment the row can start alongside them.
/// Preferring a position animation picks a row that is moving over one that is
/// only fading in; the timing is the same either way.
static CAAnimation *FBPSidebarListAnimation(UIScrollView *list) {
    CAAnimation *any = nil;
    for (UIView *sub in list.subviews) {
        if ([sub isKindOfClass:FBPSidebarEntryRow.class]) continue;
        for (NSString *key in sub.layer.animationKeys) {
            CAAnimation *animation = [sub.layer animationForKey:key];
            if (!animation || animation.beginTime != 0.0) continue;
            if ([animation isKindOfClass:CAPropertyAnimation.class] &&
                [[(CAPropertyAnimation *)animation keyPath] isEqualToString:@"position"]) {
                return animation;
            }
            if (!any) any = animation;
        }
    }
    return any;
}

/// Moves the row to @c frame, keeping step with the list when the list is
/// animating.
///
/// The row is a subview rather than a cell, so nothing animates it: its frame is
/// set from a cell's -layoutSubviews, which the collection view runs inside its
/// batch update with animations off — +areAnimationsEnabled was NO on every one
/// of those passes. The row therefore arrived at its final place in the first
/// frame of the update and then stood there for the 0.3s Facebook's own rows
/// spent travelling, which reads as the row vanishing from where it was and
/// turning up early somewhere else. It joins them by taking their animation.
///
/// Taking it needs a second pass: the move lands on the first cell laid out in
/// the update, and the cells are given their animations a few passes later —
/// 0.130s against 0.135s in the run measured. So the move is remembered and
/// every later pass through the same update is another chance to catch it,
/// which is why this runs even when the frame has not changed.
static void FBPSidebarMoveEntry(UIScrollView *list, FBPSidebarEntryRow *row, CGRect frame) {
    if (!CGRectEqualToRect(row.frame, frame)) {
        CGRect was = row.frame;
        CGPoint from = row.layer.position;
        row.frame = frame;
        row.moveWaiting = !CGRectIsEmpty(was) && !CGPointEqualToPoint(from, row.layer.position);
        row.movedFrom = from;
        row.movedTo = frame;
    }
    // A remembered move is only the one the row is still standing at the end of.
    if (!row.moveWaiting || !CGRectEqualToRect(row.frame, row.movedTo)) return;

    CAAnimation *pace = FBPSidebarListAnimation(list);
    if (!pace) return;
    row.moveWaiting = NO;

    CABasicAnimation *move = [CABasicAnimation animationWithKeyPath:@"position"];
    move.fromValue = [NSValue valueWithCGPoint:row.movedFrom];
    move.toValue = [NSValue valueWithCGPoint:row.layer.position];
    move.duration = pace.duration;
    move.timingFunction = pace.timingFunction;
    [row.layer addAnimation:move forKey:@"position"];
}

/// Puts the tweak's row in the gap the layout hooks opened above the log-out
/// row, and keeps it there as the menu's own content grows and shrinks.
static void FBPSidebarInstallEntry(UIScrollView *list) {
    FBPSidebarEntryRow *row = FBPSidebarExistingRow(list);
    if (!row) {
        row = [[FBPSidebarEntryRow alloc] initWithFrame:CGRectZero];
        [list addSubview:row];
    }

    UICollectionViewLayout *layout = ((UICollectionView *)list).collectionViewLayout;
    CGSize content = FBPSidebarOriginalContentSize(layout);
    CGRect frame = CGRectMake(0, FBPSidebarRowTop(layout, content),
                              list.bounds.size.width,
                              FBPSidebarEntryHeight(layout, content));
    FBPSidebarMoveEntry(list, row, frame);

    // Once a measurement lands the row keeps it; until then every pass is
    // another chance at one.
    if (!row.insetMeasured) {
        CGFloat inset = FBPSidebarMeasuredInset(list, frame);
        if (inset > 0.0) {
            row.leadingInset = inset;
            row.insetMeasured = YES;
        }
    }

    if (list.subviews.lastObject != row) [list bringSubviewToFront:row];
}

// The ComponentKit menu's layout: it takes the hidden rows out and opens the
// slot for the tweak's row, since the cells cannot size themselves.
//
// FBBookmarksMasonryGridCollectionViewLayout ships in FBRarelyUsedFramework,
// which is not loaded when the tweak starts, so this group cannot be installed
// with the rest; it goes in on the first menu cell laid out under that layout.
%group FBPSidebarMasonry

%hook FBBookmarksMasonryGridCollectionViewLayout

- (CGSize)collectionViewContentSize {
    CGSize size = %orig;
    if (gFBPSidebarAskingOriginal) return size;
    UICollectionView *list = ((UICollectionViewLayout *)self).collectionView;
    if (!list || !FBPSidebarIsMenuList(list)) return size;

    FBPSidebarPlan *plan = FBPSidebarPlanFor((UICollectionViewLayout *)self);
    FBPSidebarRebuildPlan((UICollectionViewLayout *)self, plan, size);

    size.height -= plan.collapsed;
    size.height += plan.entryHeight;
    return size;
}

- (NSArray<UICollectionViewLayoutAttributes *> *)layoutAttributesForElementsInRect:(CGRect)rect {
    if (gFBPSidebarAskingOriginal) return %orig;
    UICollectionView *list = ((UICollectionViewLayout *)self).collectionView;
    if (!list || !FBPSidebarIsMenuList(list)) return %orig;

    CGSize content = FBPSidebarOriginalContentSize((UICollectionViewLayout *)self);
    FBPSidebarPlan *plan = FBPSidebarPlanFor((UICollectionViewLayout *)self);
    FBPSidebarRebuildPlan((UICollectionViewLayout *)self, plan, content);
    // The rect is in the coordinates the collection view has been told about,
    // while Facebook's layout answers in its own. A row that ends up inside this
    // rect started as much as one row height above it (pushed down for the
    // tweak's row) or as much as the removed height below it, so ask about that
    // whole span — otherwise cells near the edges go missing.
    CGRect widened = rect;
    widened.origin.y -= plan.entryHeight;
    widened.size.height += plan.entryHeight + plan.collapsed;
    NSArray<UICollectionViewLayoutAttributes *> *items = %orig(widened);
    if (!items.count) return items;

    NSMutableArray<UICollectionViewLayoutAttributes *> *adjusted =
        [NSMutableArray arrayWithCapacity:items.count];
    for (UICollectionViewLayoutAttributes *attributes in items) {
        [adjusted addObject:FBPSidebarAdjusted(attributes, plan)];
    }
    return adjusted;
}

- (UICollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewLayoutAttributes *attributes = %orig;
    if (gFBPSidebarAskingOriginal || !attributes) return attributes;
    UICollectionView *list = ((UICollectionViewLayout *)self).collectionView;
    if (!list || !FBPSidebarIsMenuList(list)) return attributes;

    CGSize content = FBPSidebarOriginalContentSize((UICollectionViewLayout *)self);
    FBPSidebarPlan *plan = FBPSidebarPlanFor((UICollectionViewLayout *)self);
    FBPSidebarRebuildPlan((UICollectionViewLayout *)self, plan, content);
    return FBPSidebarAdjusted(attributes, plan);
}

%end

%end // FBPSidebarMasonry

%group FBPSidebar

// The menu list's layout. Hooking it — rather than nudging cell frames after
// the fact — is what keeps the row's slot stable: the collection view positions
// every cell from these answers itself, so nothing has to be re-corrected on each
// pass, and the taller content size means the list scrolls to the row natively
// instead of living on a bottom contentInset.
%hook BKCollectionViewLayout

- (CGSize)collectionViewContentSize {
    CGSize size = %orig;
    if (gFBPSidebarAskingOriginal) return size;
    if (!FBPSidebarLayoutIsMenu((UICollectionViewLayout *)self)) return size;
    size.height += FBPSidebarEntryHeight((UICollectionViewLayout *)self, size);
    return size;
}

- (NSArray<UICollectionViewLayoutAttributes *> *)layoutAttributesForElementsInRect:(CGRect)rect {
    if (gFBPSidebarAskingOriginal ||
        !FBPSidebarLayoutIsMenu((UICollectionViewLayout *)self)) {
        return %orig;
    }

    // The rect asked about is in the shifted coordinates the collection view has
    // been told about, while Facebook's layout still answers in its own. An item
    // that has been pushed down into the top of this rect started one row height
    // above it, so widen the question by exactly that much — otherwise the first
    // cells below the row would be missing from the answer and leave a gap.
    CGSize content = FBPSidebarOriginalContentSize((UICollectionViewLayout *)self);
    CGFloat anchor = FBPSidebarAnchorY((UICollectionViewLayout *)self, content);
    CGFloat entryHeight = FBPSidebarEntryHeight((UICollectionViewLayout *)self, content);

    CGRect widened = rect;
    widened.origin.y -= entryHeight;
    widened.size.height += entryHeight;
    NSArray<UICollectionViewLayoutAttributes *> *items = %orig(widened);
    if (!items.count) return items;

    NSMutableArray<UICollectionViewLayoutAttributes *> *shifted =
        [NSMutableArray arrayWithCapacity:items.count];
    for (UICollectionViewLayoutAttributes *attributes in items) {
        [shifted addObject:FBPSidebarShifted(attributes, anchor, entryHeight)];
    }
    return shifted;
}

- (UICollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewLayoutAttributes *attributes = %orig;
    if (gFBPSidebarAskingOriginal || !attributes) return attributes;
    if (!FBPSidebarLayoutIsMenu((UICollectionViewLayout *)self)) return attributes;

    CGSize content = FBPSidebarOriginalContentSize((UICollectionViewLayout *)self);
    return FBPSidebarShifted(attributes,
                             FBPSidebarAnchorY((UICollectionViewLayout *)self, content),
                             FBPSidebarEntryHeight((UICollectionViewLayout *)self, content));
}

%end

%hook BKCollectionView

- (void)layoutSubviews {
    FBPTraceFire("sidebar.BKCollectionView.layoutSubviews");
    %orig;
    if (!FBPSidebarIsMenuList((UIView *)self)) return;
    FBPSidebarInstallEntry((UIScrollView *)self);
}

%end

// Every ComponentKit cell in the app goes through this, the feed's included, so
// the first thing it does is leave unless this cell belongs to the menu's list —
// two comparisons, before anything walks a view tree.
%hook FBComponentHostingCollectionViewCell

- (void)layoutSubviews {
    %orig;
    UIView *host = ((UIView *)self).superview;
    if (![host isKindOfClass:UICollectionView.class]) return;
    UICollectionView *list = (UICollectionView *)host;
    Class masonry = FBPSidebarMasonryClass();
    if (!masonry || ![list.collectionViewLayout isKindOfClass:masonry]) return;
    if (!FBPSidebarIsMenuList(list)) return;

    // First menu cell seen: the framework carrying the layout is loaded now, so
    // its hooks can go in. The layout has already answered this pass, so ask it
    // to work the list out again through them.
    FBP_ONCE(gMasonry) {
        %init(FBPSidebarMasonry);
        FBPTraceLine(@"sidebar masonry layout hooked");
        UICollectionViewLayout *layout = list.collectionViewLayout;
        dispatch_async(dispatch_get_main_queue(), ^{ [layout invalidateLayout]; });
    }

    FBPSidebarRefreshForSwitches(list);
    FBPSidebarInstallEntry(list);
}

%end

%end // FBPSidebar



void FBPInitSidebarHooks(void) {
    // Generic Bloks classes plus the ComponentKit menu's own: a launch gets one
    // rendering or the other, and the group covers both.
    if (objc_getClass("BKCollectionView") ||
        objc_getClass("BKCollectionViewLayout") ||
        objc_getClass("FBBookmarksMasonryGridCollectionViewLayout") ||
        objc_getClass("FBComponentHostingCollectionViewCell")) {
        FBP_ONCE(gSidebar) { %init(FBPSidebar); }
    }
}
