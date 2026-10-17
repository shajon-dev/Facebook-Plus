// Link bridge: open inbound Facebook links at their exact destination instead of
// landing on Home.
//
// On a sideloaded / re-signed build, the "Open in Facebook" Safari extension can
// only hand the app a URL through its registered fb:// scheme. Facebook's own
// generic entry point for that (fb://facewebmodal/f?href=…) does not reliably
// resolve a Reel/post/photo/story on these builds and falls back to the News
// Feed. So the extension instead sends the clean HTTPS URL through our own
// bridge route:
//
//     fb://fbplusbridge?url=<https facebook url>
//
// This hook catches that one route, rebuilds the HTTPS URL, and feeds it to the
// app's browsing-web NSUserActivity handler — the same path a real Universal
// Link takes — so Facebook resolves it to the intended screen. Every other URL
// is passed straight through to the app's original handler untouched.
//
// Installed from FBPEntry's repeated image-load pass: FBBaseAppDelegate may not
// exist yet when the tweak first loads, so the installer simply no-ops until the
// class is present and then latches with FBP_ONCE.

#import "FBPlus.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

/// Our own bridge route. Reached as fb://fbplusbridge?url=… — the fb scheme is
/// already registered by the app, so no extra Info.plist entry is needed; we
/// only own the "fbplusbridge" host.
static NSString *const kFBPBridgeScheme = @"fb";
static NSString *const kFBPBridgeHost   = @"fbplusbridge";

/// Pull the target HTTPS URL out of an incoming bridge route, or return nil if
/// this is not our route (so the caller passes it through untouched).
static NSURL *FBPBridgeTargetURL(NSURL *incomingURL) {
    if (![incomingURL isKindOfClass:NSURL.class]) return nil;

    NSString *scheme = incomingURL.scheme.lowercaseString ?: @"";
    NSString *host = incomingURL.host.lowercaseString ?: @"";
    if (![scheme isEqualToString:kFBPBridgeScheme] || ![host isEqualToString:kFBPBridgeHost]) {
        return nil;
    }

    NSURLComponents *components = [NSURLComponents componentsWithURL:incomingURL
                                            resolvingAgainstBaseURL:NO];
    NSString *targetString = nil;
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"url"]) {
            targetString = item.value;
            break;
        }
    }
    if (!targetString.length) return nil;

    NSURL *targetURL = [NSURL URLWithString:targetString];
    NSString *targetScheme = targetURL.scheme.lowercaseString ?: @"";
    if (![targetScheme isEqualToString:@"http"] && ![targetScheme isEqualToString:@"https"]) {
        return nil;
    }

    // Canonicalize Facebook's mobile/web host variants before invoking the
    // Universal Link handler. Keep path/query/fragment so Reels, posts,
    // story.php, permalink.php, groups, watch/share URLs keep their identity.
    NSURLComponents *targetComponents = [NSURLComponents componentsWithURL:targetURL
                                                  resolvingAgainstBaseURL:NO];
    NSString *targetHost = targetComponents.host.lowercaseString ?: @"";
    BOOL facebookHost = [targetHost isEqualToString:@"facebook.com"] ||
                        [targetHost hasSuffix:@".facebook.com"];
    if (facebookHost) {
        targetComponents.scheme = @"https";
        targetComponents.host = @"www.facebook.com";
        NSURL *canonicalURL = targetComponents.URL;
        if (canonicalURL) targetURL = canonicalURL;
    }

    return targetURL;
}

%group FBPLinkBridge

%hook FBBaseAppDelegate

- (BOOL)application:(UIApplication *)application
            openURL:(NSURL *)url
            options:(NSDictionary *)options {
    NSURL *targetURL = FBPBridgeTargetURL(url);
    if (!targetURL) return %orig;

    // `self` is typed as the forward-declared FBBaseAppDelegate here, so route
    // the dynamic calls through an untyped id.
    id delegate = self;
    SEL universalLinkSelector =
        NSSelectorFromString(@"application:continueUserActivity:restorationHandler:");
    if (![delegate respondsToSelector:universalLinkSelector]) return %orig;

    NSUserActivity *activity =
        [[NSUserActivity alloc] initWithActivityType:NSUserActivityTypeBrowsingWeb];
    activity.webpageURL = targetURL;

    void (^restorationHandler)(NSArray *) = ^(NSArray *restorableObjects) {
        (void)restorableObjects;
    };

    BOOL (*sendUniversalLink)(id, SEL, UIApplication *, NSUserActivity *, void (^)(NSArray *)) =
        (BOOL (*)(id, SEL, UIApplication *, NSUserActivity *, void (^)(NSArray *)))objc_msgSend;

    return sendUniversalLink(delegate, universalLinkSelector, application, activity,
                             restorationHandler);
}

%end

%end // FBPLinkBridge

void FBPInitLinkBridge(void) {
    if (objc_getClass("FBBaseAppDelegate")) {
        FBP_ONCE(gLinkBridge) { %init(FBPLinkBridge); }
    }
}
