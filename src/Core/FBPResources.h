#import "FBPlus.h"

NS_ASSUME_NONNULL_BEGIN

/// Located by absolute path; on rootless jailbreaks it is relative to the
/// jbroot, so several candidates are tried in order.
@interface NSBundle (FBPlus)
@property (class, readonly) NSBundle *fbp_resourceBundle;
@end

@interface UIImage (FBPlus)
+ (nullable UIImage *)fbp_imageNamed:(NSString *)name;
+ (nullable UIImage *)fbp_symbolNamed:(NSString *)name size:(CGFloat)size;
+ (nullable UIImage *)fbp_symbolNamed:(NSString *)name
                                 size:(CGFloat)size
                               weight:(UIImageSymbolWeight)weight;
@end

// C linkage: the .xm files compile as Objective-C++ and the rest as
// Objective-C, so otherwise the two halves disagree on the symbol names.
#ifdef __cplusplus
extern "C" {
#endif

extern UIColor *FBPTintColor(void);

/// Fixed dark palette, pinned regardless of the host theme. Views that use
/// these must be FBP-prefixed so the OLED sweep leaves their colours alone.
extern UIColor *FBPPanelColor(void);
extern UIColor *FBPCardColor(void);
extern UIColor *FBPIconColor(void);

extern UIFont *FBPFont(CGFloat size, UIFontWeight weight);

/// Centres an alert's title and message, which iOS 26 lays out leading-aligned.
extern void FBPCenterAlertText(UIAlertController *alert);

extern NSString *FBPLocalizedString(NSString *key);

#define FBPL(key) FBPLocalizedString(key)

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
