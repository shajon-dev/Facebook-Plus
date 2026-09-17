#import "SafariWebExtensionHandler.h"

@implementation FBPSafariWebExtensionHandler

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context {
    // Nothing to compute natively — reply with an empty response so Safari knows
    // the (JavaScript-driven) extension handled the message.
    [context completeRequestReturningItems:@[] completionHandler:nil];
}

@end
