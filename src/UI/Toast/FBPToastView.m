// The toast pill: a translucent dark capsule with a leading badge, a message
// label and an optional progress bar. The badge carries the Facebook Plus app
// logo for a normal message, and a red cross for a failure so errors still read
// at a glance.

#import "FBPToast.h"
#import "FBPResources.h"

static const CGFloat kToastHeight   = 46.0;
static const CGFloat kToastMinWidth = 160.0;
static const CGFloat kToastPadding  = 16.0;
static const CGFloat kToastRadius   = 23.0;
static const CGFloat kBadgeSize     = 26.0;
static const CGFloat kBadgeRadius   = 7.0;

@interface FBPToastView ()
@property (nonatomic, strong) UIView *content;
@property (nonatomic, strong) UIView *badge;
@property (nonatomic, strong) UILabel *toastLabel;
@property (nonatomic, strong) UIImageView *toastIcon;
@property (nonatomic, strong) UIButton *toastButton;
@property (nonatomic, strong) UIProgressView *toastProgress;
@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;
@property (nonatomic, strong) NSLayoutConstraint *iconWidth;
@property (nonatomic, strong) NSLayoutConstraint *iconHeight;
@property (nonatomic, copy, nullable) dispatch_block_t stopCompletion;
@property (nonatomic, assign) BOOL isAnimating;
@property (nonatomic, assign, readwrite) BOOL isProcessing;
@property (nonatomic, strong) NSLayoutConstraint *widthConstraint;
@end

@implementation FBPToastView

- (instancetype)init {
    if ((self = [super initWithFrame:CGRectZero])) {
        [self buildInterface];
    }
    return self;
}

