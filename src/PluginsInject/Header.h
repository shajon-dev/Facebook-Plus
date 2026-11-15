// Sideload compatibility layer. Re-signing an app with a personal certificate
// strips the entitlements it was built against, so its keychain and App-Group
// storage break. This transparently restores both, and keeps CloudKit from
// hard-faulting on an iCloud container the re-signed build can never be granted.
//
// Derived from a third-party source; see THIRD_PARTY_NOTICES.md.
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
// cannot do: report what the *notification extension* saw on a real device.
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
// Compiles to nothing but still references its arguments, inside a branch the
// optimiser drops. A bare `do {} while (0)` would discard them, and a variable
// built only for a trace would then read as "set but not used" — -Werror under
// theos, failing the non-diagnostic build while the diagnostic one passes. The
// empty static inline body needs no symbol at link time.
NS_FORMAT_FUNCTION(1, 2) NS_INLINE void FBPDiagLogSink(NSString *format, ...) {}
#define FBPDiagLog(fmt, ...) do { if (0) FBPDiagLogSink(fmt, ##__VA_ARGS__); } while (0)
#endif

// The keychain access group every SecItem* call a re-signed build makes should
// end up in. Resolved lazily and **retried until it succeeds** — see
// SecRebinds.xm. Returns nil while unresolved; callers must handle that rather
// than treat it as final.
extern NSString *fbpResolvedAccessGroup(void);

// The entitlement-derived fallback, used when the keychain cannot be reached.
extern NSString *fbpAccessGroupFromEntitlements(void);

extern NSString *bundleId;

extern void rebindSecFuncs();

extern BOOL fbpClaimProcessOnce(const char *name);
extern BOOL fbpIsAppExtensionProcess(void);
extern BOOL createDirectoryIfNotExists(NSString *path);
extern BOOL prepareDefaultsContainer(NSURL *container);
extern NSURL *getAppGroupPathIfExists();

@interface LSBundleProxy: NSObject
@property(nonatomic, assign, readonly) NSDictionary *entitlements;
@property(nonatomic, assign, readonly) NSDictionary *groupContainerURLs;
+ (instancetype)bundleProxyForCurrentProcess;
@end
