// FBPNotifyBridge — the slim half of the sideload compatibility layer, loaded
// into Facebook's NotificationServiceExtension.appex instead of the full
// tweak, which registers every hook and links UIKit. An extension runs under
// a hard ~24 MB limit and a ~30 s window, and being killed there makes
// notifications worse, so it gets only the redirects and rebinds it needs.
//
// The path construction below is a line-for-line match of
// src/PluginsInject/SideloadFix.xm, including the "group" prefix check and the
// Documents fallback: an identical mapping in both processes is the entire
// point, so CHANGE ONE, CHANGE THE OTHER. The keychain half comes from the
// shared PluginsInject.mm and SecRebinds.xm, whose rebind is blanket — every
// SecItem call in the process — and is suspected of aggravating crashes.
// Hooks use plain objc swizzling rather than Logos so the dylib needs no
// injection framework, which lands in Facebook.app/Frameworks where an appex
// binary has no guaranteed rpath.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "Header.h"

#pragma mark - App-Group container

@interface NSFileManager (FBPNotifyBridge)
- (NSURL *)fbp_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier;
@end

@implementation NSFileManager (FBPNotifyBridge)

// Mirrors SideloadFix.xm. Never defers to the original, which returns nil.
- (NSURL *)fbp_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
	// Mirrors the gate in SideloadFix.xm: where the original entitlements are
	// intact, redirecting would break the one thing this exists to fix.
	if (fbpShouldLeaveAppGroupAlone(groupIdentifier)) {
		FBPDiagLog(@"containerURL for %@ -> original (group is held)", groupIdentifier);
		return [self fbp_containerURLForSecurityApplicationGroupIdentifier:groupIdentifier];
	}

	if (NSURL *ourAppGroupURL = getAppGroupPathIfExists()) {
		NSURL *fakeAppGroupURL = [ourAppGroupURL URLByAppendingPathComponent:groupIdentifier];
		createDirectoryIfNotExists(fakeAppGroupURL.path);
		FBPDiagLog(@"containerURL for %@ -> %@", groupIdentifier, fakeAppGroupURL.path);
		return fakeAppGroupURL;
	}

	// Fallback to a stand-in path in Documents. Unlike in the main app this
	// shares nothing (an extension has its own data container); it is kept only
	// so the mapping stays identical and the call never returns nil.
	NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	NSString *fakePath = [[paths lastObject] stringByAppendingPathComponent:groupIdentifier];
	createDirectoryIfNotExists(fakePath);
	return [NSURL fileURLWithPath:fakePath];
}

@end

#pragma mark - group-suite NSUserDefaults

// The selector starts with "init" plus an uppercase letter, so ARC puts it in
// the init method family — the same ownership contract as the selector it is
// exchanged with. A raw IMP would not carry it and would mis-balance retains.
@interface NSUserDefaults (FBPNotifyBridge)
- (instancetype)initFBPWithSuiteName:(NSString *)suiteName container:(NSURL *)container;
@end

@implementation NSUserDefaults (FBPNotifyBridge)

// Mirrors -[NSUserDefaults _initWithSuiteName:container:] in SideloadFix.xm;
// after the exchange this selector *is* the original, so it is the %orig.
- (instancetype)initFBPWithSuiteName:(NSString *)suiteName container:(NSURL *)container {
	PILog(@"hooking NSUserDefaults init...");

	// Mirrors the gate in SideloadFix.xm — see the container method above.
	if (fbpShouldLeaveAppGroupAlone(suiteName)) {
		FBPDiagLog(@"defaults suite %@ -> original (group is held)", suiteName);
		return [self initFBPWithSuiteName:suiteName container:container];
	}

	NSURL *appGroupURL = getAppGroupPathIfExists();
	if (!appGroupURL) {
		PILog(@"no valid app group available, defaulting to original container");
		return [self initFBPWithSuiteName:suiteName container:container];
	}
	PILog(@"app group URL: %@", appGroupURL);

	if (![suiteName hasPrefix:@"group"]) {
		PILog(@"suite name '%@' does not start with 'group', defaulting to original container", suiteName);
		return [self initFBPWithSuiteName:suiteName container:container];
	}

	if (NSURL *customContainerURL = [appGroupURL URLByAppendingPathComponent:suiteName]) {
		// Without Library/Preferences underneath it the suite reads empty and
		// never persists — see prepareDefaultsContainer in Paths.mm.
		if (!prepareDefaultsContainer(customContainerURL)) {
			PILog(@"could not prepare '%@' for defaults, defaulting to original container", suiteName);
			FBPDiagLog(@"could not prepare defaults container for suite %@", suiteName);
			return [self initFBPWithSuiteName:suiteName container:container];
		}
		PILog(@"using custom container URL: %@", customContainerURL);
		FBPDiagLog(@"defaults suite %@ -> %@", suiteName, customContainerURL.path);
		return [self initFBPWithSuiteName:suiteName container:customContainerURL];
	}

	PILog(@"failed to construct valid URL for suite '%@' in app group container", suiteName);
	return [self initFBPWithSuiteName:suiteName container:container];
}

@end

#pragma mark - Diagnostics: what the extension was handed, and what it produced

// FBP_DIAG only. Never compiled into a shipped build: it logs push payloads.
#if FBP_DIAG

@interface FBPDiagNotificationService: NSObject
- (void)fbp_didReceiveNotificationRequest:(id)request withContentHandler:(void (^)(id))contentHandler;
- (void)fbp_serviceExtensionTimeWillExpire;
@end

@implementation FBPDiagNotificationService

