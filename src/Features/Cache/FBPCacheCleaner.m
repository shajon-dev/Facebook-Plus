#import "FBPCacheCleaner.h"
#import "FBPPrefs.h"

#import <WebKit/WebKit.h>

#import "FBPTrace.h"

// Two things look like caches and are not. A CASK store under Documents or
// inside an App-Group container is durable per-account state that happens to
// use a cache-shaped API — and the group container is where the notification
// extension reads the session from — so only a CASK store under a Caches
// directory is a cache. And NSTemporaryDirectory() is shared scratch, holding
// this tweak's own downloads, conversions and log exports, so emptying it
// wholesale destroys an in-flight download.
//
// The rule: clear the Caches directories, the directories Facebook itself names
// as caches, and the local analytics and log stores. Never walk Documents or an
// App-Group container looking for things to delete.

#pragma mark - What must survive

/// Names that must never be removed, whatever directory they turn up in.
/// Matched per path COMPONENT during the walk, not once on the directory we
/// were asked to delete: -removeItemAtPath: takes everything inside a tree, so
/// a top-only check protects Library/Caches/Cookies and still loses
/// Library/Caches/something/Cookies.
static BOOL FBPIsProtectedComponent(NSString *name) {
    static NSSet<NSString *> *protected;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        protected = [NSSet setWithArray:@[
            // Session and credential stores. HTTPStorages is where iOS 13+
            // keeps cookies and URL-session state, so losing it signs out.
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

            // This tweak's own state, the log mirror included: deleting a file
            // an open descriptor is writing to leaves it logging to nothing.
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
    // App-Group containers hold the session the app and the extension share,
    // and a re-signed build's redirect puts them under Documents.
    if ([name hasPrefix:@"group.com.facebook."] || [name hasPrefix:@"group.com.metaplatforms."]) {
        return YES;
    }
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

/// Scratch this tweak owns, so the temporary-directory sweep cannot take a
/// download or a log export out from under its own feature.
static BOOL FBPIsOurScratch(NSString *name) {
    return [name hasPrefix:@"FBP"] || [name hasPrefix:@"Facebook-Plus-"];
}

#pragma mark - Measuring, staging and deleting

/// A fresh directory to rename doomed items into, or nil.
///
/// Renaming is what makes a launch-time sweep safe: unlinking a cache while
/// Facebook starts up pulls files out from under stores it has already opened,
/// while a rename leaves the app looking at an empty cache and anything it
/// holds open still readable. The staged tree is unlinked afterwards, off the
/// main thread. The name begins with "FBP" so FBPIsOurScratch keeps the
/// temporary-directory pass out of the staging area it is filling.
static NSString *_Nullable FBPStagingDirectory(NSFileManager *fm) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"FBPCacheSweep-%@", NSUUID.UUID.UUIDString]];
    if (![fm createDirectoryAtPath:path
       withIntermediateDirectories:YES
                        attributes:nil
                             error:NULL]) {
        return nil;
    }
    return path;
}

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
    // item just produced, so there is no second stat.
    for (NSString *__unused relative in enumerator) {
        NSDictionary *attributes = enumerator.fileAttributes;
        if (![attributes[NSFileType] isEqual:NSFileTypeDirectory]) {
            total += attributes.fileSize;
        }
    }
    return total;
}

/// Disposes of one item known to be safe to lose: renamed into @c staging when
/// one was given, unlinked otherwise. Only the unlinking path measures, because
/// staging runs on the main thread during launch and a size is a second walk.
static unsigned long long FBPReclaimItem(NSString *path,
                                         NSFileManager *fm,
                                         NSString *_Nullable staging) {
    if (staging.length) {
        NSString *destination =
            [staging stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [fm moveItemAtPath:path toPath:destination error:NULL];
        return 0;
    }
    unsigned long long size = FBPSizeOfPath(path, fm);
    return [fm removeItemAtPath:path error:NULL] ? size : 0;
}

/// Reclaims a file, or the unprotected parts of a directory, reporting bytes
/// freed. A directory is taken outright only once it is known to hold nothing
/// protected; otherwise its children are handled one by one and it stays.
static unsigned long long FBPReclaimPath(NSString *path,
                                         NSFileManager *fm,
                                         NSString *_Nullable staging) {
    if (!path.length || FBPIsProtectedPath(path)) {
        return 0;
    }

    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDirectory]) {
        return 0;
    }

    if (!isDirectory) {
        return FBPReclaimItem(path, fm, staging);
    }

    // Nothing in the tree has to survive, so one operation does it atomically.
    BOOL holdsProtected = NO;
    NSDirectoryEnumerator *scan = [fm enumeratorAtPath:path];
    for (NSString *relative in scan) {
        if (FBPIsProtectedPath(relative)) {
            holdsProtected = YES;
            break;
        }
    }

    if (!holdsProtected) {
        return FBPReclaimItem(path, fm, staging);
    }

    unsigned long long freed = 0;
    for (NSString *child in [fm contentsOfDirectoryAtPath:path error:NULL]) {
        freed += FBPReclaimPath([path stringByAppendingPathComponent:child], fm, staging);
    }
    return freed;
}

