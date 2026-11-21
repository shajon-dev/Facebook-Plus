#import "FBPCacheCleaner.h"

#import <WebKit/WebKit.h>

#import "FBPTrace.h"

// WHAT A CACHE IS HERE, AND WHAT IT IS NOT
//
// Every path below was checked against a real container on a device
// (2026-11-21). That mattered, because two things that look like caches are
// not:
//
//   Documents/cask/100035156896002   CASK stores are scoped by the logged-in
//   Documents/group.com.facebook.*/cask   account id. A store under Documents or
//                                    inside an App-Group container is durable
//                                    per-account state that happens to use a
//                                    cache-shaped API — the group container is
//                                    also where the notification extension
//                                    reads the session from. Only a CASK store
//                                    under a Caches directory is a cache.
//
//   NSTemporaryDirectory()           Shared scratch. This tweak's own downloads,
//                                    media conversions and log exports all write
//                                    there, so emptying it wholesale destroys an
//                                    in-flight download — and with the automatic
//                                    sweep on, it did so at every launch.
//
// So the rule is: clear the Caches directories, the directories Facebook itself
// names as caches, and the local analytics and log stores. Leave everything
// else, and never walk Documents or an App-Group container looking for things
// to delete.

#pragma mark - What must survive

/// Names that must never be removed, whatever directory they turn up in.
///
/// Matched per path component during the walk, not once on the directory we
/// were asked to delete. The difference is the whole point: removing a tree
/// with -removeItemAtPath: deletes everything inside it, so a check that only
/// ever saw the top of the tree would protect `Library/Caches/Cookies` and
/// still take `Library/Caches/something/Cookies` with the rest of `something`.
static BOOL FBPIsProtectedComponent(NSString *name) {
    static NSSet<NSString *> *protected;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        protected = [NSSet setWithArray:@[
            // Session and credential stores. HTTPStorages is where iOS 13+
            // keeps an app's cookies and its URL-session state; losing it signs
            // the account out, which is the one outcome this feature must never
            // produce.
            @"Cookies",
            @"Cookies.binarycookies",
            @"HTTPStorages",
            @"Keychains",
            @"WebKit",
            @"WebsiteData",
            @"FBAPISessionLoggedInUserIDCache",
            @"AppAttestationStorageReinstallationFlagKey",

            // Preferences, in both the system spelling and Facebook's own.
            @"Preferences",
            @"metaUserDefaults",
            @"com.facebook.Facebook.preferences",

            // This tweak's own state, including the log mirror: deleting the
            // file an open descriptor is writing to leaves the process logging
            // into an unlinked inode, so the log silently stops existing.
            @"FacebookPlus",
            @"FacebookPlusFonts",
            @"facebook-plus-trace.log",
            @"facebook-plus-trace.log.day",

            @".com.apple.mobile_container_manager.metadata.plist",
        ]];
    });

    if (!name.length) {
        return YES;
    }
    if ([protected containsObject:name]) {
        return YES;
    }
    // App-Group containers hold the session the app and the notification
    // extension share. On a re-signed build the redirect puts them under
    // Documents, so they are reachable from a sweep that walks it.
    if ([name hasPrefix:@"group.com.facebook."] || [name hasPrefix:@"group.com.metaplatforms."]) {
        return YES;
    }
    // A preferences plist anywhere is somebody's settings.
    return [name hasSuffix:@".plist"];
}

/// YES when any component of this path is protected.
static BOOL FBPIsProtectedPath(NSString *path) {
    if (!path.length) {
        return YES;
    }
    for (NSString *component in path.pathComponents) {
        if (FBPIsProtectedComponent(component)) {
            return YES;
        }
    }
    return NO;
}

/// Scratch this tweak owns. Named so the temporary-directory sweep cannot take
/// a download, a conversion or a log export out from under its own feature.
static BOOL FBPIsOurScratch(NSString *name) {
    return [name hasPrefix:@"FBP"] || [name hasPrefix:@"Facebook-Plus-"];
}

#pragma mark - Measuring and deleting

/// Size of a file, or of everything under a directory.
static unsigned long long FBPSizeOfPath(NSString *path, NSFileManager *fm) {
    if (!path.length) {
        return 0;
    }
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDirectory]) {
        return 0;
    }
    if (!isDirectory) {
        return [fm attributesOfItemAtPath:path error:NULL].fileSize;
    }

    unsigned long long total = 0;
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:path];
    // The loop variable is unused on purpose: -fileAttributes describes the
    // item the enumerator just produced, and reading it costs no second stat
    // the way building each full path and asking again would. Named with a
    // marked __unused so -Werror does not take the build down over it.
    for (NSString *__unused relative in enumerator) {
        NSDictionary *attributes = enumerator.fileAttributes;
        if (![attributes[NSFileType] isEqual:NSFileTypeDirectory]) {
            total += attributes.fileSize;
        }
    }
    return total;
}

