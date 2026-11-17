// FBP_DIAG-only: report what iOS thinks this app is allowed to show.
//
// Device logs on 2026-11-08 showed the notification extension registered by
// runningboardd but never launched for a push, while the app woke, read its
// keychain, and the badge count rose. iOS does not run a service extension for a
// notification it will not present, so "alerts off" and "extension broken" look
// identical from outside, and a reinstall resets those settings. This prints the
// answer instead of asking someone to read a Settings screen.
//
// Main tweak only: an appex has its own settings, and this links
// UserNotifications, which FBPNotifyBridge.dylib deliberately does not.
//
// No Logos directives here on purpose: Logos emits its registration code at the
// end of the file, outside any #if, so a %hook or %ctor wrapped in #if FBP_DIAG
// is still referenced in a non-diagnostic build and fails to compile. A plain
// constructor keeps the whole file inert.

#if FBP_DIAG

#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>

#import "Header.h"

static NSString *describeAuthorization(UNAuthorizationStatus status) {
	switch (status) {
		case UNAuthorizationStatusNotDetermined: return @"not-determined";
		case UNAuthorizationStatusDenied:        return @"DENIED";
		case UNAuthorizationStatusAuthorized:    return @"authorized";
		case UNAuthorizationStatusProvisional:   return @"PROVISIONAL (quiet)";
		case UNAuthorizationStatusEphemeral:     return @"ephemeral";
	}
	return [NSString stringWithFormat:@"unknown(%ld)", (long)status];
}

static NSString *describeSetting(UNNotificationSetting setting) {
	switch (setting) {
		case UNNotificationSettingNotSupported: return @"n/a";
		case UNNotificationSettingDisabled:     return @"OFF";
		case UNNotificationSettingEnabled:      return @"on";
	}
	return [NSString stringWithFormat:@"unknown(%ld)", (long)setting];
}

static void dumpNotificationSettings(NSString *when) {
	[[UNUserNotificationCenter currentNotificationCenter]
	    getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *s) {
		FBPDiagLog(@"notification settings (%@): authorization=%@ alert=%@ lockScreen=%@ "
		           @"notificationCenter=%@ badge=%@ sound=%@ alertStyle=%ld "
		           @"timeSensitive=%@ announcement=%@ criticalAlert=%@",
		           when,
		           describeAuthorization(s.authorizationStatus),
		           describeSetting(s.alertSetting),
		           describeSetting(s.lockScreenSetting),
		           describeSetting(s.notificationCenterSetting),
		           describeSetting(s.badgeSetting),
		           describeSetting(s.soundSetting),
		           (long)s.alertStyle,
		           describeSetting(s.timeSensitiveSetting),
		           describeSetting(s.announcementSetting),
		           describeSetting(s.criticalAlertSetting));
	}];
}

#pragma mark - Does Facebook ever try to post the notification itself?

// Facebook's framework carries -[UNUserNotificationCenter
// addNotificationRequest:withCompletionHandler:], so the app can post a local
// notification — what a content-available push expects after DUET wakes it.
// These two hooks record whether it does, and with what.

static void (*origAddNotificationRequest)(id, SEL, UNNotificationRequest *, void (^)(NSError *));

static void fbpAddNotificationRequest(id self, SEL _cmd, UNNotificationRequest *request,
                                      void (^completion)(NSError *)) {
	FBPDiagLog(@"addNotificationRequest id=%@ title=%@ subtitle=%@ body=%@ badge=%@ trigger=%@",
	           request.identifier ?: @"(nil)",
	           request.content.title ?: @"(empty)",
	           request.content.subtitle ?: @"(empty)",
	           request.content.body ?: @"(empty)",
	           request.content.badge ?: @"(nil)",
	           request.trigger ?: @"(immediate)");

	NSString *identifier = [request.identifier copy];
	origAddNotificationRequest(self, _cmd, request, ^(NSError *error) {
		FBPDiagLog(@"addNotificationRequest %@ -> %@", identifier ?: @"(nil)",
		           error ? error.localizedDescription : @"accepted");
		if (completion) completion(error);
	});
}

#pragma mark - The push shape, which is the whole question

