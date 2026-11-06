// Rebinds the SecItem* keychain functions (via fishhook) so a re-signed app's
// own keychain I/O lands in an access group it actually holds.
//
// The rebind is deliberately NARROW. It used to force-overwrite
// kSecAttrAccessGroup on every SecItem* call, which is too blunt: fishhook
// rebinds the symbol process-wide, so the keychain traffic of system and auth
// frameworks running inside Facebook (Accounts, AuthKit, SafariServices, the
// Messenger hand-off) was rewritten as well. Those callers ask for groups they
// are entitled to, and moving the group turns a hit into errSecItemNotFound or
// -34018 errSecMissingEntitlement. Facebook's own code logs that and degrades;
// a system caller is free to treat it as fatal — the suspected cause of GitHub
// issue #13, where tapping Message on a profile killed the app.
//
// What we still rewrite, exactly as before:
//   * a query with NO access group — pinned to the probed group, so every item
//     a re-signed app writes and reads back lands in one group it holds instead
//     of whichever group the keychain picks by default. This is the case the
//     rebind was written for.
//   * any other app's / team's group — Facebook's own keychain code and the
//     notification extension ask for Meta-owned groups (the NSE's Info.plist
//     names T84QZS65DQ.platformFamily) that a re-signed build can never hold.
//     Redirecting those is what keeps a sideloaded login persisting and what
//     lets the NSE find the session, so it is left alone deliberately.
//
// What we now pass through untouched:
//   * kSecUseDataProtectionKeychain / kSecAttrAccessControl queries — modern,
//     caller-owned items, possibly bound to an access-control object. Rewriting
//     the group can only break them.
//   * com.apple.* groups — system owned (com.apple.token,
//     com.apple.accounts.*.defaultaccess, …). This is the issue-#13 change:
//     those are the lookups a system or auth framework makes on its own behalf.
//   * the probed group itself, where a rewrite was always a no-op.
//   * every query, when the access-group probe failed. The old code assigned a
//     nil accessGroupId, which under ARC REMOVES the key and so silently
//     stripped a legitimate group from the query.
//
// The whole rebind is gated on the keychainRebind preference (default on), so
// it can be switched off at runtime with no rebuild — the A/B a keychain crash
// report needs.
//
// This file is shared with FBPNotifyBridge.dylib, which is loaded into the
// notification extension and compiles it with neither UIKit nor the settings
// code on its include path. The preference is therefore read straight out of
// the defaults suite rather than through FBPPrefs: the two string literals
// below mirror kSuiteName in src/Core/FBPPrefs.m and FBPKeyKeychainRebind /
// FBPSettingsDidChangeNotification in src/Core/FBPlus.m. In the extension that
// read finds nothing (an appex has its own preferences domain) and so falls
// back to on, which is what keeps turning the switch off in the app from
// disabling the extension's session lookup.

#import <Security/Security.h>

#import "Header.h"
#import "../../fishhook/fishhook.h"

static OSStatus (*origSecItemAdd)(CFDictionaryRef attributes, CFTypeRef *result);
static OSStatus (*origSecItemCopyMatching)(CFDictionaryRef query, CFTypeRef *result);
static OSStatus (*origSecItemUpdate)(CFDictionaryRef query, CFDictionaryRef attributesToUpdate);
static OSStatus (*origSecItemDelete)(CFDictionaryRef query);

#pragma mark - Runtime switch

// Mirrors of the settings constants — see the file header for why they are not
// imported from src/Core.
static NSString *const kPrefsSuite = @"com.shajon.fbplus";
static NSString *const kPrefKeychainRebind = @"keychainRebind";
static NSString *const kPrefsDidChange = @"FBPlusSettingsDidChangeNotification";

// Cached before the rebinds are installed and refreshed when settings change.
// Reading NSUserDefaults from inside a SecItem shim could re-enter the shim, so
// the preference is never read on the keychain path itself.
static BOOL gKeychainRebindEnabled = YES;

// Unset means on: the rebind is the sideload default, and an extension reading
// its own (empty) preferences domain must keep it.
static BOOL readKeychainRebindPref() {
	NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kPrefsSuite];
	id value = [defaults objectForKey:kPrefKeychainRebind];
	return value ? [value boolValue] : YES;
}

static void primeKeychainRebindPref() {
	gKeychainRebindEnabled = readKeychainRebindPref();
	PILog(@"keychain rebind %@ at launch", gKeychainRebindEnabled ? @"enabled" : @"disabled");

	[NSNotificationCenter.defaultCenter
	    addObserverForName:kPrefsDidChange
	                object:nil
	                 queue:nil
	            usingBlock:^(NSNotification *note) {
		gKeychainRebindEnabled = readKeychainRebindPref();
		PILog(@"keychain rebind now %@", gKeychainRebindEnabled ? @"enabled" : @"disabled");
	}];
}

