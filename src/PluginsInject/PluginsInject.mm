// Constructor: discover the keychain access group, then install the SecItem*
// rebinds that pin every keychain call to it.

#import "Header.h"

NSString *accessGroupId;
NSString *bundleId;

// The app's real keychain access group is not knowable ahead of time, so add
// (or read back) a throwaway generic-password item and let the keychain report
// which access group it landed in. Keychain calls that need it are then pinned
// to that group (see SecRebinds.xm) so a sideloaded app's keychain I/O
// succeeds. If the probe fails, accessGroupId stays nil and SecRebinds leaves
// every query alone rather than stripping the group the caller asked for.
static void probeAccessGroup() {
	NSDictionary *query = @{
		(__bridge NSString *)kSecClass: (__bridge NSString *)kSecClassGenericPassword,
		(__bridge NSString *)kSecAttrAccount: @"com.shajon.fbplus.accessGroupProbe",
		(__bridge NSString *)kSecAttrService: @"",
		(__bridge id)kSecReturnAttributes: (id)kCFBooleanTrue
	};

	CFDictionaryRef result = nil;
	OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
	if (status == errSecItemNotFound) {
		status = SecItemAdd((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
	}
	if (status != errSecSuccess) {
		return;
	}

	bundleId = [[NSBundle mainBundle] bundleIdentifier];
	accessGroupId = [(__bridge NSDictionary *)result objectForKey:(__bridge NSString *)kSecAttrAccessGroup];
	if (result) {
		CFRelease(result);
	}
}

__attribute__((constructor)) static void PluginsInjectInit() {
	probeAccessGroup();
	rebindSecFuncs();
}
