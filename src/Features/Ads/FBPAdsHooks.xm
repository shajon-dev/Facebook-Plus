// Specialised ad blocking for surfaces that do not flow through the News Feed
// model path (FBPFeedHooks handles that one).
//
//  * Watch / video feed ads come from FBVideoFeedAdsPool, which hands the player
//    an array of ad items to interleave. Returning an empty array leaves the
//    organic videos untouched and inserts nothing.
//  * Story ("Snacks") ads are loaded by FBSnacksAdsPaginatingFetcher ahead of
//    time; no-oping its fetch entry points means an ad is never requested, so no
//    gap is left between stories.
//  * Marketplace is React Native / Relay: its ads never reach a native model, so
//    they are dropped at the GraphQL layer instead (see the Marketplace section).
//
// Each hook installs only when its target class and selector are present, so a
// build that renames one degrades just that surface. Everything here is gated on
// the single "Remove Ads" preference (FBPKeyNoAds) — there is no separate toggle.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPHeaders.h"
#import "FBPTrace.h"

#import <objc/runtime.h>

#pragma mark - Feed-model ad detection
//
// The News Feed ad units flow through the single FBMemModelObject filter in
// FBPFeedHooks. Rather than hook that model class a second time here — which
// would mean two installers racing on one method — the ad-specific test lives in
// this function and the feed filter calls it. So every ad rule stays in this
// file, and the model is still hooked exactly once.

/// YES when a feed-unit model is a paid/ad unit the user has chosen to block.
BOOL FBPModelIsBlockedAd(id model) {
    if (!model) return NO;

    // "SPONSORED" category token, and any unit carrying sponsoredData (a paid
    // unit even when its category token says otherwise).
    if (FBPEnabled(FBPKeyNoAds)) {
        if ([model respondsToSelector:@selector(category)]) {
            NSString *category = [model category];
            if ([category isKindOfClass:NSString.class] &&
                [category isEqualToString:@"SPONSORED"]) {
                return YES;
            }
        }
        if ([model respondsToSelector:@selector(sponsoredData)] &&
            [model sponsoredData] != nil) {
            return YES;
        }
    }

    return NO;
}

#pragma mark - Watch / video feed ads

%group FBPVideoAds

%hook FBVideoFeedAdsPool

- (NSArray *)insertedItems {
    FBPTraceFire("ads.FBVideoFeedAdsPool.insertedItems");
    if (FBPEnabled(FBPKeyNoAds)) return @[];
    return %orig;
}

%end

%end // FBPVideoAds

#pragma mark - Story ("Snacks") ads

%group FBPStoryAds

%hook FBSnacksAdsPaginatingFetcher

- (void)startFetch:(id)arg1 organicConsumption:(id)arg2 {
    FBPTraceFire("ads.FBSnacksAdsPaginatingFetcher.startFetch");
    if (FBPEnabled(FBPKeyNoAds)) return;
    %orig;
}

- (void)fetchAdsForStoryWithRequestPayload:(id)payload {
    FBPTraceFire("ads.FBSnacksAdsPaginatingFetcher.fetchAdsForStoryWithRequestPayload");
    if (FBPEnabled(FBPKeyNoAds)) return;
    %orig;
}

- (void)fetchAdsForStoryWithRequestPayloadAsync:(id)payload {
    FBPTraceFire("ads.FBSnacksAdsPaginatingFetcher.fetchAdsForStoryWithRequestPayloadAsync");
    if (FBPEnabled(FBPKeyNoAds)) return;
    %orig;
}

%end

%end // FBPStoryAds

