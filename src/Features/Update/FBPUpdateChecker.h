#import <UIKit/UIKit.h>

// Checks GitHub Releases for a newer tweak version and, when one exists, shows
// the update screen with its changelog.
@interface FBPUpdateChecker : NSObject

/// Called at launch. Silent: only shows the update screen when a newer version
/// exists, the user hasn't been shown that version already, and update
/// notifications are enabled (FBPKeyNotifyUpdates).
+ (void)checkOnLaunch;

/// Called from Settings -> "Check for Update". Always reports back: shows the
/// update screen when newer, or a toast for "up to date" / failure.
+ (void)checkManuallyFromViewController:(UIViewController *)controller;

@end
