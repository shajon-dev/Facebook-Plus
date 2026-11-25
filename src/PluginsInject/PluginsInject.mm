
#import <objc/runtime.h>

#import "Header.h"

NSString *bundleId;

#if FBP_DIAG
#import <os/log.h>

#import "../Core/FBPTrace.h"

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
	FBPLogRecord(YES, @"diag", message);
}
#endif

// Fallback for when the keychain cannot answer, above all a locked device.
// iOS places an item with no explicit access group in the FIRST entry of the
// keychain-access-groups entitlement, so reading that entitlement gives the
// same answer; application-identifier is the last resort.
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
	// Two load commands for the bridge can be added independently, so this
	// constructor can run TWICE in one process; it has to be idempotent.
	if (!fbpClaimProcessOnce("FBPPluginsInjectInstalled")) {
		FBPDiagLog(@"PluginsInject constructor ran again — ignoring the duplicate");
		return;
	}

#if FBP_NOTIFY_BRIDGE
	// The bridge is for extensions only: injection also reaches the main binary,
	// where the full tweak already installs all of this.
	if (!fbpIsAppExtensionProcess()) {
		return;
	}
#endif

	bundleId = [[NSBundle mainBundle] bundleIdentifier];

	// Settle this before the rebinds: the SecItem shims consult it on every
	// call and it reads entitlements through LSBundleProxy, an XPC round trip
	// to lsd, which must not start from inside a keychain call. It also decides
	// whether this layer acts at all — where Facebook's own entitlements are
	// intact, every redirect here is destructive.
	__attribute__((unused)) BOOL original = fbpProcessHasOriginalEntitlements();

	// Must come first: the access-group probe calls the *original* SecItem*
	// functions, which only exist once the rebinds have been installed.
	rebindSecFuncs();

	// Warmed here; a failure is retried on first use.
	__attribute__((unused)) NSString *group = fbpResolvedAccessGroup();
	PILog(@"access group at launch: %@", group ?: @"(unresolved, will retry)");
	FBPDiagLog(@"process %@: access group at launch %@", bundleId ?: @"(unknown)",
	           group ?: @"(unresolved, will retry)");

#if FBP_DIAG
	FBPDiagLog(@"trace file: %@ (%@)", FBPTraceFilePath(),
	           FBPTraceFileIsShared() ? @"SHARED app-group container"
	                                  : @"private Caches — NOT shared with the other process");
#endif
}
