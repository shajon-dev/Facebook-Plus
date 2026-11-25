// Rebinds the SecItem* keychain functions (via fishhook) so a re-signed app's
// keychain I/O lands in an access group it actually holds. THE RULE: never
// leave a query asking for a group this process cannot hold, and never move a
// query that already asks for one it can.
//
// fishhook rebinds process-wide, so these shims also see the system and auth
// frameworks' keychain traffic; moving one of their groups turns a hit into
// errSecItemNotFound or -34018, which a system caller may treat as fatal
// (suspected cause of issue #13). A com.apple.* group, or any group the
// entitlement really grants, is therefore left exactly as given. Another
// team's group is pinned to the resolved group, or STRIPPED when none
// resolved, so the keychain searches every group the process does hold;
// leaving such a query alone would guarantee failure. A query with NO group is
// pinned, unless it carries kSecUseDataProtectionKeychain or
// kSecAttrAccessControl and may be a caller-owned item — that flag does NOT
// exempt a foreign group, since Meta's own stores set it alongside a
// Meta-owned access group, and exempting it left the extension with a null
// push token. The whole rewrite is gated on the keychainRebind preference.

#import <Security/Security.h>

#import "Header.h"
#import "../Core/fishhook/fishhook.h"

static OSStatus (*origSecItemAdd)(CFDictionaryRef attributes, CFTypeRef *result);
static OSStatus (*origSecItemCopyMatching)(CFDictionaryRef query, CFTypeRef *result);
static OSStatus (*origSecItemUpdate)(CFDictionaryRef query, CFDictionaryRef attributesToUpdate);
static OSStatus (*origSecItemDelete)(CFDictionaryRef query);

#pragma mark - Runtime switch

// Shared with FBPNotifyBridge.dylib, which compiles this with neither UIKit
// nor the settings code on its include path, so the preference comes straight
// from the defaults suite. Mirrors FBPPrefs.m and FBPlus.m — keep in step.
static NSString *const kPrefsSuite = @"com.shajon.fbplus";
static NSString *const kPrefKeychainRebind = @"keychainRebind";
static NSString *const kPrefsDidChange = @"FBPlusSettingsDidChangeNotification";

// Cached before the rebinds and refreshed on change. READING NSUserDefaults
// INSIDE A SecItem SHIM COULD RE-ENTER IT, so it is never read on that path.
static BOOL gKeychainRebindEnabled = YES;

// Unset means on: an extension reads its own empty domain and must keep it.
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

#pragma mark - Resolving the access group we can actually hold

// The probe item is deliberately AfterFirstUnlock: SecItemAdd defaults to
// WhenUnlocked, and push delivery routinely happens with the device locked,
// where such an item is unreadable. ".afu" keeps an older item out of the way.
static NSString *const kProbeAccount = @"com.shajon.fbplus.accessGroupProbe.afu";

