// Private Facebook and UIKit interfaces the hooks bind to. Declaring them adds
// no link-time dependency; they resolve through the runtime at install time.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Private UIKit

@interface UIResponder (FBPPrivate)
/// Nearest ancestor view controller. Private UIKit API, not Facebook's.
- (nullable UIViewController *)_viewControllerForAncestor;
@end

#pragma mark - Feed

/// FBSharedFramework. Every feed unit passes through -initWithFBPandoTree:.
@interface FBMemModelObject : NSObject
- (nullable NSString *)category;
- (nullable id)sponsoredData;
- (nullable NSString *)storyBucketType;
@end

#pragma mark - Ads (specialised ad sources, outside the feed-model path)

/// FBSharedFramework. An empty -insertedItems suppresses Watch/video feed ads.
@interface FBVideoFeedAdsPool : NSObject
- (NSArray *)insertedItems;
@end

/// FBSharedFramework. Fetch entry points are no-oped so story ads never load.
@interface FBSnacksAdsPaginatingFetcher : NSObject
@end

#pragma mark - Action-confirmation targets
// Each exposes the one method that commits the action; the hooks guard it.

@interface FBCommentCreateMutator : NSObject
- (void)publishWithSession:(id)session;
@end

@interface FBPersonFriendableTableViewCell : UITableViewCell
- (void)handleFriendButtonTapped:(id)sender;
@end

@interface FBPersonFriendable2TableViewCell : UITableViewCell
- (void)handleFriendButtonTapped:(id)sender;
@end

@interface FBSnacksFeedbackComposerShareButtonComponentController : NSObject
- (void)didTapShareButton;
@end

@interface FBSnacksFollowButtonComponentController : NSObject
- (void)didTapFollowButton;
@end

#pragma mark - Stories ("Snacks")

@interface FBSnacksBucketsSeenStateManager : NSObject
@end

@interface FBSnacksThreadSwitcherViewController : UIViewController
@end

@interface FBSnacksBucketViewController : UIViewController
@end

#pragma mark - Reels / Shorts

@interface FBShortsSideBarView : UIView
@end

/// FBShortsKit. The Reels tab and the full-screen viewer share this one manager
/// for the inline survey card.
@interface FBShortsInlineSurveyInjectionManager : NSObject
- (void)maybeAddInlineSurveyComponents:(id)arg1;
@end

@interface CKSurfaceViewControllerImpl : UIViewController
- (nullable id)viewManager;
@end

@interface CKSurfaceRootView : UIView
@end

@interface FBTransparentView : UIView
@end

#pragma mark - ComponentKit action routing

/// Every ComponentKit control event funnels through this one forwarder.
@interface CKComponentActionControlForwarder : NSObject
- (void)handleControlEventFromSender:(id)sender withEvent:(nullable UIEvent *)event;
@end

#pragma mark - Chrome

@interface FBTabBarContainerView : UIView
@end

@interface FBTabBarItemDefaultView : UIView
@end

// iOS 26+ tab bars; both replace FBTabBarContainerView on newer builds.
@interface FBFloatingTabBar : UIView
@end

@interface FBNativeTabBar : UIView
@end

@interface FBBaseAppDelegate : UIResponder <UIApplicationDelegate>
@end

// In-app browser; its initial-URL load is intercepted for external links.
@interface FBWebViewController : UIViewController
@end

#pragma mark - OLED targets
// Containers whose background fills the screen. Each is hooked only when
// present, so a build that renames one loses only that surface.

@interface FBTabBar : UIView
@end

@interface FBTabBarAndContentView : UIView
@end

@interface FBTopBarAndContentView : UIView
@end

@interface FBMovableNavigationBarView : UIView
@end

@interface FBNewsFeedView : UIView
@end

@interface FBNewsFeedCollectionView : UICollectionView
@end

#pragma mark - Left menu (ComponentKit rendering)

/// The chain a side-menu row's model is read through: dataSourceState,
/// objectAtIndexPath:, model, model, identifier. Rows must be told apart by that
/// identifier (an untranslated developer string), never by cell label: a reused
/// cell can still carry the previous row's content.
@interface FBPBookmarksModelChain : NSObject
- (nullable id)dataSourceState;
- (nullable id)objectAtIndexPath:(NSIndexPath *)indexPath;
- (nullable id)model;
- (nullable NSString *)identifier;
@end

/// The "<language> wasn't downloaded" screen's own retry, pressed once at first
/// launch (FBPLanguagePackHooks.xm): -_didTapRetryButton on
/// FBDownloadLanguagePackInterstitialViewController.
@interface FBPLanguagePackInterstitial : UIViewController
- (void)_didTapRetryButton;
@end

NS_ASSUME_NONNULL_END