/// Removes a file, or the unprotected parts of a directory, and reports the
/// bytes freed.
///
/// A directory is only removed outright once it is known to contain nothing
/// protected; otherwise it is walked and its children handled one by one, and
/// the directory itself is left behind. Measuring happens once, on the way in.
static unsigned long long FBPDeletePath(NSString *path, NSFileManager *fm) {
    if (!path.length || FBPIsProtectedPath(path)) {
        return 0;
    }

    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDirectory]) {
        return 0;
    }

    if (!isDirectory) {
        unsigned long long size = [fm attributesOfItemAtPath:path error:NULL].fileSize;
        return [fm removeItemAtPath:path error:NULL] ? size : 0;
    }

    // Does this tree hold anything that has to survive? If not, one removal is
    // both cheaper and atomic.
    BOOL holdsProtected = NO;
    NSDirectoryEnumerator *scan = [fm enumeratorAtPath:path];
    for (NSString *relative in scan) {
        if (FBPIsProtectedPath(relative)) {
            holdsProtected = YES;
            break;
        }
    }

    if (!holdsProtected) {
        unsigned long long size = FBPSizeOfPath(path, fm);
        return [fm removeItemAtPath:path error:NULL] ? size : 0;
    }

    unsigned long long freed = 0;
    for (NSString *child in [fm contentsOfDirectoryAtPath:path error:NULL]) {
        freed += FBPDeletePath([path stringByAppendingPathComponent:child], fm);
    }
    return freed;
}

/// Empties a directory, keeping the directory itself.
static unsigned long long FBPDeleteContentsOfDirectory(NSString *directory, NSFileManager *fm) {
    if (!directory.length) {
        return 0;
    }
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:directory isDirectory:&isDirectory] || !isDirectory) {
        return 0;
    }

    unsigned long long freed = 0;
    for (NSString *child in [fm contentsOfDirectoryAtPath:directory error:NULL]) {
        freed += FBPDeletePath([directory stringByAppendingPathComponent:child], fm);
    }
    return freed;
}

/// Clears Facebook's CASK stores **under a caches directory only**.
///
/// A CASK store outside one is not a cache: on device, `Documents/cask` and the
/// stores inside the App-Group containers are scoped by the logged-in account
/// id, and the group container is what the notification extension reads the
/// session from. Sweeping those was the most destructive thing this file did.
static unsigned long long FBPClearCaskStoresInCaches(NSString *cachesRoot, NSFileManager *fm) {
    if (!cachesRoot.length) {
        return 0;
    }
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:cachesRoot isDirectory:&isDirectory] || !isDirectory) {
        return 0;
    }

    unsigned long long freed = 0;
    NSDirectoryEnumerator *enumerator =
        [fm enumeratorAtURL:[NSURL fileURLWithPath:cachesRoot]
            includingPropertiesForKeys:@[ NSURLIsDirectoryKey ]
                               options:NSDirectoryEnumerationSkipsHiddenFiles
                          errorHandler:nil];
    for (NSURL *url in enumerator) {
        if (FBPIsProtectedPath(url.path)) {
            [enumerator skipDescendants];
            continue;
        }
        if ([url.lastPathComponent isEqualToString:@"cask"]) {
            freed += FBPDeleteContentsOfDirectory(url.path, fm);
            [enumerator skipDescendants];
        }
    }
    return freed;
}

/// Clears abandoned scratch from the temporary directory.
///
/// Not emptied wholesale. This tweak's downloads, media conversions and log
/// exports all live here, and so does Facebook's own in-flight upload and
/// transcode scratch, so anything recent is assumed to be in use.
static unsigned long long FBPClearStaleTemporaryFiles(NSFileManager *fm) {
    NSString *directory = NSTemporaryDirectory();
    if (!directory.length) {
        return 0;
    }

    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-3600];
    unsigned long long freed = 0;
    for (NSString *child in [fm contentsOfDirectoryAtPath:directory error:NULL]) {
        if (FBPIsOurScratch(child)) {
            continue;
        }
        NSString *path = [directory stringByAppendingPathComponent:child];
        NSDate *modified = [fm attributesOfItemAtPath:path error:NULL].fileModificationDate;
        if (modified && [modified compare:cutoff] == NSOrderedDescending) {
            continue;
        }
        freed += FBPDeletePath(path, fm);
    }
    return freed;
}

