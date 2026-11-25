
#import <objc/runtime.h>

#import "Header.h"

BOOL createDirectoryIfNotExists(NSString *path) {
	NSFileManager *fileManager = [NSFileManager defaultManager];
	if ([fileManager fileExistsAtPath:path]) {
		PILog(@"directory already exists: %@", path);
		return YES;
	}

	NSError *error = nil;
	[fileManager createDirectoryAtPath:path
		   withIntermediateDirectories:YES
							attributes:nil
								 error:&error];

	if (error) {
		PILog(@"failed to create directory at path (%@): %@", path, error);
		return NO;
	}

	PILog(@"created directory at path: %@", path);
	return YES;
}

// A once-guard that holds across SEPARATE COPIES of this dylib in one process.
// A plain `static BOOL` cannot: the notification extension can end up with two
// images of FBPNotifyBridge.dylib, each with its own statics. For
// method_exchangeImplementations that is worse than wasteful — exchanging the
// same pair twice puts the originals back, silently turning the redirects off.
BOOL fbpClaimProcessOnce(const char *name) {
	if (objc_getClass(name)) {
		return NO;
	}
	Class claimed = objc_allocateClassPair([NSObject class], name, 0);
	if (!claimed) {
		return NO;
	}
	objc_registerClassPair(claimed);
	return YES;
}

// True in an app extension (the appex's Info.plist carries NSExtension).
// FBPNotifyBridge.dylib uses this to stay inert in the main app, where the
// full tweak already installs every one of these redirects.
BOOL fbpIsAppExtensionProcess(void) {
	static BOOL isExtension = NO;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		isExtension = NSBundle.mainBundle.infoDictionary[@"NSExtension"] != nil;
	});
	return isExtension;
}

// Gives a stand-in App-Group container the directories a real one is born
// with; creating the container and nothing inside it is not enough.
// Library/Preferences: NSUserDefaults writes a suite beneath it and does not
// create it, so the suite reads back empty and loses every write.
// Library/Caches: a real group container has it and code writing there does
// not create it first, so the language-pack downloader's temporary file fails
// with -3000, reported as "not enough space" (issue #9).
BOOL prepareGroupContainer(NSURL *container) {
	if (!container) {
		return NO;
	}
	if (!createDirectoryIfNotExists(container.path)) {
		return NO;
	}

	NSURL *library = [container URLByAppendingPathComponent:@"Library" isDirectory:YES];
	BOOL ready = createDirectoryIfNotExists(
	    [library URLByAppendingPathComponent:@"Caches" isDirectory:YES].path);
	ready &= createDirectoryIfNotExists(
	    [library URLByAppendingPathComponent:@"Preferences" isDirectory:YES].path);
	return ready;
}

BOOL prepareDefaultsContainer(NSURL *container) {
	if (!container) {
		return NO;
	}

	NSURL *preferences = [[container URLByAppendingPathComponent:@"Library" isDirectory:YES]
	    URLByAppendingPathComponent:@"Preferences" isDirectory:YES];
	return createDirectoryIfNotExists(preferences.path);
}