// iOS starts a notification service extension only for a push that carries BOTH
// `mutable-content: 1` and user-visible alert content. Everything about this
// investigation turns on which of those a given Facebook push actually has:
//
//   alert + mutable-content  → the extension runs. If the text is still generic
//                              the extension ran and lost, which is a session
//                              problem and fixable inside FBPNotifyBridge.
//   content-available only   → the extension is never started at all. iOS sets
//                              the badge, drops the notification, and wakes the
//                              app in the background instead. Nothing in the
//                              extension can help; the app has to finish
//                              Facebook's own client-sync fetch itself.
//
// Messenger's pushes are known to be the first kind. Whether the pushes behind
// likes, comments, tags and friend requests are the second is the one thing a
// capture has to establish, so it gets its own line rather than being left for
// someone to spot inside a JSON dump.
static NSString *describeAlert(id alert) {
    if ([alert isKindOfClass:NSString.class]) {
        return ((NSString *)alert).length ? @"string" : @"empty-string";
    }
    if ([alert isKindOfClass:NSDictionary.class]) {
        NSDictionary *dict = alert;
        id titleValue = dict[@"title"];
        id bodyValue  = dict[@"body"];
        BOOL title = [titleValue isKindOfClass:NSString.class] && ((NSString *)titleValue).length > 0;
        BOOL body  = [bodyValue isKindOfClass:NSString.class] && ((NSString *)bodyValue).length > 0;
        BOOL loc   = dict[@"loc-key"] != nil || dict[@"title-loc-key"] != nil;
        if (!title && !body && !loc) return @"dict-but-empty";
        return [NSString stringWithFormat:@"dict(title=%d body=%d loc-key=%d)", title, body, loc];
    }
    return alert ? @"other" : @"none";
}

static void logPushShape(NSDictionary *userInfo) {
    NSDictionary *aps = [userInfo[@"aps"] isKindOfClass:NSDictionary.class] ? userInfo[@"aps"] : nil;
    if (!aps) {
        FBPDiagLog(@"PUSH SHAPE: no aps dictionary — not an APNs payload");
        return;
    }

    id alert = aps[@"alert"];
    NSString *alertDesc = describeAlert(alert);
    BOOL hasAlert = !([alertDesc isEqualToString:@"none"] ||
                      [alertDesc isEqualToString:@"empty-string"] ||
                      [alertDesc isEqualToString:@"dict-but-empty"]);
    BOOL mutableContent  = [aps[@"mutable-content"] boolValue];
    BOOL contentAvailable = [aps[@"content-available"] boolValue];

    // The verdict, in the same terms iOS itself uses, so the capture does not
    // need a second reading pass.
    NSString *verdict;
    if (hasAlert && mutableContent) {
        verdict = @"NSE WILL RUN";
    } else if (hasAlert) {
        verdict = @"shown as-is, NSE SKIPPED (no mutable-content)";
    } else if (contentAvailable) {
        verdict = @"NO BANNER, app woken in background (contentless push)";
    } else {
        verdict = @"NO BANNER and no background wake";
    }

    FBPDiagLog(@"PUSH SHAPE: alert=%@ mutable-content=%d content-available=%d "
               @"badge=%@ sound=%@ category=%@ → %@",
               alertDesc, mutableContent, contentAvailable,
               aps[@"badge"] ?: @"(none)",
               aps[@"sound"] ?: @"(none)",
               aps[@"category"] ?: @"(none)",
               verdict);

    // Which Facebook payload keys came along, without their values: the keys
    // alone say which expansion path the server meant this push to take.
    NSArray *keys = [[userInfo.allKeys valueForKey:@"description"]
        sortedArrayUsingSelector:@selector(compare:)];
    FBPDiagLog(@"PUSH KEYS: %@", [keys componentsJoinedByString:@","] ?: @"(none)");
}

