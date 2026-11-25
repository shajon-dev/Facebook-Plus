// Action confirmations routed through ComponentKit.
//
// Facebook's UI is ComponentKit-generated, so the concrete button classes are
// mangled and change between builds. Every ComponentKit control event funnels
// through one forwarder, so that is intercepted instead and the sender is
// identified by its accessibility identifier — stable, because Facebook's own
// UI tests depend on it — with the label as a fallback for the few buttons that
// ship no identifier.
//
// Like, Share, Follow/Join and Friend-request buttons all dispatch through this
// same forwarder, so one hook guards every one of them; the commit-level hooks
// (comment and post) live separately because they are not ComponentKit buttons.

#import "FBPlus.h"
#import "FBPPrefs.h"
#import "FBPHeaders.h"
#import "FBPTrace.h"
#import "FBPResources.h"
#import "FBPSheet.h"

typedef NS_ENUM(NSInteger, FBPConfirmKind) {
    FBPConfirmKindNone = -1,
    FBPConfirmKindLike = 0,
    FBPConfirmKindShare,
    FBPConfirmKindFollow,   // following a page, or joining a group
    FBPConfirmKindFriend,   // confirming / responding to a friend request
};

/// Classifies one view by accessibility identifier, falling back to its label
/// for the buttons that ship none ("Share now", the group "Join"). Lower-cased.
static FBPConfirmKind FBPKindForView(UIView *view) {
    NSString *identifier = view.accessibilityIdentifier;
    NSString *label = view.accessibilityLabel;
    NSString *idl = identifier.lowercaseString;
    NSString *lbl = label.lowercaseString;

    // Like — feed posts and Reels share one guard.
    if ([identifier isEqualToString:FBPAXFeedLikeButton] ||
        [identifier isEqualToString:FBPAXReelsLikeButton]) {
        return FBPConfirmKindLike;
    }

    // Share — the share-sheet's final "Share now" has only a label.
    if ([idl containsString:@"ufi-share-button"] ||
        [lbl isEqualToString:@"share now"]) {
        return FBPConfirmKindShare;
    }

    // Checked before Follow: some of these carry follow-ish labels too.
    if (([idl containsString:@"friend"] &&
         ([idl containsString:@"request"] ||
          [idl containsString:@"confirm"] ||
          [idl containsString:@"add"])) ||
        [lbl containsString:@"friend request"]) {
        return FBPConfirmKindFriend;
    }

    // The profile follow control has a "following_status" identifier; the group
    // join button has only a "Join …" label.
    if ([idl containsString:@"following_status"] ||
        [idl containsString:@"follow-button"] ||
        [lbl isEqualToString:@"follow"] ||
        [lbl isEqualToString:@"following"] ||
        [lbl hasPrefix:@"join "]) {
        return FBPConfirmKindFollow;
    }

    return FBPConfirmKindNone;
}

/// The preference that guards a kind, or nil when the kind is disabled here.
static NSString *FBPKeyForKind(FBPConfirmKind kind) {
    switch (kind) {
        case FBPConfirmKindLike:   return FBPKeyFeedLike;
        case FBPConfirmKindShare:  return FBPKeyConfirmShare;
        case FBPConfirmKindFollow: return FBPKeyConfirmFollow;
        case FBPConfirmKindFriend: return FBPKeyConfirmFriend;
        default:                   return nil;
    }
}

/// Which confirmable action this sender is, or None.
///
/// ComponentKit does not reliably put the identifier on the view that becomes
/// the sender: it can sit on a wrapper above or the tappable child below, so a
/// couple of levels are searched in each direction.
static FBPConfirmKind FBPConfirmKindForSender(id sender, UIView **outMatch) {
    if (outMatch) *outMatch = nil;
    if (![sender isKindOfClass:UIView.class]) return FBPConfirmKindNone;
    UIView *view = (UIView *)sender;

    FBPConfirmKind kind = FBPKindForView(view);
    if (kind != FBPConfirmKindNone) { if (outMatch) *outMatch = view; return kind; }

    UIView *node = view.superview;
    for (NSInteger level = 0; node && level < 3; level++, node = node.superview) {
        kind = FBPKindForView(node);
        if (kind != FBPConfirmKindNone) { if (outMatch) *outMatch = node; return kind; }
    }

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithArray:view.subviews];
    NSInteger visited = 0;
    while (queue.count && visited < 24) {
        UIView *candidate = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited += 1;
        kind = FBPKindForView(candidate);
        if (kind != FBPConfirmKindNone) { if (outMatch) *outMatch = candidate; return kind; }
        [queue addObjectsFromArray:candidate.subviews];
    }

    return FBPConfirmKindNone;
}

