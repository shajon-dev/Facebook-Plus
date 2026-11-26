#import "FBPAlert.h"
#import "FBPResources.h"

// Its own window, so a caller needs no view controller and the card cannot be
// dismissed by whatever the app does to its own hierarchy underneath.
@interface FBPAlertWindow : UIWindow
@end

@implementation FBPAlertWindow
- (BOOL)canBecomeKeyWindow { return YES; }
@end

@interface FBPAlert ()
@property (nonatomic, strong) FBPAlertWindow *window;
@property (nonatomic, strong) UIView *backdrop;
@property (nonatomic, strong) UIVisualEffectView *card;
@property (nonatomic, copy, nullable) dispatch_block_t onConfirm;
@property (nonatomic, copy, nullable) dispatch_block_t onCancel;
@end

// Held while a card is on screen; released when it goes away.
static FBPAlert *gFBPAlertShowing;

@implementation FBPAlert

+ (UIWindowScene *)activeScene {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)scene;
        }
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)scene;
    }
    return nil;
}

/// Liquid glass where iOS has it, the old dark material everywhere else.
///
/// UIGlassEffect arrived in iOS 26 and the tweak builds against an older SDK,
/// so it is looked up at runtime rather than linked. A tint keeps the card
/// readable over a bright photo, which plain glass does not guarantee.
+ (UIVisualEffect *)cardEffect {
    Class glass = NSClassFromString(@"UIGlassEffect");
    if (glass) {
        id effect = [[glass alloc] init];
        if ([effect respondsToSelector:@selector(setTintColor:)]) {
            [effect setTintColor:[UIColor colorWithWhite:0.10 alpha:0.30]];
        }
        if ([effect isKindOfClass:UIVisualEffect.class]) return effect;
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark];
}

+ (UIButton *)buttonWithTitle:(NSString *)title
                       filled:(BOOL)filled
                  destructive:(BOOL)destructive
                       target:(id)target
                       action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = FBPFont(16, UIFontWeightSemibold);
    button.titleLabel.textAlignment = NSTextAlignmentCenter;
    button.layer.cornerRadius = 23.0;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.clipsToBounds = YES;
    if (filled) {
        button.backgroundColor = destructive ? UIColor.systemRedColor : FBPTintColor();
        [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    } else {
        button.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
        [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    }
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintEqualToConstant:46.0].active = YES;
    return button;
}

+ (void)showWithTitle:(NSString *)title
              message:(NSString *)message
          cancelTitle:(NSString *)cancelTitle
         confirmTitle:(NSString *)confirmTitle
          destructive:(BOOL)destructive
            onConfirm:(dispatch_block_t)onConfirm
             onCancel:(dispatch_block_t)onCancel {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showWithTitle:title message:message cancelTitle:cancelTitle
                   confirmTitle:confirmTitle destructive:destructive
                      onConfirm:onConfirm onCancel:onCancel];
        });
        return;
    }
    UIWindowScene *scene = [self activeScene];
    if (!scene) return;

    FBPAlert *alert = [[FBPAlert alloc] init];
    alert.onConfirm = onConfirm;
    alert.onCancel = onCancel;

    FBPAlertWindow *window = [[FBPAlertWindow alloc] initWithWindowScene:scene];
    window.windowLevel = UIWindowLevelAlert + 50;
    window.backgroundColor = UIColor.clearColor;
    window.rootViewController = [[UIViewController alloc] init];
    window.rootViewController.view.backgroundColor = UIColor.clearColor;
    alert.window = window;

    UIView *host = window.rootViewController.view;

    UIView *backdrop = [[UIView alloc] initWithFrame:host.bounds];
    backdrop.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    backdrop.alpha = 0.0;
    [host addSubview:backdrop];
    alert.backdrop = backdrop;

    UIVisualEffectView *card = [[UIVisualEffectView alloc] initWithEffect:[self cardEffect]];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = 26.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.clipsToBounds = YES;
    [host addSubview:card];
    alert.card = card;

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = title;
    titleLabel.font = FBPFont(17, UIFontWeightSemibold);
    titleLabel.textColor = UIColor.whiteColor;
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.numberOfLines = 0;

    UILabel *messageLabel = [[UILabel alloc] init];
    messageLabel.text = message ?: @"";
    messageLabel.font = FBPFont(13.5, UIFontWeightRegular);
    messageLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.78];
    messageLabel.textAlignment = NSTextAlignmentCenter;
    messageLabel.numberOfLines = 0;
    messageLabel.hidden = (message.length == 0);

    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    if (cancelTitle.length) {
        [buttons addObject:[self buttonWithTitle:cancelTitle filled:NO destructive:NO
                                          target:alert action:@selector(cancelTapped)]];
    }
    [buttons addObject:[self buttonWithTitle:confirmTitle filled:YES destructive:destructive
                                      target:alert action:@selector(confirmTapped)]];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:buttons];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    row.spacing = 10.0;

    UIStackView *stack = [[UIStackView alloc]
        initWithArrangedSubviews:@[ titleLabel, messageLabel, row ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 8.0;
    [stack setCustomSpacing:20.0 afterView:messageLabel];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card.contentView addSubview:stack];

    CGFloat width = MIN(300.0, CGRectGetWidth(host.bounds) - 72.0);
    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:host.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:host.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:width],
        [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:24.0],
        [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:20.0],
        [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-20.0],
        [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-20.0],
    ]];

    gFBPAlertShowing = alert;
    [window makeKeyAndVisible];

    card.alpha = 0.0;
    card.transform = CGAffineTransformMakeScale(1.08, 1.08);
    [UIView animateWithDuration:0.22 delay:0.0
         usingSpringWithDamping:0.9 initialSpringVelocity:0.0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        backdrop.alpha = 1.0;
        card.alpha = 1.0;
        card.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)dismissThen:(dispatch_block_t)handler {
    [UIView animateWithDuration:0.16 animations:^{
        self.backdrop.alpha = 0.0;
        self.card.alpha = 0.0;
        self.card.transform = CGAffineTransformMakeScale(0.96, 0.96);
    } completion:^(__unused BOOL finished) {
        self.window.hidden = YES;
        self.window = nil;
        if (gFBPAlertShowing == self) gFBPAlertShowing = nil;
        if (handler) handler();
    }];
}

- (void)confirmTapped { [self dismissThen:self.onConfirm]; }
- (void)cancelTapped { [self dismissThen:self.onCancel]; }

@end
