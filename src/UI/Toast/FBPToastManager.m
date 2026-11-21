// Queues, stacks and repositions live toasts, tracking keyboard and tab-bar
// changes so the stack stays clear of them.

#import "FBPToast.h"
#import <objc/runtime.h>

/// Each toast owns its bottom constraint; it is stashed on the view so restacking
/// mutates the existing constraint instead of piling up new ones.
static const void *kBottomConstraintKey = &kBottomConstraintKey;

static NSLayoutConstraint *FBPBottomConstraint(UIView *view) {
    return objc_getAssociatedObject(view, kBottomConstraintKey);
}

static void FBPSetBottomConstraint(UIView *view, NSLayoutConstraint *constraint) {
    objc_setAssociatedObject(view, kBottomConstraintKey, constraint,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static const CGFloat kBottomInset  = 24.0;
static const CGFloat kToastSpacing = 8.0;
static const CGFloat kTabBarHeight = 49.0;

@interface FBPToastManager ()
@property (nonatomic, strong) NSMutableArray<FBPToastView *> *toasts;
@property (nonatomic, strong, nullable) FBPToastWindow *window;
@property (nonatomic, assign) CGFloat keyboardHeight;
/// 0 = tab bar fully visible, 1 = fully hidden. Driven by the tab-bar hook.
@property (nonatomic, assign) CGFloat tabBarFraction;
@end

@implementation FBPToastManager

+ (FBPToastManager *)shared {
    static FBPToastManager *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [[self alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _toasts = [NSMutableArray array];
        [self setupObservers];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)setupObservers {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self
               selector:@selector(keyboardWillShow:)
                   name:UIKeyboardWillShowNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(keyboardWillHide:)
                   name:UIKeyboardWillHideNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(tabBarVisibilityDidChange:)
                   name:FBPTabBarVisibilityDidChangeNotification
                 object:nil];
}

#pragma mark - Window

- (FBPToastWindow *)ensureWindow {
    if (_window) return _window;

    UIWindow *key = [FBPToastWindow appKeyWindow];
    UIWindowScene *scene = key.windowScene;
    if (!scene) return nil;

    _window = [[FBPToastWindow alloc] initWithWindowScene:scene];
    _window.frame = scene.coordinateSpace.bounds;
    [_window makeKeyAndVisible];
    return _window;
}

#pragma mark - Registration

- (void)registerToast:(FBPToastView *)toast {
    FBPToastWindow *window = [self ensureWindow];
    if (!window) return;

    UIView *host = window.rootViewController.view;
    if (!host) return;

    // Place the toast initially at the bottom-middle of the host view before
    // constraints are resolved, ensuring its layer position never originates at (0, 0).
    CGFloat screenWidth = CGRectGetWidth(host.bounds) ?: UIScreen.mainScreen.bounds.size.width;
    CGFloat screenHeight = CGRectGetHeight(host.bounds) ?: UIScreen.mainScreen.bounds.size.height;
    CGFloat initialWidth = 160.0;
    CGFloat initialHeight = 46.0;
    toast.frame = CGRectMake((screenWidth - initialWidth) / 2.0,
                             screenHeight - initialHeight - kBottomInset,
                             initialWidth,
                             initialHeight);

    if (![self.toasts containsObject:toast]) [self.toasts addObject:toast];
    [host addSubview:toast];

    [NSLayoutConstraint activateConstraints:@[
        [toast.centerXAnchor constraintEqualToAnchor:host.centerXAnchor],
    ]];

    // Settle layout synchronously without animation so the toast snaps firmly into
    // its resting bottom-middle position before its appearance animation begins.
    [UIView performWithoutAnimation:^{
        [self updateToastConstraints];
        [host layoutIfNeeded];
    }];
}

- (void)unregisterToast:(FBPToastView *)toast {
    [self.toasts removeObject:toast];
    if (self.toasts.count == 0) {
        self.window.hidden = YES;
        self.window = nil;
    } else {
        [self updateAllToasts];
    }
}

#pragma mark - Layout

/// Calculate and apply bottom constraints for all active toasts.
- (void)updateToastConstraints {
    UIView *host = self.window.rootViewController.view;
    if (!host) return;

    CGFloat bottomSafe = host.safeAreaInsets.bottom;
    CGFloat tabBarOffset = kTabBarHeight * (1.0 - self.tabBarFraction);
    CGFloat base = kBottomInset + bottomSafe + tabBarOffset;
    if (self.keyboardHeight > 0) {
        base = kBottomInset + self.keyboardHeight;
    }

    __block CGFloat offset = base;
    [self.toasts enumerateObjectsWithOptions:NSEnumerationReverse
                                  usingBlock:^(FBPToastView *toast, NSUInteger idx, BOOL *stop) {
        CGFloat height = CGRectGetHeight(toast.bounds) ?: 46.0;
        CGFloat target = -offset;
        offset += height + kToastSpacing;

        NSLayoutConstraint *existing = FBPBottomConstraint(toast);
        if (existing) {
            existing.constant = target;
        } else {
            NSLayoutConstraint *bottom =
                [toast.bottomAnchor constraintEqualToAnchor:host.bottomAnchor
                                                   constant:target];
            bottom.active = YES;
            FBPSetBottomConstraint(toast, bottom);
        }
    }];
}

/// Stack toasts upward from the bottom so a newer one never covers an older one.
- (void)updateAllToasts {
    UIView *host = self.window.rootViewController.view;
    if (!host) return;

    [self updateToastConstraints];
    [UIView animateWithDuration:0.25 animations:^{ [host layoutIfNeeded]; }];
}

#pragma mark - Notifications

- (void)keyboardWillShow:(NSNotification *)note {
    CGRect frame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    self.keyboardHeight = CGRectGetHeight(frame);
    [self updateAllToasts];
}

- (void)keyboardWillHide:(NSNotification *)note {
    self.keyboardHeight = 0;
    [self updateAllToasts];
}

- (void)tabBarVisibilityDidChange:(NSNotification *)note {
    NSNumber *fraction = note.userInfo[FBPTabBarFractionKey];
    if (![fraction isKindOfClass:NSNumber.class]) return;
    self.tabBarFraction = MAX(0.0, MIN(1.0, fraction.doubleValue));
    [self updateAllToasts];
}

#pragma mark - Convenience

- (FBPToastView *)showMessage:(NSString *)text success:(BOOL)success {
    FBPToastView *toast = [[FBPToastView alloc] init];
    [toast showMessage:text success:success];
    return toast;
}

- (FBPToastView *)showProgress:(NSString *)text
                stopCompletion:(dispatch_block_t)stopCompletion {
    FBPToastView *toast = [[FBPToastView alloc] init];
    [toast showProgressWithText:text
                       progress:0
                       withStop:(stopCompletion != nil)
                 stopCompletion:stopCompletion];
    return toast;
}

@end
