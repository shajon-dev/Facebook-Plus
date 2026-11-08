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
#import <UIKit/UIKit.h>

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "Header.h"

@interface FBPClientSyncTrigger: NSObject
- (instancetype)initWithName:(NSString *)name withDelay:(NSInteger)delay andExtra:(NSString *)extra;
@end

@interface FBPClientSyncNetworker: NSObject
- (instancetype)initWithSession:(id)session;
@end

@interface FBPClientSyncManager: NSObject
- (instancetype)initWithNetworker:(id)networker;
- (void)runWithTrigger:(id)trigger;
- (void)addListener:(id)listener;
@end

@interface FBPUserSessionProbe: NSObject
- (BOOL)isValid;
- (BOOL)hasUser;
@end

// The manager runs its fetch asynchronously on its own queue, so it has to
// outlive this method. One live run at a time is enough — the pnid cursor is
// server-side and Facebook's own rate limiter sits behind it.
static id gInFlightManager;

// The FBUserSession the client-sync networker needs. There is no global
// accessor for it in the main binary, so it is taken from whichever of
// Facebook's own objects is handed one first — both initialisers below take it,
// and a push-woken launch constructs at least one of them before any fetch.
static id gSession;

// Prefer a session that is actually usable, and let a later valid one replace an
// earlier placeholder: the first FBUserSession a process builds is not always
// the logged-in one.
static BOOL fbpSessionIsUsable(id session) {
	if (!session) return NO;
	if ([session respondsToSelector:@selector(isValid)] && ![session isValid]) return NO;
	if ([session respondsToSelector:@selector(hasUser)] && ![session hasUser]) return NO;
	return YES;
}

static void fbpRememberSession(id session) {
	if (!fbpSessionIsUsable(session)) return;
	if (gSession == session) return;
	gSession = session;
	FBPDiagLog(@"client sync: captured session %@", NSStringFromClass([session class]));
}

static id fbpIvarValue(id object, const char *name) {
	Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
	return ivar ? object_getIvar(object, ivar) : nil;
}

// A push-woken process is suspended within a couple of seconds, and the sync is
// a network round trip, so without an assertion it is cut off before anything
// can be posted. Ended from the listener below, or by the expiry handler.
static UIBackgroundTaskIdentifier gBackgroundTask = UIBackgroundTaskInvalid;

static void fbpEndBackgroundTask(void) {
	if (gBackgroundTask == UIBackgroundTaskInvalid) return;
	UIBackgroundTaskIdentifier task = gBackgroundTask;
	gBackgroundTask = UIBackgroundTaskInvalid;
	[UIApplication.sharedApplication endBackgroundTask:task];
}

static void fbpBeginBackgroundTask(void) {
	if (gBackgroundTask != UIBackgroundTaskInvalid) return;
	gBackgroundTask = [UIApplication.sharedApplication
	    beginBackgroundTaskWithName:@"FBPlusNotificationSync"
	              expirationHandler:^{
		FBPDiagLog(@"client sync: background time expired");
		fbpEndBackgroundTask();
	}];
	FBPDiagLog(@"client sync: holding background task %lu (remaining %.1fs)",
	           (unsigned long)gBackgroundTask,
	           UIApplication.sharedApplication.backgroundTimeRemaining);
}

// Facebook reports the outcome to whatever it was given through -addListener:.
// Duck typing is enough here — the two selectors are the whole protocol as far
// as this use goes.
@interface FBPClientSyncListener: NSObject
@end

@implementation FBPClientSyncListener

- (void)pushNotifClientSyncManagerSucceeded {
	FBPDiagLog(@"client sync: SUCCEEDED");
	fbpEndBackgroundTask();
	gInFlightManager = nil;
}

- (void)pushNotifClientSyncManagerFailedWithError:(NSError *)error {
	FBPDiagLog(@"client sync: FAILED — %@", error.localizedDescription ?: error);
	fbpEndBackgroundTask();
	gInFlightManager = nil;
}

@end

static FBPClientSyncListener *gListener;

static void fbpRunClientSync(id observer, NSString *pnid) {
	FBPDiagLog(@"client sync: background fetch observed");

	if (!FBPEnabled(FBPKeyNotifClientSync)) {
		FBPDiagLog(@"client sync: disabled in settings");
		return;
	}

	Class networkerClass = objc_getClass("FBPushNotifClientSyncGraphQLNetworker");
	Class managerClass = objc_getClass("FBPushNotifClientSyncManager");
	Class triggerClass = objc_getClass("FBPushNotifClientSyncSimpleTrigger");
	if (!networkerClass || !managerClass || !triggerClass) {
		FBPDiagLog(@"client sync: missing class (networker=%d manager=%d trigger=%d)",
		           networkerClass != nil, managerClass != nil, triggerClass != nil);
		return;
	}

	id session = observer ? fbpIvarValue(observer, "_session") : nil;
	if (session) fbpRememberSession(session);
	if (!session) session = gSession;
	if (!session) {
		FBPDiagLog(@"client sync: no session yet — nothing to run with");
		return;
	}
	FBPDiagLog(@"client sync: session %@", NSStringFromClass([session class]));

	@try {
		FBPClientSyncNetworker *networker = [[networkerClass alloc] initWithSession:session];
		if (!networker) return;

		FBPClientSyncManager *manager = [[managerClass alloc] initWithNetworker:networker];
		if (!manager) return;

		// Delay 0: the push has already arrived, so there is nothing to wait for.
		// The extra is the pnid. Without it the sync asks the server for nothing
		// in particular and comes back succeeded-but-empty, which is exactly
		// what the device showed: SUCCEEDED, no notification, no drop reason.
		// FBPushNotifClientSyncQueryBuilder keys its GraphQL query on pnids, and
		// the extension's own trigger is built the same way.
		FBPClientSyncTrigger *trigger =
			[[triggerClass alloc] initWithName:@"FBPlusBadgeUpdate" withDelay:0 andExtra:pnid];
		FBPDiagLog(@"client sync: trigger extra %@", pnid ?: @"(none)");
		if (!trigger) return;

		if (!gListener) gListener = [[FBPClientSyncListener alloc] init];
		if ([manager respondsToSelector:@selector(addListener:)]) {
			[manager addListener:gListener];
		}

		gInFlightManager = manager;
		fbpBeginBackgroundTask();
		FBPDiagLog(@"client sync: running");
		[manager runWithTrigger:trigger];
		FBPDiagLog(@"client sync: runWithTrigger returned");
	} @catch (NSException *exception) {
		FBPDiagLog(@"client sync: threw %@ — %@", exception.name, exception.reason);
		// A changed initialiser signature would land here rather than take the
		// app down inside a background wake.
		gInFlightManager = nil;
	}
}

