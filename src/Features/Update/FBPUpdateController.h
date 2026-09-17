#import <UIKit/UIKit.h>

// Update screen, styled like the welcome screen: a professional header, the
// changelog for the new version, and two download buttons (Telegram / GitHub).
@interface FBPUpdateController : UIViewController
- (instancetype)initWithVersion:(NSString *)version changelog:(NSString *)changelog;
@end