/// YES when the label names an already-liked state, so a tap would remove the
/// reaction. Facebook labels the control "Like" or "Unlike" by what the tap
/// will do, which makes the label the reliable signal.
static BOOL FBPLabelMeansLiked(NSString *label) {
    if (label.length == 0) return NO;
    NSString *lower = label.lowercaseString;
    return [lower hasPrefix:@"unlike"] ||
           [lower containsString:@"remove like"] ||
           [lower containsString:@"remove reaction"];
}

/// YES when the pending tap is an unlike, which needs no guard. The state lives
/// on the same component as the like identifier, but ComponentKit sometimes
/// splits identifier and label across a wrapper and its glyph child, so a
/// shallow subtree is checked for the label too.
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

/// Title, message and confirm-verb for a kind. Like builds its message from the
/// sender's reaction label, so this returns only its generic fallback.
static void FBPStringsForKind(FBPConfirmKind kind,
                              NSString **title, NSString **message, NSString **verb) {
    switch (kind) {
        case FBPConfirmKindShare:
            *title   = FBPL(@"confirm.share.title");
            *message = FBPL(@"confirm.share.message");
            *verb    = FBPL(@"confirm.share.verb");
            break;
        case FBPConfirmKindFollow:
            *title   = FBPL(@"common.confirm");
            *message = FBPL(@"confirm.follow.message");
            *verb    = FBPL(@"confirm.follow.verb");
            break;
        case FBPConfirmKindFriend:
            *title   = FBPL(@"confirm.friend.title");
            *message = FBPL(@"confirm.friend.message");
            *verb    = FBPL(@"common.confirm");
            break;
        case FBPConfirmKindLike:
        default:
            *title   = FBPL(@"confirm.like.title");
            *message = FBPL(@"confirm.like.message");
            *verb    = FBPL(@"confirm.like.verb");
            break;
    }
}

// Set while replaying a confirmed event, so the second pass through the hook
// falls straight through to the original. Logos cannot expand an orig call
// from inside a block, so the event is re-sent instead of being forwarded.
static BOOL gConfirmedPassthrough = NO;

%group FBPConfirm

%hook CKComponentActionControlForwarder

- (void)handleControlEventFromSender:(id)sender withEvent:(UIEvent *)event {
    FBPTraceFire("confirm.CKComponentActionControlForwarder.handleControlEvent");
    if (gConfirmedPassthrough) {
        %orig;
        return;
    }

    UIView *match = nil;
    FBPConfirmKind kind = FBPConfirmKindForSender(sender, &match);
    NSString *key = FBPKeyForKind(kind);
    if (!key || !FBPEnabled(key)) {
        %orig;
        return;
    }

    // Never guard an unlike: it only undoes a like.
    if (kind == FBPConfirmKindLike &&
        FBPSenderIsCurrentlyLiked(match ?: (UIView *)sender)) {
        %orig;
        return;
    }

    // The other confirmation path, or a stray second event from the same tap.
    // Dropping it does not lose the action: the first prompt still fires it.
    if (FBPConfirmPromptVisible()) {
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

    NSString *alertTitle = nil, *message = nil, *verb = nil;
    FBPStringsForKind(kind, &alertTitle, &message, &verb);

    // The sender's label ("Like", "Love", …) names the exact reaction, so the
    // message stays correct across reaction types and languages for free.
    if (kind == FBPConfirmKindLike && view.accessibilityLabel.length) {
        message = [NSString stringWithFormat:@"Send a “%@” reaction?",
                   view.accessibilityLabel];
    }

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:alertTitle
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:FBPL(@"common.cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction *action) {
        FBPSetConfirmPromptVisible(NO);
    }]];

    // Held strongly on purpose: the forwarder must outlive the prompt, or the
    // replay below would message a deallocated object.
    __block id forwarder = self;
    UIAlertAction *confirm =
        [UIAlertAction actionWithTitle:verb
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *action) {
        FBPSetConfirmPromptVisible(NO);
        gConfirmedPassthrough = YES;
        [forwarder handleControlEventFromSender:sender withEvent:event];
        gConfirmedPassthrough = NO;
    }];
    [alert addAction:confirm];
    alert.preferredAction = confirm;

    // The settings tint is tuned for the black settings panel and vanishes on
    // the alert's light background, so use system blue.
    alert.view.tintColor = UIColor.systemBlueColor;
    FBPSetConfirmPromptVisible(YES);
    [host presentViewController:alert animated:YES completion:nil];
}

%end

%end // FBPConfirm

void FBPInitConfirmHooks(void) {
    if (objc_getClass("CKComponentActionControlForwarder")) {
        FBP_ONCE(gConfirm) { %init(FBPConfirm); }
    } else {
        FBPLogOnce(@"CKComponentActionControlForwarder not found — confirmations disabled");
    }
}
