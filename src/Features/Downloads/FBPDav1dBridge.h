// Tier 2 of the AV1 conversion: borrow the dav1d decoder Facebook already
// ships, for devices whose own VideoToolbox cannot decode AV1.
//
// THIS TIER IS NOT LIVE. It declines, always, and the rest of this comment is
// why — measured, not assumed, because the failure mode of getting it wrong is
// a crash inside Facebook rather than a download that does not work.
//
// What is actually there
// ------------------------------------------------------------------------
// The idea is sound and costs no shipped bytes. `FBSharedFramework` exports the
// nine dav1d entry points a decode loop needs, and they resolve out of the host
// app with `dlsym(RTLD_DEFAULT, …)` — confirmed on the device, inside the real
// Facebook process (iPhone SE, A13, iOS 18.6.1):
//
//     dav1d_version  dav1d_open  dav1d_close  dav1d_default_settings
//     dav1d_send_data  dav1d_get_picture  dav1d_picture_unref
//     dav1d_data_wrap  dav1d_data_unref
//
// all nine resolving into
// Facebook.app/Frameworks/FBSharedFramework.framework/FBSharedFramework, whose
// `dav1d_version()` returns **"1.5.1"**. The rival tweak does exactly this —
// `_IQFDav1dAvailable` at 0xa80c74 resolves the same names with
// `dlsym(RTLD_DEFAULT, …)`, caches the result, and logs "dav1d is not available
// in this process" when it fails — so the approach is known to work in
// principle.
//
// Why it still declines: two dav1d builds, one flat namespace
// ------------------------------------------------------------------------
// The Facebook process has **two different, ABI-incompatible dav1d builds
// loaded at once**, and `dlsym(RTLD_DEFAULT, …)` draws from both:
//
//     FBSharedFramework   dav1d_version() -> "1.5.1"
//     WebCore (system)    dav1d_version() -> "1.0.0-0-g99172b1"
//                         /System/Library/PrivateFrameworks/WebCore.framework
//
// Measured in one process, in one run: the nine symbols above came from
// FBSharedFramework, while `dav1d_apply_grain`, `dav1d_flush`,
// `dav1d_parse_sequence_header` and `dav1d_data_create` — names FBSharedFramework
// does not export — came from **WebCore's 1.0.0**. So a flat-namespace lookup
// here returns a *mixture* of two libraries whose struct layouts need not agree.
//
// That breaks the rival's own safety check, and ours with it. Reading
// `dav1d_version()` and then driving `dav1d_open` does not establish anything:
// the two names can come from different images, so the version you validated is
// not necessarily the version you are about to call. Worse, WebCore is loaded
// lazily — it arrives when the app first shows a web view — so which image wins
// a given name can differ between launches and between before and after the
// user has opened a link.
//
// On top of that we have no dav1d headers, so `Dav1dSettings`, `Dav1dPicture`
// and `Dav1dData` would have to be declared by hand and would have to match the
// build being called. A wrong field offset is not a failed download; it is a
// wild write inside the host app.
//
// Two measured facts, one unverified layout, and a non-deterministic resolver is
// not a combination to ship into other people's Facebook. So this declines, and
// tier 1 carries the feature.
//
// What would make it live
// ------------------------------------------------------------------------
// In order, none of them guessed:
//
//  1. Resolve all nine symbols and prove with `dladdr` that every one of them
//     lands in the *same* Mach-O image. A mixed set must be refused outright —
//     that is the check this file exists to say is missing, and it is the one
//     the rival does not do.
//  2. Pin to that image deliberately rather than via the flat namespace:
//     `dlopen` FBSharedFramework's path and `dlsym` that handle, so WebCore can
//     never answer.
//  3. Establish the struct layouts for the exact version found, and hard-refuse
//     any version not on the verified list. `Dav1dSettings`'s layout can be
//     recovered empirically — zero a generous buffer, call
//     `dav1d_default_settings()`, and read off which words it wrote — but
//     `Dav1dPicture` cannot be confirmed without a real decode, which is the
//     part that has to happen on a device with a debugger attached.
//
// Until all three are done, -isAvailable below stays NO. An honest decline costs
// an AV1 rung on a device that has no AV1 decoder; a wrong layout costs the user
// their app.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// YES when the borrowed-dav1d tier can be used. Always NO today.
///
/// Deliberately a function rather than a compile-time 0, so the one call site in
/// FBPMediaConverter.m reads as a tier being unavailable at runtime — which is
/// what it is — rather than as dead code a future reader might delete along with
/// the reasoning above.
extern BOOL FBPDav1dTierIsAvailable(void);

/// One short line for the download diagnostic, naming why tier 2 declined.
///
/// Logged once when a conversion has to be refused, so a maintainer reading
/// Console on a device with no AV1 decoder sees the reason rather than a bare
/// failure. Never shown to a user: the user-facing sentence for this case lives
/// with the download flow, like every other one.
extern NSString *FBPDav1dTierDeclineReason(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
