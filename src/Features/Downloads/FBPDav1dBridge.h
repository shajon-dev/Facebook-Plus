// Tier 2 of the AV1 conversion: borrow the dav1d decoder Facebook already
// ships, for devices whose own VideoToolbox cannot decode AV1.
//
// NOT LIVE: -isAvailable always declines. The host process has two
// ABI-incompatible dav1d builds loaded (FBSharedFramework 1.5.1 and, lazily,
// WebCore's 1.0.0), and dlsym(RTLD_DEFAULT) draws names from both, so a
// version check cannot establish which build a later call reaches. There are
// also no dav1d headers, so the structs would be hand-declared against an
// unconfirmed layout. A wrong field offset is a wild write inside the host app,
// not a failed download.
//
// To make it live: prove with dladdr that all nine symbols land in one image
// and refuse a mixed set, dlopen FBSharedFramework's path instead of using the
// flat namespace, and verify the struct layouts per version against a
// hard-coded allow-list.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// YES when the borrowed-dav1d tier can be used. Always NO today.
///
/// A function rather than a compile-time 0, so the one call site in
/// FBPMediaConverter.m reads as a tier unavailable at runtime, not as dead code.
extern BOOL FBPDav1dTierIsAvailable(void);

/// One short line for the download diagnostic, naming why tier 2 declined.
/// Logged once per refused conversion; never shown to a user.
extern NSString *FBPDav1dTierDeclineReason(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
