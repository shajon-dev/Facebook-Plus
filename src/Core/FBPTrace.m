#import "FBPTrace.h"

#import <fcntl.h>
#import <os/lock.h>
#import <stdlib.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <time.h>
#import <unistd.h>

// The tweak version is injected at build time (-DFBP_VERSION in the Makefile),
// so it is never hardcoded here.
#ifndef FBP_VERSION
#define FBP_VERSION @"0.0.0"
#endif

#pragma mark - Line format

//     [HH:mm | dd/MM/yy] [+] [tag] message
//
// localtime_r and snprintf rather than NSDateFormatter: this runs on layout and
// download paths where a formatter's locale work would show up.
static NSString *FBPLogStamp(void) {
    time_t now = time(NULL);
    struct tm parts;
    localtime_r(&now, &parts);

    char stamp[32];
    snprintf(stamp, sizeof(stamp), "%02d:%02d | %02d/%02d/%02d",
             parts.tm_hour, parts.tm_min,
             parts.tm_mday, parts.tm_mon + 1, (parts.tm_year + 1900) % 100);
    return @(stamp);
}

// The one place the line format lives. The tag bracket is dropped when tag is
// nil, so a raw line reads as plain text.
static NSString *FBPLogFormatLine(BOOL ok, NSString *_Nullable tag, NSString *message) {
    if (tag.length) {
        return [NSString stringWithFormat:@"[%@] [%@] [%@] %@",
                                          FBPLogStamp(), ok ? @"+" : @"-", tag, message];
    }
    return [NSString stringWithFormat:@"[%@] [%@] %@",
                                      FBPLogStamp(), ok ? @"+" : @"-", message];
}

#pragma mark - The log handle

os_log_t FBPTraceLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.shajon.fbplus", "tweak");
    });
    return log;
}

#pragma mark - The file mirror

// Reading os_log back off an iPhone needs usbmux, which a network-only setup
// does not have; a root shell can `cat` this file instead. Under the app's
// Caches directory, truncated once at first use this launch, so it never needs
// rotation. All file I/O is wrapped so a failure stays silent and the
// in-memory record keeps working.
static int gFBPTraceFD = -1;
static os_unfair_lock gFBPTraceFileLock = OS_UNFAIR_LOCK_INIT;

static NSString *FBPTracePath(void) {
    NSString *caches = NSSearchPathForDirectoriesInDomains(
        NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (!caches.length) return nil;
    return [caches stringByAppendingPathComponent:@"facebook-plus-trace.log"];
}

static void FBPTraceOpenFile(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = FBPTracePath();
        if (!path.length) return;
        // O_TRUNC: each launch starts a fresh file, so no rotation is needed.
        int fd = open(path.fileSystemRepresentation,
                      O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) gFBPTraceFD = fd;
    });
}

// Writes one already-formatted line to the file mirror.
static void FBPLogMirrorToFile(NSString *line) {
    FBPTraceOpenFile();
    if (gFBPTraceFD < 0) return;

    NSString *withNewline = [line stringByAppendingString:@"\n"];
    const char *bytes = withNewline.UTF8String;
    if (!bytes) return;
    size_t remaining = strlen(bytes);

    os_unfair_lock_lock(&gFBPTraceFileLock);
    while (remaining > 0) {
        ssize_t written = write(gFBPTraceFD, bytes, remaining);
        if (written <= 0) break;   // A failed mirror must not stall a hook.
        bytes += written;
        remaining -= (size_t)written;
    }
    os_unfair_lock_unlock(&gFBPTraceFileLock);
}

#pragma mark - The record

// Held in memory rather than read back from the mirror, which depends on a
// writable path not every install has. Capped, oldest line first out, so a long
// session cannot grow without bound.
static const NSUInteger kFBPLogCapacity = 2000;

static NSMutableArray<NSString *> *FBPLogLines(void) {
    static NSMutableArray<NSString *> *lines;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lines = [NSMutableArray arrayWithCapacity:kFBPLogCapacity]; });
    return lines;
}

static os_unfair_lock gFBPLogLock = OS_UNFAIR_LOCK_INIT;