// Is this one of the pushes Facebook deliberately leaves empty?
static BOOL fbpIsBadgeUpdatePush(NSDictionary *userInfo) {
	if (![userInfo isKindOfClass:NSDictionary.class]) return NO;
	NSDictionary *pim = userInfo[@"pim"];
	if (![pim isKindOfClass:NSDictionary.class]) return NO;
	id type = pim[@"nt"];
	return [type isKindOfClass:NSString.class] && [type isEqualToString:@"badge_update"];
}

%group FBPClientSync

%hook FBNotificationsPushNotifClientSyncBackgroundFetchObserver

- (instancetype)initWithSession:(id)session {
	fbpRememberSession(session);
	return %orig;
}

// Not called for a badge-update push on this build — the device proved that —
// but it is still the cleanest point when Facebook does route one here.
- (void)handleBackgroundFetchRequest:(id)request {
	%orig;
	FBPDiagLog(@"client sync: background fetch observed");
	fbpRunClientSync(self, nil);
}

%end

%hook FBPushNotifClientSyncGraphQLNetworker

- (instancetype)initWithSession:(id)session {
	fbpRememberSession(session);
	return %orig;
}

%end

// The hook that actually fires. iOS wakes the app for the content-available
// push and hands it straight to the app delegate; the background-fetch observer
// above never sees it.
%hook FBBaseAppDelegate

- (void)application:(id)application
    didReceiveRemoteNotification:(NSDictionary *)userInfo
          fetchCompletionHandler:(id)handler {
	%orig;

	if (!fbpIsBadgeUpdatePush(userInfo)) return;

	id pnid = userInfo[@"pnid"];
	if (![pnid isKindOfClass:NSString.class]) {
		NSDictionary *p = userInfo[@"p"];
		pnid = [p isKindOfClass:NSDictionary.class] ? p[@"PushNotifID"] : nil;
	}

	FBPDiagLog(@"client sync: badge-update push delivered to the app delegate");
	fbpRunClientSync(nil, [pnid isKindOfClass:NSString.class] ? pnid : nil);
}

%end

// What the GraphQL query actually asks for. The run reports SUCCEEDED and posts
// nothing, so the question is whether it carries any pnids at all.
%hook FBPushNotifClientSyncQueryBuilder

+ (id)builderWithCount:(NSInteger)count
                cursor:(id)cursor
              deviceId:(id)deviceId
             extraData:(id)extraData
                 pnids:(id)pnids {
	FBPDiagLog(@"client sync: query count=%ld cursor=%@ deviceId=%@ pnids=%@ extra=%@",
	           (long)count, cursor ?: @"(nil)", deviceId ?: @"(nil)", pnids ?: @"(nil)",
	           extraData ?: @"(nil)");
	return %orig;
}

%end

// Called once per notification the server returned. Silence here means the
// response was empty.
%hook FBPushNotifClientSyncManager

- (void)evaluatePush:(id)push {
	FBPDiagLog(@"client sync: evaluating a fetched push");
	%orig;
}

%end

// Why a fetched notification was not shown.
%hook FBPushNotifClientSyncLocalFilterResult

- (id)dropWithReason:(id)reason {
	FBPDiagLog(@"client sync: dropped — %@", reason);
	return %orig;
}

%end

%end  // group FBPClientSync

// Widest net for the session: every FBUserSession the process builds passes
// through here. The push-woken launch constructs one before the delegate is
// handed the payload, which the narrower initWithSession: hooks missed.
%group FBPSessionCapture

%hook FBUserSession

- (instancetype)init {
	id session = %orig;
	fbpRememberSession(session);
	return session;
}

- (instancetype)initWithApiSessionStore:(id)store {
	id session = %orig;
	fbpRememberSession(session);
	return session;
}

%end

%end  // group FBPSessionCapture

%ctor {
	// House rule: verify the class and the selector before installing, so a
	// Facebook that renames either costs this feature and nothing else.
	Class delegate = objc_getClass("FBBaseAppDelegate");
	if (!delegate ||
	    !class_getInstanceMethod(
	        delegate,
	        @selector(application:didReceiveRemoteNotification:fetchCompletionHandler:))) {
		FBPDiagLog(@"client sync: app delegate class or selector missing — hook not installed");
		return;
	}
	if (!objc_getClass("FBPushNotifClientSyncManager")) {
		FBPDiagLog(@"client sync: no client-sync manager in this build — hook not installed");
		return;
	}
	FBPDiagLog(@"client sync: hook installed");
	%init(FBPClientSync);

	Class userSession = objc_getClass("FBUserSession");
	if (userSession && class_getInstanceMethod(userSession, @selector(init))) {
		%init(FBPSessionCapture);
	} else {
		FBPDiagLog(@"client sync: no FBUserSession class — session capture off");
	}
}