// os_log drops a long message, and an NSDictionary description spans lines that
// a line-based log filter loses. One line, JSON where possible, split into
// chunks small enough to survive.
static void logPayload(NSDictionary *userInfo) {
	if (!userInfo) {
		FBPDiagLog(@"didReceiveRemoteNotification payload: (nil)");
		return;
	}

	NSString *text = nil;
	if ([NSJSONSerialization isValidJSONObject:userInfo]) {
		NSData *json = [NSJSONSerialization dataWithJSONObject:userInfo options:0 error:nil];
		if (json) {
			text = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
		}
	}
	if (!text) {
		text = [[userInfo.description componentsSeparatedByCharactersInSet:
		            NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "];
	}

	const NSUInteger chunk = 700;
	NSUInteger total = (text.length + chunk - 1) / chunk;
	for (NSUInteger i = 0; i < total; i++) {
		NSRange range = NSMakeRange(i * chunk, MIN(chunk, text.length - i * chunk));
		FBPDiagLog(@"payload [%lu/%lu] %@", (unsigned long)(i + 1), (unsigned long)total,
		           [text substringWithRange:range]);
	}
}

// The payload of a push that arrives with no alert. If it carries the text (or
// a resolvable id), the tweak could post the notification itself.
static void hookRemoteNotificationDelivery(void) {
	static BOOL hooked = NO;
	if (hooked) return;

	id delegate = UIApplication.sharedApplication.delegate;
	if (!delegate) {
		return;  // -setDelegate: will call back here
	}
	hooked = YES;

	SEL selector = @selector(application:didReceiveRemoteNotification:fetchCompletionHandler:);
	Method method = class_getInstanceMethod([delegate class], selector);
	if (!method) {
		FBPDiagLog(@"%@ does not implement %@", NSStringFromClass([delegate class]),
		           NSStringFromSelector(selector));
		return;
	}

	__block IMP original = NULL;
	IMP replacement = imp_implementationWithBlock(^(id receiver, UIApplication *application,
	                                                NSDictionary *userInfo, id handler) {
		// Background vs active decides how long this process has to live. A push
		// that wakes a suspended app gets a few seconds unless something holds a
		// background assertion, which is the suspected reason Facebook's own
		// client-sync fetch never finishes on a re-signed build.
		UIApplicationState state = application.applicationState;
		NSString *stateName = state == UIApplicationStateActive     ? @"active"
		                    : state == UIApplicationStateInactive   ? @"inactive"
		                                                            : @"BACKGROUND";
		FBPDiagLog(@"didReceiveRemoteNotification — app state %@", stateName);

		logPushShape(userInfo);
		logPayload(userInfo);

		// Whether Facebook calls the fetch completion handler, and how long it
		// takes to. Calling it immediately is what lets iOS suspend the process,
		// so this is the measurement that says whether holding an assertion
		// would actually buy the fetch any time.
		NSDate *start = NSDate.date;
		id tracedHandler = handler;
		if (handler) {
			tracedHandler = [^(NSUInteger result) {
				FBPDiagLog(@"fetchCompletionHandler called after %.2fs with result %lu",
				           -start.timeIntervalSinceNow, (unsigned long)result);
				((void (^)(NSUInteger))handler)(result);
			} copy];
		}

		if (original) {
			((void (*)(id, SEL, UIApplication *, NSDictionary *, id))original)(
				receiver, selector, application, userInfo, tracedHandler);
		}
	});

	original = method_setImplementation(method, replacement);
	FBPDiagLog(@"tracing remote notifications on %@", NSStringFromClass([delegate class]));
}

// -[UIApplication setDelegate:] is where the delegate first becomes reachable.
// Waiting on a timer is not good enough: a push-woken launch is suspended within
// a couple of seconds, and that is the launch whose payload matters.
static void (*origSetDelegate)(id, SEL, id);

static void fbpSetDelegate(id self, SEL _cmd, id delegate) {
	origSetDelegate(self, _cmd, delegate);
	hookRemoteNotificationDelivery();
}

static void installDeliveryHooks(void) {
	static BOOL installed = NO;
	if (installed) return;
	installed = YES;

	Method add = class_getInstanceMethod([UNUserNotificationCenter class],
	                                     @selector(addNotificationRequest:withCompletionHandler:));
	if (add) {
		origAddNotificationRequest = (void (*)(id, SEL, UNNotificationRequest *, void (^)(NSError *)))
			method_setImplementation(add, (IMP)fbpAddNotificationRequest);
		FBPDiagLog(@"tracing addNotificationRequest:");
	}

	Method setDelegate = class_getInstanceMethod([UIApplication class], @selector(setDelegate:));
	if (setDelegate) {
		origSetDelegate = (void (*)(id, SEL, id))method_setImplementation(setDelegate,
		                                                                 (IMP)fbpSetDelegate);
	}

	// Covers the case where the delegate was already set before this ran.
	hookRemoteNotificationDelivery();
}

__attribute__((constructor)) static void FBPNotifDiagInit() {
	// At load, so a background launch that lives two seconds is still traced.
	installDeliveryHooks();

	// Read it twice: at launch Facebook may not have finished registering, and
	// the authorization prompt (on a fresh install) may still be on screen.
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
	               dispatch_get_main_queue(), ^{
		dumpNotificationSettings(@"8s after launch");
	});
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)),
	               dispatch_get_main_queue(), ^{
		dumpNotificationSettings(@"30s after launch");
	});
}

#endif
