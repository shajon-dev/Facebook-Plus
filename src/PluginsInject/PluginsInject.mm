// Constructor: install the SecItem* rebinds, and the entitlement-derived
// fallback for the keychain access group.
//
// Note what is *not* here any more: the access group used to be resolved once,
// eagerly, in this constructor, and whatever it got — including nothing — was
// what the whole process used for the rest of its life. In the notification
// extension that is a race it can lose, so resolution now lives in
// SecRebinds.xm, happens on first use, and is retried until it succeeds.

#import <objc/runtime.h>

#import "Header.h"

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

// Fallback for when the keychain cannot answer — above all a locked device,
// where an add or a read is refused outright (errSecInteractionNotAllowed).
// iOS places an item with no explicit access group in the FIRST entry of the
// keychain-access-groups entitlement, so reading that entitlement gives the
// same answer the keychain would have, without touching it. A signer gives the
// app and its extensions the same entitlement, so the two processes still
// converge. Note the first entry on a development profile is usually the
// literal wildcard "<TeamID>.*", which is also what the keychain reports as the
// group of an untagged item on such a profile.
//
// application-identifier is the last resort: with no keychain-access-groups
// entitlement at all, that is what iOS uses as the default group.
NSString *fbpAccessGroupFromEntitlements(void) {
	LSBundleProxy *bundleProxy = [objc_getClass("LSBundleProxy") bundleProxyForCurrentProcess];
	NSDictionary *entitlements = bundleProxy.entitlements;
	if (![entitlements isKindOfClass:NSDictionary.class]) {
		return nil;
	}

	id groups = entitlements[@"keychain-access-groups"];
	if ([groups isKindOfClass:NSArray.class]) {
		for (id group in (NSArray *)groups) {
			if (![group isKindOfClass:NSString.class] || ((NSString *)group).length == 0) {
				continue;
			}
			// com.apple.token and friends are shared system groups, never the
			// one this app's own items land in.
			if ([(NSString *)group hasPrefix:@"com.apple."]) {
				continue;
			}
			return (NSString *)group;
		}
	}

	id identifier = entitlements[@"application-identifier"];
	if ([identifier isKindOfClass:NSString.class] && ((NSString *)identifier).length > 0) {
		return (NSString *)identifier;
	}
	return nil;
}

__attribute__((constructor)) static void PluginsInjectInit() {
#if FBP_NOTIFY_BRIDGE
	// Inside FBPNotifyBridge.dylib. zsign's -P injects that dylib into the main
	// binary as well as the appex, where the full tweak already installs all of
	// this — so a second copy would rebind SecItem* on top of the first and
	// swizzle the container redirects twice. Device logs on 2026-11-08 showed
	// exactly that happening. The bridge exists for extensions only.
	if (!fbpIsAppExtensionProcess()) {
		return;
	}
#endif

	bundleId = [[NSBundle mainBundle] bundleIdentifier];

	// Must come first: the access-group probe calls the *original* SecItem*
	// functions, which only exist once the rebinds have been installed.
	rebindSecFuncs();

	// Warm the resolution so the main app has a group before Facebook's own
	// keychain traffic starts, and so the trace records it at launch. A failure
	// here is no longer fatal — it is retried on first use.
	// Only read by the logs, which compile away in a release build.
	__attribute__((unused)) NSString *group = fbpResolvedAccessGroup();
	PILog(@"access group at launch: %@", group ?: @"(unresolved, will retry)");
	FBPDiagLog(@"process %@: access group at launch %@", bundleId ?: @"(unknown)",
	           group ?: @"(unresolved, will retry)");
}
