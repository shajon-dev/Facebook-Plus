// Redirects the container-backed APIs a re-signed app cannot satisfy: strips
// the iCloud entitlements from CloudKit, and points App-Group and group-suite
// NSUserDefaults storage at a writable on-disk path.

#import "Header.h"

%hook CKContainer
- (id)_setupWithContainerID:(id)a options:(id)b { return nil; }
- (id)_initWithContainerIdentifier:(id)a { return nil; }
%end

%hook CKEntitlements
- (id)initWithEntitlementsDict:(NSDictionary *)entitlements {
	// Strip the iCloud entitlements a sideloaded build cannot satisfy.
	NSMutableDictionary *mutEntitlements = [entitlements mutableCopy];
	[mutEntitlements removeObjectForKey:@"com.apple.developer.icloud-container-environment"];
	[mutEntitlements removeObjectForKey:@"com.apple.developer.icloud-services"];
	return %orig([mutEntitlements copy]);
}
%end

%hook NSFileManager
- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
	// A group this process really holds must be left alone: where Facebook's
	// own groups are intact the notification extension carries no tweak and
	// reads the real container, so moving the app's side writes the session
	// where the extension never looks.
	if (fbpShouldLeaveAppGroupAlone(groupIdentifier)) {
		PILog(@"app group '%@' is held by this signature — leaving it alone", groupIdentifier);
		return %orig;
	}

	// Prepared, not just created: a real group container comes with
	// Library/Caches, and code writing a temporary file there does not make it.
	if (NSURL *ourAppGroupURL = getAppGroupPathIfExists()) {
		NSURL *fakeAppGroupURL = [ourAppGroupURL URLByAppendingPathComponent:groupIdentifier];
		prepareGroupContainer(fakeAppGroupURL);
		return fakeAppGroupURL;
	}

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

	// Same rule as the container redirect above: an entitled group suite
	// already resolves to the directory both processes share.
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
