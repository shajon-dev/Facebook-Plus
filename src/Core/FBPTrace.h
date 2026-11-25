// Tweak-wide logging: the shared os_log handle, the in-memory record, the
// mirrored trace file, and the exported log built from them.
//
// Trace entry points emit at os_log's default level, so they survive into a
// `log collect` archive; FBPLog (FBPlus.h) uses NSLog under DEBUG only.

#import <Foundation/Foundation.h>
#import <os/log.h>

NS_ASSUME_NONNULL_BEGIN

// Logos compiles every .xm as Objective-C++, so the .xm call sites would look
// for C++-mangled symbols while these definitions live in a plain .m.
#ifdef __cplusplus
extern "C" {
#endif

#pragma mark - The log handle

/// The tweak's `os_log_t` — subsystem `com.shajon.fbplus`, category `tweak`.
/// Never nil; os_log falls back to `OS_LOG_DEFAULT`.
os_log_t FBPTraceLog(void);

#pragma mark - The record

/// The one funnel: formats the line, appends it to the in-memory record,
/// mirrors it to the trace file, and emits one default-level os_log line.
///
/// Line format:
///
///     [HH:mm | dd/MM/yy] [+] [tag] message
///
/// `[-]` replaces `[+]` when ok is NO, and the `[tag]` bracket is omitted when
/// tag is nil.
void FBPLogRecord(BOOL ok, NSString *_Nullable tag, NSString *message);

/// Records a raw line as-is (ok = YES, tag = nil).
void FBPTraceEmit(NSString *line);

/// How many lines the in-memory record currently holds.
NSUInteger FBPLogLineCount(void);

/// The file the mirror is writing to right now, or `(none)`.
NSString *FBPTraceFilePath(void);

/// YES once the mirror resolved the **shared** App-Group container, which is
/// what lets the notification extension's lines reach the app's log. NO means
/// this process is writing to its own private Caches directory and the two
/// processes' logs will not meet.
BOOL FBPTraceFileIsShared(void);

/// Empties the in-memory record and truncates the file mirror.
void FBPLogClear(void);

/// Clears the log once every twelve hours, on the first call after the window
/// turns over (00:00 and 12:00 UTC). Call at launch.
///
/// The record also starts again on its own the moment it reaches 10,000 lines,
/// so neither a long session nor a call site gone wrong can leave an export
/// holding nothing but the flood that filled it.
void FBPLogClearIfDue(void);

#pragma mark - Feature diagnostics

/// Emits one default-level diagnostic line tagged with feature (ok = YES).
/// Intended at each decision point on a feature path. Developer-facing, so
/// never localized.
void FBPDiag(NSString *feature, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);

/// FBPDiag, but the line is marked `[-]` rather than `[+]`.
void FBPDiagFail(NSString *feature, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);

#pragma mark - Fire accounting

/// Records the first time a traced call site runs. Prefer FBPTraceFire.
void FBPTraceDidFire(const char *name);

#pragma mark - Export

/// The whole record as text, oldest line first, behind a header naming the
/// tweak version, the device, and the iOS version.
NSString *FBPLogExportText(void);

/// Writes FBPLogExportText to a temporary file named
/// `Facebook-Plus-HH-mm_dd-MM-yy.txt`, or nil if it could not be written.
NSURL *_Nullable FBPLogWriteExportFile(void);

#pragma mark - Device information

/// The name this device is sold under, e.g. "iPhone 16 Pro Max", resolved
/// entirely on device from the hardware identifier and falling back to that
/// identifier (e.g. "iPhone15,3") so it is never empty.
///
/// Preferred over UIDevice.name anywhere a device is named: `name` is what the
/// owner called the phone, usually their own name, and says nothing about the
/// hardware.
NSString *FBPDeviceDisplayName(void);

/// Primes the device-name lookup (computed once, then cached). Cheap and local
/// — no network, no threads.
void FBPResolveDeviceName(void);

#ifdef __cplusplus
}
#endif

/// One line the first time this call site is reached, and nothing after.
///
/// The latch is unsynchronized on purpose: two threads racing the first call
/// print the line twice, which is harmless, where a lock on a layout path is
/// not. Cost after the first call is one load and one branch.
#define FBPTraceFire(name)                                                     \
    do {                                                                       \
        static BOOL _fbp_fired = NO;                                           \
        if (!_fbp_fired) { _fbp_fired = YES; FBPTraceDidFire(name); }           \
    } while (0)

/// Like FBPTraceFire but prints every time, for a rarely taken path worth
/// counting. Takes a format so the line can carry what the call decided.
#define FBPTraceEvent(name, fmt, ...)                                          \
    FBPTraceEmit([NSString stringWithFormat:@"%s · %@", (name),                 \
                  [NSString stringWithFormat:(fmt), ##__VA_ARGS__]])

/// Unconditional one-liner, no name, for a decisive statement.
#define FBPTraceLine(fmt, ...)                                                 \
    FBPTraceEmit([NSString stringWithFormat:(fmt), ##__VA_ARGS__])

NS_ASSUME_NONNULL_END
