// Content-sized bottom sheet: one rounded card per action, a Cancel button of
// its own, and a height that is exactly the content's.

#import "FBPSheet.h"
#import "FBPResources.h"

#pragma mark - Metrics

// The approved "flat card" treatment: every action is its own rounded card with
// real air between the cards, no hairline dividers and no grouped-list
// background. The numbers below are the ones that were signed off in the
// preview, so changing one changes the design.
static const CGFloat kSideInset       = 16.0;  // card edge → sheet edge
static const CGFloat kTopInset        = 18.0;  // sheet top → title, clears the grabber
static const CGFloat kTitleGap        = 16.0;  // title → first card
static const CGFloat kCardSpacing     = 8.0;   // card → card
static const CGFloat kCardRadius      = 14.0;
static const CGFloat kCardMinHeight   = 60.0;
static const CGFloat kCardInsetX      = 14.0;
static const CGFloat kCardInsetY      = 11.0;
static const CGFloat kCardContentGap  = 12.0;  // glyph → text
static const CGFloat kGlyphBox        = 26.0;
static const CGFloat kGlyphPointSize  = 22.0;
static const CGFloat kBadgeRadius     = 8.0;

static const CGFloat kCancelGap       = 16.0;  // last card → Cancel
static const CGFloat kCancelMinHeight = 54.0;

/// Floor for the bottom inset. On a device with a home indicator the inset is
/// the indicator itself; on one without, safeAreaInsets.bottom is 0 and a
/// button flush against the screen edge looks like a mistake.
static const CGFloat kMinBottomInset  = 16.0;

#pragma mark - Palette

// The tweak's own screens paint from the fixed dark palette in FBPResources.
// The sheet never has — it follows the system appearance, because it sits on a
// systemThinMaterial backdrop over Facebook's own UI. So each colour below is a
// dynamic pair: the tweak's value in dark, its light counterpart in light.

/// #1C1C1E in dark, white in light. Resting fill of an action card.
static UIColor *FBPSheetCardColor(void) {
    static UIColor *color;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        color = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? FBPCardColor()
                : UIColor.whiteColor;
        }];
    });
    return color;
}

/// Pressed fill of an action card: one visible step away from resting, in the
/// direction that reads as "lit" in each appearance.
static UIColor *FBPSheetCardPressedColor(void) {
    static UIColor *color;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        color = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithRed:48.0/255.0 green:48.0/255.0 blue:51.0/255.0 alpha:1.0]
                : [UIColor colorWithWhite:0.92 alpha:1.0];
        }];
    });
    return color;
}

/// Badge text colour.
///
/// FBPTintColor() is #B5DAFC — a dark-mode tint. On the white card of light
/// appearance it is pale blue on near-white and the badge stops being readable
/// (the preview made that plain). Light appearance therefore gets a darkened
/// version of the same hue: still recognisably the tweak's blue, but it passes
/// as text.
static UIColor *FBPSheetAccentColor(void) {
    static UIColor *color;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        color = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? FBPTintColor()
                : [UIColor colorWithRed:0.09 green:0.40 blue:0.70 alpha:1.0];
        }];
    });
    return color;
}

/// Badge capsule fill: the accent at low alpha, each appearance's own accent.
static UIColor *FBPSheetAccentFillColor(void) {
    static UIColor *color;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        color = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [FBPTintColor() colorWithAlphaComponent:0.18]
                : [[UIColor colorWithRed:0.09 green:0.40 blue:0.70 alpha:1.0]
                       colorWithAlphaComponent:0.12];
        }];
    });
    return color;
}