- (void)buildInterface {
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.backgroundColor = UIColor.clearColor;
    self.clipsToBounds = NO;
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.40;
    self.layer.shadowRadius = 14.0;
    self.layer.shadowOffset = CGSizeMake(0, 5);

    _content = [[UIView alloc] init];
    _content.translatesAutoresizingMaskIntoConstraints = NO;
    _content.clipsToBounds = YES;
    _content.layer.cornerRadius = kToastRadius;
    _content.layer.cornerCurve = kCACornerCurveContinuous;
    _content.layer.borderWidth = 1.0;
    _content.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.14].CGColor;
    _content.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.14 alpha:0.95];
    [self addSubview:_content];

    UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark];
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:effect];
    blurView.translatesAutoresizingMaskIntoConstraints = NO;
    blurView.clipsToBounds = YES;
    blurView.layer.cornerRadius = kToastRadius;
    blurView.layer.cornerCurve = kCACornerCurveContinuous;
    blurView.userInteractionEnabled = NO;
    [_content addSubview:blurView];

    UIView *content = _content;

    // The leading badge. It carries the app logo for a normal message (no tinted
    // disc behind it — the logo reads as a mini app icon), and a red cross disc
    // for a failure.
    _badge = [[UIView alloc] init];
    _badge.translatesAutoresizingMaskIntoConstraints = NO;
    _badge.layer.cornerRadius = kBadgeRadius;
    _badge.layer.cornerCurve = kCACornerCurveContinuous;

    _toastIcon = [[UIImageView alloc] init];
    _toastIcon.contentMode = UIViewContentModeScaleAspectFit;
    _toastIcon.translatesAutoresizingMaskIntoConstraints = NO;
    _toastIcon.clipsToBounds = YES;
    _toastIcon.layer.cornerCurve = kCACornerCurveContinuous;
    [_badge addSubview:_toastIcon];

    _activityIndicator = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _activityIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    _activityIndicator.hidesWhenStopped = YES;
    _activityIndicator.color = UIColor.whiteColor;
    [_badge addSubview:_activityIndicator];

    _toastLabel = [[UILabel alloc] init];
    _toastLabel.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightSemibold];
    _toastLabel.textColor = UIColor.whiteColor;
    _toastLabel.numberOfLines = 1;
    _toastLabel.textAlignment = NSTextAlignmentLeft;
    _toastLabel.adjustsFontSizeToFitWidth = YES;
    _toastLabel.minimumScaleFactor = 0.8;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[_badge, _toastLabel]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 12;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:row];

    _toastProgress = [[UIProgressView alloc]
        initWithProgressViewStyle:UIProgressViewStyleDefault];
    _toastProgress.progressTintColor = FBPTintColor();
    _toastProgress.trackTintColor = [UIColor colorWithWhite:1.0 alpha:0.15];
    _toastProgress.translatesAutoresizingMaskIntoConstraints = NO;
    _toastProgress.hidden = YES;
    [content addSubview:_toastProgress];

    _toastButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_toastButton setImage:[UIImage fbp_symbolNamed:@"stop.circle" size:18]
                  forState:UIControlStateNormal];
    _toastButton.tintColor = UIColor.whiteColor;
    _toastButton.translatesAutoresizingMaskIntoConstraints = NO;
    _toastButton.hidden = YES;
    [_toastButton addTarget:self
                     action:@selector(cancelButtonTapped)
           forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:_toastButton];

    _widthConstraint = [self.widthAnchor constraintGreaterThanOrEqualToConstant:kToastMinWidth];
    _iconWidth  = [_toastIcon.widthAnchor constraintEqualToConstant:kBadgeSize];
    _iconHeight = [_toastIcon.heightAnchor constraintEqualToConstant:kBadgeSize];

    [NSLayoutConstraint activateConstraints:@[
        [_content.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_content.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_content.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_content.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

        [blurView.leadingAnchor constraintEqualToAnchor:_content.leadingAnchor],
        [blurView.trailingAnchor constraintEqualToAnchor:_content.trailingAnchor],
        [blurView.topAnchor constraintEqualToAnchor:_content.topAnchor],
        [blurView.bottomAnchor constraintEqualToAnchor:_content.bottomAnchor],

        [self.heightAnchor constraintEqualToConstant:kToastHeight],
        _widthConstraint,

        [_badge.widthAnchor constraintEqualToConstant:kBadgeSize],
        [_badge.heightAnchor constraintEqualToConstant:kBadgeSize],
        [_toastIcon.centerXAnchor constraintEqualToAnchor:_badge.centerXAnchor],
        [_toastIcon.centerYAnchor constraintEqualToAnchor:_badge.centerYAnchor],
        _iconWidth,
        _iconHeight,
        [_activityIndicator.centerXAnchor constraintEqualToAnchor:_badge.centerXAnchor],
        [_activityIndicator.centerYAnchor constraintEqualToAnchor:_badge.centerYAnchor],

        [row.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [row.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        [row.leadingAnchor constraintGreaterThanOrEqualToAnchor:content.leadingAnchor
                                                        constant:kToastPadding],
        [row.trailingAnchor constraintLessThanOrEqualToAnchor:content.trailingAnchor
                                                     constant:-kToastPadding],

        [_toastButton.trailingAnchor constraintEqualToAnchor:content.trailingAnchor
                                                    constant:-kToastPadding],
        [_toastButton.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],

        [_toastProgress.leadingAnchor constraintEqualToAnchor:content.leadingAnchor
                                                     constant:kToastPadding + 4],
        [_toastProgress.trailingAnchor constraintEqualToAnchor:content.trailingAnchor
                                                      constant:-(kToastPadding + 4)],
        [_toastProgress.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-5],
    ]];

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
    [self addGestureRecognizer:tap];
}

#pragma mark - Badge content

// The app logo, rounded so it reads as a mini app icon in the badge. Kept in its
// original colours (not tinted), unlike a symbol glyph.
- (void)showAppLogo {
    self.badge.backgroundColor = UIColor.clearColor;
    self.toastIcon.hidden = NO;
    self.toastIcon.tintColor = nil;
    self.toastIcon.layer.cornerRadius = 6.0;
    self.iconWidth.constant = kBadgeSize;
    self.iconHeight.constant = kBadgeSize;
    self.toastIcon.image =
        [[UIImage fbp_imageNamed:@"logo"] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

- (void)showFailureGlyph {
    self.badge.backgroundColor = [UIColor colorWithRed:0.85 green:0.20 blue:0.20 alpha:1.0];
    self.toastIcon.hidden = NO;
    self.toastIcon.tintColor = UIColor.whiteColor;
    self.toastIcon.layer.cornerRadius = 0.0;
    self.iconWidth.constant = 13.0;
    self.iconHeight.constant = 13.0;
    self.toastIcon.image = [UIImage fbp_symbolNamed:@"xmark" size:13 weight:UIImageSymbolWeightBold];
}

#pragma mark - Public

- (void)showText:(NSString *)text {
    [self showMessage:text success:YES duration:2.0];
}

- (void)showMessage:(NSString *)text success:(BOOL)success {
    [self showMessage:text success:success duration:2.0];
}

- (void)showMessage:(NSString *)text success:(BOOL)success duration:(NSTimeInterval)duration {
    self.isProcessing = NO;
    self.title = text;
    self.toastLabel.text = text;
    self.toastProgress.hidden = YES;
    self.toastButton.hidden = YES;
    [self.activityIndicator stopAnimating];

    self.badge.hidden = NO;
    if (success) {
        [self showAppLogo];
    } else {
        [self showFailureGlyph];
    }

    [self presentIfNeeded];
    [self hideWithDelay:duration];
}

- (void)showProgressWithText:(NSString *)text
                    progress:(float)progress
                    withStop:(BOOL)withStop
              stopCompletion:(dispatch_block_t)stopCompletion {
    self.isProcessing = YES;
    self.title = text;
    self.stopCompletion = stopCompletion;

    self.toastLabel.text = text;
    self.toastIcon.hidden = YES;
    self.badge.hidden = NO;
    self.badge.backgroundColor = [FBPTintColor() colorWithAlphaComponent:0.22];
    [self.activityIndicator startAnimating];
    self.toastProgress.hidden = NO;
    [self.toastProgress setProgress:progress animated:NO];
    self.toastButton.hidden = !withStop;

    [self presentIfNeeded];
}

- (void)updateText:(NSString *)text progress:(float)progress {
    [self updateText:text progress:progress animated:YES];
}

- (void)updateText:(NSString *)text progress:(float)progress animated:(BOOL)animated {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (text.length) {
            self.title = text;
            self.toastLabel.text =
                [NSString stringWithFormat:@"%@: %.0f%%", text, progress * 100.0];
        }
        [self.toastProgress setProgress:progress animated:animated];
    });
}

- (void)hideWithDelay:(NSTimeInterval)delay {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self hideWithCompletion:nil];
    });
}

- (void)hideWithCompletion:(dispatch_block_t)completion {
    if (self.isAnimating) return;
    self.isAnimating = YES;

    [UIView animateWithDuration:0.24
                          delay:0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        self.alpha = 0;
        self.transform = CGAffineTransformMakeTranslation(0, 12);
    } completion:^(BOOL finished) {
        [FBPToastManager.shared unregisterToast:self];
        [self removeFromSuperview];
        self.transform = CGAffineTransformIdentity;
        self.isAnimating = NO;
        if (completion) completion();
    }];
}

#pragma mark - Private

- (void)presentIfNeeded {
    if (self.superview) return;
    self.alpha = 0;
    self.transform = CGAffineTransformMakeTranslation(0, 16);
    [FBPToastManager.shared registerToast:self];
    [UIView animateWithDuration:0.42
                          delay:0
         usingSpringWithDamping:0.86
          initialSpringVelocity:0.2
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.alpha = 1;
        self.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)cancelButtonTapped {
    dispatch_block_t stop = self.stopCompletion;
    self.stopCompletion = nil;
    if (stop) stop();
    [self hideWithCompletion:nil];
}

- (void)handleTap {
    if (!self.isProcessing) [self hideWithCompletion:nil];
}

@end
