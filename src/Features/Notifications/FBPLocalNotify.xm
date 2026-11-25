// Post the banner ourselves, out of text Facebook has already fetched.
//
// A like, comment, tag or friend request arrives as a contentless push: badge,
// sound, no alert and no mutable-content. iOS will not present it and will not
// start the notification service extension for it, so FBPNotifyBridge never
// runs (see FBPNotifyBridge/README.md); it wakes the app in the background
// instead, where FBPNotifClientSync.xm runs Facebook's own client sync.
//
// That sync reports SUCCEEDED and posts nothing: -evaluatePush: is never
// reached, because the app-side query is a *page* query whose pnids array reads
// as "these I already have", and the pnid-targeted query exists only inside the
// extension binary.
//
// So the text is watched for instead. The chokepoint is Facebook's own store,
// -[FBNotificationsSQLiteManager saveObject:toTable:]: every path that persists
// a notification goes through it, and its schema is generic (id + data BLOB),
// so what it is handed is the model object with its text still on it. Hooking
// the write means no table name to hardcode, no archive format to parse and no
// fetch to drive. -[FBPushNotifClientSyncManager evaluatePush:] is hooked as
// the other end of the same question, before Facebook's own filters and dedup
// directory can drop a push.
//
// Neither object's class is documented and both may be renamed, so the text is
// found by probing candidate accessors with -respondsToSelector: and unwrapping
// whatever answers (NSString, or NSAttributedString / FBNotificationText
// through -string), so a release that renames some of them still works.
//
// It never posts while the app is foreground-active, never posts the same
// notification twice (identifiers are claimed in a bounded persisted set, and
// -addNotificationRequest:withCompletionHandler: is hooked so an identifier
// Facebook posts itself is claimed too), and never requests authorization,
// which cannot be answered from a background wake. It shares the
// notifClientSync preference because the two halves are one promise.
//
// Logging goes through FBPDiag(@"notify", …), compiled into the release build,
// because this feature's failure mode is "nothing happened" — which an absent
// log cannot tell apart from "the hook never ran". The always-on lines carry
// structure and never content: class names, the table, which accessor
// answered, text *lengths*, the identifier and the decision.

#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPTrace.h"
#import "Header.h"

@interface FBPNotifText: NSObject
- (NSString *)string;
@end

#pragma mark - Keeping the record readable

// Once per kind, not once per row. Unsynchronized on purpose: two threads
// racing log twice, where a lock on Facebook's save path would cost more.
static BOOL fbpNotifySeenOnce(NSString *key) {
	static NSMutableSet<NSString *> *seen;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		seen = [NSMutableSet set];
	});

	if (key.length == 0 || [seen containsObject:key]) {
		return NO;
	}
	if (seen.count < 256) {
		[seen addObject:key];
	}
	return YES;
}

// The object's declared property names, capped: what turns "no text found"
// into the next accessor to try, and names Facebook's API, not user data.
static NSString *fbpNotifyPropertyNames(id object) {
	Class cls = [object class];
	NSMutableArray<NSString *> *names = [NSMutableArray array];

	while (cls && cls != NSObject.class && names.count < 40) {
		unsigned int count = 0;
		objc_property_t *properties = class_copyPropertyList(cls, &count);
		if (properties) {
			for (unsigned int i = 0; i < count && names.count < 40; i++) {
				const char *name = property_getName(properties[i]);
				if (name) {
					[names addObject:@(name)];
				}
			}
			free(properties);
		}
		cls = class_getSuperclass(cls);
	}

	return names.count > 0 ? [names componentsJoinedByString:@","] : @"(none)";
}

#pragma mark - Which identifiers have already been shown

// Mirrors kSuiteName in src/Core/FBPPrefs.m, read directly because this
// persists an array, which that store does not carry — and a push-woken process
// is a fresh one, so an in-memory set forgets between pushes.
static NSString *const kFBPNotifySuite = @"com.shajon.fbplus";
static NSString *const kFBPNotifyPostedKey = @"localNotifyPostedIDs";

static const NSUInteger kFBPNotifyPostedLimit = 200;

