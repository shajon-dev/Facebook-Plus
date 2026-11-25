// Clears Facebook's on-disk caches and nothing else. The protected-names table
// in the implementation is the authoritative list of what must survive a sweep.

#import "FBPlus.h"

NS_ASSUME_NONNULL_BEGIN

@interface FBPCacheCleaner : NSObject

/// Settings' sweep: deletes in place, then reports bytes freed on the main
/// queue once WebKit has finished too.
+ (void)clearAllCachesWithCompletion:(nullable void (^)(unsigned long long bytesFreed))completion;

/// The automatic sweep: synchronous, before Facebook's launch work, and only
/// when the user's schedule is due. Renames each item into a staging directory
/// and unlinks that on a background queue afterwards, so Facebook starts
/// against an already-empty cache; deleting in place pulls files out from under
/// stores the app has opened.
+ (void)clearCachesAtLaunchIfDue;

/// A byte count as a localized string, e.g. "124.5 MB".
+ (NSString *)formattedByteSize:(unsigned long long)bytes;

@end

NS_ASSUME_NONNULL_END
