#import <Foundation/Foundation.h>

// Native host for the "Open in Facebook" Safari web extension. All of the link
// routing lives in the JavaScript (content.js / google.js); the host only has to
// exist and satisfy the extension request, so it is deliberately minimal.
@interface FBPSafariWebExtensionHandler : NSObject <NSExtensionRequestHandling>
@end
