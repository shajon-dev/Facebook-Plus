// One place every "save to Photos" goes through, so the tweak asks for the
// narrowest permission iOS offers (https://github.com/shajon-dev/Facebook-Plus/issues/6).
//
// Saving a reel or a story used to reach `-[PHPhotoLibrary performChanges:]`
// with the library's authorization still undetermined, and iOS then prompted for
// full read-write access — the only level a bare performChanges implies. From
// iOS 14 a creation-only client can instead ask for @c PHAccessLevelAddOnly,
// which on iOS 26 surfaces the "Add Photos Only" choice and never asks the user
// to share their whole library just to let a download land.
//
// So this requests add-only authorization first and performs the change only
// once it is granted. Where Facebook already holds full access (its own features
// need it) the add-only status is already "authorized", so nothing new is
// prompted and the save behaves exactly as before. Deletion is deliberately NOT
// routed here — removing an asset needs read-write, which add-only cannot grant,
// so the download manager keeps its own full-access performChanges.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Ensure add-only Photos authorization, then run @c changes inside a
/// performChanges transaction. @c completion is called once, on the same
/// arbitrary queue Photos uses, with the transaction's result — or, when the
/// user declines the permission, with @c NO and an error whose
/// @c localizedDescription is a finished, localized sentence the save paths can
/// show as-is.
///
/// A creation block only: it must not delete or modify existing assets, which
/// add-only authorization does not permit.
void FBPPhotoSavePerformChanges(void (^changes)(void),
                                void (^_Nullable completion)(BOOL success,
                                                             NSError *_Nullable error));

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