/// Cancel's fill. Deliberately *not* the card fill, and deliberately on the
/// other side of the backdrop from it.
///
/// The backdrop these sit on is systemThinMaterial, which settles at rgb(43,43,43)
/// in dark and rgb(203,203,203) in light (both measured on the simulator, not
/// guessed — an earlier pass picked a plausible-looking #2C2C2E and it came out
/// the same colour as the panel behind it, invisible).
///
/// The cards sit below the backdrop in dark (#1C1C1E reads as a cut-out) and
/// above it in light (white). Cancel goes the other way in each — lighter than
/// the backdrop in dark, darker in light — so it is never mistaken for one more
/// card and never disappears into the panel.
static UIColor *FBPSheetCancelColor(void) {
    static UIColor *color;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        color = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithRed:72.0/255.0 green:72.0/255.0 blue:74.0/255.0 alpha:1.0]
                : [UIColor colorWithRed:168.0/255.0 green:168.0/255.0 blue:176.0/255.0 alpha:1.0];
        }];
    });
    return color;
}

static UIColor *FBPSheetCancelPressedColor(void) {
    static UIColor *color;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        color = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithRed:96.0/255.0 green:96.0/255.0 blue:99.0/255.0 alpha:1.0]
                : [UIColor colorWithRed:144.0/255.0 green:144.0/255.0 blue:154.0/255.0 alpha:1.0];
        }];
    });
    return color;
}

/// The sheet's typeface: the plain system face, as it has always used (the
/// settings pages use FBPFont's rounded design; the sheet never has). Scaled so
/// Dynamic Type moves it, and capped so the largest sizes cannot push the
/// detent past the screen.
static UIFont *FBPSheetFont(CGFloat size, UIFontWeight weight, UIFontTextStyle style) {
    UIFont *base = [UIFont systemFontOfSize:size weight:weight];
    return [[UIFontMetrics metricsForTextStyle:style] scaledFontForFont:base
                                                      maximumPointSize:size + 7.0];
}

#pragma mark - Badge capsule

/// The tinted capsule beside a title, e.g. "Best". Hugs its text so it sits
/// tight against the title instead of stretching.
static UIView *FBPSheetBadgeCapsule(NSString *text) {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = FBPSheetFont(11, UIFontWeightSemibold, UIFontTextStyleCaption2);
    label.adjustsFontForContentSizeCategory = YES;
    label.textColor = FBPSheetAccentColor();
    label.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *capsule = [[UIView alloc] init];
    capsule.backgroundColor = FBPSheetAccentFillColor();
    capsule.layer.cornerRadius = kBadgeRadius;
    capsule.layer.cornerCurve = kCACornerCurveContinuous;
    [capsule addSubview:label];
    [capsule setContentHuggingPriority:UILayoutPriorityRequired
                               forAxis:UILayoutConstraintAxisHorizontal];
    [capsule setContentCompressionResistancePriority:UILayoutPriorityRequired
                                             forAxis:UILayoutConstraintAxisHorizontal];

    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:capsule.leadingAnchor constant:7],
        [label.trailingAnchor constraintEqualToAnchor:capsule.trailingAnchor constant:-7],
        [label.topAnchor constraintEqualToAnchor:capsule.topAnchor constant:2],
        [label.bottomAnchor constraintEqualToAnchor:capsule.bottomAnchor constant:-2],
    ]];
    return capsule;
}

/// Eats the slack between the title and the trailing detail. Hugging below
/// everything else so it is the only thing that stretches.
static UIView *FBPSheetSpacer(void) {
    UIView *spacer = [[UIView alloc] init];
    [spacer setContentHuggingPriority:UILayoutPriorityDefaultLow - 1
                              forAxis:UILayoutConstraintAxisHorizontal];
    [spacer setContentCompressionResistancePriority:UILayoutPriorityDefaultLow - 1
                                            forAxis:UILayoutConstraintAxisHorizontal];
    return spacer;
}

#pragma mark - Action card

/// One action, as its own card. A UIControl so the whole card is the tap target
/// and highlights as a unit — which is what replaces the table's row selection.
@interface FBPSheetCard : UIControl
@property (nonatomic, strong, readonly) FBPSheetAction *action;
- (instancetype)initWithAction:(FBPSheetAction *)action;
@end

@implementation FBPSheetCard