static NSObject *fbpNotifyLock(void) {
	static NSObject *lock;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		lock = [NSObject new];
	});
	return lock;
}

// YES when this identifier was not shown before and is now claimed. Read, test
// and write are one critical section: the hooks run on Facebook's own queues.
static BOOL fbpNotifyClaim(NSString *identifier) {
	if (identifier.length == 0) {
		return NO;
	}

	@synchronized (fbpNotifyLock()) {
		NSUserDefaults *store = [[NSUserDefaults alloc] initWithSuiteName:kFBPNotifySuite];
		if (!store) {
			return NO;
		}

		id stored = [store objectForKey:kFBPNotifyPostedKey];
		NSArray *posted = [stored isKindOfClass:NSArray.class] ? (NSArray *)stored : @[];
		if ([posted containsObject:identifier]) {
			return NO;
		}

		NSMutableArray *updated = [posted mutableCopy];
		[updated addObject:identifier];
		if (updated.count > kFBPNotifyPostedLimit) {
			[updated removeObjectsInRange:NSMakeRange(0, updated.count - kFBPNotifyPostedLimit)];
		}
		[store setObject:[updated copy] forKey:kFBPNotifyPostedKey];
		return YES;
	}
}

#pragma mark - Reading the text off an object whose class we do not own

static NSString *fbpNotifyUnwrap(id value) {
	if ([value isKindOfClass:NSString.class]) {
		NSString *text = (NSString *)value;
		return text.length > 0 ? text : nil;
	}
	if ([value isKindOfClass:NSAttributedString.class]) {
		NSString *text = ((NSAttributedString *)value).string;
		return text.length > 0 ? text : nil;
	}
	// By selector rather than class, so a rename costs nothing.
	if ([value respondsToSelector:@selector(string)]) {
		id text = [(FBPNotifText *)value string];
		if ([text isKindOfClass:NSString.class] && ((NSString *)text).length > 0) {
			return (NSString *)text;
		}
	}
	return nil;
}

// -respondsToSelector: first, so a missing key costs a lookup rather than an
// NSUndefinedKeyException; -valueForKey: still runs inside the caller's @try,
// because a synthesised accessor can raise.
static NSString *fbpNotifyFirstText(id object, NSArray<NSString *> *keys,
                                    NSString **matchedKey) {
	for (NSString *key in keys) {
		SEL selector = NSSelectorFromString(key);
		if (!selector || ![object respondsToSelector:selector]) {
			continue;
		}
		NSString *text = fbpNotifyUnwrap([object valueForKey:key]);
		if (text.length > 0) {
			if (matchedKey) {
				*matchedKey = key;
			}
			return text;
		}
	}
	return nil;
}

// A stable identifier, so the same notification down two paths shows once:
// Facebook's own push notif id, else the text's hash.
static NSString *fbpNotifyIdentifier(id object, NSString *title, NSString *body,
                                     NSString **matchedKey) {
	static NSArray<NSString *> *keys;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		keys = @[ @"pnid", @"pushNotifID", @"notifID", @"notificationID", @"objectID", @"identifier" ];
	});

	for (NSString *key in keys) {
		SEL selector = NSSelectorFromString(key);
		if (!selector || ![object respondsToSelector:selector]) {
			continue;
		}
		id value = [object valueForKey:key];
		if ([value isKindOfClass:NSString.class] && ((NSString *)value).length > 0) {
			if (matchedKey) {
				*matchedKey = key;
			}
			return (NSString *)value;
		}
		if ([value isKindOfClass:NSNumber.class]) {
			if (matchedKey) {
				*matchedKey = key;
			}
			return ((NSNumber *)value).stringValue;
		}
	}

	// A run where every notification lands on the hash means the id accessors
	// above need a new name, so the log says the fallback was taken.
	if (matchedKey) {
		*matchedKey = @"hash-fallback";
	}
	return [NSString stringWithFormat:@"fbp-%lu",
	                                  (unsigned long)[[NSString stringWithFormat:@"%@|%@",
	                                                                             title ?: @"",
	                                                                             body ?: @""] hash]];
}