static unsigned long long FBPReclaimContentsOfDirectory(NSString *directory,
                                                        NSFileManager *fm,
                                                        NSString *_Nullable staging) {
    if (!directory.length) {
        return 0;
    }
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:directory isDirectory:&isDirectory] || !isDirectory) {
        return 0;
    }

    unsigned long long freed = 0;
    for (NSString *child in [fm contentsOfDirectoryAtPath:directory error:NULL]) {
        freed += FBPReclaimPath([directory stringByAppendingPathComponent:child], fm, staging);
    }
    return freed;
}

/// Facebook's CASK stores **under a caches directory only**: one outside is not
/// a cache but account-scoped state, and the App-Group container is what the
/// notification extension reads the session from.
static unsigned long long FBPClearCaskStoresInCaches(NSString *cachesRoot,
                                                     NSFileManager *fm,
                                                     NSString *_Nullable staging) {
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
            freed += FBPReclaimContentsOfDirectory(url.path, fm, staging);
            [enumerator skipDescendants];
        }
    }
    return freed;
}

/// Abandoned scratch only. This tweak's downloads and log exports live here, as
/// does Facebook's own upload and transcode scratch, so anything recent is
/// assumed to be in use.
static unsigned long long FBPClearStaleTemporaryFiles(NSFileManager *fm,
                                                      NSString *_Nullable staging) {
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
        freed += FBPReclaimPath(path, fm, staging);
    }
    return freed;
}

#pragma mark - The paths

/// The one list of what a sweep covers, so the launch pass and the Settings
/// button cannot drift apart. Returns the bytes freed, which is zero when
/// staging (see FBPReclaimItem).
static unsigned long long FBPRunSweep(NSString *_Nullable staging) {
    NSFileManager *fm = NSFileManager.defaultManager;
    unsigned long long freed = 0;

    NSString *caches = NSSearchPathForDirectoriesInDomains(
        NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSString *appSupport = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;

    // Library/Caches: CDN images, media segments, DNS/TLS, WebKit's network
    // cache.
    freed += FBPReclaimContentsOfDirectory(caches, fm, staging);

    freed += FBPClearStaleTemporaryFiles(fm, staging);

    // Named by Facebook as caches but sitting under Application Support, so
    // they are listed rather than found by a walk.
    if (appSupport.length) {
        NSString *base = [appSupport stringByAppendingPathComponent:@"com.facebook.Facebook"];
        for (NSString *name in @[ @"News Feed Cache", @"analytics" ]) {
            freed += FBPReclaimContentsOfDirectory(
                [base stringByAppendingPathComponent:name], fm, staging);
        }
        for (NSString *name in @[ @"executorchcoreml", @"PrefetchPlayML" ]) {
            freed += FBPReclaimContentsOfDirectory(
                [appSupport stringByAppendingPathComponent:name], fm, staging);
        }
    }

    // Named individually: Documents holds durable account state alongside them.
    if (documents.length) {
        for (NSString *child in [fm contentsOfDirectoryAtPath:documents error:NULL]) {
            if ([child hasPrefix:@"FFLogger.sql"] ||
                [child hasPrefix:@"time_in_app_"] ||
                [child hasPrefix:@"proxy_video_data_usage.stats"]) {
                freed += FBPReclaimPath(
                    [documents stringByAppendingPathComponent:child], fm, staging);
            }
        }
        for (NSString *name in @[ @"analytics", @"TerminationReporter" ]) {
            freed += FBPReclaimContentsOfDirectory(
                [documents stringByAppendingPathComponent:name], fm, staging);
        }
    }

    freed += FBPClearCaskStoresInCaches(caches, fm, staging);
    if (appSupport.length) {
        freed += FBPClearCaskStoresInCaches(
            [appSupport stringByAppendingPathComponent:
                            @"com.facebook.Facebook/News Feed Cache"], fm, staging);
    }

    // Its caches directory only: the rest of that container is the session.
    NSURL *group = [fm containerURLForSecurityApplicationGroupIdentifier:
                           @"group.com.facebook.Facebook"];
    if (group.path.length) {
        NSString *groupCaches = [group.path stringByAppendingPathComponent:@"Library/Caches"];
        freed += FBPReclaimContentsOfDirectory(groupCaches, fm, staging);
        freed += FBPClearCaskStoresInCaches(groupCaches, fm, staging);
    }

    [NSURLCache.sharedURLCache removeAllCachedResponses];
    return freed;
}

/// WebKit's own stores, answered for asynchronously. Cookies stay — they are
/// the in-app browser's logins — and local and session storage with them,
/// because a web login keeps its token there as readily as in a cookie.
static void FBPClearWebsiteData(void (^_Nullable completion)(void)) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![WKWebsiteDataStore class]) {
            if (completion) completion();
            return;
        }
        NSMutableSet *types = [[WKWebsiteDataStore allWebsiteDataTypes] mutableCopy];
        [types removeObject:WKWebsiteDataTypeCookies];
        [types removeObject:WKWebsiteDataTypeLocalStorage];
        [types removeObject:WKWebsiteDataTypeSessionStorage];

        [WKWebsiteDataStore.defaultDataStore removeDataOfTypes:types
                                                 modifiedSince:NSDate.distantPast
                                             completionHandler:^{
            if (completion) completion();
        }];
    });
}

