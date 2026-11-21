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

// Releases are published under the shajon-dev GitHub owner.
static NSString *const kGitHubOwner = @"shajon-dev";
static NSString *const kRepoName    = @"Facebook-Plus";

// This launch's resolved owner (mirrors FBPKeyResolvedGitHubOwner, which
// persists it across launches).
static NSString *sResolvedOwner;

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

#pragma mark - Owner resolution

+ (NSString *)activeGitHubOwner {
    return kGitHubOwner;
}

+ (void)setResolvedOwner:(NSString *)owner {
    sResolvedOwner = owner.length ? owner : kGitHubOwner;
    [FBPPrefs.shared setString:sResolvedOwner forKey:FBPKeyResolvedGitHubOwner];
    [FBPPrefs.shared commit];
}

+ (NSString *)githubProfileURL {
    return [NSString stringWithFormat:@"https://github.com/%@", [self activeGitHubOwner]];
}

+ (NSString *)githubRepoURL {
    return [NSString stringWithFormat:@"https://github.com/%@/%@", [self activeGitHubOwner], kRepoName];
}

+ (NSString *)githubReleasesURL {
    return [NSString stringWithFormat:@"https://github.com/%@/%@/releases/latest/",
            [self activeGitHubOwner], kRepoName];
}

+ (void)refreshGitHubOwner {
    [self setResolvedOwner:kGitHubOwner];
}

#pragma mark - Release fetch

/// Fetches one owner's latest release. Reports the HTTP status so the caller can
/// decide whether to fall back to the other owner. The completion is NOT
/// dispatched to the main thread (callers that touch UI do that themselves).
+ (void)fetchFromOwner:(NSString *)owner
            completion:(void (^)(NSInteger status, NSString *tag,
                                 NSString *body, NSError *error))completion {
    NSString *api = [NSString stringWithFormat:
                     @"https://api.github.com/repos/%@/%@/releases/latest", owner, kRepoName];
    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:[NSURL URLWithString:api]];
    request.timeoutInterval = 15.0;
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Facebook-Plus" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task = [NSURLSession.sharedSession
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
            ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSString *tag = nil;
        NSString *body = @"";
        if (!error && [data isKindOfClass:NSData.class]) {
            NSDictionary *json =
                [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:NSDictionary.class]) {
                if ([json[@"tag_name"] isKindOfClass:NSString.class]) tag = json[@"tag_name"];
                if ([json[@"body"] isKindOfClass:NSString.class]) body = json[@"body"];
            }
        }
        completion(status, tag, body, error);
    }];
    [task resume];
}

+ (void)fetchLatest:(void (^)(NSString *version, NSString *changelog,
                              NSError *error))completion {
    void (^reply)(NSString *, NSString *, NSError *) =
        ^(NSString *v, NSString *c, NSError *e) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(v, c, e); });
        };

    [self fetchFromOwner:kGitHubOwner
              completion:^(NSInteger status, NSString *tag, NSString *body, NSError *error) {
        if (status == 200 && tag.length) {
            [self setResolvedOwner:kGitHubOwner];
            reply(tag, body, nil);
        } else {
            reply(nil, nil, error ?: [NSError errorWithDomain:@"FBPUpdate" code:2 userInfo:nil]);
        }
    }];
}

#pragma mark - Presentation

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
    // Always resolve which owner is live, even when update prompts are off, so
    // Settings / Welcome / the download button link to a working account.
    if (!FBPEnabled(FBPKeyNotifyUpdates)) {
        [self refreshGitHubOwner];
        return;
    }

    // fetchLatest resolves the live owner as a side effect, so no separate probe.
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
            FBPDiagFail(@"update", @"manual check failed: %@",
                        error.localizedDescription ?: @"no version in response");
            [FBPToastManager.shared showMessage:FBPL(@"update.failed") success:NO];
            return;
        }
        FBPDiag(@"update", @"latest %@, current %@", version, FBP_VERSION);
        if (FBPVersionCompare(version, FBP_VERSION) > 0) {
            [self presentUpdateForVersion:version changelog:changelog];
        } else {
            [FBPToastManager.shared showMessage:FBPL(@"update.uptodate") success:YES];
        }
    }];
}

@end