#pragma mark - Posting

// Main queue: -applicationState is a main-thread read, and the hooks that lead
// here run on Facebook's own queues.
static void fbpNotifyPost(NSString *identifier, NSString *title, NSString *body, NSString *source) {
	dispatch_async(dispatch_get_main_queue(), ^{
		UIApplication *application = UIApplication.sharedApplication;
		if (!application) {
			FBPDiagFail(@"notify", @"%@: no UIApplication, cannot post id=%@", source, identifier);
			return;
		}

		UIApplicationState state = application.applicationState;
		if (state == UIApplicationStateActive) {
			FBPDiag(@"notify", @"%@: app active (state=%ld), skipping id=%@", source, (long)state,
			        identifier);
			return;
		}

		if (!fbpNotifyClaim(identifier)) {
			FBPDiag(@"notify", @"%@: id=%@ already shown, skipping", source, identifier);
			return;
		}

		UNMutableNotificationContent *content = [UNMutableNotificationContent new];
		if (title.length > 0) {
			content.title = title;
		}
		content.body = body;
		content.sound = UNNotificationSound.defaultSound;

		// nil trigger delivers immediately. The prefix only keeps the
		// identifier distinct; the claim above is what stops a duplicate.
		UNNotificationRequest *request =
			[UNNotificationRequest requestWithIdentifier:[@"fbplus." stringByAppendingString:identifier]
			                                    content:content
			                                    trigger:nil];

		FBPDiag(@"notify", @"%@: posting id=%@ state=%ld title=%lu body=%lu", source, identifier,
		        (long)state, (unsigned long)title.length, (unsigned long)body.length);

		[UNUserNotificationCenter.currentNotificationCenter
		    addNotificationRequest:request
		     withCompletionHandler:^(NSError *error) {
			if (error) {
				FBPDiagFail(@"notify", @"%@: post of id=%@ failed — %@", source, identifier,
				            error.localizedDescription ?: error);
			} else {
				FBPDiag(@"notify", @"%@: delivered id=%@", source, identifier);
			}
		}];
	});
}

// Read-only and wrapped, so an object that is not a notification — and the
// store hook sees every kind — costs one failed probe and is dropped.
static void fbpNotifyConsider(id object, NSString *source, NSString *detail) {
	if (!object) {
		return;
	}
	if (!FBPEnabled(FBPKeyNotifClientSync)) {
		if (fbpNotifySeenOnce(@"disabled")) {
			FBPDiag(@"notify", @"disabled in settings — not posting anything this launch");
		}
		return;
	}

	static NSArray<NSString *> *titleKeys;
	static NSArray<NSString *> *bodyKeys;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		titleKeys = @[ @"title", @"titleText", @"headline", @"senderName", @"subtitle" ];
		bodyKeys = @[ @"body", @"bodyText", @"message", @"messageText", @"text",
		              @"alertBody", @"summary", @"shortSummary", @"notificationText" ];
	});

	NSString *className = NSStringFromClass([object class]) ?: @"(unknown)";

	@try {
		NSString *titleKey = nil;
		NSString *bodyKey = nil;
		NSString *title = fbpNotifyFirstText(object, titleKeys, &titleKey);
		NSString *body = fbpNotifyFirstText(object, bodyKeys, &bodyKey);

		// Better as the body than a bare title: iOS shows "Facebook" above it.
		if (body.length == 0) {
			body = title;
			bodyKey = titleKey;
			title = nil;
			titleKey = nil;
		}

		if (body.length == 0) {
			// Once per class-and-table, with the property names that say which
			// accessor to add next.
			NSString *once = [NSString stringWithFormat:@"notext.%@.%@", className, detail ?: @"-"];
			if (fbpNotifySeenOnce(once)) {
				FBPDiag(@"notify", @"%@: no text on %@ (%@) — properties: %@", source, className,
				        detail ?: @"no detail", fbpNotifyPropertyNames(object));
			}
			return;
		}

		NSString *idKey = nil;
		NSString *identifier = fbpNotifyIdentifier(object, title, body, &idKey);

		// Always logged: lengths and accessor names only, never the words.
		FBPDiag(@"notify", @"%@: text on %@ (%@) id=%@ via=%@ title=%@/%lu body=%@/%lu", source,
		        className, detail ?: @"no detail", identifier, idKey ?: @"-", titleKey ?: @"-",
		        (unsigned long)title.length, bodyKey ?: @"-", (unsigned long)body.length);
		FBPDiagLog(@"local notify: title=%@ body=%@", title ?: @"(none)", body);

		fbpNotifyPost(identifier, title, body, source);
	} @catch (NSException *exception) {
		FBPDiagFail(@"notify", @"%@: probe of %@ threw %@ — %@", source, className, exception.name,
		            exception.reason ?: @"(no reason)");
	}
}

