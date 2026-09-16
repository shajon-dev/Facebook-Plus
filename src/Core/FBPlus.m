// Definitions of the shared constants declared in FBPlus.h: notification
// names, preference keys, and Facebook accessibility identifiers.

#import "FBPlus.h"

NSNotificationName const FBPSettingsDidChangeNotification =
    @"FBPlusSettingsDidChangeNotification";
NSNotificationName const FBPTabBarVisibilityDidChangeNotification =
    @"FBPlusTabBarVisibilityDidChangeNotification";
NSString *const FBPTabBarFractionKey = @"fraction";

NSString *const FBPKeyNoAds            = @"noAds";
NSString *const FBPKeyNoRecs           = @"noRecs";
NSString *const FBPKeyNoPYMK           = @"noPYMK";
NSString *const FBPKeyNoReels          = @"noReels";
NSString *const FBPKeyNoStoryPYMK      = @"noStoryPYMK";
NSString *const FBPKeyNoThreads        = @"noThreads";
NSString *const FBPKeyNoGroupSuggestions = @"noGroupSuggestions";
NSString *const FBPKeyNoSuggestedPages = @"noSuggestedPages";

NSString *const FBPKeyReelsLike        = @"reelsLike";

NSString *const FBPKeyAnonymousStories = @"anonymousStories";
NSString *const FBPKeyNoAutoNext       = @"noAutoNext";

NSString *const FBPKeyFeedLike         = @"feedLike";

NSString *const FBPKeyOLED             = @"oledMode";

NSString *const FBPKeyMetaPlus         = @"metaFacebookPlus";

NSString *const FBPKeyNotifyUpdates    = @"notifyUpdates";
NSString *const FBPKeyAutoClearCache   = @"autoClearCache";
NSString *const FBPKeyLanguage         = @"uiLanguage";

NSString *const FBPKeyIntroduced       = @"introduced";

NSString *const FBPAXFeedLikeButton    = @"cell-ufi-like-button";
NSString *const FBPAXReelsLikeButton   = @"shorts-like-top-button";
NSString *const FBPAXNavSettingsButton = @"nav-settings-button";
NSString *const FBPAXStoryHeaderView   = @"story-header-view";
