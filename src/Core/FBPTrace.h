// Trace entry points emit at os_log's default level, so they survive into a
// `log collect` archive; FBPLog (FBPlus.h) uses NSLog under DEBUG only.

#import <Foundation/Foundation.h>
#import <os/log.h>

NS_ASSUME_NONNULL_BEGIN

// C linkage: these live in a plain .m, every .xm call site in Objective-C++.
#ifdef __cplusplus
extern "C" {
#endif

#pragma mark - The log handle

os_log_t FBPTraceLog(void);

#pragma mark - The record

void FBPLogRecord(BOOL ok, NSString *_Nullable tag, NSString *message);

void FBPTraceEmit(NSString *line);

NSUInteger FBPLogLineCount(void);

NSString *FBPTraceFilePath(void);

/// YES once the mirror resolved the shared App-Group container, which is what
/// lets the notification extension's lines reach the app's log.
BOOL FBPTraceFileIsShared(void);

void FBPLogClear(void);

/// Clears once every twelve hours (00:00 and 12:00 UTC), and the record also
/// restarts on its own at 10,000 lines. Call at launch.
void FBPLogClearIfDue(void);

#pragma mark - Feature diagnostics

void FBPDiag(NSString *feature, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);

void FBPDiagFail(NSString *feature, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);

#pragma mark - Fire accounting

void FBPTraceDidFire(const char *name);

#pragma mark - Export

NSString *FBPLogExportText(void);

NSURL *_Nullable FBPLogWriteExportFile(void);

#pragma mark - Device information

/// Preferred over UIDevice.name, which is what the owner called the phone.
NSString *FBPDeviceDisplayName(void);

void FBPResolveDeviceName(void);

#ifdef __cplusplus
}
#endif

/// One line the first time this call site is reached. The latch is
/// deliberately unsynchronized: a lock on a layout path is the worse risk.
#define FBPTraceFire(name)                                                     \
    do {                                                                       \
        static BOOL _fbp_fired = NO;                                           \
        if (!_fbp_fired) { _fbp_fired = YES; FBPTraceDidFire(name); }           \
    } while (0)

#define FBPTraceEvent(name, fmt, ...)                                          \
    FBPTraceEmit([NSString stringWithFormat:@"%s · %@", (name),                 \
                  [NSString stringWithFormat:(fmt), ##__VA_ARGS__]])

#define FBPTraceLine(fmt, ...)                                                 \
    FBPTraceEmit([NSString stringWithFormat:(fmt), ##__VA_ARGS__])

NS_ASSUME_NONNULL_END
