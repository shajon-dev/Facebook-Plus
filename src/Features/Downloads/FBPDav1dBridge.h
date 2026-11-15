// Tier 2 of the AV1 conversion: borrow the dav1d decoder Facebook already
// ships, for devices whose own VideoToolbox cannot decode AV1.
//
// THIS TIER IS NOT LIVE. It declines, always, and the rest of this comment is
// why — measured, not assumed, because getting it wrong crashes Facebook rather
// than failing a download.
//
// What is actually there
// ------------------------------------------------------------------------
// The idea is sound and costs no shipped bytes. `FBSharedFramework` exports the
// nine dav1d entry points a decode loop needs, and they resolve out of the host
// app with `dlsym(RTLD_DEFAULT, …)` — confirmed on device, inside the real
// Facebook process (iPhone SE, A13, iOS 18.6.1):
//
//     dav1d_version  dav1d_open  dav1d_close  dav1d_default_settings
//     dav1d_send_data  dav1d_get_picture  dav1d_picture_unref
//     dav1d_data_wrap  dav1d_data_unref
//
// all nine resolving into
// Facebook.app/Frameworks/FBSharedFramework.framework/FBSharedFramework, whose
// `dav1d_version()` returns "1.5.1".
//
// Why it still declines: two dav1d builds, one flat namespace
// ------------------------------------------------------------------------
// The Facebook process has two different, ABI-incompatible dav1d builds loaded
// at once, and `dlsym(RTLD_DEFAULT, …)` draws from both:
//
//     FBSharedFramework   dav1d_version() -> "1.5.1"
//     WebCore (system)    dav1d_version() -> "1.0.0-0-g99172b1"
//                         /System/Library/PrivateFrameworks/WebCore.framework
//
// Measured in one process, one run: the nine symbols above came from
// FBSharedFramework, while `dav1d_apply_grain`, `dav1d_flush`,
// `dav1d_parse_sequence_header` and `dav1d_data_create` — names FBSharedFramework
// does not export — came from WebCore's 1.0.0. So a flat-namespace lookup here
// returns a mixture of two libraries whose struct layouts need not agree.
//
// That breaks the obvious safety check. Reading `dav1d_version()` and then
// driving `dav1d_open` establishes nothing: the two names can come from
// different images, so the version validated is not necessarily the version
// called. Worse, WebCore loads lazily — when the app first shows a web view — so
// which image wins a given name can differ between launches and before/after the
// user opens a link.
//
// On top of that there are no dav1d headers, so `Dav1dSettings`, `Dav1dPicture`
// and `Dav1dData` would have to be declared by hand and match the build being
// called. A wrong field offset is not a failed download; it is a wild write
// inside the host app.
//
// Two measured facts, one unverified layout, and a non-deterministic resolver is
// not something to ship into other people's Facebook. So this declines, and
// tier 1 carries the feature.
//
// What would make it live
// ------------------------------------------------------------------------
// In order, none of them guessed:
//
//  1. Resolve all nine symbols and prove with `dladdr` that every one lands in
//     the *same* Mach-O image. A mixed set must be refused outright — the check
//     this file exists to say is missing.
//  2. Pin to that image deliberately rather than via the flat namespace:
//     `dlopen` FBSharedFramework's path and `dlsym` that handle, so WebCore can
//     never answer.
//  3. Establish the struct layouts for the exact version found, and hard-refuse
//     any version not on the verified list. `Dav1dSettings`'s layout can be
//     recovered empirically — zero a generous buffer, call
//     `dav1d_default_settings()`, read off which words it wrote — but
//     `Dav1dPicture` cannot be confirmed without a real decode, which needs a
//     device with a debugger attached.
//
// Until all three are done, -isAvailable below stays NO. An honest decline costs
// an AV1 rung on a device with no AV1 decoder; a wrong layout costs the user
// their app.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// YES when the borrowed-dav1d tier can be used. Always NO today.
///
/// A function rather than a compile-time 0, so the one call site in
/// FBPMediaConverter.m reads as a tier unavailable at runtime, not as dead code
/// a future reader might delete along with the reasoning above.
extern BOOL FBPDav1dTierIsAvailable(void);

/// One short line for the download diagnostic, naming why tier 2 declined.
///
/// Logged once when a conversion is refused, so a maintainer reading Console on
/// a device with no AV1 decoder sees the reason, not a bare failure. Never shown
/// to a user: the user-facing sentence lives with the download flow.
extern NSString *FBPDav1dTierDeclineReason(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
