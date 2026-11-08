// Sideload compatibility layer. Re-signing an app with a personal certificate
// strips the entitlements it was built against, so its keychain and App-Group
// storage break. This transparently restores both, and keeps CloudKit from
// hard-faulting on an iCloud container the re-signed build can never be granted.
//
// PluginsInject.mm  — constructor: resolve the keychain access group, install rebinds
// SecRebinds.xm     — steer SecItem* at that access group via fishhook
// SideloadFix.xm    — redirect CloudKit / App-Group / group NSUserDefaults containers
// Paths.mm          — resolve (or fabricate) the App-Group container path

#import <Foundation/Foundation.h>

// Debug-only logging, compiled out of the release (FINALPACKAGE) build.
#if DEBUG
#define PILog(fmt, ...) NSLog(@"[Facebook Plus] " fmt, ##__VA_ARGS__)
#else
#define PILog(fmt, ...) do {} while (0)
#endif

// Diagnostic logging that survives a release build, for the one thing PILog
// cannot do: tell us what the *notification extension* saw on a real device.
// An appex is not attached to a debugger and NSLog from it is easy to lose, so
// this goes through os_log on subsystem "com.shajon.fbplus", category
// "FBPDIAG", and every line is prefixed [FBPDIAG] so it can be grepped out of
// `idevicesyslog` as well as filtered in Console.app.
//
// Off unless the build asks for it:
//
//   make FBP_DIAG=1 && make -C FBPNotifyBridge/src FBP_DIAG=1 FINALPACKAGE=1
//
// See FBPNotifyBridge/README.md ("Tracing it on a device"). Keep it out of
// shipped builds: the lines name keychain services and container paths.
#if FBP_DIAG
#define FBPDiagLog(fmt, ...) FBPDiagLogv(fmt, ##__VA_ARGS__)
extern void FBPDiagLogv(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
#else
#define FBPDiagLog(fmt, ...) do {} while (0)
#endif

// The keychain access group every SecItem* call a re-signed build makes should
// end up in. Resolved lazily and **retried until it succeeds** — see
// SecRebinds.xm. Returns nil while it is still unresolved, which is a state the
// callers have to handle rather than a permanent answer.
extern NSString *fbpResolvedAccessGroup(void);

// The entitlement-derived fallback, used when the keychain cannot be reached.
extern NSString *fbpAccessGroupFromEntitlements(void);

extern NSString *bundleId;

extern void rebindSecFuncs();

extern BOOL createDirectoryIfNotExists(NSString *path);
extern NSURL *getAppGroupPathIfExists();

@interface LSBundleProxy: NSObject
@property(nonatomic, assign, readonly) NSDictionary *entitlements;
@property(nonatomic, assign, readonly) NSDictionary *groupContainerURLs;
+ (instancetype)bundleProxyForCurrentProcess;
@end