// Resolved on demand and CACHED ONLY ON SUCCESS. A dispatch_once would cache a
// failure just as permanently: LSBundleProxy is not always usable at the first
// call in the notification extension, and one lost race then sends every later
// call to the extension's private Documents directory, which the app does not
// share — so the group defaults read empty and the extension decides the user
// is logged out.
NSURL *getAppGroupPathIfExists() {
	static NSURL *cachedAppGroupPath = nil;
	static NSObject *resolutionLock = nil;
	static dispatch_once_t lockOnceToken;
	dispatch_once(&lockOnceToken, ^{
		resolutionLock = [NSObject new];
	});

	@synchronized (resolutionLock) {
		if (cachedAppGroupPath) {
			return cachedAppGroupPath;
		}

		PILog(@"fetching app group path...");

		LSBundleProxy *bundleProxy = [objc_getClass("LSBundleProxy") bundleProxyForCurrentProcess];
		if (!bundleProxy) {
			PILog(@"failed to retrieve LSBundleProxy for the current process");
			return nil;
		}

		NSDictionary *entitlements = bundleProxy.entitlements;
		if (!entitlements || ![entitlements isKindOfClass:[NSDictionary class]]) {
			PILog(@"failed to retrieve entitlements");
			return nil;
		}

		NSArray *appGroups = entitlements[@"com.apple.security.application-groups"];
		if (!appGroups) {
			PILog(@"no app groups found in entitlements");
			return nil;
		}

		if (appGroups.count == 0) {
			PILog(@"app group entitlement exists, but no app groups are configured");
			return nil;
		}

			// The choice must be DETERMINISTIC, not "the first one": the app and the
			// notification extension resolve this independently and every redirected
			// container hangs off whatever is returned here, so two processes picking
			// different groups write the session where the other never looks. Nothing
			// promises the entitlement array arrives in the same order in both, so
			// filter, sort locale-independently, then take the first that resolves.
		NSMutableArray<NSString *> *candidates = [NSMutableArray array];
		for (id group in appGroups) {
			if (![group isKindOfClass:[NSString class]]) {
				continue;
			}
			// Meta-owned ids can never belong to a third-party signer, so one here
			// is a leftover from the original entitlements, not a usable container.
			if ([group hasPrefix:@"group.com.facebook."] || [group hasPrefix:@"group.com.metaplatforms."]) {
				PILog(@"skipping Meta-owned app group: %@", group);
				continue;
			}
			[candidates addObject:(NSString *)group];
		}

		if (candidates.count == 0) {
			PILog(@"no third-party app group in entitlements — nothing to redirect to");
			return nil;
		}

		[candidates sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
			return [a compare:b options:NSLiteralSearch];
		}];
		PILog(@"app group candidates (sorted): %@", candidates);

		NSDictionary *appGroupsPaths = bundleProxy.groupContainerURLs;
		if (!appGroupsPaths || ![appGroupsPaths isKindOfClass:[NSDictionary class]]) {
			PILog(@"failed to retrieve group container URLs");
			return nil;
		}

		for (NSString *appGroupName in candidates) {
			NSURL *ourAppGroupURL = appGroupsPaths[appGroupName];
			if (!ourAppGroupURL) {
				PILog(@"no path found for app group name: %@ — trying the next", appGroupName);
				continue;
			}
			cachedAppGroupPath = ourAppGroupURL;
			PILog(@"app group name: %@", appGroupName);
			PILog(@"app group path: %@", cachedAppGroupPath.path);
			break;
		}

		if (!cachedAppGroupPath) {
			PILog(@"none of the %lu app group candidates resolved to a container URL",
				  (unsigned long)candidates.count);
		}

		FBPDiagLog(@"app group container: %@ (from %lu candidate%@)",
				   cachedAppGroupPath.path ?: @"(none)",
				   (unsigned long)candidates.count, candidates.count == 1 ? @"" : @"s");

		return cachedAppGroupPath;
	}
}

#pragma mark - What this signature actually grants

// Everything below answers one question: is the entitlement Facebook is
// asking about one this process really holds? On a re-signed build the answer
// is always no, so every lookup naming a Meta-owned group must be rewritten.
// WHERE THE ORIGINAL ENTITLEMENTS ARE INTACT THE ANSWER IS YES AND REWRITING
// IS DESTRUCTIVE: the app is sent to a container the notification extension
// (which carries no tweak there) never reads, so the session it needs is
// written to the wrong place and notifications go generic.
//
// getAppGroupPathIfExists cannot be the test: it deliberately skips
// Meta-owned groups, so on an original-entitlements install it returns nil
// and the caller falls through to the Documents fallback — the worst outcome.