#pragma mark - Marketplace ads (React Native / Relay)
//
// Marketplace is a React Native surface: Relay fetches its data with GraphQL over
// React Native's RCTNetworking, and every request carries an "X-FB-Friendly-Name"
// header (and/or an fb_api_req_friendly_name body param) naming the query.
// -[RCTNetworking handlerForRequest:] is hooked to do two things while Remove Ads
// is on:
//
//   1. Dedicated ad / sponsored-feed queries (MarketplaceHomeFeedAdsQueryRendererQuery,
//      MarketplacePDPPersonalizedAdsQuery, MarketplaceContextualSponsoredFeedSurfaceQuery,
//      …) are handed a handler that fails the request immediately, so their
//      QueryRenderers render nothing. Organic listings come from other queries.
//   2. Every other Marketplace query may blend ad / boosted-listing items into its
//      listing edges, so the real handler is wrapped, the response buffered, and any
//      item dropped whose __typename is an ad type (…AdStory, …AdsStory, Sponsored…)
//      or that carries a sponsored/boosted marker field. This is deliberately not
//      limited to "…Feed…" names: the home-pagination, search and category grids
//      (MarketplaceSearchAppQuery, MarketplaceCategoryViewRootQuery,
//      MarketplaceHomePaginationQuery, MarketplacePlainHomeAppQuery) carry blended
//      ads too and have no "Feed" in their name.
//
// The core GraphQL-layer logic is adapted from a third-party source; see
// THIRD_PARTY_NOTICES.md. Restyled here as a toggle-gated port in the tweak's own
// conventions.

// A dedicated ad surface to fail outright. Two families: "…Ads…Query" (Home/Local/
// PDP/InstantIntent/Themed/Pagination/BoostedListing…) and the pure
// "…SponsoredFeed…Query" surfaces, which carry only ads. "Ads" needs an uppercase
// letter or the end after it so Address/Adsomething never match; only queries are
// failed, never mutations.
static BOOL FBPMarketplaceIsAdQuery(NSString *name) {
    if (name.length == 0) return NO;

    static NSSet<NSString *> *names;
    static NSRegularExpression *adsRe;
    static NSRegularExpression *sponsoredRe;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = [NSSet setWithArray:@[
            @"MarketplaceHomeFeedAdsQueryRendererQuery",
            @"MarketplaceHomeFeedAdsPaginationQuery",
            @"MarketplaceHomeFeedBoostedListingAdsQuery",
            @"MarketplaceHomeFeedBoostedListingAdsPaginationQuery",
            @"MarketplaceContextualSponsoredFeedSurfaceQuery",
            @"MarketplacePersonalizedSponsoredFeedQuery",
        ]];
        adsRe = [NSRegularExpression
            regularExpressionWithPattern:@"^Marketplace\\w*Ads(?:[A-Z]\\w*)?Query$"
                                 options:0
                                   error:nil];
        sponsoredRe = [NSRegularExpression
            regularExpressionWithPattern:@"^Marketplace\\w*SponsoredFeed\\w*Query$"
                                 options:0
                                   error:nil];
    });

    if ([names containsObject:name]) return YES;
    NSRange full = NSMakeRange(0, name.length);
    return [adsRe firstMatchInString:name options:0 range:full] != nil ||
           [sponsoredRe firstMatchInString:name options:0 range:full] != nil;
}

// Any Marketplace query that was not failed may still blend ads into its response,
// so filter them all rather than only the "…Feed…" names. The strip no-ops when a
// response has no ads, so wrapping a listing/PDP/mutation query is harmless.
static BOOL FBPMarketplaceShouldFilterQuery(NSString *name) {
    return [name hasPrefix:@"Marketplace"];
}

// An ad __typename: MarketplaceAdStory, MarketplaceSearchAdStory, …AdsBlended…,
// SponsoredX. Requires an uppercase letter after "Ad"/"Ads" so Additional/Address
// never match.
static BOOL FBPMarketplaceIsAdTypename(NSString *typeName) {
    if (typeName.length == 0) return NO;
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"Ads?[A-Z]|Sponsored"
                                                      options:0
                                                        error:nil];
    });
    return [re firstMatchInString:typeName options:0 range:NSMakeRange(0, typeName.length)] != nil;
}

