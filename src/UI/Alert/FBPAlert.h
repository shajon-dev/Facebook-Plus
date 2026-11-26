// The tweak's own confirmation card.
//
// UIAlertController was used for these until iOS 27, which lays the title and
// message out leading-aligned and resets any alignment written beforehand while
// the alert is presenting. Owning the view is the only way to keep the text
// centred on every iOS, and it lets the card match the rest of the tweak.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface FBPAlert : NSObject

/// Centred card with a title, an optional message and one or two buttons.
/// Pass a nil @c cancelTitle for a single acknowledgement button. It hosts
/// itself in its own window, so it needs no view controller to present from.
+ (void)showWithTitle:(NSString *)title
              message:(nullable NSString *)message
          cancelTitle:(nullable NSString *)cancelTitle
         confirmTitle:(NSString *)confirmTitle
          destructive:(BOOL)destructive
            onConfirm:(nullable dispatch_block_t)onConfirm
             onCancel:(nullable dispatch_block_t)onCancel;

@end

NS_ASSUME_NONNULL_END
