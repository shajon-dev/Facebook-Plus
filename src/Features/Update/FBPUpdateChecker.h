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

/// The GitHub owner currently in use. We publish under two owners; the primary
/// ("SHAJON-404") is preferred whenever its releases endpoint answers HTTP 200,
/// otherwise the mirror ("shajon-dev") is used. Resolved asynchronously and
/// cached; returns the last known-live owner (mirror until proven otherwise).
+ (NSString *)activeGitHubOwner;

/// https://github.com/<owner>                      — the owner's profile.
+ (NSString *)githubProfileURL;
/// https://github.com/<owner>/Facebook-Plus        — the repository.
+ (NSString *)githubRepoURL;
/// https://github.com/<owner>/Facebook-Plus/releases/latest/ — the .deb release.
+ (NSString *)githubReleasesURL;

/// Probes the primary owner and caches which owner is live. Safe to call at
/// launch regardless of the update-notification setting; shows no UI.
+ (void)refreshGitHubOwner;

@end
