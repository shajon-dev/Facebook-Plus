// Make Facebook fetch and show a notification that its server only hinted at.
//
// THE PROBLEM, as the device proved on 2026-11-08. Facebook sends two kinds of
// APNs push. A real notification carries an alert and mutable-content:1, so iOS
// runs the service extension — that is what Messenger and calls still get. A
// Facebook notification (like, comment, tag, friend request) arrives instead as
// content-available:1 with no alert at all and "pim":{"nt":"badge_update"},
// which iOS refuses outright:
//
//   Saving notification 81EB-0D1E: NO [ hasAlertContent: NO ]
//   Error … UNErrorDomain Code=2002 "Repository could not save notification.
//                                    No content that needs to alert."
//   NOT delivering user visible push notification 81EB-0D1E
//
// Only the badge moves. The extension is never even eligible, because iOS does
// not run a service extension for a notification it will not present.
//
// THE PART FACEBOOK SKIPS. That push is not meant to carry the text: the text is
// fetched. -[FBNotificationsPushNotifClientSyncBackgroundFetchObserver
// handleBackgroundFetchRequest:] wakes on the push, reads the MobileConfig pair
// silent_push_app_layer_badge_update_only / …_use_pim_nt, sees nt ==
// badge_update, and takes the badge-only branch — Facebook's own counter for it
// is bg_fetch_app_layer_silent_push_skipped_not_badge_update. So
// FBPushNotifClientSyncManager, which would fetch the notification by pnid over
// GraphQL and post it through Facebook's own display pipeline (dedup included,
// via FBPushNotifClientSyncLocalStorageManager and its DisplayedDirectory),
// never runs.
//
// WHAT THIS DOES. After the observer has done its badge-only work, run that
// client sync ourselves with the session the observer already holds. Everything
// here is Facebook's own machinery — the fetch, the filters, the dedup and the
// posting are all its code; the only thing added is the trigger it declined to
// pull.
//
// Nothing is forced: if any class, selector or ivar is missing the hook does
// not install, which is the house rule — one Facebook change costs this feature
// and nothing else.

#import <objc/runtime.h>

#import "FBPlus.h"
#import "FBPPrefs.h"

@interface FBPClientSyncTrigger: NSObject
- (instancetype)initWithName:(NSString *)name withDelay:(NSInteger)delay andExtra:(NSString *)extra;
@end

@interface FBPClientSyncNetworker: NSObject
- (instancetype)initWithSession:(id)session;
@end

@interface FBPClientSyncManager: NSObject
- (instancetype)initWithNetworker:(id)networker;
- (void)runWithTrigger:(id)trigger;
@end

// The manager runs its fetch asynchronously on its own queue, so it has to
// outlive this method. One live run at a time is enough — the pnid cursor is
// server-side and Facebook's own rate limiter sits behind it.
static id gInFlightManager;

static id fbpIvarValue(id object, const char *name) {
	Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
	return ivar ? object_getIvar(object, ivar) : nil;
}

static void fbpRunClientSync(id observer) {
	if (!FBPEnabled(FBPKeyNotifClientSync)) return;

	Class networkerClass = objc_getClass("FBPushNotifClientSyncGraphQLNetworker");
	Class managerClass = objc_getClass("FBPushNotifClientSyncManager");
	Class triggerClass = objc_getClass("FBPushNotifClientSyncSimpleTrigger");
	if (!networkerClass || !managerClass || !triggerClass) return;

	id session = fbpIvarValue(observer, "_session");
	if (!session) return;

	@try {
		FBPClientSyncNetworker *networker = [[networkerClass alloc] initWithSession:session];
		if (!networker) return;

		FBPClientSyncManager *manager = [[managerClass alloc] initWithNetworker:networker];
		if (!manager) return;

		// Delay 0: the push has already arrived, so there is nothing to wait for.
		// The name is only carried into Facebook's own logging.
		FBPClientSyncTrigger *trigger =
			[[triggerClass alloc] initWithName:@"FBPlusBadgeUpdate" withDelay:0 andExtra:nil];
		if (!trigger) return;

		gInFlightManager = manager;
		[manager runWithTrigger:trigger];
	} @catch (NSException *exception) {
		// A changed initialiser signature would land here rather than take the
		// app down inside a background wake.
		gInFlightManager = nil;
	}
}

%hook FBNotificationsPushNotifClientSyncBackgroundFetchObserver

- (void)handleBackgroundFetchRequest:(id)request {
	%orig;
	fbpRunClientSync(self);
}

%end

%ctor {
	// House rule: verify the class and the selector before installing, so a
	// Facebook that renames either costs this feature and nothing else.
	Class observer = objc_getClass("FBNotificationsPushNotifClientSyncBackgroundFetchObserver");
	if (!observer || !class_getInstanceMethod(observer, @selector(handleBackgroundFetchRequest:))) {
		return;
	}
	if (!class_getInstanceVariable(observer, "_session")) {
		return;
	}
	%init;
}