// The friendly name of a request: the header first, else the body's
// fb_api_req_friendly_name param.
static NSString *FBPMarketplaceFriendlyName(NSURLRequest *request) {
    NSString *name = [request valueForHTTPHeaderField:@"X-FB-Friendly-Name"];
    if (name.length) return name;

    NSData *body = request.HTTPBody;
    if (body.length == 0 || body.length > 512 * 1024) return nil;
    NSString *str = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    NSRange r = [str rangeOfString:@"fb_api_req_friendly_name="];
    if (r.location == NSNotFound) return nil;
    NSUInteger start = NSMaxRange(r);
    NSRange end = [str rangeOfString:@"&" options:0 range:NSMakeRange(start, str.length - start)];
    NSString *value = [str substringWithRange:
        NSMakeRange(start, (end.location == NSNotFound ? str.length : end.location) - start)];
    return value.stringByRemovingPercentEncoding ?: value;
}

// A boosted listing can reach the grid with an ordinary listing __typename and
// only a sponsored/boosted marker field. These keys are ad-only: a truthy value
// on an edge node means the item is paid. Organic listings leave them null/absent.
static BOOL FBPMarketplaceDictIsSponsored(NSDictionary *dict) {
    static NSArray<NSString *> *presenceKeys;  // present and non-null => ad
    static NSArray<NSString *> *boolKeys;      // == YES => ad
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        presenceKeys = @[@"sponsored_data", @"sponsoredData",
                         @"boosted_listing", @"boostedListingAdsData",
                         @"ad_id", @"ad_client_token"];
        boolKeys = @[@"is_sponsored", @"isSponsored"];
    });
    for (NSString *k in presenceKeys) {
        id v = dict[k];
        if (!v || v == (id)NSNull.null) continue;
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] == 0) continue;
        return YES;
    }
    for (NSString *k in boolKeys) {
        id v = dict[k];
        if ([v isKindOfClass:[NSNumber class]] && [v boolValue]) return YES;
    }
    return NO;
}

// An edge is an ad if it, its node, or the node's story is an ad __typename, or if
// any of those carries a sponsored/boosted marker field. Returns the matched token
// (a __typename or a marker label) as a truthy "drop this" signal, else nil.
static NSString *FBPMarketplaceAdTypenameOfItem(id item) {
    if (![item isKindOfClass:[NSDictionary class]]) return nil;
    NSMutableArray *candidates = [NSMutableArray arrayWithObject:item];
    for (NSString *key in @[@"node", @"story"]) {
        id v = item[key];
        if ([v isKindOfClass:[NSDictionary class]]) {
            [candidates addObject:v];
            id story = v[@"story"];
            if ([story isKindOfClass:[NSDictionary class]]) [candidates addObject:story];
        }
    }
    for (NSDictionary *c in candidates) {
        id t = c[@"__typename"];
        if ([t isKindOfClass:[NSString class]] && FBPMarketplaceIsAdTypename(t)) return t;
        if (FBPMarketplaceDictIsSponsored(c)) return @"<sponsored-marker>";
    }
    return nil;
}

// Recursively removes ad items from any array reached in the parsed response.
static NSUInteger FBPMarketplaceStripAds(id obj) {
    NSUInteger removed = 0;
    if ([obj isKindOfClass:[NSMutableArray class]]) {
        NSMutableArray *arr = obj;
        for (NSInteger i = (NSInteger)arr.count - 1; i >= 0; i--) {
            id item = arr[i];
            if (FBPMarketplaceAdTypenameOfItem(item)) {
                [arr removeObjectAtIndex:i];
                removed++;
            } else {
                removed += FBPMarketplaceStripAds(item);
            }
        }
    } else if ([obj isKindOfClass:[NSMutableDictionary class]]) {
        for (id value in [obj allValues]) removed += FBPMarketplaceStripAds(value);
    }
    return removed;
}