void FBPLogRecord(BOOL ok, NSString *_Nullable tag, NSString *message) {
    if (!message.length) return;

    NSString *line = FBPLogFormatLine(ok, tag, message);

    os_unfair_lock_lock(&gFBPLogLock);
    NSMutableArray<NSString *> *lines = FBPLogLines();
    [lines addObject:line];
    if (lines.count > kFBPLogCapacity) {
        [lines removeObjectsInRange:NSMakeRange(0, lines.count - kFBPLogCapacity)];
    }
    os_unfair_lock_unlock(&gFBPLogLock);

    os_log(FBPTraceLog(), "%{public}s", line.UTF8String);
    FBPLogMirrorToFile(line);
}

void FBPTraceEmit(NSString *line) {
    if (!line.length) return;
    FBPLogRecord(YES, nil, line);
}

NSUInteger FBPLogLineCount(void) {
    os_unfair_lock_lock(&gFBPLogLock);
    NSUInteger count = FBPLogLines().count;
    os_unfair_lock_unlock(&gFBPLogLock);
    return count;
}

void FBPLogClear(void) {
    os_unfair_lock_lock(&gFBPLogLock);
    [FBPLogLines() removeAllObjects];
    os_unfair_lock_unlock(&gFBPLogLock);
}

#pragma mark - Feature diagnostics

void FBPDiag(NSString *feature, NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    FBPLogRecord(YES, feature, msg);
}

void FBPDiagFail(NSString *feature, NSString *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    FBPLogRecord(NO, feature, msg);
}

#pragma mark - Fire accounting

void FBPTraceDidFire(const char *name) {
    if (!name) return;
    FBPLogRecord(YES, @"fire", @(name));
}

#pragma mark - Device information

// The hardware identifier, e.g. "iPhone17,2". On the Simulator sysctl reports
// the host architecture, so the identifier comes from the environment there.
static NSString *FBPDeviceIdentifier(void) {
    NSString *simulated =
        NSProcessInfo.processInfo.environment[@"SIMULATOR_MODEL_IDENTIFIER"];
    if (simulated.length) return simulated;

    size_t size = 0;
    if (sysctlbyname("hw.machine", NULL, &size, NULL, 0) != 0 || size == 0) return nil;
    char *value = (char *)malloc(size);
    if (!value) return nil;
    NSString *result = nil;
    if (sysctlbyname("hw.machine", value, &size, NULL, 0) == 0) {
        result = [NSString stringWithUTF8String:value];
    }
    free(value);
    return result;
}

static NSString *gFBPDeviceName = nil;   // resolved from ipsw.me, or the disk cache
static os_unfair_lock gFBPDeviceNameLock = OS_UNFAIR_LOCK_INIT;

// The public ipsw.me device list; the entry whose "identifier" matches this
// hardware carries the marketing "name".
static NSString *const kFBPDeviceListURL = @"https://api.ipsw.me/v4/devices";

// On-disk cache, so the request happens once per device and an offline phone
// keeps the name it learned earlier.
static NSString *_Nullable FBPDeviceNameCachePath(void) {
    NSString *support = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    if (!support.length) return nil;
    NSString *dir = [support stringByAppendingPathComponent:@"FacebookPlus"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"device-name.txt"];
}

static void FBPSetResolvedDeviceName(NSString *name) {
    if (!name.length) return;
    os_unfair_lock_lock(&gFBPDeviceNameLock);
    gFBPDeviceName = [name copy];
    os_unfair_lock_unlock(&gFBPDeviceNameLock);
    NSString *path = FBPDeviceNameCachePath();
    if (path) [name writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// Resolves the marketing device name from the ipsw.me list by hardware
// identifier, so a model newer than this build still gets its real name and no
// device table need ship in the binary. Runs once; the disk cache short-circuits
// the request, and until it resolves (or if it fails, or offline) the built-in
// map and then the raw identifier stand in. Only the hardware identifier
// (e.g. iPhone15,3) leaves the device — never UIDevice.name, which usually holds
// the owner's own name.
void FBPResolveDeviceName(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *identifier = FBPDeviceIdentifier();
        if (!identifier.length) return;

        NSString *path = FBPDeviceNameCachePath();
        NSString *cached = path ? [[NSString stringWithContentsOfFile:path
                                                             encoding:NSUTF8StringEncoding
                                                                error:nil]
                                      stringByTrimmingCharactersInSet:
                                          NSCharacterSet.whitespaceAndNewlineCharacterSet]
                                : nil;
        if (cached.length) {
            os_unfair_lock_lock(&gFBPDeviceNameLock);
            gFBPDeviceName = cached;
            os_unfair_lock_unlock(&gFBPDeviceNameLock);
            return;
        }

        NSURLSessionConfiguration *cfg =
            NSURLSessionConfiguration.ephemeralSessionConfiguration;
        cfg.timeoutIntervalForRequest = 20;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
        [[session dataTaskWithURL:[NSURL URLWithString:kFBPDeviceListURL]
                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            (void)response;
            if (error || !data.length) {
                FBPDiagFail(@"trace", @"device list unreachable (%@) — naming the device by "
                                      @"its identifier",
                            error.localizedDescription ?: @"empty response");
                return;
            }
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![parsed isKindOfClass:NSArray.class]) {
                FBPDiagFail(@"trace", @"device list was not the expected array");
                return;
            }
            for (id entry in (NSArray *)parsed) {
                if (![entry isKindOfClass:NSDictionary.class]) continue;
                id entryId = entry[@"identifier"];
                if (![entryId isKindOfClass:NSString.class] ||
                    ![entryId isEqualToString:identifier]) continue;
                id name = entry[@"name"];
                if ([name isKindOfClass:NSString.class] && [name length]) {
                    FBPSetResolvedDeviceName(name);
                    FBPDiag(@"trace", @"device resolved %@ -> %@", identifier, name);
                }
                return;
            }
            FBPDiagFail(@"trace", @"device list has no entry for %@", identifier);
        }] resume];
    });
}

