// Open inbound Facebook links at their exact destination instead of Home: on a
// re-signed build, a Facebook web link arriving from outside does not reliably
// resolve a Reel/post/photo/story.
//
// Three sources arrive in two shapes: the Safari extension's own route
// (fb://fbplusbridge?url=<https url>), a FaceWeb deep link carrying an embedded
// web URL (fb://faceweb…?href=…), and a plain Facebook universal link, possibly
// wrapped in LinkShim (l.facebook.com/l.php?u=…). All are normalized to a
// canonical https://www.facebook.com URL and fed to the app's browsing-web
// NSUserActivity handler, the same path a real Universal Link takes.
//
// Structured native deep links (fb://story?…, fb://group?id=…, notification
// routing) already resolve correctly and are passed straight through.

#import "FBPlus.h"
#import "FBPTrace.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

/// The fb scheme is already registered by the app, so only the host is claimed.
static NSString *const kFBPBridgeScheme = @"fb";
static NSString *const kFBPBridgeHost   = @"fbplusbridge";

static BOOL FBPIsFacebookHost(NSString *host) {
    if (!host.length) return NO;
    host = host.lowercaseString;
    return [host isEqualToString:@"facebook.com"] || [host hasSuffix:@".facebook.com"];
}

static NSString *FBPQueryValue(NSURL *url, NSArray<NSString *> *names) {
    NSURLComponents *components = [NSURLComponents componentsWithURL:url
                                            resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems) {
        for (NSString *name in names) {
            if ([item.name caseInsensitiveCompare:name] == NSOrderedSame) {
                return item.value;
            }
        }
    }
    return nil;
}

/// Unwrap LinkShim (/l.php?u=, /l/?u=, ?url=). Returns the input unchanged if
/// it is not one.
static NSURL *FBPUnwrapLinkShim(NSURL *url) {
    if (!FBPIsFacebookHost(url.host)) return url;
    NSString *path = url.path.lowercaseString ?: @"";
    if (![path isEqualToString:@"/l.php"] && ![path hasPrefix:@"/l/"]) return url;

    NSString *inner = FBPQueryValue(url, @[ @"u", @"url" ]);
    if (!inner.length) return url;
    NSURL *innerURL = [NSURL URLWithString:inner];
    return innerURL ?: url;
}

/// Canonicalize to https://www.facebook.com/…, keeping path, query and fragment
/// so the URL keeps its identity. nil for non-Facebook or non-http(s) input.
static NSURL *FBPCanonicalFacebookURL(NSURL *url) {
    if (![url isKindOfClass:NSURL.class]) return nil;

    url = FBPUnwrapLinkShim(url);
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return nil;

    if (!FBPIsFacebookHost(url.host)) return nil;

    NSURLComponents *components = [NSURLComponents componentsWithURL:url
                                            resolvingAgainstBaseURL:NO];
    components.scheme = @"https";
    components.host = @"www.facebook.com";
    return components.URL ?: url;
}

/// The web URL embedded in a FaceWeb-style fb:// link, or nil.
static NSURL *FBPHrefFromFaceWeb(NSURL *url) {
    if ([url.scheme.lowercaseString isEqualToString:@"fb"]) {
        NSString *host = url.host.lowercaseString ?: @"";
        if ([host isEqualToString:@"faceweb"] ||
            [host isEqualToString:@"facewebmodal"] ||
            [host isEqualToString:@"web"]) {
            NSString *embedded = FBPQueryValue(url, @[ @"href", @"url" ]);
            if (embedded.length) return [NSURL URLWithString:embedded];
        }
    }
    return nil;
}

/// The destination to route, or nil to leave the URL to the app's handler.
static NSURL *FBPBridgeTargetURL(NSURL *incomingURL) {
    if (![incomingURL isKindOfClass:NSURL.class]) return nil;

    NSString *scheme = incomingURL.scheme.lowercaseString ?: @"";
    NSString *host = incomingURL.host.lowercaseString ?: @"";

    if ([scheme isEqualToString:kFBPBridgeScheme] && [host isEqualToString:kFBPBridgeHost]) {
        NSString *target = FBPQueryValue(incomingURL, @[ @"url" ]);
        return target.length ? FBPCanonicalFacebookURL([NSURL URLWithString:target]) : nil;
    }

    NSURL *href = FBPHrefFromFaceWeb(incomingURL);
    if (href) return FBPCanonicalFacebookURL(href);

    if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) {
        return FBPCanonicalFacebookURL(incomingURL);
    }

    // Structured fb:// deep links and other schemes are left alone.
    return nil;
}

static BOOL FBPRouteThroughUniversalLink(id delegate, UIApplication *application, NSURL *targetURL) {
    SEL universalLinkSelector =
        NSSelectorFromString(@"application:continueUserActivity:restorationHandler:");
    if (![delegate respondsToSelector:universalLinkSelector]) return NO;

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

%group FBPLinkBridge

%hook FBBaseAppDelegate

- (BOOL)application:(UIApplication *)application
            openURL:(NSURL *)url
            options:(NSDictionary *)options {
    FBPTraceFire("linkbridge.FBBaseAppDelegate.openURL");
    NSURL *targetURL = FBPBridgeTargetURL(url);
    if (!targetURL) return %orig;

    // `self` is the forward-declared type here, so the dynamic call needs id.
    id delegate = self;
    if (FBPRouteThroughUniversalLink(delegate, application, targetURL)) return YES;
    return %orig;
}

- (BOOL)application:(UIApplication *)application
    continueUserActivity:(NSUserActivity *)userActivity
      restorationHandler:(id)restorationHandler {
    FBPTraceFire("linkbridge.FBBaseAppDelegate.continueUserActivity");
    // A real Universal Link: rewrite the host to the canonical www form before
    // the app routes it, or mobile/web host variants degrade to Home.
    if ([userActivity.activityType isEqualToString:NSUserActivityTypeBrowsingWeb]) {
        NSURL *canonical = FBPCanonicalFacebookURL(userActivity.webpageURL);
        if (canonical && ![canonical isEqual:userActivity.webpageURL]) {
            userActivity.webpageURL = canonical;
        }
    }
    return %orig;
}

%end

%end // FBPLinkBridge

void FBPInitLinkBridge(void) {
    if (objc_getClass("FBBaseAppDelegate")) {
        FBP_ONCE(gLinkBridge) { %init(FBPLinkBridge); }
    }
}
