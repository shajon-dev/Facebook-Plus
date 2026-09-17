#import "FBPUpdateChecker.h"
#import "FBPUpdateController.h"
#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPResources.h"
#import "FBPSheet.h"
#import "FBPToast.h"

#ifndef FBP_VERSION
#define FBP_VERSION @"0.0.0"
#endif

static NSString *const kReleasesAPI =
    @"https://api.github.com/repos/SHAJON-404/Facebook-Plus/releases/latest";

/// Numeric dotted-version compare: 1 if a > b, -1 if a < b, 0 if equal. Any
/// leading non-digits (e.g. a "v" tag prefix) are ignored.
static NSInteger FBPVersionCompare(NSString *a, NSString *b) {
    NSCharacterSet *trim = [NSCharacterSet characterSetWithCharactersInString:@"vV \t"];
    a = [a stringByTrimmingCharactersInSet:trim];
    b = [b stringByTrimmingCharactersInSet:trim];
    NSArray<NSString *> *pa = [a componentsSeparatedByString:@"."];
    NSArray<NSString *> *pb = [b componentsSeparatedByString:@"."];
    NSUInteger count = MAX(pa.count, pb.count);
    for (NSUInteger i = 0; i < count; i++) {
        NSInteger va = i < pa.count ? pa[i].integerValue : 0;
        NSInteger vb = i < pb.count ? pb[i].integerValue : 0;
        if (va != vb) return va > vb ? 1 : -1;
    }
    return 0;
}

@implementation FBPUpdateChecker

+ (void)fetchLatest:(void (^)(NSString *version, NSString *changelog,
                              NSError *error))completion {
    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kReleasesAPI]];
    request.timeoutInterval = 15.0;
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Facebook-Plus" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task = [NSURLSession.sharedSession
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        void (^reply)(NSString *, NSString *, NSError *) =
            ^(NSString *v, NSString *c, NSError *e) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(v, c, e); });
            };

        if (error || ![data isKindOfClass:NSData.class]) {
            reply(nil, nil, error ?: [NSError errorWithDomain:@"FBPUpdate" code:1 userInfo:nil]);
            return;
        }
        NSDictionary *json =
            [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *tag = [json isKindOfClass:NSDictionary.class] ? json[@"tag_name"] : nil;
        if (![tag isKindOfClass:NSString.class] || tag.length == 0) {
            reply(nil, nil, [NSError errorWithDomain:@"FBPUpdate" code:2 userInfo:nil]);
            return;
        }
        NSString *body = [json[@"body"] isKindOfClass:NSString.class] ? json[@"body"] : @"";
        reply(tag, body, nil);
    }];
    [task resume];
}

+ (void)presentUpdateForVersion:(NSString *)version changelog:(NSString *)changelog {
    UIViewController *host = [FBPSheetPresenter topViewController];
    while (host.presentedViewController) host = host.presentedViewController;
    if (!host || [host isKindOfClass:FBPUpdateController.class]) return;

    FBPUpdateController *update =
        [[FBPUpdateController alloc] initWithVersion:version changelog:changelog];
    update.modalPresentationStyle = UIModalPresentationOverFullScreen;
    [host presentViewController:update animated:YES completion:nil];
}

+ (void)checkOnLaunch {
    if (!FBPEnabled(FBPKeyNotifyUpdates)) return;

    [self fetchLatest:^(NSString *version, NSString *changelog, NSError *error) {
        if (error || !version) return;
        if (FBPVersionCompare(version, FBP_VERSION) <= 0) return;

        // Only nag once per new version.
        NSString *last = [FBPPrefs.shared stringForKey:FBPKeyLastNotifiedVersion];
        if (last && FBPVersionCompare(version, last) <= 0) return;
        [FBPPrefs.shared setString:version forKey:FBPKeyLastNotifiedVersion];
        [FBPPrefs.shared commit];

        [self presentUpdateForVersion:version changelog:changelog];
    }];
}

+ (void)checkManuallyFromViewController:(UIViewController *)controller {
    [self fetchLatest:^(NSString *version, NSString *changelog, NSError *error) {
        if (error || !version) {
            [FBPToastManager.shared showMessage:FBPL(@"update.failed") success:NO];
            return;
        }
        if (FBPVersionCompare(version, FBP_VERSION) > 0) {
            [self presentUpdateForVersion:version changelog:changelog];
        } else {
            [FBPToastManager.shared showMessage:FBPL(@"update.uptodate") success:YES];
        }
    }];
}

@end
