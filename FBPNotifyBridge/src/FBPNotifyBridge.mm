// FBPNotifyBridge — the slim half of the sideload compatibility layer, loaded
// into Facebook's NotificationServiceExtension.appex (the NSE) instead of the
// full tweak.
//
// Why a separate dylib: FacebookPlus.dylib's constructor registers preferences
// and installs every feature hook unconditionally, and it links UIKit. An NSE
// runs under a hard ~24 MB memory limit and a ~30 s execution window — being
// killed there makes notifications *worse* (iOS falls back to the generic
// payload), so the extension gets only the two container redirects it needs.
//
// What it does: the NSE resolves a push into real text only when it can find the
// logged-in session. On a re-signed build that session is not where Facebook
// looks — the Meta app groups (group.com.facebook.*) and the T84QZS65DQ keychain
// group cannot be claimed by a third-party signer. The main app already works
// around this (src/PluginsInject/), and this dylib applies the *same* mapping
// inside the extension so both processes read and write the same container:
//
//   <real app group container>/<requested group id>
//
// The path construction below is a line-for-line match of
// src/PluginsInject/SideloadFix.xm — including the "group" prefix check and the
// Documents/<group id> fallback — because an identical mapping in both processes
// is the entire point. Change one, change the other.
//
// The keychain half (probe + SecItem rebinds) comes from the shared
// src/PluginsInject/PluginsInject.mm + SecRebinds.xm, compiled in here too: the
// NSE asks for kSecAttrAccessGroup "T84QZS65DQ.platformFamily" (see its
// Info.plist's FBKeychainAccessGroup), which a re-signed extension can never be
// granted, so without the rebinds the container redirect alone cannot surface a
// session. The probe asks the keychain which group a throwaway item actually
// landed in, so the app and the extension converge on the same group whenever
// the signer gives them the same keychain entitlement — which is what a signer's
// "merge entitlements" step does by re-prefixing Facebook's own keychain groups
// with the signer's team id. Note that the rebind is blanket — it forces
// kSecAttrAccessGroup on *every* SecItem call in the process — and project notes
// record a suspicion that this aggravates crashes elsewhere. See
// FBPNotifyBridge/README.md.
//
// Hooks are installed with plain objc runtime swizzling rather than Logos so the
// dylib carries no Cydia Substrate / ElleKit dependency: cyan drops
// CydiaSubstrate.framework into Facebook.app/Frameworks, which an appex binary
// has no guaranteed rpath to.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "Header.h"

#pragma mark - App-Group container

@interface NSFileManager (FBPNotifyBridge)
- (NSURL *)fbp_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier;
@end

@implementation NSFileManager (FBPNotifyBridge)

// Mirrors -[NSFileManager containerURLForSecurityApplicationGroupIdentifier:] in
// SideloadFix.xm: never defers to the original, because the original returns nil
// for a group this build does not hold.
- (NSURL *)fbp_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
	if (NSURL *ourAppGroupURL = getAppGroupPathIfExists()) {
		NSURL *fakeAppGroupURL = [ourAppGroupURL URLByAppendingPathComponent:groupIdentifier];
		createDirectoryIfNotExists(fakeAppGroupURL.path);
		return fakeAppGroupURL;
	}

	// fallback to a fake App Group path in Documents/App Group
	//
	// Unlike in the main app this fallback cannot actually share anything: an
	// app extension gets its own data container, so the extension's Documents/
	// is not the app's. It is kept only so the mapping stays identical and the
	// call never returns nil.
	NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	NSString *fakePath = [[paths lastObject] stringByAppendingPathComponent:groupIdentifier];
	createDirectoryIfNotExists(fakePath);
	return [NSURL fileURLWithPath:fakePath];
}

@end

#pragma mark - group-suite NSUserDefaults

// The selector starts with "init" followed by an uppercase letter, so ARC places
// it in the init method family — same ownership contract as the
// -_initWithSuiteName:container: it is exchanged with. A raw IMP function
// pointer would not carry that contract and would mis-balance retains.
@interface NSUserDefaults (FBPNotifyBridge)
- (instancetype)initFBPWithSuiteName:(NSString *)suiteName container:(NSURL *)container;
@end

@implementation NSUserDefaults (FBPNotifyBridge)

// Mirrors -[NSUserDefaults _initWithSuiteName:container:] in SideloadFix.xm.
// After the exchange, -initFBPWithSuiteName:container: *is* the original
// implementation, so calling it on self is the %orig equivalent.
- (instancetype)initFBPWithSuiteName:(NSString *)suiteName container:(NSURL *)container {
	PILog(@"hooking NSUserDefaults init...");

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
		PILog(@"using custom container URL: %@", customContainerURL);
		return [self initFBPWithSuiteName:suiteName container:customContainerURL];
	}

	PILog(@"failed to construct valid URL for suite '%@' in app group container", suiteName);
	return [self initFBPWithSuiteName:suiteName container:container];
}

@end

#pragma mark - Install

// Swaps two instance methods, but only when both really exist — a future
// Foundation that drops the private initialiser then costs the group-suite
// redirect instead of taking the extension down with it.
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
		// The exchanges must always run — only the log is debug-gated, so the
		// results are unused in the release build (PILog compiles to a no-op).
		__attribute__((unused)) BOOL container =
			fbpExchange([NSFileManager class],
						@selector(containerURLForSecurityApplicationGroupIdentifier:),
						@selector(fbp_containerURLForSecurityApplicationGroupIdentifier:));
		__attribute__((unused)) BOOL suite =
			fbpExchange([NSUserDefaults class],
						@selector(_initWithSuiteName:container:),
						@selector(initFBPWithSuiteName:container:));

		PILog(@"notify bridge loaded into %@ (container=%d, suite=%d)",
			  NSBundle.mainBundle.bundleIdentifier, container, suite);
	}
}
