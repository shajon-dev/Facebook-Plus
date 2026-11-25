// Sideload compatibility layer: restores the keychain and App-Group storage a
// re-signed app loses. Derived from a third-party source; see THIRD_PARTY_NOTICES.md.

#import <Foundation/Foundation.h>

#if DEBUG
#define PILog(fmt, ...) NSLog(@"[Facebook Plus] " fmt, ##__VA_ARGS__)
#else
#define PILog(fmt, ...) do {} while (0)
#endif

#if FBP_DIAG
#define FBPDiagLog(fmt, ...) FBPDiagLogv(fmt, ##__VA_ARGS__)
extern void FBPDiagLogv(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
#else
// Compiles to nothing but still references its arguments: a bare do {} while (0)
// would leave a trace-only variable "set but not used" — -Werror under theos.
NS_FORMAT_FUNCTION(1, 2) NS_INLINE void FBPDiagLogSink(NSString *format, ...) {}
#define FBPDiagLog(fmt, ...) do { if (0) FBPDiagLogSink(fmt, ##__VA_ARGS__); } while (0)
#endif

// Resolved lazily and RETRIED until it succeeds; nil means unresolved, not final.
extern NSString *fbpResolvedAccessGroup(void);

extern NSString *fbpAccessGroupFromEntitlements(void);

extern NSString *bundleId;

extern void rebindSecFuncs();

extern BOOL fbpClaimProcessOnce(const char *name);
extern BOOL fbpIsAppExtensionProcess(void);
extern BOOL createDirectoryIfNotExists(NSString *path);
extern BOOL prepareGroupContainer(NSURL *container);
extern BOOL prepareDefaultsContainer(NSURL *container);
extern NSURL *getAppGroupPathIfExists();

// Where the app's original entitlements are intact these redirects are
// destructive: they move Facebook's session where the extension never looks.
extern BOOL fbpProcessHoldsAppGroup(NSString *group);
extern BOOL fbpProcessHoldsKeychainGroup(NSString *group);
extern BOOL fbpProcessHasOriginalEntitlements(void);
extern BOOL fbpShouldLeaveAppGroupAlone(NSString *group);

@interface LSBundleProxy: NSObject
@property(nonatomic, assign, readonly) NSDictionary *entitlements;
@property(nonatomic, assign, readonly) NSDictionary *groupContainerURLs;
+ (instancetype)bundleProxyForCurrentProcess;
@end
