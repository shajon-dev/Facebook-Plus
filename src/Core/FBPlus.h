#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import "FBPTrace.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Logging

// Recorded to the exportable log in release as well as debug; DEBUG also prints.
#ifdef DEBUG
#define FBPLog(fmt, ...)                                                       \
    do {                                                                       \
        NSLog(@"[Facebook Plus] " fmt, ##__VA_ARGS__);                          \
        FBPTraceEmit([NSString stringWithFormat:(fmt), ##__VA_ARGS__]);         \
    } while (0)
#else
#define FBPLog(fmt, ...) FBPTraceEmit([NSString stringWithFormat:(fmt), ##__VA_ARGS__])
#endif

#pragma mark - Deferred hook installation

/// Installs a hook group once. FBPEntry re-runs the installers per dyld image,
/// because Facebook dlopens most of its frameworks long after %ctor.
#define FBP_ONCE(name) static BOOL name = NO; if (!name && (name = YES))

/// Every report inside an FBPInit* uses this, not FBPLog: the installers re-run
/// per image, failure branches included.
#define FBPLogOnce(fmt, ...)                                                   \
    do {                                                                       \
        static BOOL _fbp_logged_once = NO;                                     \
        if (!_fbp_logged_once) {                                               \
            _fbp_logged_once = YES;                                            \
            FBPLog(fmt, ##__VA_ARGS__);                                        \
        }                                                                      \
    } while (0)

#pragma mark - Notifications

extern NSNotificationName const FBPSettingsDidChangeNotification;

/// userInfo carries @c FBPTabBarFractionKey, an NSNumber<double>, 0 = visible.
extern NSNotificationName const FBPTabBarVisibilityDidChangeNotification;
extern NSString *const FBPTabBarFractionKey;

#pragma mark - Preference keys

// Feed
extern NSString *const FBPKeyNoAds;             // Remove sponsored units
extern NSString *const FBPKeyNoRecs;            // Remove ENGAGEMENT recommendations
extern NSString *const FBPKeyNoPYMK;            // Remove "People you may know"
extern NSString *const FBPKeyNoReels;           // Remove Reels from the feed
extern NSString *const FBPKeyNoStories;         // Remove stories from the feed
extern NSString *const FBPKeyNoMainStories;     // Remove top Stories tray
extern NSString *const FBPKeyNoStoryPYMK;       // Remove PYMK from the story tray
extern NSString *const FBPKeyNoThreads;         // Remove the Threads promo unit
extern NSString *const FBPKeyNoGroupSuggestions;// Remove "groups you should join"
extern NSString *const FBPKeyNoSuggestedPages;  // Remove "suggested pages for you"
extern NSString *const FBPKeyNoSurveys;         // Remove "are you interested in this post?" surveys
extern NSString *const FBPKeyNoCommentProductBanner; // Remove the affiliate/product link banner in the comment sheet
extern NSString *const FBPKeyNoCommentEmojiBar; // Remove the quick reaction emoji bar above the comment composer
extern NSString *const FBPKeyNoReelsRecommended; // Remove the "Recommended" mid-card interstitial in Reels

// Confirmations (opt-in: guard an action behind a prompt)
extern NSString *const FBPKeyConfirmComment;    // Confirm before posting a comment
extern NSString *const FBPKeyConfirmFriend;     // Confirm before a friend-request action
extern NSString *const FBPKeyConfirmShare;      // Confirm before sharing
extern NSString *const FBPKeyConfirmFollow;     // Confirm before following / joining
extern NSString *const FBPKeyConfirmPost;       // Confirm before publishing a post

// Downloads
extern NSString *const FBPKeyReelsDownloaderEnabled;
extern NSString *const FBPKeyStoryDownloaderEnabled;
extern NSString *const FBPKeyDownloadQualityPicker;

// Reels
extern NSString *const FBPKeyReelsHideOverlay;  // Strip the Reels overlay (always on; no toggle)

// Stories
extern NSString *const FBPKeyAnonymousStories;
extern NSString *const FBPKeyNoAutoNext;

extern NSString *const FBPKeyFeedLike;          // Confirm every like (feed + Reels)

// Appearance
extern NSString *const FBPKeyOLED;              // True-black background in dark mode
extern NSString *const FBPKeyOLEDDividers;      // Show the faint post separators in OLED mode (off = fully black feed)
extern NSString *const FBPKeyHideSidebarUpgrades;     // Hide the "Upgrades" row in the left menu
extern NSString *const FBPKeyHideSidebarAlsoFromMeta; // Hide the "Also from Meta" row in the left menu
extern NSString *const FBPKeyDisableHDR;        // Force SDR rendering (clamp HDR photos and video)
extern NSString *const FBPKeyFont;              // Chosen UI font family ("" / unset = original)
extern NSString *const FBPKeyFontScale;         // Custom-font size multiplier ("" / unset = 1.0)

// Facebook Plus
extern NSString *const FBPKeyMetaPlus;          // Unlock paid subscriber benefits for preview
extern NSString *const FBPKeyMetaPlusMode;      // Unlock method: "direct" (force gates) or "trial" (simulate an active trial)

// Links
extern NSString *const FBPKeyLinksInSafari;     // Open external links in the default browser

// Diagnostics
extern NSString *const FBPKeyLogsKeep;          // keep the diagnostic log across launches
extern NSString *const FBPKeyOLEDGreyDiag;      // log OLED surfaces left grey (FBP_DIAG only)
// Sideload compatibility
/// Pins keychain calls to the probed access group. SecRebinds.xm cannot see
/// this header and reads the raw @c "keychainRebind" key: keep the two in step.
extern NSString *const FBPKeyKeychainRebind;

extern NSString *const FBPKeyNotifClientSync;

extern NSString *const FBPKeyNotifyUpdates;
extern NSString *const FBPKeyAutoClearCache;    // Sweep the caches on every launch
extern NSString *const FBPKeyCacheSchedule;     // Sweep on a UTC schedule instead: "off", "12" or "24" hours
extern NSString *const FBPKeyLanguage;          // In-tweak UI language ("" = English/Base, "fr", …)

extern NSString *const FBPKeyIntroduced;        // Onboarding has been shown
extern NSString *const FBPKeyLastNotifiedVersion; // Latest release the user was told about
extern NSString *const FBPKeyResolvedGitHubOwner; // GitHub owner last found live (primary or mirror)
extern NSString *const FBPKeyLastCacheSweep;    // When the caches were last swept, as a Unix time

#pragma mark - Confirmations

/// One shared latch, so the two confirmation paths (the ComponentKit forwarder
/// and the method-swizzle commit hooks) never stack a second prompt on a first.
#ifdef __cplusplus
extern "C" {
#endif
BOOL FBPConfirmPromptVisible(void);
void FBPSetConfirmPromptVisible(BOOL visible);
#ifdef __cplusplus
}
#endif

#pragma mark - Fonts

/// Reentrancy guard: the tweak's own UI and the font hooks themselves build
/// UIFont objects, which must fall through instead of being replaced again.
#ifdef __cplusplus
extern "C" {
#endif
BOOL FBPFontScopeActive(void);
void FBPSetFontScopeActive(BOOL active);
#ifdef __cplusplus
}
#endif

#pragma mark - Ads

/// Defined in FBPAdsHooks.xm and called from the single FBMemModelObject filter
/// in FBPFeedHooks, so that model stays hooked exactly once.
#ifdef __cplusplus
extern "C" BOOL FBPModelIsBlockedAd(id model);
#else
extern BOOL FBPModelIsBlockedAd(id model);
#endif

#pragma mark - Accessibility identifiers used to locate Facebook views
// Stable across app versions because Facebook's own UI tests depend on them.

extern NSString *const FBPAXFeedLikeButton;     // cell-ufi-like-button
extern NSString *const FBPAXReelsLikeButton;    // shorts-like-top-button
extern NSString *const FBPAXNavSettingsButton;  // nav-settings-button

#pragma mark - View tags
// Found again with -viewWithTag: rather than re-created, so repeated layout
// passes cannot stack duplicate buttons.

typedef NS_ENUM(NSInteger, FBPViewTag) {
    FBPViewTagStoryButton  = 0x7B902,
};

NS_ASSUME_NONNULL_END
