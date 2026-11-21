// Make Facebook fetch and show a notification that its server only hinted at.
//
// The problem. Facebook sends two kinds of APNs push. A real notification carries
// an alert and mutable-content:1, so iOS runs the service extension — that is
// what Messenger and calls still get. A Facebook notification (like, comment,
// tag, friend request) arrives instead as content-available:1 with no alert at
// all and "pim":{"nt":"badge_update"}, which iOS refuses outright:
//
//   Saving notification 81EB-0D1E: NO [ hasAlertContent: NO ]
//   Error … UNErrorDomain Code=2002 "Repository could not save notification.
//                                    No content that needs to alert."
//   NOT delivering user visible push notification 81EB-0D1E
//
// Only the badge moves. The extension is never eligible, because iOS does not
// run a service extension for a notification it will not present.
//
// The part Facebook skips. That push is not meant to carry the text; the text is
// fetched. -[FBNotificationsPushNotifClientSyncBackgroundFetchObserver
// handleBackgroundFetchRequest:] wakes on the push, reads the MobileConfig pair
// silent_push_app_layer_badge_update_only / …_use_pim_nt, sees nt ==
// badge_update, and takes the badge-only branch (counter
// bg_fetch_app_layer_silent_push_skipped_not_badge_update). So
// FBPushNotifClientSyncManager — which would fetch the notification by pnid over
// GraphQL and post it through Facebook's own display pipeline (dedup included,
// via FBPushNotifClientSyncLocalStorageManager and its DisplayedDirectory) —
// never runs.
//
// The fix. After the observer has done its badge-only work, run that client sync
// with the session the observer already holds. The fetch, the filters, the dedup
// and the posting are all Facebook's own code; the only thing added is the
// trigger it declined to pull.
//
// Nothing is forced: if any class, selector or ivar is missing the hook does not
// install — one Facebook change costs this feature and nothing else.

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

// The manager runs its fetch asynchronously on its own queue, so it has to
// outlive this method. One live run at a time is enough — the pnid cursor is
// server-side and Facebook's own rate limiter sits behind it.
static id gInFlightManager;

// WHAT THE DEVICE SAID ABOUT THIS QUERY, 2026-11-16
//
// Splicing the push's own pnid into FBPushNotifClientSyncQueryBuilder's pnids
// array was tried here and **made no difference**, so it was removed rather
// than left in as decoration. Two captures, same outcome:
//
//   without the pnid : SUCCEEDED, -evaluatePush: never called, nothing posted
//   with the pnid    : SUCCEEDED, -evaluatePush: never called, nothing posted
//
// Two things were learned, and both argue the app-side path is the wrong
// engine for this job rather than a broken one:
//
//   * This builder is a *page* query — count, cursor and
//     FBNotificationsPageConnectionExtraData alongside the pnids. The 175
//     pnids it already carries are all notifications the client has seen, so
//     the array reads far more like "these I already have" than "fetch these".
//     If that is what it is, adding the new pnid told the server to skip
//     exactly the one notification we wanted.
//   * The pnid-*targeted* query is not in this binary at all.
//     FBPushNotifClientSyncExtensionGraphQLNetworker / ...Query / ...QueryParams
//     / ...Response exist only inside NotificationServiceExtension — the
//     process iOS refuses to start for a contentless push.
//
// SETTLED 2026-11-21: `count` is an OBJECT, not an NSInteger. The "different
// nonsense value on every call" (20281400, 34027576, 93648952, 89747664) was a
// heap pointer's low 32 bits printed with %d. Disassembling
// +[FBPushNotifClientSyncQueryBuilder builderWithCount:cursor:deviceId:extraData:pnids:]
// at 0x1003b52c8 in 588.0.0 shows `mov x0, x2` followed immediately by a call —
// x2, the first declared argument, is retained, which an NSInteger never is.
//
// It follows that forwarding the arguments IS safe: all five are 64-bit
// register arguments on arm64, so the declaration only ever mattered for how
// they were printed. The hook below now declares `count` as `id` and may pass
// its arguments on.

// YES while the sync WE started is in flight, so the query hook below only ever
// alters our own run and never a fetch Facebook made for its own reasons.
// Bracketed by fbpRunClientSync and the listener's succeeded/failed callbacks.
static BOOL gOurSyncInFlight = NO;

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

		// Delay 0: the push has already arrived, nothing to wait for. The extra
		// is the pnid; without it the sync asks the server for nothing in
		// particular and returns succeeded-but-empty (SUCCEEDED, no notification,
		// no drop reason). FBPushNotifClientSyncQueryBuilder keys its GraphQL
		// query on pnids, and the extension's own trigger is built the same way.
		FBPClientSyncTrigger *trigger =
			[[triggerClass alloc] initWithName:@"FBPlusBadgeUpdate" withDelay:0 andExtra:pnid];
		FBPDiagLog(@"client sync: trigger extra %@", pnid ?: @"(none)");
		if (!trigger) return;

		if (!gListener) gListener = [[FBPClientSyncListener alloc] init];
		if ([manager respondsToSelector:@selector(addListener:)]) {
			[manager addListener:gListener];
		}

		gInFlightManager = manager;
		// Set before the run starts: the query is built asynchronously on
		// Facebook's own queue, so the flag has to already be true by the time
		// it gets there. Cleared by the listener above, whichever way it ends.
		gOurSyncInFlight = YES;
		fbpBeginBackgroundTask();
		FBPDiagLog(@"client sync: running");
		[manager runWithTrigger:trigger];
		FBPDiagLog(@"client sync: runWithTrigger returned");
	} @catch (NSException *exception) {
		gOurSyncInFlight = NO;
		FBPDiagFail(@"notify", @"client-sync: threw %@ — %@", exception.name, exception.reason);
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
	FBPTraceFire("notif.FBNotificationsPushNotifClientSyncBackgroundFetchObserver.initWithSession");
	fbpRememberSession(session);
	return %orig;
}