static NSDictionary *fbpProcessEntitlements(void) {
	static NSDictionary *cached = nil;
	static NSObject *lock = nil;
	static dispatch_once_t lockOnceToken;
	dispatch_once(&lockOnceToken, ^{
		lock = [NSObject new];
	});

	// Cached only on success: LSBundleProxy is not always usable at the moment
	// of the first call in a push-woken extension, and caching that miss would
	// answer "holds nothing" for the life of the process, turning every
	// redirect back on.
	@synchronized (lock) {
		if (cached) {
			return cached;
		}
		LSBundleProxy *proxy = [objc_getClass("LSBundleProxy") bundleProxyForCurrentProcess];
		NSDictionary *entitlements = proxy.entitlements;
		if ([entitlements isKindOfClass:[NSDictionary class]] && entitlements.count > 0) {
			cached = entitlements;
		}
		return cached;
	}
}

// An app group is held or it is not: the entitlement is a plain list of ids
// with no wildcard form.
BOOL fbpProcessHoldsAppGroup(NSString *group) {
	if (![group isKindOfClass:[NSString class]] || group.length == 0) {
		return NO;
	}

	NSArray *granted = fbpProcessEntitlements()[@"com.apple.security.application-groups"];
	if (![granted isKindOfClass:[NSArray class]]) {
		return NO;
	}

	for (id candidate in granted) {
		if ([candidate isKindOfClass:[NSString class]] && [(NSString *)candidate isEqualToString:group]) {
			return YES;
		}
	}
	return NO;
}

// Keychain groups have a wildcard form: a development profile grants
// "<TeamID>.*", covering every group with that prefix, which is how a merged
// entitlement makes Facebook's own groups reachable. An exact match is not
// enough; pinning such a group elsewhere breaks a query that would work.
BOOL fbpProcessHoldsKeychainGroup(NSString *group) {
	if (![group isKindOfClass:[NSString class]] || group.length == 0) {
		return NO;
	}

	NSArray *granted = fbpProcessEntitlements()[@"keychain-access-groups"];
	if (![granted isKindOfClass:[NSArray class]]) {
		return NO;
	}

	for (id candidate in granted) {
		if (![candidate isKindOfClass:[NSString class]]) {
			continue;
		}
		NSString *entry = (NSString *)candidate;
		if ([entry isEqualToString:group]) {
			return YES;
		}
		if ([entry isEqualToString:@"*"]) {
			return YES;
		}
		if ([entry hasSuffix:@".*"]) {
			NSString *prefix = [entry substringToIndex:entry.length - 1];  // keep the dot
			if ([group hasPrefix:prefix]) {
				return YES;
			}
		}
	}
	return NO;
}

// True when this process runs on Facebook's own entitlements rather than a
// signer's; Meta's own app group is the marker, since no third-party
// signature can carry it. A coarse gate in front of the per-group checks, so
// such a process is never redirected over some other group it also holds.
BOOL fbpProcessHasOriginalEntitlements(void) {
	static BOOL original = NO;
	static BOOL settled = NO;
	static NSObject *lock = nil;
	static dispatch_once_t lockOnceToken;
	dispatch_once(&lockOnceToken, ^{
		lock = [NSObject new];
	});

	@synchronized (lock) {
		if (settled) {
			return original;
		}
		if (!fbpProcessEntitlements()) {
			return NO;  // unreadable for now; ask again rather than settle on a miss
		}
		original = fbpProcessHoldsAppGroup(@"group.com.facebook.Facebook");
		settled = YES;
		PILog(@"entitlements are %@", original ? @"Facebook's own (no redirects needed)"
		                                      : @"a signer's (redirects active)");
		FBPDiagLog(@"entitlements: %@", original ? @"ORIGINAL — redirect layer standing down"
		                                        : @"re-signed — redirect layer active");
		return original;
	}
}

// The one call the redirects ask: leave this group's container alone?
BOOL fbpShouldLeaveAppGroupAlone(NSString *group) {
	return fbpProcessHasOriginalEntitlements() || fbpProcessHoldsAppGroup(group);
}
