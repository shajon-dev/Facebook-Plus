// Like confirmation.
//
// Facebook's UI is ComponentKit-generated, so the concrete button classes are
// mangled and change between builds. Every ComponentKit control event funnels
// through one forwarder, so that is intercepted instead and the sender is
// identified by accessibility identifier — which is stable, because Facebook's
// own UI tests depend on it.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPHeaders.h"
#import "FBPResources.h"
#import "FBPSheet.h"

static NSString *FBPKeyForIdentifier(NSString *identifier) {
    if (identifier.length == 0) return nil;
    if ([identifier isEqualToString:FBPAXFeedLikeButton])  return FBPKeyFeedLike;
    if ([identifier isEqualToString:FBPAXReelsLikeButton]) return FBPKeyReelsLike;
    return nil;
}

/// Preference guarding this sender, or nil when it is not a like button.
///
/// ComponentKit does not consistently put the accessibility identifier on the
/// view that ends up as the sender — depending on how the component tree was
/// built it can sit on a wrapper above it or on the tappable child below.
/// Checking only the sender itself is why confirmation fired on some posts and
/// not others, so a couple of levels are searched in each direction.
static NSString *FBPConfirmKeyForSender(id sender, UIView **outMatch) {
    if (outMatch) *outMatch = nil;
    if (![sender isKindOfClass:UIView.class]) return nil;
    UIView *view = (UIView *)sender;

    NSString *key = FBPKeyForIdentifier(view.accessibilityIdentifier);
    if (key) { if (outMatch) *outMatch = view; return key; }

    // Upwards: a wrapper carrying the identifier for its subtree.
    UIView *node = view.superview;
    for (NSInteger level = 0; node && level < 3; level++, node = node.superview) {
        key = FBPKeyForIdentifier(node.accessibilityIdentifier);
        if (key) { if (outMatch) *outMatch = node; return key; }
    }

    // Downwards: the identifier on the actual glyph inside a tappable wrapper.
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithArray:view.subviews];
    NSInteger visited = 0;
    while (queue.count && visited < 24) {
        UIView *candidate = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited += 1;
        key = FBPKeyForIdentifier(candidate.accessibilityIdentifier);
        if (key) { if (outMatch) *outMatch = candidate; return key; }
        [queue addObjectsFromArray:candidate.subviews];
    }

    return nil;
}

/// YES when an accessibility label names an "already liked" state — i.e. tapping
/// would *remove* the reaction. Facebook labels the control "Like" when it will
/// add a like and "Unlike" when it will take one away (both are literal strings
/// in FBSharedFramework), so the label is the reliable signal.
static BOOL FBPLabelMeansLiked(NSString *label) {
    if (label.length == 0) return NO;
    NSString *lower = label.lowercaseString;
    return [lower hasPrefix:@"unlike"] ||
           [lower containsString:@"remove like"] ||
           [lower containsString:@"remove reaction"];
}

/// YES when the like control is currently in the liked state, so the pending tap
/// is an *unlike* and must not be confirmed — undoing a like needs no guard.
///
/// The state lives on the same component as the like identifier (its label flips
/// to "Unlike", and it carries the selected trait), but ComponentKit sometimes
/// splits the identifier and the label across a wrapper and its glyph child, so
/// a shallow subtree is checked for the label too.
static BOOL FBPSenderIsCurrentlyLiked(UIView *view) {
    if (!view) return NO;
    if (view.accessibilityTraits & UIAccessibilityTraitSelected) return YES;
    if (FBPLabelMeansLiked(view.accessibilityLabel)) return YES;

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithArray:view.subviews];
    NSInteger visited = 0;
    while (queue.count && visited < 24) {
        UIView *candidate = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited += 1;
        if (FBPLabelMeansLiked(candidate.accessibilityLabel)) return YES;
        [queue addObjectsFromArray:candidate.subviews];
    }
    return NO;
}

// Set while replaying a confirmed event, so the second pass through the hook
// falls straight through to the original. Logos cannot expand an orig call
// from inside a block, so the event is re-sent instead of being forwarded.
static BOOL gConfirmedPassthrough = NO;

%group FBPConfirm

%hook CKComponentActionControlForwarder

- (void)handleControlEventFromSender:(id)sender withEvent:(UIEvent *)event {
    if (gConfirmedPassthrough) {
        %orig;
        return;
    }

    UIView *likeView = nil;
    NSString *key = FBPConfirmKeyForSender(sender, &likeView);
    if (!key || !FBPEnabled(key)) {
        %orig;
        return;
    }

    // Confirm a like, never an unlike: if the control is already liked this tap
    // just undoes it, which needs no guard — let it through untouched.
    if (FBPSenderIsCurrentlyLiked(likeView ?: (UIView *)sender)) {
        %orig;
        return;
    }

    UIView *view = (UIView *)sender;
    UIViewController *host = view._viewControllerForAncestor
        ?: [FBPSheetPresenter topViewController];
    if (!host) {
        %orig;
        return;
    }
    while (host.presentedViewController) host = host.presentedViewController;

    // A centred confirmation. The sender's accessibility label ("Like", "Love",
    // …) names the exact reaction in the message, so the prompt stays correct
    // across reaction types and languages without the tweak shipping its own copy
    // of each.
    NSString *reaction = view.accessibilityLabel.length ? view.accessibilityLabel : nil;
    BOOL reels = [key isEqualToString:FBPKeyReelsLike];
    NSString *alertTitle = reels ? @"Confirm Reels Like" : @"Confirm Like";
    NSString *message = reaction
        ? [NSString stringWithFormat:@"Send a “%@” reaction?", reaction]
        : @"Send this reaction?";

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:alertTitle
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    // Held strongly on purpose: the forwarder must outlive the prompt, or the
    // replay below would message a deallocated object.
    __block id forwarder = self;
    UIAlertAction *confirm =
        [UIAlertAction actionWithTitle:@"Like"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *action) {
        // Only now does the like actually fire.
        gConfirmedPassthrough = YES;
        [forwarder handleControlEventFromSender:sender withEvent:event];
        gConfirmedPassthrough = NO;
    }];
    [alert addAction:confirm];
    alert.preferredAction = confirm;

    alert.view.tintColor = FBPTintColor();
    [host presentViewController:alert animated:YES completion:nil];
}

%end

%end // FBPConfirm

void FBPInitConfirmHooks(void) {
    if (objc_getClass("CKComponentActionControlForwarder")) {
        FBP_ONCE(gConfirm) { %init(FBPConfirm); }
    } else {
        FBPLog(@"CKComponentActionControlForwarder not found — confirmations disabled");
    }
}
