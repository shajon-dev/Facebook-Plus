// Left side menu ("bookmarks"): hides the rows the user has switched off, and
// adds the tweak's own "Facebook Plus" row above log out.
//
// Facebook ships the menu in two renderings and a launch gets one or the other:
// a Bloks panel (BKCollectionView, BKBloksCollectionCell_SyncUpdates) or a
// ComponentKit surface (a UICollectionView on
// FBBookmarksMasonryGridCollectionViewLayout, with
// FBComponentHostingCollectionViewCell rows).
//
// The tweak's own row is added to both. Hiding a row is done in the CK menu
// only: a hidden row and the hairline at its top come out of the layout and
// everything below moves up. A row is identified by its MODEL, never its cell —
// FBBookmarkDropdownButtonModel.identifier names each section in a string
// Facebook does not translate, while a reused cell can still carry the previous
// row's content (see FBPBookmarksModelChain in FBPHeaders.h). The Bloks menu
// carries no such identifier, and its only per-row signal is an accessibility
// label, which means matching English words and missing every other language,
// so the hide switches leave Bloks as Facebook draws it.
//
// Neither list's model is touched. The tweak's row is a plain UIControl added as
// a subview of the list, and the layout opens the space for it: it reports a
// content size one row taller and pushes everything from the log-out row down.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPHeaders.h"
#import "FBPTrace.h"
#import "FBPResources.h"
#import "FBPSettingsController.h"

#import <objc/runtime.h>

#pragma mark - Facebook Plus row

// A menu row is a 1pt rule and a 24x24 glyph with the label beside it. Height
// and leading inset differ between the two menus and are measured off a row
// Facebook draws; these are the fallbacks before the menu lays out.
static const CGFloat kFBPSidebarRule = 1.0;
static const CGFloat kFBPSidebarGlyph = 24.0;
static const CGFloat kFBPSidebarGlyphGap = 12.0;
static const CGFloat kFBPSidebarDefaultInset = 16.0;
static const CGFloat kFBPSidebarDefaultHeight = 57.0;

/// The tweak's row, just above log out. The FBP prefix is deliberate: the OLED
/// sweep and the font replacement both skip FBP-prefixed views, so this row
/// keeps the colours set here.
@interface FBPSidebarEntryRow : UIControl
/// Facebook's own glyph inset, measured off a row beside the tweak's.
@property (nonatomic) CGFloat leadingInset;
@property (nonatomic) BOOL insetMeasured;
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
    // A product name, so not run through the string catalog.
    self.accessibilityLabel = @"Facebook Plus";
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.isAccessibilityElement = YES;

    _rule = [[UIView alloc] initWithFrame:CGRectZero];
    _rule.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.22];
    [self addSubview:_rule];

    // Facebook's rows each carry a rule at their top and the log-out button
    // below has none, so this row draws the one that closes it off.
    _bottomRule = [[UIView alloc] initWithFrame:CGRectZero];
    _bottomRule.backgroundColor = _rule.backgroundColor;
    [self addSubview:_bottomRule];

    _glyph = [[UIImageView alloc] initWithFrame:CGRectZero];
    _glyph.contentMode = UIViewContentModeScaleAspectFit;
    // A colour mark: fbp_imageNamed: would flatten it to a template.
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
    // Facebook's own primary label colour, dynamic so it follows the theme.
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
    // Rules on the edges and the contents centred, so the row reads at its
    // neighbours' weight whatever height it is given.
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

/// YES when @c list is the menu's own list, read from the live hierarchy rather
/// than a class name because the two renderings nest differently: walking out
/// reaches either FBBookmarksPanelNavigationController (Bloks; the
/// identically-classed container in the main app answers
/// FBNewNavigationController instead) or FBBookmarksViewController. The menu's
/// list is also the OUTER collection, which rejects the shortcuts strip inside
/// it.
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

/// Cached, so the walk runs once per view. Nothing is cached before the view
/// reaches a window, because the chain it reads is not in place yet.
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

// Items shorter than this are spacers and rules, not rows.
static const CGFloat kFBPSidebarMinRowHeight = 24.0;

static const void *kFBPSidebarAnchorKey = &kFBPSidebarAnchorKey;
static const void *kFBPSidebarAnchorHeightKey = &kFBPSidebarAnchorHeightKey;

/// Set while the hooks ask the layout what it would do on its own, so the answer
/// is Facebook's and not the shifted one. Main thread, so a plain flag will do.
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

/// Where the tweak's row goes: the top of Facebook's last row, which is log
/// out. Read from the layout rather than any row's text, so it holds in every
/// language — the last item is a short spacer, and the last one tall enough to
/// be a row is log out.
static const void *kFBPSidebarHeightKey = &kFBPSidebarHeightKey;

