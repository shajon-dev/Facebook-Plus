// Removes the affiliate / product-link banner that Facebook pins to the bottom
// of the comment sheet (https://github.com/shajon-dev/Facebook-Plus/issues/3).
//
// When a post's author attaches an affiliate / product link (e.g. a Shopee
// product), Facebook shows a floating CTA — product thumbnail, title, store
// name and an "X" — pinned above the comment composer. It sits in the comment
// stream's *sticky footer*, a region separate from the composer and the comment
// list, and it also appears in the comment sheet opened from Reels. The feed /
// Marketplace ad hooks never touch it: its class names
// (FBCommentStreamOrganicAffiliateFloatingCtaHandlerFragment,
// FBCommentsBFAffiliateLinkComponent) carry no "Ad"/"Sponsored" token, so
// "Remove Ads" leaves it on screen.
//
// FBCommentStreamRootComponentModel drives the sheet. It carries the sticky
// footer as two read-only properties — stickyFooterController and
// stickyFooterStory — set from the matching arguments of its long
// -initWith…stickyFooterController:stickyFooterStory:stickyFooterDelegate:… .
// The root component spec reads those to decide whether to build the
// FBCommentStreamStickyFooterContainerComponent at all; a post with no attached
// link leaves them nil, and the spec already renders that case with no footer
// bar and no reserved gap. Returning nil from both getters therefore puts the
// sheet into a state Facebook's own code produces for an ordinary post, which
// is exactly the issue's suggested direction ("nil out the sticky footer
// controller/story for the comment stream").
//
// The composer (the comment input box) is a different thing entirely — a
// separate composerConfiguration / isComposerHidden pair, with its own
// stickyFooterRequestHide/UnhideCommentComposer callbacks — so it is untouched;
// only the CTA bar goes away.
//
// All of the above was read out of the Objective-C metadata of Facebook
// 587.0.0 (FBCommentStreamRootComponentModel in FBSharedFramework, which is
// linked at launch), not guessed. The group installs only when the class and
// both getters are present, so a rename in a future build leaves this one
// surface unaffected instead of taking the comment sheet down.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPHeaders.h"
#import "FBPTrace.h"

#import <objc/runtime.h>

#pragma mark - Comment-stream sticky footer (affiliate / product banner)

%group FBPCommentProductBanner

%hook FBCommentStreamRootComponentModel

- (id)stickyFooterController {
    FBPTraceFire("comments.FBCommentStreamRootComponentModel.stickyFooterController");
    // nil is the "no footer for this post" value Facebook already sets for a post
    // with no attached link, so the sheet renders exactly as it does there.
    if (FBPEnabled(FBPKeyNoCommentProductBanner)) return nil;
    return %orig;
}

- (id)stickyFooterStory {
    FBPTraceFire("comments.FBCommentStreamRootComponentModel.stickyFooterStory");
    if (FBPEnabled(FBPKeyNoCommentProductBanner)) return nil;
    return %orig;
}

%end

%end // FBPCommentProductBanner

#pragma mark - Reels creator-storefront product tag

// The same affiliate CTA also appears as an in-video product card ON a Reel (a
// creator-storefront product tag: thumbnail, title, store name, "commission
// eligible") — a surface separate from the comment sheet above, so the comment
// hook never touched it. It is built from a Swift class,
// FBShortsCreatorStorefrontProductTagResolver, whose @objc gate
// +hasAnyPayloadWithFragment: answers whether a Reel carries a tag. Answering NO
// is the state the app already renders for every untagged Reel, so the card is
// never built — no empty slot, no reserved gap. Bound to the resolved Swift
// runtime class in %init. Gated on the same toggle as the comment banner, since
// to the user both are "the product/affiliate banner".
%group FBPReelsProductTag

%hook FBPShortsProductTagResolver

+ (BOOL)hasAnyPayloadWithFragment:(id)fragment {
    if (FBPEnabled(FBPKeyNoCommentProductBanner)) {
        FBPTraceFire("reels.CreatorStorefrontProductTag.hasAnyPayload.suppressed");
        return NO;
    }
    return %orig;
}

%end

%end // FBPReelsProductTag

#pragma mark - Init

void FBPInitCommentHooks(void) {
    // FBSharedFramework is linked at launch, so this normally latches on the
    // first pass; the installer is still re-run from the dyld image-load
    // callback (see FBPEntry.xm) and FBP_ONCE keeps it to a single install.
    Class model = objc_getClass("FBCommentStreamRootComponentModel");
    if (model &&
        [model instancesRespondToSelector:@selector(stickyFooterController)] &&
        [model instancesRespondToSelector:@selector(stickyFooterStory)]) {
        FBP_ONCE(gCommentProductBanner) { %init(FBPCommentProductBanner); }
    } else {
        FBPLog(@"FBCommentStreamRootComponentModel sticky-footer getters not found — comment product banner not hidden");
    }

    // The same affiliate card ON a Reel is a separate, Swift-backed surface.
    Class resolver =
        NSClassFromString(@"_TtC43FBShortsCreatorStorefrontProductTagResolver43FBShortsCreatorStorefrontProductTagResolver")
        ?: objc_getClass("FBShortsCreatorStorefrontProductTagResolver");
    if (resolver && [resolver respondsToSelector:@selector(hasAnyPayloadWithFragment:)]) {
        FBP_ONCE(gReelsProductTag) { %init(FBPReelsProductTag, FBPShortsProductTagResolver = resolver); }
        FBPLog(@"reels: creator-storefront product-tag gate installed");
    } else {
        FBPLog(@"reels: FBShortsCreatorStorefrontProductTagResolver not found");
    }
}