// Returns a filtered copy of the response, or the original if nothing changed or
// it is not JSON. Handles single JSON documents and newline-separated streamed
// payloads; anything unexpected (multipart, etc.) is left untouched.
static NSData *FBPMarketplaceFilterResponse(NSData *data, NSString *name) {
    if (data.length == 0) return data;
    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!body) return data;

    NSString *sep = [body containsString:@"\r\n"] ? @"\r\n" : @"\n";
    NSArray<NSString *> *parts = [body componentsSeparatedByString:sep];
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:parts.count];
    NSUInteger removed = 0;

    for (NSString *part in parts) {
        NSString *trimmed =
            [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (trimmed.length == 0) { [out addObject:part]; continue; }
        id json = [NSJSONSerialization
            JSONObjectWithData:[trimmed dataUsingEncoding:NSUTF8StringEncoding]
                       options:NSJSONReadingMutableContainers
                         error:nil];
        if (!json) return data; // not JSON (multipart / unexpected): leave untouched
        NSUInteger n = FBPMarketplaceStripAds(json);
        if (n == 0) { [out addObject:part]; continue; }
        NSData *re = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
        if (!re) return data;
        [out addObject:[[NSString alloc] initWithData:re encoding:NSUTF8StringEncoding]];
        removed += n;
    }

    if (removed == 0) return data;
    FBPLog(@"marketplace: stripped %lu ad item(s) from %@", (unsigned long)removed, name);
    return [[out componentsJoinedByString:sep] dataUsingEncoding:NSUTF8StringEncoding];
}

#pragma mark Marketplace — request handlers

// The subset of RCTURLRequestDelegate called on the task RCTNetworking passes to
// a handler. Declared locally so the calls are typed; resolved at runtime.
@protocol FBPMarketplaceRequestDelegate <NSObject>
- (void)URLRequest:(id)token didReceiveData:(NSData *)data;
- (void)URLRequest:(id)token didCompleteWithError:(NSError *)error;
@end

// Stands in for a real RCTURLRequestHandler and fails the ad query immediately, so
// its QueryRenderer renders nothing.
@interface FBPMarketplaceBlockingHandler : NSObject
+ (instancetype)shared;
@end

@implementation FBPMarketplaceBlockingHandler

+ (instancetype)shared {
    static FBPMarketplaceBlockingHandler *h;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ h = [self new]; });
    return h;
}

+ (NSString *)moduleName { return @"FBPMarketplaceBlockingHandler"; }
- (BOOL)canHandleRequest:(NSURLRequest *)request { return YES; }
- (float)handlerPriority { return 0; }

- (id)sendRequest:(NSURLRequest *)request withDelegate:(id<FBPMarketplaceRequestDelegate>)delegate {
    id token = [NSUUID UUID];
    NSError *error = [NSError errorWithDomain:NSURLErrorDomain
                                         code:NSURLErrorNotConnectedToInternet
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    @"Blocked by Facebook Plus"}];
    // Complete asynchronously so RCTNetworkTask has stored the token first.
    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate URLRequest:token didCompleteWithError:error];
    });
    return token;
}

- (void)cancelRequest:(id)requestToken {}

@end

// Stands in for RCTNetworkTask as the inner handler's delegate: buffers the body
// and hands the filtered result to the real delegate on completion. Everything
// else the handler calls is forwarded untouched.
@interface FBPMarketplaceFilteringDelegate : NSObject <FBPMarketplaceRequestDelegate>
@property (nonatomic, strong) id realDelegate;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSMutableData *buffer;
@end