/// Rows sit between these; anything taller is a header or a card.
static const CGFloat kFBPSidebarMaxRowHeight = 120.0;

/// Where the tweak's row goes and how tall it should be to sit level with the
/// row above it. Cached against the content height they were read from.
static void FBPSidebarMeasure(UICollectionViewLayout *layout, CGSize content) {
    NSNumber *cachedFor = objc_getAssociatedObject(layout, kFBPSidebarAnchorHeightKey);
    if (cachedFor && fabs(cachedFor.doubleValue - content.height) < 0.5) return;

    BOOL saved = gFBPSidebarAskingOriginal;
    gFBPSidebarAskingOriginal = YES;
    NSArray<UICollectionViewLayoutAttributes *> *items =
        [layout layoutAttributesForElementsInRect:
            CGRectMake(0, 0, MAX(content.width, 1.0), MAX(content.height, 1.0))];
    gFBPSidebarAskingOriginal = saved;

    // The one before the last row is what the tweak's row sits against.
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
    // An empty or still-loading menu has no row to sit above.
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

/// The height of Facebook's own row above the tweak's.
static CGFloat FBPSidebarEntryHeight(UICollectionViewLayout *layout, CGSize content) {
    FBPSidebarMeasure(layout, content);
    NSNumber *height = objc_getAssociatedObject(layout, kFBPSidebarHeightKey);
    return height ? height.doubleValue : kFBPSidebarDefaultHeight;
}

/// A copy pushed down by the row's height when it sits at or below the anchor.
/// The layout hands out objects from its own cache, so never move an original.
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
/// long after the first cells lay out, so one lookup would cache nil forever.
static Class FBPSidebarMasonryClass(void) {
    static Class masonry;
    if (!masonry) masonry = objc_getClass("FBBookmarksMasonryGridCollectionViewLayout");
    return masonry;
}

#pragma mark - Reading the ComponentKit menu's rows

// From FBBookmarkDropdownButtonModel.identifier, a developer string Facebook
// does not translate, so these hold in whatever language the app runs in.
static NSString *const kFBPSidebarUpgradesID = @"dropdown_section_name-upsell";
static NSString *const kFBPSidebarAlsoFromMetaID =
    @"dropdown_section_name-products_from_facebook";

// Items shorter than this are rules and spacers, not rows.
static const CGFloat kFBPSidebarRuleMaxHeight = 2.0;

static NSUInteger FBPSidebarHideMask(void) {
    NSUInteger mask = 0;
    if (FBPEnabled(FBPKeyHideSidebarUpgrades)) mask |= 1 << 0;
    if (FBPEnabled(FBPKeyHideSidebarAlsoFromMeta)) mask |= 1 << 1;
    return mask;
}

/// What kind of row sits at @c indexPath. Only two kinds need naming, because
/// only two of them bound a section.
typedef NS_ENUM(NSUInteger, FBPSidebarRowKind) {
    /// Anything else; which section it belongs to is decided by what preceded it.
    FBPSidebarRowOther = 0,
    /// A collapsible section's own header. @c identifier names which one.
    FBPSidebarRowSection,
    /// In this menu, the log-out row: the one row known to come after every
    /// section, so it ends the last one.
    FBPSidebarRowBookmark,
};

/// Classifies the row and, for a section header, hands back its identifier.
/// Read from the data source's model, never the cell — see
/// FBPBookmarksModelChain for the chain and why a cell cannot be trusted.
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

/// What the layout does differently: which rows come out, how much height that
/// removes above a point, where the tweak's row goes. Built from the data
/// source's models, not whichever cell holds a row at the time.
@interface FBPSidebarPlan : NSObject
/// {origin.y, height} of each item removed, in the layout's own coordinates.
@property (nonatomic, strong) NSArray<NSValue *> *cuts;
@property (nonatomic) CGFloat collapsed;
@property (nonatomic) CGFloat anchorY;
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

/// Moves a hidden section's gathered rows into the plan now that something has
/// ended it; leaves the gathering lists empty either way.
static void FBPSidebarCloseRun(NSMutableArray<NSValue *> *cuts,
                               NSMutableArray<NSNumber *> *cutTops,
                               NSMutableArray<NSValue *> *pending,
                               NSMutableArray<NSNumber *> *pendingTops,
                               CGFloat *collapsed, CGFloat *pendingHeight) {
    [cuts addObjectsFromArray:pending];
    [cutTops addObjectsFromArray:pendingTops];
    *collapsed += *pendingHeight;
    [pending removeAllObjects];
    [pendingTops removeAllObjects];
    *pendingHeight = 0.0;
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

    // In document order: the walk carries running state, and
    // layoutAttributesForElementsInRect: promises no order at all.
    NSArray<UICollectionViewLayoutAttributes *> *ordered =
        [items sortedArrayUsingComparator:^NSComparisonResult(UICollectionViewLayoutAttributes *a,
                                                              UICollectionViewLayoutAttributes *b) {
        CGFloat left = CGRectGetMinY(a.frame), right = CGRectGetMinY(b.frame);
        if (left < right) return NSOrderedAscending;
        if (left > right) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    // A section is its header AND the rows under it. An open section puts its
    // contents in the list as rows of their own, and nothing on them says which
    // section they belong to, so position decides it: a section runs from its
    // header to the next header or to the log-out row, rules included, which
    // stops two of them meeting where the section was. Collapsing the section
    // instead, by answering NO from FBBookmarkDropdownButtonModel.isExpanded,
    // does not work: the contents are already in the data source.
    //
    // "From this header to the next" is only safe while a next one arrives: an
    // unclosed run took the whole rest of the list with it. So a run's contents
    // are held back until a boundary arrives and dropped if none does, while
    // the header's own row is cut as soon as it is seen.
    BOOL insideHidden = NO;
    NSMutableArray<NSValue *> *pending = [NSMutableArray array];
    NSMutableArray<NSNumber *> *pendingTops = [NSMutableArray array];
    CGFloat pendingHeight = 0.0;

    for (UICollectionViewLayoutAttributes *attributes in ordered) {
        if (attributes.representedElementCategory != UICollectionElementCategoryCell) continue;
        CGFloat height = CGRectGetHeight(attributes.frame);
        CGFloat top = CGRectGetMinY(attributes.frame);
        if (height >= kFBPSidebarMinRowHeight && top > anchor) anchor = top;
        if (!list) continue;

        BOOL isRule = height <= kFBPSidebarRuleMaxHeight;
        BOOL isHeader = NO;
        if (!isRule) {
            NSString *identifier = nil;
            switch (FBPSidebarRowKindAt(list, attributes.indexPath, &identifier)) {
                case FBPSidebarRowSection:
                    isHeader = YES;
                    FBPSidebarCloseRun(cuts, cutTops, pending, pendingTops,
                                       &collapsed, &pendingHeight);
                    insideHidden = FBPSidebarIdentifierIsHidden(identifier, mask);
                    break;
                case FBPSidebarRowBookmark:
                    FBPSidebarCloseRun(cuts, cutTops, pending, pendingTops,
                                       &collapsed, &pendingHeight);
                    insideHidden = NO;
                    break;
                case FBPSidebarRowOther:
                    break;
            }
        }
        if (!insideHidden || height <= 0.0) continue;

        if (isHeader) {
            [cuts addObject:[NSValue valueWithCGPoint:CGPointMake(top, height)]];
            [cutTops addObject:@(top)];
            collapsed += height;
            continue;
        }

        [pending addObject:[NSValue valueWithCGPoint:CGPointMake(top, height)]];
        if (!isRule) [pendingTops addObject:@(top)];
        pendingHeight += height;
    }

    // Nothing ever closed this run, so only the heading goes.
    BOOL unclosed = pending.count > 0;
    [pending removeAllObjects];
    [pendingTops removeAllObjects];
    pendingHeight = 0.0;

    // Each row carries a hairline at its top, which would otherwise be left
    // behind stacked against the next one.
    for (UICollectionViewLayoutAttributes *attributes in items) {
        if (attributes.representedElementCategory != UICollectionElementCategoryCell) continue;
        CGFloat height = CGRectGetHeight(attributes.frame);
        if (height <= 0.0 || height > kFBPSidebarRuleMaxHeight) continue;
        CGFloat top = CGRectGetMinY(attributes.frame);
        // Already taken by the walk above; counting it twice would pull
        // everything below the section up too far.
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

    // Backstop: two hide switches, each covering one heading, cannot account
    // for half a menu. If the walk says they do it misread this list, and the
    // right answer is to change nothing — a switch that did not work beats a
    // menu with most of it removed, the tweak's own row included.
    BOOL abandoned = NO;
    if (content.height > 0.0 && collapsed > content.height * 0.5) {
        abandoned = YES;
        [cuts removeAllObjects];
        collapsed = 0.0;
    }

    if (abandoned || unclosed) {
        FBPDiag(@"sidebar", @"hide mask=%lu: %@ (cut %.0f of %.0f points, %lu rows)",
                (unsigned long)mask,
                abandoned ? @"abandoned, menu left alone"
                          : @"section never closed, heading only",
                collapsed, content.height, (unsigned long)cuts.count);
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

/// A copy with the hidden rows taken out of its position and the tweak's row
/// allowed for. Never move an original: they come from the layout's cache.
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
    if (cut) copy.hidden = YES;
    return copy;
}

/// The log-out row's place, with rows removed above it accounted for.
static CGFloat FBPSidebarRowTop(UICollectionViewLayout *layout, CGSize content) {
    Class masonry = FBPSidebarMasonryClass();
    if (masonry && [layout isKindOfClass:masonry]) {
        FBPSidebarPlan *plan = FBPSidebarPlanFor(layout);
        FBPSidebarRebuildPlan(layout, plan, content);
        return plan.anchorY - FBPSidebarDropAbove(plan, plan.anchorY);
    }
    return FBPSidebarAnchorY(layout, content);
}

/// The hide switches live on a screen presented over the menu, so the menu is
/// never told they moved; this asks it to work itself out again.
static void FBPSidebarRefreshForSwitches(UICollectionView *list) {
    UICollectionViewLayout *layout = list.collectionViewLayout;
    if (FBPSidebarPlanFor(layout).builtMask == FBPSidebarHideMask()) return;
    dispatch_async(dispatch_get_main_queue(), ^{ [layout invalidateLayout]; });
}

/// Where Facebook starts the glyph on its own rows; 0 when there is nothing to
/// read, and the row keeps its default. Measured off the nearest row of the
/// same height, which is what picks out a row of the same kind. Any such row
/// will do, because the list only keeps the cells it is showing and the row
/// directly above the tweak's is off screen when the menu first opens.
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
/// Opening a section puts the whole change inside one performBatchUpdates and
/// hands every cell a 0.3s easeInEaseOut animation. A zero beginTime says those
/// animations are still in the open transaction rather than already running,
/// which is the only moment the row can start alongside them. Preferring a
/// position animation picks a row that is moving over one only fading in.
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
/// The row is a subview rather than a cell, so nothing animates it: its frame
/// is set from a cell's -layoutSubviews, which the collection view runs inside
/// its batch update with +areAnimationsEnabled NO. The row therefore lands in
/// its final place on the first frame while Facebook's rows spend 0.3s
/// travelling, so it joins them by taking their animation.
///
/// Taking it needs a second pass: the move lands on the first cell laid out in
/// the update, and the cells are given their animations a few passes later. So
/// the move is remembered and every later pass through the same update is
/// another chance to catch it — which is why this runs even when the frame has
/// not changed.
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

    if (!row.insetMeasured) {
        CGFloat inset = FBPSidebarMeasuredInset(list, frame);
        if (inset > 0.0) {
            row.leadingInset = inset;
            row.insetMeasured = YES;
        }
    }

    if (list.subviews.lastObject != row) [list bringSubviewToFront:row];
}

// FBBookmarksMasonryGridCollectionViewLayout ships in FBRarelyUsedFramework,
// which is not loaded when the tweak starts, so this group cannot go in with
// the rest: it installs on the first menu cell laid out under that layout.
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
    // The rect is in the coordinates the collection view was told about, while
    // Facebook's layout answers in its own, so widen the question by a row
    // height above and the removed height below or cells near the edges vanish.
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

// Hooking the layout, rather than nudging cell frames afterwards, is what keeps
// the slot stable: the collection view positions every cell from these answers
// itself, and the taller content size makes the list scroll to the row natively
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

    // As above: an item pushed down into the top of this rect started one row
    // height above it, so widen the question by exactly that much.
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
// it leaves on two comparisons before anything walks a view tree.
%hook FBComponentHostingCollectionViewCell

- (void)layoutSubviews {
    %orig;
    UIView *host = ((UIView *)self).superview;
    if (![host isKindOfClass:UICollectionView.class]) return;
    UICollectionView *list = (UICollectionView *)host;
    Class masonry = FBPSidebarMasonryClass();
    if (!masonry || ![list.collectionViewLayout isKindOfClass:masonry]) return;
    if (!FBPSidebarIsMenuList(list)) return;

    // The framework carrying the layout is loaded by now, so its hooks can go
    // in; it has already answered this pass, so ask it again through them.
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
    // A launch gets one rendering or the other, and the group covers both.
    if (objc_getClass("BKCollectionView") ||
        objc_getClass("BKCollectionViewLayout") ||
        objc_getClass("FBBookmarksMasonryGridCollectionViewLayout") ||
        objc_getClass("FBComponentHostingCollectionViewCell")) {
        FBP_ONCE(gSidebar) { %init(FBPSidebar); }
    }
}
