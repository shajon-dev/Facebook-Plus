// Implementation of the add-only Photos save. See FBPPhotoSave.h.

#import "FBPPhotoSave.h"

#import <Photos/Photos.h>

extern NSString *FBPLocalizedString(NSString *key);

static NSError *FBPPhotoDeniedError(void) {
    NSString *message = FBPLocalizedString(@"save.photos.denied");
    return [NSError errorWithDomain:@"com.shajon.fbplus.photosave"
                               code:1
                           userInfo:@{ NSLocalizedDescriptionKey:
                                           message ?: @"save.photos.denied" }];
}

static void FBPPhotoRunChanges(void (^changes)(void),
                               void (^completion)(BOOL, NSError *)) {
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:changes
                                      completionHandler:^(BOOL success, NSError *error) {
        if (completion) completion(success, error);
    }];
}

void FBPPhotoSavePerformChanges(void (^changes)(void),
                                void (^completion)(BOOL, NSError *)) {
    if (!changes) {
        if (completion) completion(NO, FBPPhotoDeniedError());
        return;
    }

    if (@available(iOS 14.0, *)) {
        PHAccessLevel level = PHAccessLevelAddOnly;
        PHAuthorizationStatus status =
            [PHPhotoLibrary authorizationStatusForAccessLevel:level];

        // Already granted at least add-only (a full-access grant covers it too):
        // save straight away, no new prompt.
        if (status == PHAuthorizationStatusAuthorized ||
            status == PHAuthorizationStatusLimited) {
            FBPPhotoRunChanges(changes, completion);
            return;
        }

        // Explicitly undetermined: ask for add-only, so iOS offers "Add Photos
        // Only" rather than the full-library prompt a bare performChanges forces.
        if (status == PHAuthorizationStatusNotDetermined) {
            [PHPhotoLibrary requestAuthorizationForAccessLevel:level
                                                       handler:^(PHAuthorizationStatus granted) {
                if (granted == PHAuthorizationStatusAuthorized ||
                    granted == PHAuthorizationStatusLimited) {
                    FBPPhotoRunChanges(changes, completion);
                } else if (completion) {
                    completion(NO, FBPPhotoDeniedError());
                }
            }];
            return;
        }

        // Denied or restricted: nothing to do but report it.
        if (completion) completion(NO, FBPPhotoDeniedError());
        return;
    }

    // Pre-iOS 14 has no access levels; the old performChanges path is the only
    // one, and iOS prompts as it always did.
    FBPPhotoRunChanges(changes, completion);
}