#pragma mark - Wider net: where else does the text appear?

// Log-only, deliberately: all three hooks below install and none has been seen
// to fire, so either FBNotificationsSQLiteManager is not what holds the
// notification list on current builds or it is only written in situations not
// yet reached. These two taps ask the device instead. They never post, because
// FBNotificationText is built by the list UI too and a background fetch could
// make dozens; once a line appears in a background wake, that is the chokepoint
// to post from. Once per distinct text, so a redraw does not fill the record.
static void fbpNotifyObserveText(NSString *text, NSString *where) {
	if (text.length == 0) {
		return;
	}
	NSString *once = [NSString stringWithFormat:@"text.%@.%lu", where, (unsigned long)text.hash];
	if (!fbpNotifySeenOnce(once)) {
		return;
	}

	UIApplication *application = UIApplication.sharedApplication;
	// -applicationState is main-thread only, and this runs on whichever queue
	// built the text, so say so rather than read it.
	NSString *state = NSThread.isMainThread && application
	                      ? [NSString stringWithFormat:@"%ld", (long)application.applicationState]
	                      : @"off-main";

	FBPDiag(@"notify", @"text seen via %@ len=%lu state=%@", where, (unsigned long)text.length,
	        state);
	FBPDiagLog(@"local notify: %@ text=%@", where, text);
}

#pragma mark - Hooks

%group FBPLocalNotifyStore

%hook FBNotificationsSQLiteManager

- (void)saveObject:(id)object toTable:(NSString *)table {
	FBPTraceFire("notif.FBNotificationsSQLiteManager.saveObject");
	%orig;

	// The table name is a parameter of Facebook's generic schema, so this line
	// is the only place it is learned.
	NSString *name = table ?: @"(nil)";
	if (fbpNotifySeenOnce([@"table." stringByAppendingString:name])) {
		FBPDiag(@"notify", @"store: table '%@' in use, first write was %@", name,
		        NSStringFromClass([object class]) ?: @"(unknown)");
	}

	fbpNotifyConsider(object, @"store", name);
}

- (id)fetchObjectsFromTable:(NSString *)table {
	id result = %orig;
	NSString *name = table ?: @"(nil)";
	if (fbpNotifySeenOnce([@"fetch." stringByAppendingString:name])) {
		NSUInteger count = [result isKindOfClass:NSArray.class] ? ((NSArray *)result).count : 0;
		FBPDiag(@"notify", @"store: read table '%@' -> %lu object(s)", name, (unsigned long)count);
	}
	return result;
}

%end

%end  // group FBPLocalNotifyStore

// Every notification's words are built through this, so if the store is the
// wrong chokepoint this is where they show up. Log-only.
%group FBPLocalNotifyText

%hook FBNotificationText

- (instancetype)initWithString:(NSString *)string {
	id result = %orig;
	fbpNotifyObserveText(string, @"FBNotificationText.initWithString:");
	return result;
}

- (instancetype)initWithString:(NSString *)string
                        tokens:(id)tokens
                   fontFoundry:(id)fontFoundry {
	id result = %orig;
	fbpNotifyObserveText(string, @"FBNotificationText.initWithString:tokens:");
	return result;
}

%end

%end  // group FBPLocalNotifyText

