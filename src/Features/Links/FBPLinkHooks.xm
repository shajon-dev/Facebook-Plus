// External links: open them in the system default browser instead of Facebook's
// in-app browser (IAB). Facebook loads tapped links in FBWebViewController; when
// an off-Facebook http(s) link is loaded, hand it to the default browser via
// -[UIApplication openURL:] and dismiss the in-app browser. Links to
// Facebook-owned properties keep loading in-app as before.
//
// The load path varies by build/entry point, so several methods are hooked and a
// per-instance guard makes sure a URL is only handed off once:
//   * -_loadRequest:isInitial:  — the low-level load funnel (no visible flash)
//   * -loadInitialURL:config: / -loadInitialURL:  — the public initial loaders
//   * -viewDidAppear:           — guaranteed fallback, reads the current URL

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPDiagnostics.h"
#import "FBPHeaders.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static const void *kFBPLinkHandledKey = &kFBPLinkHandledKey;

/// Facebook-owned hosts that should stay in the in-app browser. Everything else
/// on http/https is treated as an external link.
static BOOL FBPHostIsFacebookOwned(NSString *host) {
    if (!host.length) return NO;
    host = host.lowercaseString;
    static NSArray<NSString *> *suffixes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        suffixes = @[
            @"facebook.com", @"fb.com", @"fb.watch", @"fbwat.ch", @"fb.me",
            @"fb.gg", @"m.me", @"messenger.com", @"fbcdn.net", @"fbsbx.com",
            @"facebook.net", @"meta.com", @"oculus.com",
        ];
    });
    for (NSString *suffix in suffixes) {
        if ([host isEqualToString:suffix] ||
            [host hasSuffix:[@"." stringByAppendingString:suffix]]) {
            return YES;
        }
    }
    return NO;
}

static BOOL FBPShouldOpenURLExternally(NSURL *url) {
    if (!url || !FBPEnabled(FBPKeyLinksInSafari)) return NO;
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return NO;
    return !FBPHostIsFacebookOwned(url.host);
}

/// The load entry points take either an NSURL or an NSURLRequest depending on the
/// call site, so resolve defensively.
static NSURL *FBPResolveURL(id arg) {
    if ([arg isKindOfClass:NSURL.class]) return arg;
    if ([arg isKindOfClass:NSURLRequest.class]) return [(NSURLRequest *)arg URL];
    if ([arg respondsToSelector:@selector(URL)]) return [arg URL];
    return nil;
}

/// Read the controller's current URL from whichever getter it exposes.
static NSURL *FBPControllerURL(id controller) {
    static NSArray<NSString *> *getters;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        getters = @[ @"currentRequestURL", @"requestURL",
                     @"initialNavigationURL", @"currentLocationURL" ];
    });
    for (NSString *name in getters) {
        SEL sel = NSSelectorFromString(name);
        if (![controller respondsToSelector:sel]) continue;
        NSURL *url = ((NSURL *(*)(id, SEL))objc_msgSend)(controller, sel);
        if ([url isKindOfClass:NSURL.class]) return url;
    }
    return nil;
}

static void FBPDismissInAppBrowser(UIViewController *webVC) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = webVC;
        while (top.parentViewController) top = top.parentViewController;
        if (top.presentingViewController) {
            [top.presentingViewController dismissViewControllerAnimated:YES completion:nil];
        } else {
            [top.navigationController popViewControllerAnimated:YES];
        }
    });
}

static BOOL FBPTryOpenExternally(UIViewController *webVC, NSURL *url) {
    if (!url || !FBPShouldOpenURLExternally(url)) return NO;
    if ([objc_getAssociatedObject(webVC, kFBPLinkHandledKey) boolValue]) return YES;
    objc_setAssociatedObject(webVC, kFBPLinkHandledKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    FBPDismissInAppBrowser(webVC);
    return YES;
}

%group FBPLinks

%hook FBWebViewController

- (void)_loadRequest:(id)request isInitial:(BOOL)isInitial {
    if (isInitial && FBPTryOpenExternally((UIViewController *)self, FBPResolveURL(request))) return;
    %orig;
}

- (void)loadInitialURL:(id)urlArg config:(id)config {
    if (FBPTryOpenExternally((UIViewController *)self, FBPResolveURL(urlArg))) return;
    %orig;
}

- (void)loadInitialURL:(id)urlArg {
    if (FBPTryOpenExternally((UIViewController *)self, FBPResolveURL(urlArg))) return;
    %orig;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if ([objc_getAssociatedObject(self, kFBPLinkHandledKey) boolValue]) return;
    FBPTryOpenExternally((UIViewController *)self, FBPControllerURL(self));
}

%end

%end // FBPLinks

void FBPInitLinkHooks(void) {
    if (objc_getClass("FBWebViewController")) {
        FBP_ONCE(gLinks) { %init(FBPLinks); }
        [FBPDiagnostics.shared recordGroup:@"FBPLinks" installed:YES detail:nil];
    }
}
