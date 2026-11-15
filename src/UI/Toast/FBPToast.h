// HUD toast stack: the pill view, its hosting window, and the manager that
// queues and repositions live toasts.

#import "FBPlus.h"

NS_ASSUME_NONNULL_BEGIN

/// A single HUD pill.
///
/// Three shapes: a plain message, a message with the app logo (or a failure
/// glyph), and an indeterminate-or-determinate progress row with an optional
/// stop button.
@interface FBPToastView : UIView

@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, readonly) BOOL isProcessing;

- (void)showText:(NSString *)text;
- (void)showMessage:(NSString *)text success:(BOOL)success;
- (void)showMessage:(NSString *)text success:(BOOL)success duration:(NSTimeInterval)duration;

- (void)showProgressWithText:(NSString *)text
                    progress:(float)progress
                    withStop:(BOOL)withStop
              stopCompletion:(nullable dispatch_block_t)stopCompletion;

- (void)updateText:(nullable NSString *)text progress:(float)progress;
- (void)updateText:(nullable NSString *)text progress:(float)progress animated:(BOOL)animated;

- (void)hideWithDelay:(NSTimeInterval)delay;
- (void)hideWithCompletion:(nullable dispatch_block_t)completion;

@end

/// Window that hosts the toasts.
///
/// Lives above the app so a message keeps showing after the user navigates
/// elsewhere, through modals and full-screen video. It deliberately never
/// becomes key and never owns the status bar.
@interface FBPToastWindow : UIWindow
+ (nullable UIWindow *)appKeyWindow;
@end

/// Queue, stacking and repositioning for all live toasts.
@interface FBPToastManager : NSObject

@property (class, readonly) FBPToastManager *shared;

- (void)registerToast:(FBPToastView *)toast;
- (void)unregisterToast:(FBPToastView *)toast;
- (void)updateAllToasts;

/// Convenience entry points used by the hooks.
- (FBPToastView *)showMessage:(NSString *)text success:(BOOL)success;
- (FBPToastView *)showProgress:(NSString *)text
                stopCompletion:(nullable dispatch_block_t)stopCompletion;

@end

NS_ASSUME_NONNULL_END