// Ask the keychain where an item with no explicit access group lands: ground
// truth, whatever the entitlements say. Calls the ORIGINAL SecItem* functions,
// because this runs from inside the shims and would otherwise recurse.
static NSString *probeAccessGroupSentinel(OSStatus *statusOut) {
	if (!origSecItemCopyMatching || !origSecItemAdd) {
		if (statusOut) *statusOut = errSecUnimplemented;
		return nil;
	}

	NSDictionary *common = @{
		(__bridge NSString *)kSecClass: (__bridge NSString *)kSecClassGenericPassword,
		(__bridge NSString *)kSecAttrAccount: kProbeAccount,
		(__bridge NSString *)kSecAttrService: @"",
		(__bridge id)kSecReturnAttributes: (id)kCFBooleanTrue
	};

	NSMutableDictionary *search = [common mutableCopy];
	search[(__bridge NSString *)kSecAttrSynchronizable] = (__bridge id)kSecAttrSynchronizableAny;
	search[(__bridge NSString *)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;

	CFTypeRef result = nil;
	OSStatus status = origSecItemCopyMatching((__bridge CFDictionaryRef)search, &result);
	if (status == errSecItemNotFound) {
		NSMutableDictionary *add = [common mutableCopy];
		add[(__bridge NSString *)kSecAttrAccessible] =
			(__bridge id)kSecAttrAccessibleAfterFirstUnlock;
		add[(__bridge NSString *)kSecValueData] = [NSData data];
		status = origSecItemAdd((__bridge CFDictionaryRef)add, &result);
	}
	if (statusOut) *statusOut = status;

	NSString *group = nil;
	if (status == errSecSuccess && result) {
		id attributes = (__bridge id)result;
		if ([attributes isKindOfClass:NSDictionary.class]) {
			group = [attributes[(__bridge NSString *)kSecAttrAccessGroup] copy];
		}
	}
	if (result) {
		CFRelease(result);
	}
	return group.length > 0 ? group : nil;
}

// Lazy, locked, and CACHED ONLY ON SUCCESS. An eager version cached a failure
// for the whole process, so an extension woken on a locked device never had
// a group at all.
NSString *fbpResolvedAccessGroup(void) {
	static NSString *resolved = nil;
	static NSObject *resolutionLock = nil;
	static BOOL loggedFailure = NO;
	static dispatch_once_t lockOnceToken;
	dispatch_once(&lockOnceToken, ^{
		resolutionLock = [NSObject new];
	});

	@synchronized (resolutionLock) {
		if (resolved.length > 0) {
			return resolved;
		}

		OSStatus probeStatus = errSecSuccess;
		NSString *group = probeAccessGroupSentinel(&probeStatus);
		__attribute__((unused)) NSString *source = @"keychain probe";
		if (group.length == 0) {
			group = fbpAccessGroupFromEntitlements();
			source = @"keychain-access-groups entitlement";
		}

		if (group.length > 0) {
			resolved = [group copy];
			PILog(@"resolved access group via %@ (probe OSStatus %d)", source, (int)probeStatus);
			FBPDiagLog(@"resolved access group %@ via %@ (probe OSStatus %d)", resolved, source,
			           (int)probeStatus);
			return resolved;
		}

		if (!loggedFailure) {
			loggedFailure = YES;
			PILog(@"no access group resolved yet (probe OSStatus %d) — will retry", (int)probeStatus);
			FBPDiagLog(@"no access group resolved yet (probe OSStatus %d) — will retry",
			           (int)probeStatus);
		}
		return nil;
	}
}

#pragma mark - What to do with a query's access group

typedef NS_ENUM(NSUInteger, FBPAccessGroupAction) {
	FBPAccessGroupLeave,  // hand the query to the keychain exactly as given
	FBPAccessGroupPin,    // set kSecAttrAccessGroup to the resolved group
	FBPAccessGroupStrip   // remove kSecAttrAccessGroup entirely
};

// injectWhenMissing is NO for SecItemUpdate's attributesToUpdate: adding a
// group that was not there would MIGRATE the item. One already present is
// still normalised, because leaving a foreign group fails the update.
static FBPAccessGroupAction accessGroupActionForQuery(NSDictionary *query, BOOL injectWhenMissing) {
	if (!gKeychainRebindEnabled) return FBPAccessGroupLeave;
	if (![query isKindOfClass:NSDictionary.class]) return FBPAccessGroupLeave;

	// Facebook's own entitlements are intact, so the whole rewrite stands down.
	// Resolved and cached in the constructor, before any shim is reachable, so
	// this never calls out to lsd from inside a keychain call.
	if (fbpProcessHasOriginalEntitlements()) return FBPAccessGroupLeave;

	id group = query[(__bridge NSString *)kSecAttrAccessGroup];

	if (group && (![group isKindOfClass:NSString.class] || ((NSString *)group).length == 0)) {
		return FBPAccessGroupLeave;
	}

	if (group) {
		NSString *requested = (NSString *)group;

		// A system or auth framework asking for a group it is entitled to.
		if ([requested hasPrefix:@"com.apple."]) return FBPAccessGroupLeave;

		// Granted by an exact entry or a "<TeamID>.*" wildcard. The probe resolves
		// ONE group, so comparing against it alone would pin away queries that
		// would have succeeded on an install holding several of Facebook's groups.
		if (fbpProcessHoldsKeychainGroup(requested)) return FBPAccessGroupLeave;

		NSString *ours = fbpResolvedAccessGroup();

		if (ours.length > 0 && [requested isEqualToString:ours]) {
			return FBPAccessGroupLeave;
		}

		// Another team's group: the query cannot succeed as written.
		return ours.length > 0 ? FBPAccessGroupPin : FBPAccessGroupStrip;
	}

	// No access group from here on: a caller may legitimately own the item, so
	// the modern-keychain markers are honoured and nothing is pinned blind.
	if (!injectWhenMissing) return FBPAccessGroupLeave;
	if (query[(__bridge NSString *)kSecUseDataProtectionKeychain]) return FBPAccessGroupLeave;
	if (query[(__bridge NSString *)kSecAttrAccessControl]) return FBPAccessGroupLeave;
	if (fbpResolvedAccessGroup().length == 0) return FBPAccessGroupLeave;

	return FBPAccessGroupPin;
}

// An NSDictionary, so ARC keeps the rewritten copy alive for the call.
static NSDictionary *effectiveDictionary(CFDictionaryRef query, BOOL injectWhenMissing) {
	NSDictionary *incoming = (__bridge NSDictionary *)query;
	switch (accessGroupActionForQuery(incoming, injectWhenMissing)) {
		case FBPAccessGroupLeave:
			return incoming;
		case FBPAccessGroupPin: {
			NSMutableDictionary *rewritten = [incoming mutableCopy];
			rewritten[(__bridge NSString *)kSecAttrAccessGroup] = fbpResolvedAccessGroup();
			return rewritten;
		}
		case FBPAccessGroupStrip: {
			NSMutableDictionary *rewritten = [incoming mutableCopy];
			// Assigning nil removes the key, so every entitled group is searched.
			rewritten[(__bridge NSString *)kSecAttrAccessGroup] = nil;
			return rewritten;
		}
	}
}

static NSDictionary *effectiveQuery(CFDictionaryRef query) {
	return effectiveDictionary(query, YES);
}

// SecItemUpdate's second dictionary: normalise, never add.
static NSDictionary *effectiveUpdateAttributes(CFDictionaryRef attributes) {
	return effectiveDictionary(attributes, NO);
}

#pragma mark - Tracing

#if DEBUG || FBP_DIAG
static NSString *describeAction(FBPAccessGroupAction action) {
	switch (action) {
		case FBPAccessGroupLeave: return @"untouched";
		case FBPAccessGroupPin:   return @"pinned";
		case FBPAccessGroupStrip: return @"stripped";
	}
}

// FBP_DIAG also names service and account, to tell one call from another.
static void logSecCall(const char *name, CFDictionaryRef query, OSStatus status) {
	NSDictionary *incoming = (__bridge NSDictionary *)query;
	if (![incoming isKindOfClass:NSDictionary.class]) return;

	id group = incoming[(__bridge NSString *)kSecAttrAccessGroup];
	NSString *action = describeAction(accessGroupActionForQuery(incoming, YES));

	PILog(@"%s group %@ [%@] -> OSStatus %d", name, group ?: @"(unset)", action, (int)status);
	FBPDiagLog(@"%s svce=%@ acct=%@ group=%@ [%@] -> OSStatus %d", name,
	           incoming[(__bridge NSString *)kSecAttrService] ?: @"(unset)",
	           incoming[(__bridge NSString *)kSecAttrAccount] ?: @"(unset)",
	           group ?: @"(unset)", action, (int)status);
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
		OSStatus status = origSecItemUpdate(
			(__bridge CFDictionaryRef)effectiveQuery(query),
			(__bridge CFDictionaryRef)effectiveUpdateAttributes(attributesToUpdate));
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

// INSTALLED UNCONDITIONALLY, in the main app and in the notification
// extension alike: both have to agree on the group the session is written to.
void rebindSecFuncs() {
	// Warmed before the shims can be reached: no defaults read inside a call.
	primeKeychainRebindPref();

	struct rebinding rebinds[4] = {
		{"SecItemAdd", (void *)fbpSecItemAdd, (void **)&origSecItemAdd},
		{"SecItemCopyMatching", (void *)fbpSecItemCopyMatching, (void **)&origSecItemCopyMatching},
		{"SecItemUpdate", (void *)fbpSecItemUpdate, (void **)&origSecItemUpdate},
		{"SecItemDelete", (void *)fbpSecItemDelete, (void **)&origSecItemDelete}
	};
	// The rebind itself must always run; only the logs are build-gated.
	__attribute__((unused)) int result = rebind_symbols(rebinds, 4);
	PILog(@"rebind_symbols result: %d", result);
	FBPDiagLog(@"SecItem rebinds installed (result %d), rebind %@", result,
	           gKeychainRebindEnabled ? @"enabled" : @"disabled");
}
