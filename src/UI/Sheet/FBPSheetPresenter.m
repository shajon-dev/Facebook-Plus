// Presents the action sheet, choosing native detents on iOS 15+ and the custom
// detent presentation on older systems.

#import "FBPSheet.h"
#import "FBPResources.h"
#import "FBPToast.h"
#import <objc/runtime.h>

@implementation FBPSheetAction

+ (instancetype)actionWithTitle:(NSString *)title
                         detail:(NSString *)detail
                       iconName:(NSString *)iconName
                        handler:(dispatch_block_t)handler {
    FBPSheetAction *action = [[self alloc] init];
    action.title = title;
    action.detail = detail;
    action.iconName = iconName;
    action.handler = handler;
    return action;
}

@end

@implementation FBPSheetPresenter

+ (UIViewController *)topViewController {
    UIWindow *window = [FBPToastWindow appKeyWindow];
    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController) {
        controller = controller.presentedViewController;
    }
    return controller;
}

+ (void)presentActions:(NSArray<FBPSheetAction *> *)actions
                 title:(NSString *)title
    fromViewController:(UIViewController *)viewController
            sourceView:(UIView *)sourceView {
    if (actions.count == 0) return;

    UIViewController *host = viewController ?: [self topViewController];
    if (!host) {
        FBPLog(@"no host view controller — cannot present sheet");
        return;
    }
    // Presenting on a controller that is itself presenting silently fails.
    while (host.presentedViewController) host = host.presentedViewController;

    FBPSheetController *sheet =
        [[FBPSheetController alloc] initWithActions:actions title:title];

    if (@available(iOS 15.0, *)) {
        sheet.modalPresentationStyle = UIModalPresentationPageSheet;
        UISheetPresentationController *presentation = sheet.sheetPresentationController;
        if (@available(iOS 16.0, *)) {
            // Asked of the sheet on every resolution rather than captured once:
            // the height depends on the row count, the safe area and Dynamic
            // Type, and the sheet calls -invalidateDetents when those move. The
            // reference is weak because the detent is ultimately owned by the
            // controller it measures.
            __weak FBPSheetController *weakSheet = sheet;
            presentation.detents = @[
                [UISheetPresentationControllerDetent
                    customDetentWithIdentifier:@"fbp.content"
                                      resolver:^CGFloat(id<UISheetPresentationControllerDetentResolutionContext> ctx) {
                        FBPSheetController *measured = weakSheet;
                        if (!measured) return ctx.maximumDetentValue * 0.5;
                        return MIN(measured.preferredDetentHeight, ctx.maximumDetentValue);
                    }],
                UISheetPresentationControllerDetent.largeDetent,
            ];
        } else {
            presentation.detents = @[
                UISheetPresentationControllerDetent.mediumDetent,
                UISheetPresentationControllerDetent.largeDetent,
            ];
        }
        presentation.prefersGrabberVisible = YES;
        presentation.preferredCornerRadius = 20.0;
    } else {
        FBPDetentTransitioningDelegate *delegate =
            [[FBPDetentTransitioningDelegate alloc] init];
        delegate.customHeight = sheet.preferredSheetHeight;
        // The delegate is only weakly held by UIKit, so keep it alive with the
        // controller it configures.
        objc_setAssociatedObject(sheet, @selector(transitioningDelegate), delegate,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sheet.modalPresentationStyle = UIModalPresentationCustom;
        sheet.transitioningDelegate = delegate;
    }

    [host presentViewController:sheet animated:YES completion:nil];
}

@end
