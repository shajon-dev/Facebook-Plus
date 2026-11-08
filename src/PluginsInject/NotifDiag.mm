// FBP_DIAG-only: report what iOS thinks this app is allowed to show.
//
// Why this exists. Device logs on 2026-11-08 showed the notification extension
// being registered by runningboardd but **never launched** for a push, while
// the app itself woke and read its keychain each time and the badge count rose.
// iOS does not run a service extension for a notification it is not going to
// present, so "alerts are switched off" and "the extension is broken" look
// identical from the outside — and a reinstall resets those settings. This
// prints the answer instead of asking someone to read a Settings screen.
//
// Main tweak only: an appex has its own (different) settings, and this links
// UserNotifications, which FBPNotifyBridge.dylib deliberately does not.
//
// No Logos directives here on purpose. Logos emits its registration code at the
// end of the file, *outside* any #if, so a %hook or %ctor wrapped in
// #if FBP_DIAG still gets referenced in a non-diagnostic build and fails to
// compile. A plain constructor keeps the whole file inert instead.

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

// Facebook's own framework carries -[UNUserNotificationCenter
// addNotificationRequest:withCompletionHandler:], so the app CAN post a local
// notification — which is what a content-available push expects it to do after
// DUET wakes it. These two hooks answer whether it tries, and what it was
// handed to work with.

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

// The payload of a push that arrives with no alert. If it carries the text (or
// an id the app could resolve), the tweak could post the notification itself —
// which is the whole point of looking.
static void hookRemoteNotificationDelivery(void) {
	id delegate = UIApplication.sharedApplication.delegate;
	if (!delegate) {
		FBPDiagLog(@"no app delegate yet — cannot trace remote notifications");
		return;
	}

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
		FBPDiagLog(@"didReceiveRemoteNotification payload: %@", userInfo ?: @"(nil)");
		if (original) {
			((void (*)(id, SEL, UIApplication *, NSDictionary *, id))original)(
				receiver, selector, application, userInfo, handler);
		}
	});

	original = method_setImplementation(method, replacement);
	FBPDiagLog(@"tracing remote notifications on %@", NSStringFromClass([delegate class]));
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

	hookRemoteNotificationDelivery();
}

__attribute__((constructor)) static void FBPNotifDiagInit() {
	// Read it twice: at launch Facebook may not have finished registering, and
	// the authorization prompt (on a fresh install) may still be on screen.
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
	               dispatch_get_main_queue(), ^{
		dumpNotificationSettings(@"8s after launch");
		installDeliveryHooks();
	});
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)),
	               dispatch_get_main_queue(), ^{
		dumpNotificationSettings(@"30s after launch");
	});
}

#endif
