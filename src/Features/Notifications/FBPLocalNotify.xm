// Post the banner ourselves, out of text Facebook has already fetched.
//
// THE GAP THIS FILLS
//
// A like, comment, tag or friend request arrives as a contentless push:
// content-available:1, a badge, a sound, "pim":{"nt":"badge_update"}, and no
// alert and no mutable-content. iOS will not present it and will not start the
// notification service extension for it, so FBPNotifyBridge never runs — see
// FBPNotifyBridge/README.md. What iOS does instead is wake the app in the
// background, which is where FBPNotifClientSync.xm picks the push up and runs
// Facebook's own client sync.
//
// That sync reports SUCCEEDED and posts nothing. Two device captures showed
// -evaluatePush: never being reached, so the GraphQL response carried no push
// to evaluate — the app-side query is a *page* query whose pnids array reads as
// "these I already have", and the pnid-targeted query exists only inside the
// extension (FBPushNotifClientSyncExtensionGraphQLQuery is in the appex binary
// and nowhere else). So waiting for Facebook's own display pipeline to fire is
// waiting for a call that does not come.
//
// WHAT THIS DOES INSTEAD
//
// It stops asking Facebook to display anything and watches for the text to
// appear anywhere in the process, then posts a local notification itself.
//
// The chokepoint that makes this practical is Facebook's own notification
// store: -[FBNotificationsSQLiteManager saveObject:toTable:]. Every path that
// persists a notification goes through it — client sync, the jewel sync, a tab
// load — and its schema is generic ("CREATE TABLE IF NOT EXISTS %@ (id INTEGER
// PRIMARY KEY AUTOINCREMENT, data BLOB NOT NULL)"), so the object handed to it
// is the model object itself, with its text still on it. Hooking the write
// rather than reading the database back means no table name to hardcode, no
// archive format to parse, and no fetch to drive: whatever Facebook learns, we
// see at the moment it learns it.
//
// -[FBPushNotifClientSyncManager evaluatePush:] is hooked for the same reason,
// as the other end of the same question: if a response ever does carry a push,
// its text is on that object, and Facebook's own filters (the push-settings
// filter, and the dedup directory that a re-signed build redirects along with
// every other container) can still drop it afterwards. We read it before they
// get the chance.
//
// WHY NOTHING IS HARDCODED
//
// Neither object's class is documented and both are free to be renamed, so the
// text is found by asking: a short list of candidate accessors is probed with
// -respondsToSelector:, and whatever answers is unwrapped — an NSString as
// itself, an NSAttributedString or Facebook's own FBNotificationText through
// -string. A Facebook release that renames every one of them costs this feature
// and nothing else; one that renames some of them still works.
//
// WHAT IT DELIBERATELY DOES NOT DO
//
//   * It never posts while the app is foreground-active. Facebook's own UI is
//     already showing the notification there, and a banner over it is noise.
//   * It never posts the same notification twice. Identifiers are claimed in a
//     bounded, persisted set, and -[UNUserNotificationCenter
//     addNotificationRequest:withCompletionHandler:] is hooked so an identifier
//     Facebook posts itself is claimed too — if Facebook's own pipeline ever
//     starts working, this stands down rather than doubling up.
//   * It does not request notification authorization. A device capture read
//     back authorization=authorized alert=on, so the permission is already
//     there, and a prompt cannot be answered from a background wake.
//
// It shares the notifClientSync preference rather than adding one of its own:
// the two halves make a single promise to the user ("detailed notifications"),
// and either is useless without the other.
//
// LOGGING
//
// Every decision on this path is logged through FBPDiag(@"notify", …), which is
// compiled into the **release** build and lands in the tweak's own record —
// Settings → Logs, with an Export button — as well as os_log. FBPDiagLog is
// deliberately not used here: it compiles away unless FBP_DIAG=1, and this is a
// feature whose whole failure mode is "nothing happened", which is exactly what
// an absent log cannot tell you apart from "the hook never ran".
//
// What the always-on lines carry is **structure, never content**: class names,
// the table written to, which accessor answered, text *lengths*, the identifier,
// and the decision taken. The notification's words are the user's mail, and the
// log is exportable and gets pasted into bug reports. The text itself is logged
// only under FBP_DIAG, and the banner shows it anyway, so a release log never
// needs it.
//
// The store hook sees every object Facebook persists, so an unconditional line
// per write would drown the record. Writes that yielded no text are logged once
// per class-and-table pair; a write that did yield text is always logged. When
// nothing is found, the object's own property names are listed — that is
// structure, and it is the one line that says which accessor to add next.

