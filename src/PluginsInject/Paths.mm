// Filesystem helpers: create a directory on demand, and resolve the app's real
// App-Group container path from its entitlements (via LSBundleProxy).

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
// A plain `static BOOL` cannot: the notification extension ends up with two
// images of FBPNotifyBridge.dylib (build.sh inserts a load command and zsign -P
// inserts another), and each image gets its own statics, so each ran the
// constructor again. For method_exchangeImplementations that is worse than
// wasteful — exchanging the same pair twice puts the originals back, silently
// turning the container and defaults redirects off.
//
// Registering a uniquely named class is process-wide and costs one lookup.
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

// True in an app extension (the appex's own Info.plist carries NSExtension),
// false in the host app. FBPNotifyBridge.dylib uses this to stay completely
// inert in the main app: zsign's -P injects it into the main binary as well as
// the appex, and the main app already has the full tweak, so without this gate
// every redirect and every SecItem rebind is installed twice there.
BOOL fbpIsAppExtensionProcess(void) {
	static BOOL isExtension = NO;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		isExtension = NSBundle.mainBundle.infoDictionary[@"NSExtension"] != nil;
	});
	return isExtension;
}

// NSUserDefaults writes a suite to <container>/Library/Preferences/<suite>.plist
// and does NOT create those intermediate directories itself. Hand it a
// redirected container that lacks them and the suite silently reads back empty
// and loses every write — which, for the group suites Facebook keeps session
// and account state in, looks exactly like being logged out, in the app and in
// the notification extension alike. So create them before handing the
// container over. (The same point is made in sparkle-ig's SPKSideloadFix,
// which is the other living descendant of zxPluginsInject.)
BOOL prepareDefaultsContainer(NSURL *container) {
	if (!container) {
		return NO;
	}

	NSURL *preferences = [[container URLByAppendingPathComponent:@"Library" isDirectory:YES]
	    URLByAppendingPathComponent:@"Preferences" isDirectory:YES];
	return createDirectoryIfNotExists(preferences.path);
}

// Resolved on demand and **cached only on success**. This used to be a
// dispatch_once, which cached a *failure* just as permanently: in the
// notification extension LSBundleProxy is not always usable at the moment of
// the first call, and one lost race then left every later call in that process
// falling back to the extension's private Documents directory — which is not
// shared with the app, so the Msys store and the group defaults both read empty
// and the extension concluded the user was logged out. Retrying costs a cheap
// LSBundleProxy lookup until it works once.
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

		// Why the choice has to be deterministic, not just "the first one":
		// the main app and the Notification Service Extension are two separate
		// processes that each resolve this independently, and every redirected
		// container (App Group, group-suite NSUserDefaults) is built as a
		// subdirectory of whatever is returned here. If the two processes pick
		// different groups they end up with different roots, and the session the
		// app writes lands somewhere the extension never looks. Nothing promises
		// that the entitlement array arrives in the same order in both processes,
		// so we filter, sort with a locale-independent comparison, and then take
		// the first candidate that actually resolves.
		NSMutableArray<NSString *> *candidates = [NSMutableArray array];
		for (id group in appGroups) {
			if (![group isKindOfClass:[NSString class]]) {
				continue;
			}
			// Meta-owned ids can never belong to a third-party signer: Apple will
			// not authorize another team's group id, so one showing up here is a
			// leftover from the original entitlements, not a usable container.
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