#pragma mark - Which queries we may touch

static BOOL shouldPinAccessGroup(NSDictionary *query) {
	if (!gKeychainRebindEnabled) return NO;
	// Probe failed: we have no group to pin to, and assigning nil would strip
	// whatever group the caller asked for.
	if (accessGroupId.length == 0) return NO;
	if (![query isKindOfClass:NSDictionary.class]) return NO;

	// Caller-owned modern keychain items: leave the group exactly as given.
	if (query[(__bridge NSString *)kSecUseDataProtectionKeychain]) return NO;
	if (query[(__bridge NSString *)kSecAttrAccessControl]) return NO;

	id group = query[(__bridge NSString *)kSecAttrAccessGroup];
	if (!group) return YES;  // the sideload case this rebind exists for
	if (![group isKindOfClass:NSString.class]) return NO;

	// System and auth frameworks running inside Facebook query their own groups
	// (com.apple.token, com.apple.accounts.*.defaultaccess, …). They are
	// entitled to them; moving the group is what breaks them.
	if ([group hasPrefix:@"com.apple."]) return NO;

	// Already where we would put it.
	if ([group isEqualToString:accessGroupId]) return NO;

	// Everything else — Facebook's own Meta-owned groups above all — keeps the
	// behaviour the sideload fix depends on. Narrowing this further would risk
	// the login and the notification-extension session lookup, which the toggle
	// is there to test instead.
	return YES;
}

// The dictionary actually handed to the real SecItem* call. Returned as an
// NSDictionary (not a CFDictionaryRef) so ARC keeps the rewritten copy alive
// for the duration of the call.
static NSDictionary *effectiveQuery(CFDictionaryRef query) {
	NSDictionary *incoming = (__bridge NSDictionary *)query;
	if (!shouldPinAccessGroup(incoming)) return incoming;

	NSMutableDictionary *pinned = [incoming mutableCopy];
	pinned[(__bridge NSString *)kSecAttrAccessGroup] = accessGroupId;
	return pinned;
}

// Debug-only trace of what each shim saw and what the keychain answered.
// PILog is a no-op under FINALPACKAGE, and in the release build the macro
// discards its arguments, so nothing here costs anything once shipped.
#if DEBUG
static void logSecCall(const char *name, CFDictionaryRef query, OSStatus status) {
	NSDictionary *incoming = (__bridge NSDictionary *)query;
	id group = [incoming isKindOfClass:NSDictionary.class]
	    ? incoming[(__bridge NSString *)kSecAttrAccessGroup]
	    : nil;
	PILog(@"%s group %@%@ -> OSStatus %d", name, group ?: @"(unset)",
	      shouldPinAccessGroup(incoming) ? @" [pinned]" : @" [untouched]", (int)status);
}
#else
#define logSecCall(name, query, status) do {} while (0)
#endif

#pragma mark - Shims

static OSStatus fbpSecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
	@autoreleasepool {
		OSStatus status = origSecItemAdd((__bridge CFDictionaryRef)effectiveQuery(attributes), result);
		logSecCall("SecItemAdd", attributes, status);
		return status;
	}
}

static OSStatus fbpSecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
	@autoreleasepool {
		OSStatus status = origSecItemCopyMatching((__bridge CFDictionaryRef)effectiveQuery(query), result);
		logSecCall("SecItemCopyMatching", query, status);
		return status;
	}
}

static OSStatus fbpSecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
	@autoreleasepool {
		OSStatus status = origSecItemUpdate((__bridge CFDictionaryRef)effectiveQuery(query), attributesToUpdate);
		logSecCall("SecItemUpdate", query, status);
		return status;
	}
}

static OSStatus fbpSecItemDelete(CFDictionaryRef query) {
	@autoreleasepool {
		OSStatus status = origSecItemDelete((__bridge CFDictionaryRef)effectiveQuery(query));
		logSecCall("SecItemDelete", query, status);
		return status;
	}
}

void rebindSecFuncs() {
	// Warmed here, before the shims can be reached, so the preference read never
	// runs inside a keychain call.
	primeKeychainRebindPref();

	struct rebinding rebinds[4] = {
		{"SecItemAdd", (void *)fbpSecItemAdd, (void **)&origSecItemAdd},
		{"SecItemCopyMatching", (void *)fbpSecItemCopyMatching, (void **)&origSecItemCopyMatching},
		{"SecItemUpdate", (void *)fbpSecItemUpdate, (void **)&origSecItemUpdate},
		{"SecItemDelete", (void *)fbpSecItemDelete, (void **)&origSecItemDelete}
	};
	// The rebind itself must always run — only the log is debug-gated, so the
	// result is unused in the release build (PILog compiles to a no-op).
	__attribute__((unused)) int result = rebind_symbols(rebinds, 4);
	PILog(@"rebind_symbols result: %d", result);
}