#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPTrace.h"
#import "Header.h"

// Facebook's own text wrapper (FBNotificationText). Declared for -string only;
// the probe below never assumes the class exists.
@interface FBPNotifText: NSObject
- (NSString *)string;
@end

#pragma mark - Keeping the record readable

// True the first time this key is seen in this process. Used to log the uninter-
// esting store writes once per kind instead of once per row. Unsynchronized on
// purpose, like FBPTraceFire: two threads racing the first call log twice, which
// is harmless, where a lock on Facebook's save path is not.
static BOOL fbpNotifySeenOnce(NSString *key) {
	static NSMutableSet<NSString *> *seen;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		seen = [NSMutableSet set];
	});

	if (key.length == 0 || [seen containsObject:key]) {
		return NO;
	}
	// Bounded: a build that renames classes often should not grow this forever.
	if (seen.count < 256) {
		[seen addObject:key];
	}
	return YES;
}

// The object's own declared property names, up to a cap. This is what turns
// "no text found" from a dead end into the next accessor to try, and it names
// Facebook's API rather than the user's data.
static NSString *fbpNotifyPropertyNames(id object) {
	Class cls = [object class];
	NSMutableArray<NSString *> *names = [NSMutableArray array];

	// Walk up to NSObject so an inherited text property is listed too.
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

// Mirrors kSuiteName in src/Core/FBPPrefs.m. Read directly rather than through
// FBPPrefs because this needs to persist an array, which that store does not
// carry — and because a push-woken process is a fresh process, so an in-memory
// set would forget everything between two pushes.
static NSString *const kFBPNotifySuite = @"com.shajon.fbplus";
static NSString *const kFBPNotifyPostedKey = @"localNotifyPostedIDs";

// Enough to cover a burst without the array ever growing without bound. Oldest
// entries fall off the front.
static const NSUInteger kFBPNotifyPostedLimit = 200;

static NSObject *fbpNotifyLock(void) {
	static NSObject *lock;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		lock = [NSObject new];
	});
	return lock;
}

// YES when this identifier had not been shown before and is now claimed. The
// read, the test and the write are one critical section: the store hook and the
// client-sync hook run on Facebook's own queues and can race.
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

// Unwrap one candidate value. Anything that is not text, or is empty, reads as
// nothing so the caller moves on to the next candidate.
static NSString *fbpNotifyUnwrap(id value) {
	if ([value isKindOfClass:NSString.class]) {
		NSString *text = (NSString *)value;
		return text.length > 0 ? text : nil;
	}
	if ([value isKindOfClass:NSAttributedString.class]) {
		NSString *text = ((NSAttributedString *)value).string;
		return text.length > 0 ? text : nil;
	}
	// FBNotificationText, and anything else that spells its plain text the same
	// way. Checked by selector rather than by class so a rename costs nothing.
	if ([value respondsToSelector:@selector(string)]) {
		id text = [(FBPNotifText *)value string];
		if ([text isKindOfClass:NSString.class] && ((NSString *)text).length > 0) {
			return (NSString *)text;
		}
	}
	return nil;
}

// -respondsToSelector: first, so a key the object does not have costs a lookup
// instead of an NSUndefinedKeyException. -valueForKey: still runs inside the
// caller's @try, because a synthesised accessor can raise on its own.
// matchedKey reports which accessor answered, for the log — the one thing that
// makes a wrong-looking banner diagnosable without a debugger.
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

// A stable identifier for "this notification", so the same one arriving down
// two paths is shown once. Facebook's own push notif id is the right answer
// when the object carries it; the text's hash is the fallback, which is stable
// within a device and is only ever compared against itself.
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

	// No id of Facebook's on the object. The text's hash is only ever compared
	// against itself, so it is enough to stop a repeat — and the log says the
	// fallback was taken, because a run where every notification lands on the
	// hash means the id accessors above need a new name.
	if (matchedKey) {
		*matchedKey = @"hash-fallback";
	}
	return [NSString stringWithFormat:@"fbp-%lu",
	                                  (unsigned long)[[NSString stringWithFormat:@"%@|%@",
	                                                                             title ?: @"",
	                                                                             body ?: @""] hash]];
}

