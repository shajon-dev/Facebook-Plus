// Redirects the container-backed APIs a re-signed app can't satisfy: strips the
// iCloud entitlements from CloudKit, and points App-Group and group-suite
// NSUserDefaults storage at a writable on-disk path.

#import "Header.h"

%hook CKContainer
- (id)_setupWithContainerID:(id)a options:(id)b { return nil; }
- (id)_initWithContainerIdentifier:(id)a { return nil; }
%end

%hook CKEntitlements
- (id)initWithEntitlementsDict:(NSDictionary *)entitlements {
	// Strip the iCloud entitlements a sideloaded build can't satisfy so CloudKit
	// doesn't hard-fault on a container it will never be granted.
	NSMutableDictionary *mutEntitlements = [entitlements mutableCopy];
	[mutEntitlements removeObjectForKey:@"com.apple.developer.icloud-container-environment"];
	[mutEntitlements removeObjectForKey:@"com.apple.developer.icloud-services"];
	return %orig([mutEntitlements copy]);
}
%end

%hook NSFileManager
- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
	// A group this process really holds needs nothing from us, and redirecting
	// it is destructive rather than merely pointless: on a jailbroken App Store
	// install or a TrollStore install Facebook's own groups are intact, the
	// notification extension carries no tweak and reads the real container, and
	// moving the app's side of it writes the session where the extension never
	// looks. The Documents fallback below makes that worse, because
	// getAppGroupPathIfExists() skips Meta-owned ids and so returns nil exactly
	// on those installs.
	if (fbpShouldLeaveAppGroupAlone(groupIdentifier)) {
		PILog(@"app group '%@' is held by this signature — leaving it alone", groupIdentifier);
		return %orig;
	}

	// The container is prepared, not just created: a real group container comes
	// with Library/Caches, and code that writes a temporary file there does not
	// create it first. See prepareGroupContainer in Paths.mm.
	if (NSURL *ourAppGroupURL = getAppGroupPathIfExists()) {
		NSURL *fakeAppGroupURL = [ourAppGroupURL URLByAppendingPathComponent:groupIdentifier];
		prepareGroupContainer(fakeAppGroupURL);
		return fakeAppGroupURL;
	}

	// fallback to a fake App Group path in Documents/App Group
	NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	NSString *fakePath = [[paths lastObject] stringByAppendingPathComponent:groupIdentifier];
	NSURL *fallbackURL = [NSURL fileURLWithPath:fakePath];
	prepareGroupContainer(fallbackURL);
	return fallbackURL;
}
%end

%hook NSUserDefaults
- (id)_initWithSuiteName:(NSString *)suiteName container:(NSURL *)container {
	PILog(@"hooking NSUserDefaults init...");

	// Same rule as the container redirect above: a group suite this process is
	// entitled to already resolves to the directory both processes share.
	if (fbpShouldLeaveAppGroupAlone(suiteName)) {
		PILog(@"suite '%@' is held by this signature — leaving it alone", suiteName);
		return %orig(suiteName, container);
	}

	NSURL *appGroupURL = getAppGroupPathIfExists();
	if (!appGroupURL) {
		PILog(@"no valid app group available, defaulting to original container");
		return %orig(suiteName, container);
	}
	PILog(@"app group URL: %@", appGroupURL);

	if (![suiteName hasPrefix:@"group"]) {
		PILog(@"suite name '%@' does not start with 'group', defaulting to original container", suiteName);
		return %orig(suiteName, container);
	}

	if (NSURL *customContainerURL = [appGroupURL URLByAppendingPathComponent:suiteName]) {
		// Without Library/Preferences underneath it the suite reads empty and
		// never persists — see prepareDefaultsContainer in Paths.mm.
		if (!prepareDefaultsContainer(customContainerURL)) {
			PILog(@"could not prepare '%@' for defaults, defaulting to original container", suiteName);
			return %orig(suiteName, container);
		}
		PILog(@"using custom container URL: %@", customContainerURL);
		return %orig(suiteName, customContainerURL);
	}

	PILog(@"failed to construct valid URL for suite '%@' in app group container", suiteName);
	return %orig(suiteName, container);
}
%end