- (instancetype)initWithAction:(FBPSheetAction *)action {
    if ((self = [super initWithFrame:CGRectZero])) {
        _action = action;

        self.backgroundColor = FBPSheetCardColor();
        self.layer.cornerRadius = kCardRadius;
        self.layer.cornerCurve = kCACornerCurveContinuous;

        UIColor *tint = action.destructive ? UIColor.systemRedColor : UIColor.labelColor;

        UIImageView *glyph = [[UIImageView alloc] init];
        glyph.image = action.iconName
            ? [UIImage fbp_symbolNamed:action.iconName size:kGlyphPointSize]
            : nil;
        glyph.contentMode = UIViewContentModeScaleAspectFit;
        glyph.tintColor = tint;
        glyph.translatesAutoresizingMaskIntoConstraints = NO;

        UILabel *title = [[UILabel alloc] init];
        title.text = action.title;
        title.font = FBPSheetFont(20, UIFontWeightRegular, UIFontTextStyleBody);
        title.adjustsFontForContentSizeCategory = YES;
        title.textColor = tint;

        UILabel *detail = [[UILabel alloc] init];
        detail.text = action.detail;
        detail.font = FBPSheetFont(15, UIFontWeightRegular, UIFontTextStyleSubheadline);
        detail.adjustsFontForContentSizeCategory = YES;
        detail.textColor = UIColor.secondaryLabelColor;

        // Title and badge share a row so the capsule tracks the title's
        // baseline wherever the title ends up.
        UIStackView *titleRow = [[UIStackView alloc] initWithArrangedSubviews:@[title]];
        titleRow.axis = UILayoutConstraintAxisHorizontal;
        titleRow.alignment = UIStackViewAlignmentCenter;
        titleRow.spacing = 8;
        if (action.badge.length) {
            [titleRow addArrangedSubview:FBPSheetBadgeCapsule(action.badge)];
        }

        UIStackView *content = [[UIStackView alloc] init];
        content.axis = UILayoutConstraintAxisHorizontal;
        content.alignment = UIStackViewAlignmentCenter;
        content.spacing = kCardContentGap;
        content.userInteractionEnabled = NO;
        content.translatesAutoresizingMaskIntoConstraints = NO;
        [content addArrangedSubview:glyph];

        if (action.titleFirst) {
            // The approved layout: glyph, title (+ badge), then the detail
            // trailing on the same line. One line, one decision per card.
            [content addArrangedSubview:titleRow];
            [content addArrangedSubview:FBPSheetSpacer()];
            if (detail.text.length) [content addArrangedSubview:detail];
        } else {
            // The original order, kept because titleFirst is public and
            // defaults to NO: the grey detail on its own line above the title,
            // both stacked beside the glyph.
            NSArray<UIView *> *lines =
                detail.text.length ? @[detail, titleRow] : @[titleRow];
            UIStackView *lineStack = [[UIStackView alloc] initWithArrangedSubviews:lines];
            lineStack.axis = UILayoutConstraintAxisVertical;
            lineStack.alignment = UIStackViewAlignmentFill;
            lineStack.spacing = 2;
            [content addArrangedSubview:lineStack];
            [content addArrangedSubview:FBPSheetSpacer()];
        }

        [self addSubview:content];
        [NSLayoutConstraint activateConstraints:@[
            [glyph.widthAnchor constraintEqualToConstant:kGlyphBox],
            [glyph.heightAnchor constraintEqualToConstant:kGlyphBox],

            [content.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                                  constant:kCardInsetX],
            [content.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                   constant:-kCardInsetX],
            [content.topAnchor constraintEqualToAnchor:self.topAnchor constant:kCardInsetY],
            [content.bottomAnchor constraintEqualToAnchor:self.bottomAnchor
                                                 constant:-kCardInsetY],
            [self.heightAnchor constraintGreaterThanOrEqualToConstant:kCardMinHeight],
        ]];

        // One element per card, so VoiceOver reads the row rather than three
        // unrelated fragments.
        NSMutableArray<NSString *> *spoken = [NSMutableArray array];
        if (action.title.length) [spoken addObject:action.title];
        if (action.detail.length) [spoken addObject:action.detail];
        if (action.badge.length) [spoken addObject:action.badge];
        self.isAccessibilityElement = YES;
        self.accessibilityLabel = [spoken componentsJoinedByString:@", "];
        self.accessibilityTraits = UIAccessibilityTraitButton;
    }
    return self;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    UIColor *fill = highlighted ? FBPSheetCardPressedColor() : FBPSheetCardColor();
    [UIView animateWithDuration:0.12 animations:^{
        self.backgroundColor = fill;
    }];
}

