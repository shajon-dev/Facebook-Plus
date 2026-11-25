// Make Facebook fetch and show a notification that its server only hinted at.
//
// Facebook sends two kinds of APNs push. A real notification carries an alert
// and mutable-content:1, so iOS runs the service extension. A Facebook
// notification (like, comment, tag, friend request) arrives as
// content-available:1 with no alert and "pim":{"nt":"badge_update"}, which iOS
// refuses to present (UNErrorDomain 2002) and so never runs the extension for
// either. Only the badge moves.
//
// That push is not meant to carry the text; the text is fetched.
// -[FBNotificationsPushNotifClientSyncBackgroundFetchObserver
// handleBackgroundFetchRequest:] wakes on the push, reads the MobileConfig pair
// silent_push_app_layer_badge_update_only / …_use_pim_nt, sees nt ==
// badge_update and takes the badge-only branch, so
// FBPushNotifClientSyncManager — which would fetch the notification by pnid and
// post it through Facebook's own display pipeline, dedup included — never runs.
//
// So after the observer has done its badge-only work, that client sync is run
// with the session the observer already holds. The fetch, the filters, the
// dedup and the posting are all Facebook's own code; the only thing added is
// the trigger it declined to pull. If any class, selector or ivar is missing
// the hook does not install.

#import <objc/runtime.h>
#import <UIKit/UIKit.h>

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPTrace.h"
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

// The manager fetches asynchronously on its own queue, so it must outlive this
// method. One live run at a time: the cursor is server-side and Facebook's own
// rate limiter sits behind it.
static id gInFlightManager;

// FBPushNotifClientSyncQueryBuilder is a *page* query — count, cursor and page
// extra-data alongside the pnids — and the pnids it carries are notifications
// the client has already seen, so splicing the push's own pnid in made no
// difference. The pnid-*targeted* query is not in this binary at all; it exists
// only inside the notification service extension, the process iOS refuses to
// start for a contentless push.
//
// `count` is an OBJECT, not an NSInteger: the builder retains its first
// declared argument. All five are 64-bit register arguments, so the
// declaration only affects printing and forwarding them is safe.

// YES while the sync WE started is in flight, so the query hook below never
// alters a fetch Facebook made for its own reasons.
static BOOL gOurSyncInFlight = NO;

// The FBUserSession the networker needs. No global accessor exists in the main
// binary, so it is taken from whichever of Facebook's objects gets one first.
static id gSession;

// A later valid session replaces an earlier placeholder: the first one a
// process builds is not always the logged-in one.
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

// A push-woken process is suspended within seconds and the sync is a network
// round trip, so without an assertion it is cut off before anything is posted.
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

// -addListener: takes anything; these two selectors are the whole protocol.
@interface FBPClientSyncListener: NSObject
@end

@implementation FBPClientSyncListener

- (void)pushNotifClientSyncManagerSucceeded {
	FBPDiag(@"notify", @"client-sync: SUCCEEDED");
	gOurSyncInFlight = NO;
	fbpEndBackgroundTask();
	gInFlightManager = nil;
}

- (void)pushNotifClientSyncManagerFailedWithError:(NSError *)error {
	FBPDiagFail(@"notify", @"client-sync: FAILED — %@", error.localizedDescription ?: error);
	gOurSyncInFlight = NO;
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

		// Delay 0: the push has arrived. The extra is the pnid; without it the
		// sync asks for nothing in particular and returns succeeded-but-empty.
		FBPClientSyncTrigger *trigger =
			[[triggerClass alloc] initWithName:@"FBPlusBadgeUpdate" withDelay:0 andExtra:pnid];
		FBPDiagLog(@"client sync: trigger extra %@", pnid ?: @"(none)");
		if (!trigger) return;

		if (!gListener) gListener = [[FBPClientSyncListener alloc] init];
		if ([manager respondsToSelector:@selector(addListener:)]) {
			[manager addListener:gListener];
		}

		gInFlightManager = manager;
		// Set before the run: the query is built asynchronously on Facebook's
		// own queue, so the flag must already be true when it gets there.
		gOurSyncInFlight = YES;
		fbpBeginBackgroundTask();
		FBPDiagLog(@"client sync: running");
		[manager runWithTrigger:trigger];
		FBPDiagLog(@"client sync: runWithTrigger returned");
	} @catch (NSException *exception) {
		gOurSyncInFlight = NO;
		FBPDiagFail(@"notify", @"client-sync: threw %@ — %@", exception.name, exception.reason);
		// A changed initialiser signature lands here, not in a crash.
		gInFlightManager = nil;
	}
}

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
	FBPTraceFire("notif.FBNotificationsPushNotifClientSyncBackgroundFetchObserver.initWithSession");
	fbpRememberSession(session);
	return %orig;
}

