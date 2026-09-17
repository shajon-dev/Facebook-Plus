// Update screen. Mirrors FBPWelcomeController's look — dark branded gradient,
// logo header, a scrollable body — but the body is the new version's changelog
// and the actions are two download buttons.

#import "FBPUpdateController.h"
#import "FBPPrefs.h"
#import "FBPResources.h"
#import "FBPSheet.h"

static NSString *const kTelegramURL = @"https://t.me/ReFacebookPlus";
static NSString *const kGitHubURL =
    @"https://github.com/SHAJON-404/Facebook-Plus/releases/latest/";

static const CGFloat kLogoSize     = 46.0;
static const CGFloat kSideMargin   = 24.0;
static const CGFloat kButtonHeight = 54.0;

@interface FBPUpdateController ()
@property (nonatomic, copy) NSString *version;
@property (nonatomic, copy) NSString *changelog;
@property (nonatomic, strong) CAGradientLayer *backgroundGradient;
@end

@implementation FBPUpdateController

- (instancetype)initWithVersion:(NSString *)version changelog:(NSString *)changelog {
    if ((self = [super init])) {
        _version = [version stringByTrimmingCharactersInSet:
                    [NSCharacterSet characterSetWithCharactersInString:@"vV "]];
        _changelog = changelog.length ? changelog : FBPL(@"update.nochangelog");
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = UIColor.blackColor;
    [self buildBackground];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsVerticalScrollIndicator = NO;
    [self.view addSubview:scroll];

    UIStackView *content = [[UIStackView alloc] init];
    content.axis = UILayoutConstraintAxisVertical;
    content.alignment = UIStackViewAlignmentFill;
    content.spacing = 18;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:content];

    [content addArrangedSubview:[self headerView]];
    [content addArrangedSubview:[self changelogCard]];

    UIView *bottom = [self bottomBar];
    [self.view addSubview:bottom];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:bottom.topAnchor],

        [content.topAnchor constraintEqualToAnchor:scroll.topAnchor constant:28],
        [content.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:-24],
        [content.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:kSideMargin],
        [content.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-kSideMargin],

        [bottom.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [bottom.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [bottom.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.backgroundGradient.frame = self.view.bounds;
}

#pragma mark - Background

- (void)buildBackground {
    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.colors = @[
        (id)[UIColor colorWithRed:0.07 green:0.11 blue:0.20 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.02 green:0.03 blue:0.06 alpha:1.0].CGColor,
        (id)UIColor.blackColor.CGColor,
    ];
    gradient.locations = @[@0.0, @0.55, @1.0];
    [self.view.layer insertSublayer:gradient atIndex:0];
    self.backgroundGradient = gradient;
}

#pragma mark - Header

- (UIView *)headerView {
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 10;

    UIImage *logo = [[UIImage imageNamed:@"logo"
                               inBundle:NSBundle.fbp_resourceBundle
          compatibleWithTraitCollection:nil]
                       imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    if (logo) {
        UIImageView *logoView = [[UIImageView alloc] initWithImage:logo];
        logoView.contentMode = UIViewContentModeScaleAspectFit;
        logoView.layer.cornerRadius = 10;
        logoView.layer.cornerCurve = kCACornerCurveContinuous;
        logoView.clipsToBounds = YES;
        logoView.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [logoView.widthAnchor constraintEqualToConstant:kLogoSize],
            [logoView.heightAnchor constraintEqualToConstant:kLogoSize],
        ]];
        [stack addArrangedSubview:logoView];
    }

    UILabel *title = [[UILabel alloc] init];
    title.text = FBPL(@"update.title");
    title.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    title.textColor = UIColor.labelColor;
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 0;
    [stack addArrangedSubview:title];

    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.text = [NSString stringWithFormat:FBPL(@"update.subtitle"), self.version];
    subtitle.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    subtitle.textColor = UIColor.secondaryLabelColor;
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.numberOfLines = 0;
    [stack addArrangedSubview:subtitle];

    return stack;
}

#pragma mark - Changelog

- (UIView *)changelogCard {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor.labelColor colorWithAlphaComponent:0.08];
    card.layer.cornerRadius = 16;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *heading = [[UILabel alloc] init];
    heading.text = FBPL(@"update.whatsnew");
    heading.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    heading.textColor = UIColor.secondaryLabelColor;
    heading.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:heading];

    UILabel *body = [[UILabel alloc] init];
    body.text = self.changelog;
    body.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    body.textColor = UIColor.labelColor;
    body.numberOfLines = 0;
    body.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:body];

    [NSLayoutConstraint activateConstraints:@[
        [heading.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [heading.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [heading.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],

        [body.topAnchor constraintEqualToAnchor:heading.bottomAnchor constant:10],
        [body.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [body.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [body.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
    ]];
    return card;
}

#pragma mark - Bottom bar

- (UIView *)bottomBar {
    UIView *bar = [[UIView alloc] init];
    bar.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];
    bar.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *hairline = [[UIView alloc] init];
    hairline.backgroundColor = [UIColor.labelColor colorWithAlphaComponent:0.12];
    hairline.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:hairline];

    // GitHub on top, Telegram below, then Later — all the same card-box style.
    UIButton *github = [self cardButtonWithImage:@"github" title:FBPL(@"update.github")
                                       tintImage:YES action:@selector(openGitHub)];
    UIButton *telegram = [self cardButtonWithImage:@"telegram" title:FBPL(@"update.telegram")
                                         tintImage:NO action:@selector(openTelegram)];
    UIButton *later = [self cardButtonWithImage:nil title:FBPL(@"update.later")
                                      tintImage:NO action:@selector(dismissTapped)];

    [bar addSubview:github];
    [bar addSubview:telegram];
    [bar addSubview:later];

    [NSLayoutConstraint activateConstraints:@[
        [hairline.topAnchor constraintEqualToAnchor:bar.topAnchor],
        [hairline.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
        [hairline.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor],
        [hairline.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale],

        [github.topAnchor constraintEqualToAnchor:bar.topAnchor constant:16],
        [github.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:kSideMargin],
        [github.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-kSideMargin],
        [github.heightAnchor constraintEqualToConstant:kButtonHeight],

        [telegram.topAnchor constraintEqualToAnchor:github.bottomAnchor constant:12],
        [telegram.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:kSideMargin],
        [telegram.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-kSideMargin],
        [telegram.heightAnchor constraintEqualToConstant:kButtonHeight],

        [later.topAnchor constraintEqualToAnchor:telegram.bottomAnchor constant:12],
        [later.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:kSideMargin],
        [later.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-kSideMargin],
        [later.heightAnchor constraintEqualToConstant:kButtonHeight],
        [later.bottomAnchor constraintEqualToAnchor:bar.safeAreaLayoutGuide.bottomAnchor constant:-14],
    ]];
    return bar;
}

/// A full-width rounded "card" button: a faint fill, a leading brand icon
/// (optional), and a centred title — used for all three actions so they read as
/// one set.
- (UIButton *)cardButtonWithImage:(NSString *)imageName
                            title:(NSString *)title
                        tintImage:(BOOL)tintImage
                           action:(SEL)action {
    NSDictionary *attrs =
        @{ NSFontAttributeName : [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold] };

    UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
    cfg.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:attrs];
    cfg.baseForegroundColor = UIColor.labelColor;
    cfg.imagePadding = 10;

    if (imageName.length) {
        // A brand icon shows in its own colours; a monochrome one is tinted white.
        UIImage *icon = tintImage
            ? [UIImage fbp_imageNamed:imageName]
            : [[UIImage imageNamed:imageName
                          inBundle:NSBundle.fbp_resourceBundle
             compatibleWithTraitCollection:nil]
                 imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
        if (icon) {
            UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
            fmt.opaque = NO;
            CGSize target = CGSizeMake(22, 22);
            UIGraphicsImageRenderer *renderer =
                [[UIGraphicsImageRenderer alloc] initWithSize:target format:fmt];
            icon = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                [icon drawInRect:CGRectMake(0, 0, target.width, target.height)];
            }];
            cfg.image = [icon imageWithRenderingMode:tintImage
                                ? UIImageRenderingModeAlwaysTemplate
                                : UIImageRenderingModeAlwaysOriginal];
        }
    }

    UIButton *button = [UIButton buttonWithConfiguration:cfg primaryAction:nil];
    button.tintColor = UIColor.labelColor;
    button.backgroundColor = [UIColor.labelColor colorWithAlphaComponent:0.10];
    button.layer.cornerRadius = 16;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

#pragma mark - Actions

- (void)openTelegram { [self openURLString:kTelegramURL]; }
- (void)openGitHub   { [self openURLString:kGitHubURL]; }
- (void)dismissTapped { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)openURLString:(NSString *)string {
    NSURL *url = [NSURL URLWithString:string];
    if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}

@end
