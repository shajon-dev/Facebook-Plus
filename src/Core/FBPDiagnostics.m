// Diagnostics log implementation: buffered lines, view-tree capture, hook-group
// tracking, and export to a text file under Caches.

#import "FBPDiagnostics.h"

#import <objc/runtime.h>
#import <sys/utsname.h>

#import "FBPHeaders.h"

#ifndef FBP_VERSION
#define FBP_VERSION @"0.0.0"
#endif

/// Generous, because the point is to capture a whole session, but bounded so a
/// runaway call site cannot exhaust memory.
static const NSUInteger kMaxLines = 4000;
/// A view tree deeper than this is noise; Facebook's are typically under 20.
static const NSInteger kMaxDepth = 28;
static const NSInteger kMaxNodes = 900;

/// Classes worth reporting on: a missing one explains a missing feature. Grouped
/// by the feature that depends on it, so the report reads as a feature checklist.
static NSArray<NSString *> *FBPWatchedClasses(void) {
    return @[
        // Feed cleanup
        @"FBMemModelObject",
        @"FBMemGroupsYouShouldJoinFeedUnit",
        @"FBMemPagesYouMayLikeFeedUnit",
        // Stories
        @"FBSnacksBucketViewController",
        @"FBSnacksThreadSwitcherViewController",
        @"FBSnacksSettingsBottomSheetActionHandlerV2",
        @"FBSnacksTrayTileMenuConfiguration",
        @"FDSControl_SwiftBridge",
        // Reels
        @"FBShortsSideBarView",
        @"CKSurfaceViewControllerImpl",
        @"CKSurfaceRootView",
        // Like confirmation
        @"CKComponentActionControlForwarder",
        // Chrome and settings entry
        @"FBTabBarAndContentViewController",
        // OLED surfaces
        @"FBTabBar",
        @"FBNewsFeedView",
    ];
}

@implementation FBPDiagnostics {
    NSMutableDictionary<NSString *, NSDictionary *> *_groups;
    NSMutableArray<NSString *> *_lines;
    NSMutableSet<NSString *> *_dumped;
    NSDate *_start;
    dispatch_queue_t _queue;
}

+ (FBPDiagnostics *)shared {
    static FBPDiagnostics *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [[self alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _groups = [NSMutableDictionary dictionary];
        _lines = [NSMutableArray array];
        _dumped = [NSMutableSet set];
        _start = [NSDate date];
        _queue = dispatch_queue_create("com.shajon.fbplus.log", DISPATCH_QUEUE_SERIAL);
        [self logHeader];
    }
    return self;
}

- (void)logHeader {
    struct utsname system;
    uname(&system);
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    [self log:@"boot" format:@"Facebook Plus %@ in Facebook %@ (%@)",
        FBP_VERSION,
        info[@"CFBundleShortVersionString"] ?: @"?",
        info[@"CFBundleVersion"] ?: @"?"];
    [self log:@"boot" format:@"%s, iOS %@",
        system.machine, UIDevice.currentDevice.systemVersion];
}

- (NSString *)stamp {
    return [NSString stringWithFormat:@"%7.2fs",
            [[NSDate date] timeIntervalSinceDate:_start]];
}

#pragma mark - Recording

- (void)appendLine:(NSString *)line {
    dispatch_async(_queue, ^{
        [self->_lines addObject:line];
        if (self->_lines.count > kMaxLines) {
            [self->_lines removeObjectsInRange:NSMakeRange(0, 200)];
            [self->_lines insertObject:@"… earlier lines dropped …" atIndex:0];
        }
    });
}

- (void)log:(NSString *)category format:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *text = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    [self appendLine:[NSString stringWithFormat:@"%@  [%@] %@",
                      [self stamp], category, text]];
    FBPLog(@"[%@] %@", category, text);
}

- (void)recordEvent:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *text = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    [self log:@"event" format:@"%@", text];
}

- (void)recordGroup:(NSString *)group installed:(BOOL)installed detail:(NSString *)detail {
    @synchronized (self) {
        // First success wins: a group installs once, and later passes over the
        // same installer would otherwise overwrite the interesting outcome.
        if (_groups[group] && [_groups[group][@"installed"] boolValue]) return;
        _groups[group] = @{
            @"installed" : @(installed),
            @"detail" : detail ?: (installed ? @"" : @"class not loaded"),
            @"at" : [self stamp],
        };
    }
    [self log:@"hook" format:@"%@ %@%@", installed ? @"installed" : @"skipped",
        group, detail.length ? [@" — " stringByAppendingString:detail] : @""];
}

#pragma mark - View trees

