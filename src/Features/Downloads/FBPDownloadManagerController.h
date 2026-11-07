// The download manager: the list the user opens to see every download, and the
// HUD pill that gets them back to it.
//
// Neither of these owns a download. FBPDownloadStore does; both of these are
// views of it, rebuilt from FBPDownloadStoreDidChangeNotification, which is what
// makes closing either of them harmless.

#import "FBPlus.h"

NS_ASSUME_NONNULL_BEGIN

/// Every job in the session, with live progress and per-job actions.
///
/// Pushed from Settings → Downloads, and presented on its own from the HUD pill.
@interface FBPDownloadManagerController : UITableViewController

/// Present it wrapped in its own navigation controller, from anywhere.
///
/// Used by the HUD pill, which has a window rather than a navigation stack.
/// Pass nil to let it find the topmost controller itself.
+ (void)presentFromViewController:(nullable UIViewController *)viewController;

@end

#ifdef __cplusplus
extern "C" {
#endif

/// Start watching the store, so a download started anywhere raises a HUD pill.
///
/// Called once from FBPInitReelsDownloader — the one installer FBPEntry always
/// runs — because the pill belongs to downloads in general, not to either
/// surface. Safe to call more than once.
extern void FBPDownloadActivityInstall(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