#pragma mark - Posting

// The whole decision runs on the main queue: -applicationState is a main-thread
// read, and the hooks that lead here run on Facebook's own queues.
static void fbpNotifyPost(NSString *identifier, NSString *title, NSString *body, NSString *source) {
	dispatch_async(dispatch_get_main_queue(), ^{
		UIApplication *application = UIApplication.sharedApplication;
		if (!application) {
			FBPDiagFail(@"notify", @"%@: no UIApplication, cannot post id=%@", source, identifier);
			return;
		}

		UIApplicationState state = application.applicationState;
		// Foreground: Facebook's own UI is showing this already.
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

		// nil trigger delivers immediately. The identifier is prefixed so it
		// cannot collide with one Facebook posts for the same notification —
		// the claim above is what stops the duplicate, not the identifier.
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

// Everything the hooks hand over comes through here. Extraction is read-only
// and wrapped, so an object that does not behave like a notification — and the
// store hook sees every kind of object Facebook persists — costs one failed
// probe and is dropped.
static void fbpNotifyConsider(id object, NSString *source, NSString *detail) {
	if (!object) {
		return;
	}
	if (!FBPEnabled(FBPKeyNotifClientSync)) {
		// Once per process: the switch being off is a fine reason for silence,
		// but it should not be an unexplained one.
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

		// One piece of text reads better as the body than as a bare title: iOS
		// already shows "Facebook" above it.
		if (body.length == 0) {
			body = title;
			bodyKey = titleKey;
			title = nil;
			titleKey = nil;
		}

		if (body.length == 0) {
			// The uninteresting case, and the common one on the store hook —
			// logged once per class-and-table so the record stays readable, with
			// the property names that say which accessor to add next.
			NSString *once = [NSString stringWithFormat:@"notext.%@.%@", className, detail ?: @"-"];
			if (fbpNotifySeenOnce(once)) {
				FBPDiag(@"notify", @"%@: no text on %@ (%@) — properties: %@", source, className,
				        detail ?: @"no detail", fbpNotifyPropertyNames(object));
			}
			return;
		}

		NSString *idKey = nil;
		NSString *identifier = fbpNotifyIdentifier(object, title, body, &idKey);

		// Always logged, however often it happens: a write that carried text is
		// the event this whole feature exists for. Lengths and accessor names
		// only — the words are the user's.
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

// Log-only, deliberately. The device run on 2026-11-21 03:01 proved all three
// hooks below install (store=1 sync=1 claim=1, enabled=1) and that NONE of them
// fired — Facebook persisted nothing through FBNotificationsSQLiteManager in a
// minute of use with the Notifications tab open. So either that store is not
// what holds the notification list on 588, or it is only written in situations
// that session never reached.
//
// Rather than guess which, these two taps ask the device. They never post:
// FBNotificationText is constructed by the list UI as well, and a fetch in the
// background could build dozens of them, so promoting this to a banner before
// the log shows what actually fires would mean a burst of duplicates. Once a
// line below appears in a background wake, that is the chokepoint to post from.

// Reported once per distinct text, so a list redraw does not fill the record.
static void fbpNotifyObserveText(NSString *text, NSString *where) {
	if (text.length == 0) {
		return;
	}
	NSString *once = [NSString stringWithFormat:@"text.%@.%lu", where, (unsigned long)text.hash];
	if (!fbpNotifySeenOnce(once)) {
		return;
	}

	UIApplication *application = UIApplication.sharedApplication;
	// -applicationState is main-thread only; off the main thread, say so rather
	// than read it, because this runs on whichever queue built the text.
	NSString *state = NSThread.isMainThread && application
	                      ? [NSString stringWithFormat:@"%ld", (long)application.applicationState]
	                      : @"off-main";

	FBPDiag(@"notify", @"text seen via %@ len=%lu state=%@", where, (unsigned long)text.length,
	        state);
	FBPDiagLog(@"local notify: %@ text=%@", where, text);
}

#pragma mark - Hooks

// Facebook's notification store. The write is the moment the text exists in
// this process, whichever path fetched it.
%group FBPLocalNotifyStore

%hook FBNotificationsSQLiteManager

- (void)saveObject:(id)object toTable:(NSString *)table {
	FBPTraceFire("notif.FBNotificationsSQLiteManager.saveObject");
	%orig;

	// The table name is a parameter of Facebook's generic schema, so it is never
	// written down anywhere in this project — this line is where it is learned.
	// Once per table is enough to answer "what is it even called".
	NSString *name = table ?: @"(nil)";
	if (fbpNotifySeenOnce([@"table." stringByAppendingString:name])) {
		FBPDiag(@"notify", @"store: table '%@' in use, first write was %@", name,
		        NSStringFromClass([object class]) ?: @"(unknown)");
	}

	fbpNotifyConsider(object, @"store", name);
}

// The read side, so a store that is read but rarely written still shows up.
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

// Facebook's own text wrapper. Every notification's words are built through it,
// so if the store is the wrong chokepoint this is where they will show up.
// Log-only — see the note above fbpNotifyObserveText.
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

// The other end: a push the client sync did fetch, before Facebook's own
// filters and dedup directory can drop it.
%group FBPLocalNotifySync

%hook FBPushNotifClientSyncManager

- (void)evaluatePush:(id)push {
	FBPTraceFire("notif.local.evaluatePush");
	// Always logged, unconditionally: two device captures have never seen this
	// call, so each one that does happen is the single most informative line in
	// the record. If this never appears, the response carried no push and the
	// store hook is the only one that can help.
	FBPDiag(@"notify", @"client-sync: evaluatePush: reached with %@",
	        NSStringFromClass([push class]) ?: @"(unknown)");
	%orig;
	fbpNotifyConsider(push, @"client-sync", nil);
}

%end

%end  // group FBPLocalNotifySync

// Claim what Facebook posts itself, so if its own pipeline ever starts working
// this stands down instead of showing a second banner for the same thing.
%group FBPLocalNotifyClaim

%hook UNUserNotificationCenter

- (void)addNotificationRequest:(UNNotificationRequest *)request
         withCompletionHandler:(void (^)(NSError *))completionHandler {
	NSString *identifier = request.identifier;
	// Our own posts arrive here too, already claimed — the prefix is what tells
	// them apart, and claiming twice is a no-op either way.
	if (identifier.length > 0 && ![identifier hasPrefix:@"fbplus."]) {
		// Worth a line every time: Facebook posting a notification request at
		// all is the thing that is supposed to be happening and is not. Seeing
		// these means its own pipeline works and this feature should stand down.
		FBPDiag(@"notify", @"facebook posted its own request id=%@ (claimed=%d)", identifier,
		        fbpNotifyClaim(identifier));
	}
	%orig;
}

%end

%end  // group FBPLocalNotifyClaim

%ctor {
	// House rule: verify the class and the selector before installing, so a
	// Facebook that renames either costs this feature and nothing else. Each
	// group is independent — the store hook is the one that matters, and it
	// should not be held back by a client-sync class that moved.
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

	// UserNotifications is Apple's, so this one only fails if the SDK moved
	// underneath us. Checked anyway: a missing selector here would mean posting
	// without the duplicate guard.
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

	// One line that says exactly how much of this feature is live, so a silent
	// run can be told apart from a run that never installed.
	//
	// It is emitted TWICE, and the second one is the one that can actually be
	// read. FBPLogClearIfDue() runs from FBPEntry's constructor and wipes
	// the record, and constructors do not all run before it — a device export
	// from 2026-11-21 contains not one line written by any constructor in the
	// tweak, its own "launch ·" line included. Anything a constructor records is
	// gone before the app finishes starting. Repeating it on a delay puts it
	// after the clear; NotifDiag.mm reports its notification settings the same
	// way, for the same reason.
	// The entitlement mode belongs on this line because it decides what the
	// whole notification path even is. Paths.mm reports it too, but only
	// through FBPDiagLog, which compiles away in a release build — and a
	// release build is exactly what gets installed on the jailbroken device
	// where the question "did the redirect layer stand down?" matters. This
	// line is FBPDiag, so it survives, and FBPLocalNotify is main-tweak only,
	// so it can call FBPDiag without dragging FBPTrace into the bridge's
	// non-diagnostic link.
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
