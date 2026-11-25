// Bottom action sheet: action model, controller, presenter, detent fallback.

#import "FBPlus.h"

NS_ASSUME_NONNULL_BEGIN

/// One card. Renders @c detail above @c title unless @c titleFirst is set.
@interface FBPSheetAction : NSObject

@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *detail;
@property (nonatomic, copy, nullable) NSString *iconName;
@property (nonatomic, assign) BOOL destructive;
@property (nonatomic, copy, nullable) dispatch_block_t handler;

/// Short tinted capsule beside the title, e.g. "Best". Nil for no capsule.
@property (nonatomic, copy, nullable) NSString *badge;

/// One-line layout: title (and badge) leading, detail trailing. Defaults to NO.
@property (nonatomic, assign) BOOL titleFirst;

+ (instancetype)actionWithTitle:(NSString *)title
                         detail:(nullable NSString *)detail
                       iconName:(nullable NSString *)iconName
                        handler:(nullable dispatch_block_t)handler;

@end

@interface FBPSheetController : UIViewController

- (instancetype)initWithActions:(NSArray<FBPSheetAction *> *)actions
                          title:(nullable NSString *)title;

/// Measured content plus insets: what a self-framing presentation needs.
@property (nonatomic, readonly) CGFloat preferredSheetHeight;

/// For a custom detent: UIKit makes the sheet taller than the detent it
/// resolved by the bottom safe area, so that is already subtracted here.
@property (nonatomic, readonly) CGFloat preferredDetentHeight;

@end

@interface FBPSheetPresenter : NSObject

+ (void)presentActions:(NSArray<FBPSheetAction *> *)actions
                 title:(nullable NSString *)title
    fromViewController:(nullable UIViewController *)viewController
            sourceView:(nullable UIView *)sourceView;

+ (nullable UIViewController *)topViewController;

@end

/// Fallback half-sheet for iOS < 15 and for exact pixel heights.
@interface FBPDetentPresentationController : UIPresentationController
@property (nonatomic, assign) CGFloat customHeight;
@end

@interface FBPDetentTransitioningDelegate : NSObject <UIViewControllerTransitioningDelegate>
@property (nonatomic, assign) CGFloat customHeight;
@end

NS_ASSUME_NONNULL_END