- (void)fbp_didReceiveNotificationRequest:(id)request withContentHandler:(void (^)(id))contentHandler {
	id content = [request valueForKey:@"content"];
	NSDictionary *userInfo = [content valueForKey:@"userInfo"];
	NSString *identifier = [request valueForKey:@"identifier"] ?: @"(none)";

	// The identifier ties this line to SpringBoard's own delivery line.
	NSString *incomingTitle = [content valueForKey:@"title"] ?: @"";
	NSString *incomingBody  = [content valueForKey:@"body"] ?: @"";
	FBPDiagLog(@"NSE RAN for request %@ — incoming title '%@' body '%@'",
	           identifier, incomingTitle, incomingBody);
	FBPDiagLog(@"NSE payload keys: %@",
	           [[userInfo.allKeys sortedArrayUsingSelector:@selector(compare:)]
	               componentsJoinedByString:@","] ?: @"(none)");

	NSDate *start = NSDate.date;
	[self fbp_didReceiveNotificationRequest:request
	                    withContentHandler:^(id finalContent) {
		NSString *finalTitle = [finalContent valueForKey:@"title"] ?: @"";
		NSString *finalBody  = [finalContent valueForKey:@"body"] ?: @"";

		// An unchanged body means the extension ran and lost: a session problem.
		BOOL changed = ![finalBody isEqualToString:incomingBody] ||
		               ![finalTitle isEqualToString:incomingTitle];
		FBPDiagLog(@"NSE RESULT for %@ after %.2fs: %@ — title '%@' body '%@'",
		           identifier, -start.timeIntervalSinceNow,
		           changed ? @"CONTENT REPLACED" : @"UNCHANGED (expansion failed)",
		           finalTitle, finalBody);
		if (contentHandler) contentHandler(finalContent);
	}];
}

// Silent unless Facebook missed the content handler, so a line here is itself
// the finding.
- (void)fbp_serviceExtensionTimeWillExpire {
	FBPDiagLog(@"NSE TIME EXPIRED — Facebook never called the content handler; "
	           @"iOS will deliver the original payload");
	[self fbp_serviceExtensionTimeWillExpire];
}

@end

#endif

#pragma mark - Install

// Swaps two instance methods only when both really exist, so a Foundation
// that drops the private initialiser costs the redirect, not the extension.
static BOOL fbpExchange(Class cls, SEL original, SEL replacement) {
	if (!cls) {
		return NO;
	}

	Method originalMethod = class_getInstanceMethod(cls, original);
	Method replacementMethod = class_getInstanceMethod(cls, replacement);
	if (!originalMethod || !replacementMethod) {
		PILog(@"missing method for %@ on %@ — skipping", NSStringFromSelector(original), cls);
		return NO;
	}

	method_exchangeImplementations(originalMethod, replacementMethod);
	return YES;
}

__attribute__((constructor)) static void FBPNotifyBridgeInit() {
	@autoreleasepool {
		// Loaded twice in the extension (see PluginsInject.mm): exchanging the
		// same two methods a second time would undo the first.
		if (!fbpClaimProcessOnce("FBPNotifyBridgeInstalled")) {
			FBPDiagLog(@"notify bridge constructor ran again — ignoring the duplicate");
			return;
		}

		// Extensions only: in the main app FacebookPlus.dylib installs all of this.
		if (!fbpIsAppExtensionProcess()) {
			return;
		}

		__attribute__((unused)) BOOL container =
			fbpExchange([NSFileManager class],
						@selector(containerURLForSecurityApplicationGroupIdentifier:),
						@selector(fbp_containerURLForSecurityApplicationGroupIdentifier:));
		__attribute__((unused)) BOOL suite =
			fbpExchange([NSUserDefaults class],
						@selector(_initWithSuiteName:container:),
						@selector(initFBPWithSuiteName:container:));

#if FBP_DIAG
		NSDictionary *extension = NSBundle.mainBundle.infoDictionary[@"NSExtension"];
		NSString *principal = [extension isKindOfClass:NSDictionary.class]
		                          ? extension[@"NSExtensionPrincipalClass"]
		                          : nil;
		Class service = principal.length ? NSClassFromString(principal) : Nil;
		if (!service) service = objc_getClass("FBNotificationService");

		FBPDiagLog(@"notification service class: %@ (from %@)",
		           service ? NSStringFromClass(service) : @"(not found)",
		           principal.length ? @"Info.plist" : @"fallback name");

		// Grafted on first: fbpExchange needs both methods on the same class.
		if (service) {
			SEL replacements[2] = {
				@selector(fbp_didReceiveNotificationRequest:withContentHandler:),
				@selector(fbp_serviceExtensionTimeWillExpire),
			};
			SEL originals[2] = {
				@selector(didReceiveNotificationRequest:withContentHandler:),
				@selector(serviceExtensionTimeWillExpire),
			};
			for (size_t i = 0; i < 2; i++) {
				Method donor = class_getInstanceMethod([FBPDiagNotificationService class],
				                                       replacements[i]);
				if (!donor) continue;
				class_addMethod(service, replacements[i], method_getImplementation(donor),
				                method_getTypeEncoding(donor));
				fbpExchange(service, originals[i], replacements[i]);
			}
		}
#endif

		PILog(@"notify bridge loaded into %@ (container=%d, suite=%d)",
			  NSBundle.mainBundle.bundleIdentifier, container, suite);
		FBPDiagLog(@"notify bridge loaded into %@ (container=%d, suite=%d)",
				   NSBundle.mainBundle.bundleIdentifier ?: @"(unknown)", container, suite);
	}
}