@end

#pragma mark - Cancel button

/// Cancel, as a button rather than a card.
///
/// It is not one of the choices, so it does not look like one: a capsule
/// instead of the cards' 14pt corners, a fill on the far side of the backdrop
/// from theirs (see @c FBPSheetCancelColor), centred semibold text and no
/// glyph, with @c kCancelGap of air above it. The radius is taken from the live
/// height so Dynamic Type cannot turn the capsule into a rounded rectangle.
@interface FBPSheetCancelButton : UIControl
@end

@implementation FBPSheetCancelButton

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = FBPSheetCancelColor();
        self.layer.cornerCurve = kCACornerCurveContinuous;

        // FBPL falls back to the key itself when the resource bundle is
        // missing, and "common.cancel" on a button is worse than an
        // untranslated word.
        NSString *text = FBPL(@"common.cancel");
        if ([text isEqualToString:@"common.cancel"]) text = @"Cancel";

        UILabel *label = [[UILabel alloc] init];
        label.text = text;
        label.font = FBPSheetFont(17, UIFontWeightSemibold, UIFontTextStyleHeadline);
        label.adjustsFontForContentSizeCategory = YES;
        label.textColor = UIColor.labelColor;
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 1;
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.8;
        label.userInteractionEnabled = NO;
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:label];

        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
            [label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
            [label.topAnchor constraintEqualToAnchor:self.topAnchor constant:12],
            [label.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-12],
            [self.heightAnchor constraintGreaterThanOrEqualToConstant:kCancelMinHeight],
        ]];

        self.isAccessibilityElement = YES;
        self.accessibilityLabel = label.text;
        self.accessibilityTraits = UIAccessibilityTraitButton;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = CGRectGetHeight(self.bounds) / 2.0;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    UIColor *fill = highlighted ? FBPSheetCancelPressedColor() : FBPSheetCancelColor();
    [UIView animateWithDuration:0.12 animations:^{
        self.backgroundColor = fill;
    }];
}

@end

#pragma mark - Controller

@interface FBPSheetController ()
@property (nonatomic, copy) NSArray<FBPSheetAction *> *actions;
@property (nonatomic, copy, nullable) NSString *sheetTitle;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *stackView;
/// Held so the bottom inset can follow the safe area. The same value feeds
/// -preferredSheetHeight, which is what keeps the detent and the content the
/// same height.
@property (nonatomic, strong) NSLayoutConstraint *stackBottom;
/// The height -preferredDetentHeight last handed the detent, and how much
/// taller than it UIKit then made the view. See -viewDidLayoutSubviews.
@property (nonatomic, assign) CGFloat requestedHeight;
@property (nonatomic, assign) CGFloat sheetChrome;
/// NO until a laid-out sheet has confirmed @c sheetChrome, while which
/// -appliedChrome runs on the bottom safe area — what current iOS adds.
@property (nonatomic, assign) BOOL sheetChromeKnown;
@end

@implementation FBPSheetController

- (instancetype)initWithActions:(NSArray<FBPSheetAction *> *)actions
                          title:(NSString *)title {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _actions = [actions copy];
        _sheetTitle = [title copy];
    }
    return self;
}

#pragma mark Sizing

/// Air under the last element. The home indicator where there is one, otherwise
/// a floor so Cancel is not flush with the screen edge. Nothing beyond it — the
/// slack below the sheet's content is exactly what this replaces.
- (CGFloat)bottomInset {
    return MAX(self.view.safeAreaInsets.bottom, kMinBottomInset);
}

