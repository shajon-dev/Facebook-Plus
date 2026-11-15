// Rebinds the SecItem* keychain functions (via fishhook) so a re-signed app's
// own keychain I/O lands in an access group it actually holds.
//
// The rule: never leave a query asking for an access group this process cannot
// hold, and never move a query that already asks for one it can.
//
// fishhook rebinds the symbol process-wide, so these shims also see the keychain
// traffic of the system and auth frameworks running inside Facebook (Accounts,
// AuthKit, SafariServices, the Messenger hand-off). Those callers ask for groups
// they are entitled to, and moving the group turns a hit into errSecItemNotFound
// or -34018 errSecMissingEntitlement — Facebook's own code logs that and
// degrades, and a system caller may treat it as fatal (the suspected cause of
// GitHub issue #13, where tapping Message on a profile killed the app). Hence
// the three outcomes below.
//
// WHAT HAPPENS TO A QUERY
//
//   * it names ANOTHER TEAM's group — Facebook's own keychain code and the
//     notification extension ask for Meta-owned groups (the NSE's Info.plist
//     names T84QZS65DQ.platformFamily) that a re-signed build can never be
//     granted. The query as written can only fail, so it is always rewritten:
//     pinned to the resolved group, or, if none was resolved, the access group
//     is REMOVED, which makes the keychain search every group the process *is*
//     entitled to. Nothing else in the query changes this — see the note on
//     kSecUseDataProtectionKeychain below.
//   * it names a com.apple.* group — system owned (com.apple.token,
//     com.apple.accounts.*.defaultaccess, …). Left exactly as it is: that is a
//     system or auth framework asking on its own behalf, and the issue-#13 fix.
//   * it names the resolved group — left alone, the rewrite was a no-op.
//   * it names NO group — pinned to the resolved group, so everything a
//     re-signed app writes and reads back lands in one group it holds instead
//     of whichever group the keychain picks by default. This is the case the
//     rebind was originally written for. Two exceptions, both left untouched:
//     a kSecUseDataProtectionKeychain or kSecAttrAccessControl query (modern,
//     caller-owned, possibly bound to an access-control object), and the case
//     where no access group was resolved at all.
//
// WHY kSecUseDataProtectionKeychain NO LONGER EXCLUDES A FOREIGN GROUP
//
// It used to. Passing those queries through untouched was added with the
// issue-#13 narrowing, on the reasoning that they are caller-owned items a
// rewrite can only break. In the notification extension that reasoning is
// backwards: disassembling NotificationServiceExtension (Facebook
// 586.0.0) shows kSecUseDataProtectionKeychain is loaded in the *same*
// dictionary build as kSecAttrAccessGroup, four instructions apart, and the
// only code that does it is Meta's own Swift keychain stores — the push-notif
// token store behind the client-sync fetch that resolves Facebook notification
// text, and MetaPushEncryptionKeyStore / MetaHPKEManager. The access group they
// pass is T84QZS65DQ.platformFamily, the one string of its kind in the binary.
// So the exclusion skipped precisely the queries that had to be redirected, the
// extension got a null token, and likes / comments / friend requests fell back
// to generic text while Messenger messages and calls — which come out of the
// redirected app-group container, not the keychain — kept working. The flag now
// only protects the no-group case, where a system caller might really own the
// item. See .agent/notification-extension.md.
//
// WHY THE GROUP IS RESOLVED LAZILY AND RETRIED
//
// It used to be resolved once, eagerly, in the constructor, and a failure there
// was cached for the life of the process. An extension woken by a push on a
// locked device cannot read or add a keychain item, so it failed there and
// never had a group at all. Resolution now happens on first use, under a lock,
// and is cached only on success. The probe calls the *original* SecItem*
// functions so running it from inside a shim does not recurse.
//
// WHY A FAILED LOOKUP STRIPS THE GROUP RATHER THAN PASSING IT THROUGH
//
// Also from the issue-#13 narrowing, which replaced "assign a nil
// accessGroupId" (ARC removes the key, so the group was stripped) with "leave
// the query alone". Leaving it alone is strictly worse: the query keeps a group
// the process cannot hold and is guaranteed to fail, whereas a query with no
// access group searches every group the process *is* entitled to, which is the
// right answer for a re-signed app. Stripping is now deliberate, and only ever
// applied to a foreign group — a caller's own group is never removed.
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
// back to on, so turning the switch off in the app does not disable the
// extension's session lookup.

#import <Security/Security.h>
#import <mach-o/dyld.h>

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

#pragma mark - Resolving the access group we can actually hold

// The probe item is deliberately AfterFirstUnlock. The default for SecItemAdd
// is WhenUnlocked, and the notification extension runs on push delivery, which
// routinely happens with the device locked — a WhenUnlocked probe item is
// unreadable there, the probe fails, and the extension loses the access group
// it needs. The account name carries ".afu" so an item left behind by an
// earlier (WhenUnlocked) build is not read back instead.
static NSString *const kProbeAccount = @"com.shajon.fbplus.accessGroupProbe.afu";

// Ask the keychain where an item with no explicit access group lands. This is
// ground truth — whatever the entitlements say, this is the group the app's own
// untagged keychain traffic ends up in.
//
// It calls the ORIGINAL SecItem* functions, not the rebound ones, because this
// runs from inside the shims: going through the shims would recurse.
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
	// Match the item whether or not an earlier run marked it synchronizable.
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

