// Bottom action sheet: the action model, its content-sized controller, the
// presenter, and a custom detent presentation for older iOS.

#import "FBPlus.h"

NS_ASSUME_NONNULL_BEGIN

/// One card in an action sheet.
///
/// By default the card renders @c detail above @c title — the detail small and
/// grey on top, the title large underneath. @c titleFirst turns that around for
/// callers whose title is the thing to read first; see below.
@interface FBPSheetAction : NSObject

@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *detail;
/// SF Symbol name for the leading glyph.
@property (nonatomic, copy, nullable) NSString *iconName;
@property (nonatomic, assign) BOOL destructive;
@property (nonatomic, copy, nullable) dispatch_block_t handler;

/// Short tinted capsule beside the title, e.g. "Best". Nil for no capsule.
///
/// Additive: a card that does not set it renders exactly as it did before this
/// existed.
@property (nonatomic, copy, nullable) NSString *badge;

/// Put @c title on the first line and @c detail underneath, instead of the
/// default detail-above-title order.
///
/// Defaults to NO, which keeps the two labels stacked inside the card: the grey
/// detail on its own line above the title, same fonts, colours and 2pt gap as
/// before. Set it when the title carries the decision and the detail only
/// qualifies it, which is what the download quality picker needs: a card there
/// has to read "1080p" first and "~24.8 MB, estimated" second. With it set the
/// card reads on one line — title (and badge) leading, detail trailing — which
/// is the layout the picker was designed around.
@property (nonatomic, assign) BOOL titleFirst;

+ (instancetype)actionWithTitle:(NSString *)title
                         detail:(nullable NSString *)detail
                       iconName:(nullable NSString *)iconName
                        handler:(nullable dispatch_block_t)handler;

@end

/// Content-sized bottom sheet: one rounded card per action, with Cancel as a
/// button of its own underneath.
@interface FBPSheetController : UIViewController

- (instancetype)initWithActions:(NSArray<FBPSheetAction *> *)actions
                          title:(nullable NSString *)title;

/// Height the whole sheet wants: the measured content and its two insets, and
/// nothing else. This is the figure a presentation that sets the frame itself
/// needs — @c FBPDetentPresentationController below.
@property (nonatomic, readonly) CGFloat preferredSheetHeight;

/// The same height as a @c UISheetPresentationController custom detent wants
/// it. UIKit makes the sheet taller than the detent it resolved — every current
/// release by exactly the bottom safe area — so that difference is already
/// taken off here. Detents want this one; a hand-set frame wants
/// @c preferredSheetHeight, and mixing them up leaves a strip of empty sheet
/// under the last element.
///
/// Re-read on every detent resolution, so it is safe to call repeatedly and at
/// any point after init.
@property (nonatomic, readonly) CGFloat preferredDetentHeight;

@end

@interface FBPSheetPresenter : NSObject

+ (void)presentActions:(NSArray<FBPSheetAction *> *)actions
                 title:(nullable NSString *)title
    fromViewController:(nullable UIViewController *)viewController
            sourceView:(nullable UIView *)sourceView;

/// Best-effort topmost presented controller, for hooks that only have a view.
+ (nullable UIViewController *)topViewController;

@end

/// Fallback half-sheet presentation for iOS < 15, and for the cases where a
/// precise pixel height is wanted that native detents cannot express.
@interface FBPDetentPresentationController : UIPresentationController
@property (nonatomic, assign) CGFloat customHeight;
@end

@interface FBPDetentTransitioningDelegate : NSObject <UIViewControllerTransitioningDelegate>
@property (nonatomic, assign) CGFloat customHeight;
@end

NS_ASSUME_NONNULL_END