// Keeps in-flight proxies alive in case the inner handler holds its delegate weakly.
static NSMutableSet *FBPMarketplaceLiveDelegates(void) {
    static NSMutableSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

@implementation FBPMarketplaceFilteringDelegate

- (BOOL)respondsToSelector:(SEL)sel {
    return [super respondsToSelector:sel] || [self.realDelegate respondsToSelector:sel];
}

- (id)forwardingTargetForSelector:(SEL)sel { return self.realDelegate; }

- (void)URLRequest:(id)token didReceiveData:(NSData *)data {
    @synchronized (self) { [self.buffer appendData:data]; }
}

- (void)URLRequest:(id)token didCompleteWithError:(NSError *)error {
    if (!error) {
        NSData *body;
        @synchronized (self) { body = [self.buffer copy]; }
        body = FBPMarketplaceFilterResponse(body, self.name);
        if (body.length) [self.realDelegate URLRequest:token didReceiveData:body];
    }
    [self.realDelegate URLRequest:token didCompleteWithError:error];
    @synchronized (FBPMarketplaceLiveDelegates()) {
        [FBPMarketplaceLiveDelegates() removeObject:self];
    }
}

@end

// Per-request wrapper around the handler RCTNetworking picked, so the response can
// be buffered and filtered before it reaches Relay.
@interface FBPMarketplaceFilteringHandler : NSObject
@property (nonatomic, strong) id inner;
@property (nonatomic, copy) NSString *name;
@end

@implementation FBPMarketplaceFilteringHandler

- (BOOL)respondsToSelector:(SEL)sel {
    return [super respondsToSelector:sel] || [self.inner respondsToSelector:sel];
}

- (id)forwardingTargetForSelector:(SEL)sel { return self.inner; }

- (id)sendRequest:(NSURLRequest *)request withDelegate:(id)delegate {
    FBPMarketplaceFilteringDelegate *proxy = [FBPMarketplaceFilteringDelegate new];
    proxy.realDelegate = delegate;
    proxy.name = self.name;
    proxy.buffer = [NSMutableData data];
    @synchronized (FBPMarketplaceLiveDelegates()) {
        [FBPMarketplaceLiveDelegates() addObject:proxy];
    }
    return [self.inner sendRequest:request withDelegate:proxy];
}

@end

#pragma mark Marketplace — hook

%group FBPMarketplaceAds

%hook RCTNetworking

- (id)handlerForRequest:(NSURLRequest *)request {
    FBPTraceFire("ads.RCTNetworking.handlerForRequest");
    // Zero overhead and full fidelity when Remove Ads is off.
    if (!FBPEnabled(FBPKeyNoAds)) return %orig;

    NSString *name = FBPMarketplaceFriendlyName(request);

    if (FBPMarketplaceIsAdQuery(name)) {
        FBPLog(@"marketplace: blocked %@", name);
        return [FBPMarketplaceBlockingHandler shared];
    }

    id handler = %orig;
    if (handler && FBPMarketplaceShouldFilterQuery(name)) {
        FBPMarketplaceFilteringHandler *wrapper = [FBPMarketplaceFilteringHandler new];
        wrapper.inner = handler;
        wrapper.name = name;
        return wrapper;
    }
    return handler;
}

%end

%end // FBPMarketplaceAds

#pragma mark - Init

void FBPInitAdsHooks(void) {
    Class videoPool = objc_getClass("FBVideoFeedAdsPool");
    if (videoPool && [videoPool instancesRespondToSelector:@selector(insertedItems)]) {
        FBP_ONCE(gVideoAds) { %init(FBPVideoAds); }
    } else {
        FBPLogOnce(@"FBVideoFeedAdsPool not found — video ad blocking disabled");
    }

    Class storyFetcher = objc_getClass("FBSnacksAdsPaginatingFetcher");
    if (storyFetcher) {
        FBP_ONCE(gStoryAds) { %init(FBPStoryAds); }
    } else {
        FBPLogOnce(@"FBSnacksAdsPaginatingFetcher not found — story ad blocking disabled");
    }

    // RCTNetworking lives in FBReactNativeProductsFramework, which Facebook dlopens
    // on demand — so this installer is re-run from the dyld image-load callback and
    // latches once the class finally arrives.
    Class networking = objc_getClass("RCTNetworking");
    if (networking && [networking instancesRespondToSelector:@selector(handlerForRequest:)]) {
        FBP_ONCE(gMarketplaceAds) { %init(FBPMarketplaceAds); }
    }
}
