// Clears the caches Facebook accumulates on disk, and nothing else.
//
// What it clears:
//  - Library/Caches in full: the CDN image stores (MosaicIGImageDiskCache and
//    friends), media segment caches, the DNS/TLS/QUIC stores, WebKit's network
//    cache
//  - the News Feed cache and the prefetched model stores, which Facebook keeps
//    under Application Support rather than Caches
//  - CASK stores that sit inside a caches directory
//  - local analytics and logging stores (FFLogger, time in app, proxy video
//    usage, TerminationReporter)
//  - temporary scratch nothing has touched for an hour
//  - the shared App-Group container's own caches directory
//  - the URL cache, and WebKit's non-credential website data
//
// What it must never touch, and is written to protect:
//  - the keychain
//  - Library/Cookies and Library/HTTPStorages, which hold the account's cookies
//    and URL-session state on iOS 13 and later
//  - WebKit's cookies, local storage and session storage, where an in-app web
//    login keeps its token
//  - preferences, in both the system spelling and Facebook's own
//    (metaUserDefaults, com.facebook.Facebook.preferences)
//  - FBAPISessionLoggedInUserIDCache
//  - the App-Group containers, which are the session the app and the
//    notification extension share
//  - this tweak's own state and its log mirror
//
// Two things that look like caches and are not, both confirmed against a device
// container rather than assumed — see the long note at the top of the
// implementation: a CASK store outside a caches directory (scoped by the
// logged-in account id, durable), and the temporary directory (shared scratch,
// including this tweak's in-flight downloads).
//
// It also no longer posts UIApplicationDidReceiveMemoryWarningNotification to
// evict in-memory caches. That is a system notification, and faking it tells
// every component in the app — and UIKit — that the device is under memory
// pressure; the automatic sweep did it during launch. Freeing memory is not
// worth asking live code to tear itself down.

#import "FBPlus.h"

NS_ASSUME_NONNULL_BEGIN

@interface FBPCacheCleaner : NSObject

/// Clears the caches above, then calls the completion handler on the main queue
/// with the bytes freed. The handler runs after WebKit has finished too, so the
/// figure it reports is the whole of what was freed.
+ (void)clearAllCachesWithCompletion:(nullable void (^)(unsigned long long bytesFreed))completion;

/// A byte count as a localized string, e.g. "124.5 MB".
+ (NSString *)formattedByteSize:(unsigned long long)bytes;

@end

NS_ASSUME_NONNULL_END
