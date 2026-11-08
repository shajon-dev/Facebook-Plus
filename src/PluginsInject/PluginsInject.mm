// Constructor: resolve the keychain access group this process can actually
// hold, then install the SecItem* rebinds that steer keychain calls at it.

#import <objc/runtime.h>

#import "Header.h"

NSString *accessGroupId;
NSString *accessGroupSource;
NSString *bundleId;

#if FBP_DIAG
#import <os/log.h>

void FBPDiagLogv(NSString *format, ...) {
	static os_log_t log;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		log = os_log_create("com.shajon.fbplus", "FBPDIAG");
	});

	va_list args;
	va_start(args, format);
	NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
	va_end(args);

	os_log(log, "[FBPDIAG] %{public}s", message.UTF8String ?: "(nil)");
}
#endif

// The probe item is deliberately AfterFirstUnlock. The default for SecItemAdd
// is WhenUnlocked, and the notification extension runs on push delivery, which
// routinely happens with the device locked — a WhenUnlocked probe item is
// unreadable there, the probe fails, and the extension loses the access group
// it needs. The account name carries ".afu" so an item left behind by an
// earlier (WhenUnlocked) build is not what we read back.
static NSString *const kProbeAccount = @"com.shajon.fbplus.accessGroupProbe.afu";

// Ask the keychain where an item with no explicit access group actually lands.
// This is ground truth — whatever the entitlements say, this is the group the
// app's own untagged keychain traffic ends up in — so it is tried first.
static NSString *probeAccessGroup() {
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

	CFDictionaryRef result = nil;
	OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)search, (CFTypeRef *)&result);
	if (status == errSecItemNotFound) {
		NSMutableDictionary *add = [common mutableCopy];
		add[(__bridge NSString *)kSecAttrAccessible] =
			(__bridge id)kSecAttrAccessibleAfterFirstUnlock;
		status = SecItemAdd((__bridge CFDictionaryRef)add, (CFTypeRef *)&result);
	}

	NSString *group = nil;
	if (status == errSecSuccess) {
		group = [(__bridge NSDictionary *)result objectForKey:(__bridge NSString *)kSecAttrAccessGroup];
	}
	if (result) {
		CFRelease(result);
	}

	FBPDiagLog(@"access-group probe: OSStatus %d, group %@", (int)status, group ?: @"(none)");
	return group.length > 0 ? group : nil;
}

// Fallback for when the probe cannot run — above all a locked device, where a
// keychain add or read is refused outright (errSecInteractionNotAllowed).
// iOS places an item with no explicit access group in the FIRST entry of the
// keychain-access-groups entitlement, so reading that entitlement gives the
// same answer the probe would have, without touching the keychain. A signer
// gives the app and its extensions the same entitlement, so the two processes
// still converge. Note the first entry on a development profile is usually the
// literal wildcard "<TeamID>.*", which is also what the keychain reports as the
// group of an untagged item on such a profile.
static NSString *accessGroupFromEntitlements() {
	LSBundleProxy *bundleProxy = [objc_getClass("LSBundleProxy") bundleProxyForCurrentProcess];
	NSDictionary *entitlements = bundleProxy.entitlements;
	if (![entitlements isKindOfClass:NSDictionary.class]) {
		return nil;
	}

	id groups = entitlements[@"keychain-access-groups"];
	if (![groups isKindOfClass:NSArray.class]) {
		return nil;
	}

	for (id group in (NSArray *)groups) {
		if (![group isKindOfClass:NSString.class] || ((NSString *)group).length == 0) {
			continue;
		}
		// com.apple.token and friends are shared system groups, never the one
		// this app's own items land in.
		if ([(NSString *)group hasPrefix:@"com.apple."]) {
			continue;
		}
		return (NSString *)group;
	}
	return nil;
}

static void resolveAccessGroup() {
	bundleId = [[NSBundle mainBundle] bundleIdentifier];

	if ((accessGroupId = probeAccessGroup())) {
		accessGroupSource = @"keychain probe";
	} else if ((accessGroupId = accessGroupFromEntitlements())) {
		accessGroupSource = @"keychain-access-groups entitlement";
	} else {
		accessGroupSource = @"unresolved";
	}

	PILog(@"access group %@ (%@)", accessGroupId ?: @"(none)", accessGroupSource);
	FBPDiagLog(@"process %@: access group %@ via %@", bundleId ?: @"(unknown)",
	           accessGroupId ?: @"(none)", accessGroupSource);
}

__attribute__((constructor)) static void PluginsInjectInit() {
	resolveAccessGroup();
	rebindSecFuncs();
}