// A push the client sync did fetch, before Facebook's filters can drop it.
%group FBPLocalNotifySync

%hook FBPushNotifClientSyncManager

- (void)evaluatePush:(id)push {
	FBPTraceFire("notif.local.evaluatePush");
	// This call has never been observed, so each one is worth a line.
	FBPDiag(@"notify", @"client-sync: evaluatePush: reached with %@",
	        NSStringFromClass([push class]) ?: @"(unknown)");
	%orig;
	fbpNotifyConsider(push, @"client-sync", nil);
}

%end

%end  // group FBPLocalNotifySync

// Claim what Facebook posts itself, so if its pipeline starts working this
// stands down rather than showing a second banner.
%group FBPLocalNotifyClaim

%hook UNUserNotificationCenter

- (void)addNotificationRequest:(UNNotificationRequest *)request
         withCompletionHandler:(void (^)(NSError *))completionHandler {
	NSString *identifier = request.identifier;
	// Our own posts arrive here too, already claimed; claiming twice is a no-op.
	if (identifier.length > 0 && ![identifier hasPrefix:@"fbplus."]) {
		// Facebook posting at all means its pipeline works, so log every one.
		FBPDiag(@"notify", @"facebook posted its own request id=%@ (claimed=%d)", identifier,
		        fbpNotifyClaim(identifier));
	}
	%orig;
}

%end

%end  // group FBPLocalNotifyClaim

%ctor {
	// Verify class and selector before installing, and keep each group
	// independent: the store hook must not be held back by a class that moved.
	BOOL storeHooked = NO;
	BOOL syncHooked = NO;
	BOOL claimHooked = NO;

	Class store = objc_getClass("FBNotificationsSQLiteManager");
	if (store && class_getInstanceMethod(store, @selector(saveObject:toTable:))) {
		%init(FBPLocalNotifyStore);
		storeHooked = YES;
	} else {
		FBPDiagFail(@"notify", @"no FBNotificationsSQLiteManager -saveObject:toTable: in this "
		                       @"build — the main text source is gone");
	}

	Class text = objc_getClass("FBNotificationText");
	if (text && class_getInstanceMethod(text, @selector(initWithString:))) {
		%init(FBPLocalNotifyText);
	}

	Class sync = objc_getClass("FBPushNotifClientSyncManager");
	if (sync && class_getInstanceMethod(sync, @selector(evaluatePush:))) {
		%init(FBPLocalNotifySync);
		syncHooked = YES;
	} else {
		FBPDiagFail(@"notify", @"no FBPushNotifClientSyncManager -evaluatePush: — sync hook off");
	}

	Class center = objc_getClass("UNUserNotificationCenter");
	if (center &&
	    class_getInstanceMethod(center,
	                            @selector(addNotificationRequest:withCompletionHandler:))) {
		%init(FBPLocalNotifyClaim);
		claimHooked = YES;
	} else {
		FBPDiagFail(@"notify", @"no UNUserNotificationCenter -addNotificationRequest: — "
		                       @"duplicate guard off");
	}

	// How much of this feature is live, so a silent run can be told apart from
	// one that never installed. Emitted twice because FBPLogClearIfDue() runs
	// from FBPEntry's constructor and wipes the record, and constructors do not
	// all run before it; repeating it on a delay puts it after the clear. The
	// entitlement mode belongs here because it decides what the notification
	// path even is, and FBPDiag survives a release build.
	NSString *summary =
		[NSString stringWithFormat:
		             @"installed: store=%d sync=%d claim=%d, enabled=%d, entitlements=%s, process=%@",
		             storeHooked, syncHooked, claimHooked, FBPEnabled(FBPKeyNotifClientSync),
		             fbpProcessHasOriginalEntitlements() ? "ORIGINAL (redirects off)"
		                                                 : "re-signed (redirects on)",
		             NSBundle.mainBundle.bundleIdentifier ?: @"(unknown)"];
	FBPDiag(@"notify", @"%@", summary);
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
	               dispatch_get_main_queue(), ^{
		FBPDiag(@"notify", @"%@ (8s after launch)", summary);
	});
}