// Not called for a badge-update push on this build, but still the cleanest point
// if Facebook ever routes one here.
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

// The hook that actually fires. iOS wakes the app for the content-available
// push and hands it straight to the app delegate; the background-fetch observer
// above never sees it.
%hook FBBaseAppDelegate

- (void)application:(id)application
    didReceiveRemoteNotification:(NSDictionary *)userInfo
          fetchCompletionHandler:(id)handler {
	FBPTraceFire("notif.FBBaseAppDelegate.didReceiveRemoteNotification");
	%orig;

	// EVERY push that reaches the app, not just the ones this hook acts on.
	//
	// A capture on 2026-11-21 03:27 had the extension running for a Messenger
	// call — payload keys aps,ep,ki,pim,pnid,t, with the text already in it —
	// and this selector never firing at all. That is the single most useful
	// fact in the file and it was only knowable from the *absence* of a line,
	// which is indistinguishable from the hook not being installed. One line
	// per push settles it: a like or comment that reaches the app shows up
	// here, with the shape that decides what can be done about it.
	//
	// Structure only. The payload carries the user's own notification text.
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

// What the GraphQL query actually asks for. The run reports SUCCEEDED and posts
// nothing, so the question is whether it carries any pnids at all.
%hook FBPushNotifClientSyncQueryBuilder

+ (id)builderWithCount:(id)count
                cursor:(id)cursor
              deviceId:(id)deviceId
             extraData:(id)extraData
                 pnids:(id)pnids {
	FBPTraceFire("notif.FBPushNotifClientSyncQueryBuilder.builderWithCount");

	// WHAT THE CURSOR TURNED OUT TO BE, AND WHY IT IS MOVED.
	//
	// The 03:31 capture on 2026-11-21 caught three badge-update pushes end to
	// end: each reached the app delegate, each ran this sync, each reported
	// SUCCEEDED, and -evaluatePush: was not called once. The response carried
	// nothing. The cursors used were 1795174192, 1795203110 and 1795203150 —
	// Unix seconds — while the pnid the push itself carried embeds 1795210307,
	// later than all three.
	//
	// That kills the reading where the query asks for notifications *after* the
	// cursor: the new notification is newer than every cursor used, so it would
	// have come back and did not. What is left is a page that reaches BACKWARDS
	// from the cursor, which can never contain a notification newer than it —
	// which is exactly the empty-but-successful result three captures have
	// shown. The pnids array is the "already have" list; adding the new pnid to
	// it was tried and changed nothing, consistent with that reading too.
	//
	// So the cursor is moved past now for our own run, and only ours. If this
	// is right, the next capture reaches -evaluatePush:. If it is wrong, the
	// line below says what was asked for and the idea is dead with evidence
	// rather than argument.
	id effectiveCursor = cursor;
	if (gOurSyncInFlight && cursor) {
		NSTimeInterval ahead = NSDate.date.timeIntervalSince1970 + 60;
		// Match whatever type Facebook used, rather than assuming one.
		if ([cursor isKindOfClass:NSString.class]) {
			effectiveCursor = [NSString stringWithFormat:@"%.0f", ahead];
		} else if ([cursor isKindOfClass:NSNumber.class]) {
			effectiveCursor = @((long long)ahead);
		}
	}

	// One line: an NSArray description spans lines and a line-based log filter
	// loses everything after the opening bracket. The pnids themselves are not
	// logged any more — 175 of them per call is most of a log, and the count is
	// what the question needs.
	NSUInteger pnidCount =
		[pnids isKindOfClass:NSArray.class] ? ((NSArray *)pnids).count : 0;

	FBPDiag(@"notify", @"client-sync query: count=%@ cursor=%@%@ pnids=%lu ours=%d", count ?: @"(nil)",
	        cursor ?: @"(nil)",
	        effectiveCursor == cursor ? @"" : [NSString stringWithFormat:@" -> %@", effectiveCursor],
	        (unsigned long)pnidCount, gOurSyncInFlight);

	return %orig(count, effectiveCursor, deviceId, extraData, pnids);
}

%end

// Called once per notification the server returned. Silence here means the
// response was empty.
%hook FBPushNotifClientSyncManager

- (void)evaluatePush:(id)push {
	FBPTraceFire("notif.FBPushNotifClientSyncManager.evaluatePush");
	FBPDiagLog(@"client sync: evaluating a fetched push");
	%orig;
}

%end

// Why a fetched notification was not shown.
%hook FBPushNotifClientSyncLocalFilterResult

- (id)dropWithReason:(id)reason {
	FBPTraceFire("notif.FBPushNotifClientSyncLocalFilterResult.dropWithReason");
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