- (void)dumpView:(UIView *)view depth:(NSInteger)depth counter:(NSInteger *)counter {
    if (!view || depth > kMaxDepth || *counter > kMaxNodes) return;
    *counter += 1;

    NSMutableString *line = [NSMutableString string];
    for (NSInteger i = 0; i < depth; i++) [line appendString:@"  "];

    CGRect frame = view.frame;
    [line appendFormat:@"%@ (%.0f,%.0f %.0fx%.0f)",
        NSStringFromClass(view.class),
        frame.origin.x, frame.origin.y, frame.size.width, frame.size.height];

    if (view.isHidden) [line appendString:@" HIDDEN"];
    if (view.alpha < 0.99) [line appendFormat:@" alpha=%.2f", view.alpha];
    if (view.clipsToBounds) [line appendString:@" clips"];
    if (view.tag != 0) [line appendFormat:@" tag=%ld", (long)view.tag];
    if (view.accessibilityIdentifier.length) {
        [line appendFormat:@" id=%@", view.accessibilityIdentifier];
    }

    [self appendLine:line];

    for (UIView *subview in view.subviews) {
        [self dumpView:subview depth:depth + 1 counter:counter];
    }
}

- (void)dumpViewTree:(UIView *)view label:(NSString *)label {
    if (!view) {
        [self log:@"tree" format:@"%@: nil view", label];
        return;
    }
    UIViewController *owner = view._viewControllerForAncestor;
    [self log:@"tree" format:@"--- %@ (owner %@) ---",
        label, owner ? NSStringFromClass(owner.class) : @"none"];
    NSInteger counter = 0;
    [self dumpView:view depth:1 counter:&counter];
    [self log:@"tree" format:@"--- end %@ (%ld nodes) ---", label, (long)counter];
}

- (void)dumpViewTreeOnce:(UIView *)view label:(NSString *)label {
    @synchronized (self) {
        if ([_dumped containsObject:label]) return;
        [_dumped addObject:label];
    }
    [self dumpViewTree:view label:label];
}

- (void)captureCurrentScreen {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) { window = candidate; break; }
        }
        if (window) break;
    }
    if (!window) {
        [self log:@"tree" format:@"manual capture: no key window"];
        return;
    }

    UIViewController *top = window.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    [self log:@"tree" format:@"manual capture, top controller %@",
        NSStringFromClass(top.class)];
    // Deliberately not "once" — the user asks for this explicitly, and asking
    // twice on two different screens has to produce two dumps.
    [self dumpViewTree:window label:@"key window"];
}

#pragma mark - Reading

- (BOOL)checkClass:(NSString *)name {
    return objc_getClass(name.UTF8String) != nil;
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)groupReport {
    NSMutableArray *rows = [NSMutableArray array];

    @synchronized (self) {
        for (NSString *group in [_groups.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            NSDictionary *entry = _groups[group];
            BOOL installed = [entry[@"installed"] boolValue];
            NSString *detail = entry[@"detail"];
            [rows addObject:@{
                @"title" : [NSString stringWithFormat:@"%@ %@",
                            installed ? @"✅" : @"❌", group],
                @"detail" : detail.length ? detail
                                          : [NSString stringWithFormat:@"installed at %@",
                                             entry[@"at"]],
            }];
        }
    }

    // Evaluated live rather than remembered: a framework missing at launch may
    // well be loaded by now, and that difference is often the whole diagnosis.
    for (NSString *name in FBPWatchedClasses()) {
        BOOL present = [self checkClass:name];
        [rows addObject:@{
            @"title" : [NSString stringWithFormat:@"%@ %@", present ? @"·" : @"✖", name],
            @"detail" : present ? @"class loaded" : @"class NOT loaded",
        }];
    }

    return rows;
}

- (NSArray<NSString *> *)eventLog {
    __block NSArray *lines;
    dispatch_sync(_queue, ^{ lines = [self->_lines copy]; });
    return lines;
}

- (NSString *)report {
    NSMutableString *text = [NSMutableString string];
    [text appendString:@"================ Facebook Plus diagnostics ================\n\n"];

    [text appendString:@"HOOKS AND CLASSES\n"];
    for (NSDictionary *row in self.groupReport) {
        [text appendFormat:@"  %-52@ %@\n", row[@"title"], row[@"detail"]];
    }

    [text appendString:@"\nLOG\n"];
    for (NSString *line in self.eventLog) {
        [text appendFormat:@"%@\n", line];
    }
    [text appendString:@"\n================ end ================\n"];
    return text;
}

- (NSURL *)exportToFile {
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory
                                                         inDomains:NSUserDomainMask].firstObject;
    if (!caches) return nil;

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *name = [NSString stringWithFormat:@"FacebookPlus-log-%@.txt",
                      [formatter stringFromDate:[NSDate date]]];
    NSURL *url = [caches URLByAppendingPathComponent:name];

    NSError *error = nil;
    if (![self.report writeToURL:url
                      atomically:YES
                        encoding:NSUTF8StringEncoding
                           error:&error]) {
        FBPLog(@"could not write log: %@", error);
        return nil;
    }
    return url;
}

- (void)clear {
    @synchronized (self) {
        [_dumped removeAllObjects];
    }
    dispatch_async(_queue, ^{ [self->_lines removeAllObjects]; });
    [self logHeader];
}

@end