- (void)handleBackgroundFetchRequest:(id)request {
	FBPTraceFire("notif.FBNotificationsPushNotifClientSyncBackgroundFetchObserver.handleBackgroundFetchRequest");
	%orig;
	FBPDiagLog(@"client sync: background fetch observed");
	fbpRunClientSync(self, nil);
}

%end

%hook FBPushNotifClientSyncGraphQLNetworker

- (instancetype)initWithSession:(id)session {
	FBPTraceFire("notif.FBPushNotifClientSyncGraphQLNetworker.initWithSession");
	fbpRememberSession(session);
	return %orig;
}

%end

// iOS hands the content-available push straight to the app delegate, so this,
// not the observer above, is what fires.
%hook FBBaseAppDelegate

- (void)application:(id)application
    didReceiveRemoteNotification:(NSDictionary *)userInfo
          fetchCompletionHandler:(id)handler {
	FBPTraceFire("notif.FBBaseAppDelegate.didReceiveRemoteNotification");
	%orig;

	// EVERY push that reaches the app, not just the ones this hook acts on: the
	// useful finding here was the *absence* of this call, which is
	// indistinguishable from the hook not being installed. Structure only — the
	// payload carries the user's own notification text.
	NSDictionary *pim = [userInfo isKindOfClass:NSDictionary.class] ? userInfo[@"pim"] : nil;
	id notifType = [pim isKindOfClass:NSDictionary.class] ? pim[@"nt"] : nil;
	NSArray *keys = [userInfo isKindOfClass:NSDictionary.class]
	                    ? [userInfo.allKeys sortedArrayUsingSelector:@selector(compare:)]
	                    : nil;
	FBPDiag(@"notify", @"push to app delegate: keys=%@ nt=%@ badge-update=%d",
	        keys.count ? [keys componentsJoinedByString:@","] : @"(none)",
	        [notifType isKindOfClass:NSString.class] ? notifType : @"(none)",
	        fbpIsBadgeUpdatePush(userInfo));

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

%hook FBPushNotifClientSyncQueryBuilder

+ (id)builderWithCount:(id)count
                cursor:(id)cursor
              deviceId:(id)deviceId
             extraData:(id)extraData
                 pnids:(id)pnids {
	FBPTraceFire("notif.FBPushNotifClientSyncQueryBuilder.builderWithCount");

	// The cursor is Unix seconds, and the page reaches BACKWARDS from it: the
	// pushes observed all carried a pnid newer than the cursor the query used,
	// and all returned empty-but-successful. So the cursor is moved past now,
	// for our own run only.
	id effectiveCursor = cursor;
	if (gOurSyncInFlight && cursor) {
		NSTimeInterval ahead = NSDate.date.timeIntervalSince1970 + 60;
		if ([cursor isKindOfClass:NSString.class]) {
			effectiveCursor = [NSString stringWithFormat:@"%.0f", ahead];
		} else if ([cursor isKindOfClass:NSNumber.class]) {
			effectiveCursor = @((long long)ahead);
		}
	}

	// One line: an NSArray description spans lines and a line-based log filter
	// loses everything after the bracket. The count, not the hundreds of pnids.
	NSUInteger pnidCount =
		[pnids isKindOfClass:NSArray.class] ? ((NSArray *)pnids).count : 0;

	FBPDiag(@"notify", @"client-sync query: count=%@ cursor=%@%@ pnids=%lu ours=%d", count ?: @"(nil)",
	        cursor ?: @"(nil)",
	        effectiveCursor == cursor ? @"" : [NSString stringWithFormat:@" -> %@", effectiveCursor],
	        (unsigned long)pnidCount, gOurSyncInFlight);

	return %orig(count, effectiveCursor, deviceId, extraData, pnids);
}

%end

%hook FBPushNotifClientSyncManager

- (void)evaluatePush:(id)push {
	FBPTraceFire("notif.FBPushNotifClientSyncManager.evaluatePush");
	FBPDiagLog(@"client sync: evaluating a fetched push");
	%orig;
}

%end

%hook FBPushNotifClientSyncLocalFilterResult

- (id)dropWithReason:(id)reason {
	FBPTraceFire("notif.FBPushNotifClientSyncLocalFilterResult.dropWithReason");
	FBPDiagLog(@"client sync: dropped — %@", reason);
	return %orig;
}

%end

%end  // group FBPClientSync

// Widest net: a push-woken launch builds a session before the delegate gets
// the payload, which the narrower initWithSession: hooks miss.
%group FBPSessionCapture

%hook FBUserSession

- (instancetype)init {
	FBPTraceFire("notif.FBUserSession.init");
	id session = %orig;
	fbpRememberSession(session);
	return session;
}

- (instancetype)initWithApiSessionStore:(id)store {
	FBPTraceFire("notif.FBUserSession.initWithApiSessionStore");
	id session = %orig;
	fbpRememberSession(session);
	return session;
}

%end

%end  // group FBPSessionCapture

%ctor {
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