// Lazy, locked, and **cached only on success**. The eager constructor-time
// version cached a failure for the whole process, which in an extension woken
// on a locked device meant it never had a group at all. Retrying costs one
// keychain round trip per call until it works once.
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
		// Only read by the logs, which compile away in a release build.
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
// group that was not there would *migrate* the item to another access group,
// which is not what an update meant to do. A group already present there is
// still normalised, because leaving a foreign one fails the update.
static FBPAccessGroupAction accessGroupActionForQuery(NSDictionary *query, BOOL injectWhenMissing) {
	if (!gKeychainRebindEnabled) return FBPAccessGroupLeave;
	if (![query isKindOfClass:NSDictionary.class]) return FBPAccessGroupLeave;

	id group = query[(__bridge NSString *)kSecAttrAccessGroup];

	// Present but not a usable group name: leave it as it
	// is rather than pinning over it.
	if (group && (![group isKindOfClass:NSString.class] || ((NSString *)group).length == 0)) {
		return FBPAccessGroupLeave;
	}

	if (group) {
		NSString *requested = (NSString *)group;

		// A system or auth framework asking for a group it is entitled to.
		if ([requested hasPrefix:@"com.apple."]) return FBPAccessGroupLeave;

		NSString *ours = fbpResolvedAccessGroup();

		// Already the resolved group.
		if (ours.length > 0 && [requested isEqualToString:ours]) {
			return FBPAccessGroupLeave;
		}

		// Another team's group. Apple will not grant it to this signature, so
		// the query cannot succeed as written whatever else it carries.
		return ours.length > 0 ? FBPAccessGroupPin : FBPAccessGroupStrip;
	}

	// No access group from here on. These are the queries where a caller may
	// legitimately own the item it is asking about, so the modern-keychain
	// markers are honoured and nothing is pinned without a group to pin to.
	if (!injectWhenMissing) return FBPAccessGroupLeave;
	if (query[(__bridge NSString *)kSecUseDataProtectionKeychain]) return FBPAccessGroupLeave;
	if (query[(__bridge NSString *)kSecAttrAccessControl]) return FBPAccessGroupLeave;
	if (fbpResolvedAccessGroup().length == 0) return FBPAccessGroupLeave;

	return FBPAccessGroupPin;
}

// The dictionary actually handed to the real SecItem* call. Returned as an
// NSDictionary (not a CFDictionaryRef) so ARC keeps the rewritten copy alive
// for the duration of the call.
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
			// Assigning nil through the subscript removes the key, so the
			// keychain searches every entitled group.
			rewritten[(__bridge NSString *)kSecAttrAccessGroup] = nil;
			return rewritten;
		}
	}
}

static NSDictionary *effectiveQuery(CFDictionaryRef query) {
	return effectiveDictionary(query, YES);
}

// SecItemUpdate's second dictionary: normalise a group that is there, never
// add one that is not.
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

// What each shim saw and what the keychain answered. In the FBP_DIAG build this
// also names the service and account, because on a device that is the only way
// to tell the push-notif token lookup apart from the fifty other keychain calls
// an extension makes. PILog is a no-op under FINALPACKAGE and FBPDiagLog is a
// no-op unless FBP_DIAG=1, so a shipped build costs nothing here.
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

// YES if the vendored keychain patch blatantsPatch is in the image list. The
// patched IPA injects blatantsPatch.dylib (vendor/blatantsPatch/) into the MAIN
// app to keep a sideloaded session from being dropped (issue #2); it rebinds the
// same SecItem* functions. Two rebinders fighting over one symbol is
// unpredictable, so when it is present this rebind stands down and lets it own
// the main app's keychain. All images are mapped before any initializer runs, so
// the constructor sees it even if blatantsPatch's own initializer has not run
// yet. The notification extension is a separate process this dylib is NOT
// injected into, so there this returns NO and the rebind installs as usual —
// issue #12 notifications keep working.
static BOOL blatantsPatchPresent(void) {
	uint32_t count = _dyld_image_count();
	for (uint32_t i = 0; i < count; i++) {
		const char *name = _dyld_get_image_name(i);
		if (name && strstr(name, "blatantsPatch")) return YES;
	}
	return NO;
}

void rebindSecFuncs() {
	// Defer to the injected third-party patch when present rather than rebinding
	// the same functions twice (see blatantsPatchPresent).
	if (blatantsPatchPresent()) {
		PILog(@"blatantsPatch present — leaving the keychain rebind to it");
		FBPDiagLog(@"blatantsPatch present — SecItem rebind not installed by us");
		return;
	}

	// Warmed here, before the shims can be reached, so the preference read never
	// runs inside a keychain call.
	primeKeychainRebindPref();

	struct rebinding rebinds[4] = {
		{"SecItemAdd", (void *)fbpSecItemAdd, (void **)&origSecItemAdd},
		{"SecItemCopyMatching", (void *)fbpSecItemCopyMatching, (void **)&origSecItemCopyMatching},
		{"SecItemUpdate", (void *)fbpSecItemUpdate, (void **)&origSecItemUpdate},
		{"SecItemDelete", (void *)fbpSecItemDelete, (void **)&origSecItemDelete}
	};
	// The rebind itself must always run — only the logs are build-gated, so the
	// result is unused in a plain release build.
	__attribute__((unused)) int result = rebind_symbols(rebinds, 4);
	PILog(@"rebind_symbols result: %d", result);
	FBPDiagLog(@"SecItem rebinds installed (result %d), rebind %@", result,
	           gKeychainRebindEnabled ? @"enabled" : @"disabled");
}