- (CGFloat)preferredSheetHeight {
    [self loadViewIfNeeded];

    // Measured rather than arithmetic on row constants, so Dynamic Type, a
    // wrapped title and a ladder of any length all come out right. The sheet is
    // full-width on iPhone, so the screen is the right fallback before the view
    // has a window.
    CGFloat width = CGRectGetWidth(self.view.window.bounds);
    if (width <= 0) width = CGRectGetWidth(self.view.bounds);
    if (width <= 0) width = CGRectGetWidth(UIScreen.mainScreen.bounds);

    CGSize fitting =
        [self.stackView systemLayoutSizeFittingSize:CGSizeMake(width - (kSideInset * 2.0), 0)
                      withHorizontalFittingPriority:UILayoutPriorityRequired
                            verticalFittingPriority:UILayoutPriorityFittingSizeLevel];

    // Same three terms as the content's own constraints, in the same order:
    // top inset, the stack, the bottom inset. By construction there is no
    // fourth term, which is what makes this exactly the content height.
    return kTopInset + ceil(fitting.height) + self.bottomInset;
}

/// How much taller than the resolved detent UIKit is expected to make the
/// sheet.
///
/// Every current release adds exactly the bottom safe area — measured, not
/// assumed: a 473pt detent came back as a 507pt view, 475 as 509, 457 as 491.
/// Seeding with that makes the first resolution already right, so the sheet
/// does not visibly settle after it appears. -viewDidLayoutSubviews corrects it
/// from what actually lands on screen, so this is a starting point rather than
/// a hard-coded answer.
- (CGFloat)appliedChrome {
    return self.sheetChromeKnown ? self.sheetChrome : self.view.safeAreaInsets.bottom;
}

/// What a UISheetPresentationController custom detent has to be told.
///
/// A custom detent's value is not the height of the sheet — UIKit grows the
/// sheet past it. Handing it -preferredSheetHeight left exactly one home
/// indicator of dead grey under Cancel, which is the gap the maintainer asked
/// to have removed; the difference comes off here.
///
/// -preferredSheetHeight stays the whole height, because a presentation that
/// sets the frame itself — FBPDetentPresentationController — needs that one.
- (CGFloat)preferredDetentHeight {
    [self loadViewIfNeeded];
    CGFloat height = MAX(self.preferredSheetHeight - self.appliedChrome,
                         kTopInset + self.bottomInset);
    self.requestedHeight = height;
    return height;
}

/// Correct @c sheetChrome from the empty strip actually left under Cancel.
///
/// What is measured is the view against the content it is holding *now*, not
/// against the height last requested. Requesting and being resized are separate
/// passes, so a request-based measurement reads the previous pass's view: it
/// reported 16pt of chrome where there were 34, and the sheet came out 18pt too
/// tall. The content is never stale.
///
/// Whatever is left over is fed straight back into the chrome, so one pass is
/// enough from any starting point. A drag toward the large detent opens a gap
/// wider than the chrome can legitimately be and is rejected by the bound
/// below, rather than mistaken for a correction.
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat stack = CGRectGetHeight(self.stackView.bounds);
    if (stack <= 0 || self.requestedHeight <= 0) return;

    CGFloat empty = CGRectGetHeight(self.view.bounds)
                  - (kTopInset + stack + self.bottomInset);
    if (fabs(empty) < 0.5) {          // nothing left over: this is the answer
        self.sheetChromeKnown = YES;
        return;
    }

    CGFloat chrome = self.appliedChrome + empty;
    if (chrome < 0.0 || chrome > self.bottomInset + 1.0) return;

    self.sheetChrome = chrome;
    self.sheetChromeKnown = YES;
    [self invalidateSheetHeight];
}

/// Ask UIKit to re-resolve the custom detent. Called whenever one of the terms
/// above can have moved.
- (void)invalidateSheetHeight {
    if (@available(iOS 16.0, *)) {
        [self.sheetPresentationController invalidateDetents];
    }
}

- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    self.stackBottom.constant = -self.bottomInset;
    // The safe area is what the system adds on top of the detent, so a new one
    // puts the question again.
    self.sheetChromeKnown = NO;
    [self invalidateSheetHeight];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    // Dynamic Type moves every label, so the measured stack moves with it.
    if (![previous.preferredContentSizeCategory
            isEqualToString:self.traitCollection.preferredContentSizeCategory]) {
        [self invalidateSheetHeight];
    }
}

#pragma mark Content

- (void)loadView {
    [super loadView];
    self.view.backgroundColor = UIColor.clearColor;

    UIVisualEffectView *backdrop = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
    backdrop.frame = self.view.bounds;
    backdrop.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:backdrop];
    [self.view sendSubviewToBack:backdrop];

    _stackView = [[UIStackView alloc] init];
    _stackView.axis = UILayoutConstraintAxisVertical;
    _stackView.alignment = UIStackViewAlignmentFill;
    _stackView.spacing = kCardSpacing;
    _stackView.translatesAutoresizingMaskIntoConstraints = NO;

    if (self.sheetTitle.length) {
        UILabel *title = [[UILabel alloc] init];
        title.text = self.sheetTitle;
        title.font = FBPSheetFont(17, UIFontWeightSemibold, UIFontTextStyleHeadline);
        title.adjustsFontForContentSizeCategory = YES;
        title.textColor = UIColor.labelColor;
        title.textAlignment = NSTextAlignmentCenter;
        title.numberOfLines = 0;
        [_stackView addArrangedSubview:title];
        [_stackView setCustomSpacing:kTitleGap afterView:title];
    }

    UIView *lastCard = nil;
    for (FBPSheetAction *action in self.actions) {
        FBPSheetCard *card = [[FBPSheetCard alloc] initWithAction:action];
        [card addTarget:self
                 action:@selector(cardTapped:)
       forControlEvents:UIControlEventTouchUpInside];
        [_stackView addArrangedSubview:card];
        lastCard = card;
    }

    FBPSheetCancelButton *cancel = [[FBPSheetCancelButton alloc] initWithFrame:CGRectZero];
    [cancel addTarget:self
               action:@selector(cancelTapped)
     forControlEvents:UIControlEventTouchUpInside];
    [_stackView addArrangedSubview:cancel];
    // Extra air above Cancel so it reads as separate from the choices rather
    // than as the last of them.
    if (lastCard) [_stackView setCustomSpacing:kCancelGap afterView:lastCard];

    _scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scrollView.backgroundColor = UIColor.clearColor;
    _scrollView.showsVerticalScrollIndicator = NO;
    _scrollView.alwaysBounceVertical = NO;
    // The insets below are applied by hand and already account for the safe
    // area; letting UIKit adjust as well would put the slack straight back.
    _scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [_scrollView addSubview:_stackView];
    [self.view addSubview:_scrollView];

    UILayoutGuide *content = _scrollView.contentLayoutGuide;
    UILayoutGuide *frame = _scrollView.frameLayoutGuide;
    _stackBottom = [_stackView.bottomAnchor constraintEqualToAnchor:content.bottomAnchor
                                                           constant:-self.bottomInset];

    [NSLayoutConstraint activateConstraints:@[
        [_scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [_stackView.topAnchor constraintEqualToAnchor:content.topAnchor constant:kTopInset],
        _stackBottom,
        [_stackView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor
                                                 constant:kSideInset],
        [_stackView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor
                                                  constant:-kSideInset],
        // Pins the content width to the sheet's, so the stack lays out at the
        // same width -preferredSheetHeight measures it at.
        [_stackView.widthAnchor constraintEqualToAnchor:frame.widthAnchor
                                             constant:-(kSideInset * 2.0)],
    ]];
}

#pragma mark Actions

- (void)cardTapped:(FBPSheetCard *)card {
    [self dismissWithHandler:card.action.handler];
}

- (void)cancelTapped {
    [self dismissWithHandler:nil];
}

/// Runs the handler after dismissal so anything it presents has a free stack.
- (void)dismissWithHandler:(dispatch_block_t)handler {
    [self dismissViewControllerAnimated:YES completion:^{
        if (handler) handler();
    }];
}

@end