#pragma mark - The sweep

@implementation FBPCacheCleaner

+ (void)clearAllCachesWithCompletion:(void (^)(unsigned long long bytesFreed))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        unsigned long long freed = 0;

        NSString *caches = NSSearchPathForDirectoriesInDomains(
            NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        NSString *appSupport = NSSearchPathForDirectoriesInDomains(
            NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
        NSString *documents = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject;

        // Library/Caches, which is what a caches directory is for: the CDN image
        // stores, the media segment caches, the DNS and TLS stores, the WebKit
        // network cache.
        freed += FBPDeleteContentsOfDirectory(caches, fm);

        // Scratch nothing is still using.
        freed += FBPClearStaleTemporaryFiles(fm);

        // The directories Facebook itself names as caches. These sit under
        // Application Support rather than Caches, so they are listed by name
        // instead of being found by a walk.
        if (appSupport.length) {
            NSString *base = [appSupport stringByAppendingPathComponent:@"com.facebook.Facebook"];
            for (NSString *name in @[ @"News Feed Cache", @"analytics" ]) {
                freed += FBPDeleteContentsOfDirectory(
                    [base stringByAppendingPathComponent:name], fm);
            }
            for (NSString *name in @[ @"executorchcoreml", @"PrefetchPlayML" ]) {
                freed += FBPDeleteContentsOfDirectory(
                    [appSupport stringByAppendingPathComponent:name], fm);
            }
        }

        // Local analytics and logging stores. Named individually: Documents
        // holds durable account state alongside them and must not be walked.
        if (documents.length) {
            for (NSString *child in [fm contentsOfDirectoryAtPath:documents error:NULL]) {
                if ([child hasPrefix:@"FFLogger.sql"] ||
                    [child hasPrefix:@"time_in_app_"] ||
                    [child hasPrefix:@"proxy_video_data_usage.stats"]) {
                    freed += FBPDeletePath([documents stringByAppendingPathComponent:child], fm);
                }
            }
            for (NSString *name in @[ @"analytics", @"TerminationReporter" ]) {
                freed += FBPDeleteContentsOfDirectory(
                    [documents stringByAppendingPathComponent:name], fm);
            }
        }

        // CASK stores, in caches directories only.
        freed += FBPClearCaskStoresInCaches(caches, fm);
        if (appSupport.length) {
            freed += FBPClearCaskStoresInCaches(
                [appSupport stringByAppendingPathComponent:
                                @"com.facebook.Facebook/News Feed Cache"], fm);
        }

        // The shared container's own caches directory, and nothing else inside
        // it: the rest of that container is the session.
        NSURL *group = [fm containerURLForSecurityApplicationGroupIdentifier:
                               @"group.com.facebook.Facebook"];
        if (group.path.length) {
            NSString *groupCaches = [group.path stringByAppendingPathComponent:@"Library/Caches"];
            freed += FBPDeleteContentsOfDirectory(groupCaches, fm);
            freed += FBPClearCaskStoresInCaches(groupCaches, fm);
        }

        [NSURLCache.sharedURLCache removeAllCachedResponses];

        FBPDiag(@"cache", @"cleared %@ from disk",
                [self formattedByteSize:freed]);

        // WebKit last, because it answers asynchronously and the completion has
        // to wait for it — the previous version reported a total before this
        // ran and before the caller's toast could be truthful.
        dispatch_async(dispatch_get_main_queue(), ^{
            void (^finish)(void) = ^{
                if (completion) {
                    completion(freed);
                }
            };

            if (![WKWebsiteDataStore class]) {
                finish();
                return;
            }

            // Cookies stay: they are the in-app browser's logins. Local and
            // session storage stay with them, because a web login keeps its
            // token there as readily as in a cookie.
            NSMutableSet *types = [[WKWebsiteDataStore allWebsiteDataTypes] mutableCopy];
            [types removeObject:WKWebsiteDataTypeCookies];
            [types removeObject:WKWebsiteDataTypeLocalStorage];
            [types removeObject:WKWebsiteDataTypeSessionStorage];

            [WKWebsiteDataStore.defaultDataStore removeDataOfTypes:types
                                                     modifiedSince:NSDate.distantPast
                                                 completionHandler:finish];
        });
    });
}

+ (NSString *)formattedByteSize:(unsigned long long)bytes {
    return [NSByteCountFormatter stringFromByteCount:(long long)bytes
                                          countStyle:NSByteCountFormatterCountStyleFile];
}

@end