// The resolved ipsw.me name once known; until then (or offline) the raw
// hardware identifier, so it is never empty.
NSString *FBPDeviceDisplayName(void) {
    FBPResolveDeviceName();
    os_unfair_lock_lock(&gFBPDeviceNameLock);
    NSString *resolved = gFBPDeviceName;
    os_unfair_lock_unlock(&gFBPDeviceNameLock);
    if (resolved.length) return resolved;
    return FBPDeviceIdentifier() ?: @"Unknown device";
}

#pragma mark - Export

static NSString *FBPLogHeader(NSUInteger lineCount) {
    NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;

    NSArray<NSArray<NSString *> *> *rows = @[
        @[ @"exported",      FBPLogStamp() ],
        @[ @"tweak_version", FBP_VERSION ],
        @[ @"device_name",   FBPDeviceDisplayName() ],
        @[ @"ios_version",   [NSString stringWithFormat:@"%ld.%ld.%ld",
                              (long)os.majorVersion, (long)os.minorVersion, (long)os.patchVersion] ],
        @[ @"log_lines",     [NSString stringWithFormat:@"%lu", (unsigned long)lineCount] ],
    ];

    NSMutableString *text = [NSMutableString stringWithString:@"Facebook Plus log\n\n"];
    for (NSArray<NSString *> *row in rows) {
        [text appendFormat:@"%-14s ---->  %@\n", row[0].UTF8String, row[1]];
    }
    [text appendString:@"\n"];
    return text;
}

NSString *FBPLogExportText(void) {
    os_unfair_lock_lock(&gFBPLogLock);
    NSArray<NSString *> *snapshot = [FBPLogLines() copy];
    os_unfair_lock_unlock(&gFBPLogLock);

    NSMutableString *text = [NSMutableString stringWithString:FBPLogHeader(snapshot.count)];
    for (NSString *line in snapshot) {
        [text appendString:line];
        [text appendString:@"\n"];
    }
    return text;
}

NSURL *_Nullable FBPLogWriteExportFile(void) {
    time_t now = time(NULL);
    struct tm parts;
    localtime_r(&now, &parts);

    // Same stamp as a log line, with '-' where a line uses ':' and '/': a colon
    // is legal on device but renders badly in the share sheet and in receiving
    // apps.
    char stamp[32];
    snprintf(stamp, sizeof(stamp), "%02d-%02d_%02d-%02d-%02d",
             parts.tm_hour, parts.tm_min,
             parts.tm_mday, parts.tm_mon + 1, (parts.tm_year + 1900) % 100);

    NSString *name = [NSString stringWithFormat:@"Facebook-Plus-%s.txt", stamp];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];

    NSError *error = nil;
    BOOL ok = [FBPLogExportText() writeToFile:path atomically:YES
                                     encoding:NSUTF8StringEncoding error:&error];
    if (!ok) {
        os_log(FBPTraceLog(), "log export failed %{public}s",
               error.localizedDescription.UTF8String ?: "(unknown)");
        return nil;
    }
    return [NSURL fileURLWithPath:path];
}