#pragma mark - The schedule

static NSTimeInterval FBPSchedulePeriod(void) {
    NSString *choice = [FBPPrefs.shared stringForKey:FBPKeyCacheSchedule];
    if ([choice isEqualToString:@"12"]) return 12 * 3600;
    if ([choice isEqualToString:@"24"]) return 24 * 3600;
    return 0;
}

static void FBPRecordSweep(void) {
    [FBPPrefs.shared setDouble:NSDate.date.timeIntervalSince1970
                        forKey:FBPKeyLastCacheSweep];
}

/// Whether a scheduled sweep is owed; the every-launch switch answers for
/// itself.
///
/// The schedule is clock times in UTC, not an elapsed-time countdown, so a
/// sweep is owed when the last one happened before the most recent of those
/// times — once, on the first launch after the hour comes round, in any time
/// zone. The boundary is arithmetic rather than an NSCalendar question because
/// Unix time counts from midnight UTC with no leap seconds, so flooring to a
/// multiple of the period lands exactly on it.
static BOOL FBPScheduledSweepIsDue(void) {
    NSTimeInterval period = FBPSchedulePeriod();
    if (period <= 0) {
        return NO;
    }
    NSTimeInterval last = [FBPPrefs.shared doubleForKey:FBPKeyLastCacheSweep];
    if (last <= 0) {
        // Never swept, the first launch after switching the schedule on
        // included.
        return YES;
    }
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (now < last) {
        // The clock moved backwards: better to sweep now than park the next
        // one somewhere in the future.
        return YES;
    }
    return last < floor(now / period) * period;
}

#pragma mark - The sweep

@implementation FBPCacheCleaner

+ (void)clearAllCachesWithCompletion:(void (^)(unsigned long long bytesFreed))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        unsigned long long freed = FBPRunSweep(nil);
        // A hand-cleared cache restarts the schedule: the next automatic sweep
        // is due a full interval from here, not from whenever the last one ran.
        FBPRecordSweep();

        FBPDiag(@"cache", @"cleared %@ from disk",
                [self formattedByteSize:freed]);

        // WebKit last: it answers asynchronously, and the completion has to
        // wait for it or the total it reports is not the whole figure.
        FBPClearWebsiteData(^{
            if (completion) {
                completion(freed);
            }
        });
    });
}

+ (void)clearCachesAtLaunchIfDue {
    if (!FBPEnabled(FBPKeyAutoClearCache) && !FBPScheduledSweepIsDue()) {
        return;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *staging = FBPStagingDirectory(fm);
    if (!staging) {
        // With nowhere to rename into there is no safe launch sweep, and
        // deleting in place is what this avoids. Settings still works.
        FBPDiag(@"cache", @"no staging directory — skipping the launch sweep");
        return;
    }

    FBPRunSweep(staging);
    FBPRecordSweep();

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [NSFileManager.defaultManager removeItemAtPath:staging error:NULL];
        FBPDiag(@"cache", @"launch sweep complete");
    });

    FBPClearWebsiteData(nil);
}

+ (NSString *)formattedByteSize:(unsigned long long)bytes {
    return [NSByteCountFormatter stringFromByteCount:(long long)bytes
                                          countStyle:NSByteCountFormatterCountStyleFile];
}

@end
