// Preference store backed by the com.shajon.fbplus defaults suite, plus the
// FBPEnabled() shorthand used throughout the hooks.

#import "FBPlus.h"

NS_ASSUME_NONNULL_BEGIN

/// Preference store, backed by the @c com.shajon.fbplus suite.
///
/// Defaults are registered once at launch so an unset option reads as its
/// intended value rather than NO.
@interface FBPPrefs : NSObject

@property (class, readonly) FBPPrefs *shared;

- (BOOL)boolForKey:(NSString *)key;
- (void)setBool:(BOOL)value forKey:(NSString *)key;

/// For values the tweak records rather than the user sets — a timestamp, say.
/// Unlike the setters above these are not followed by -commit, so writing one
/// does not announce a settings change to the hooks.
- (double)doubleForKey:(NSString *)key;
- (void)setDouble:(double)value forKey:(NSString *)key;

- (nullable NSString *)stringForKey:(NSString *)key;
- (void)setString:(nullable NSString *)value forKey:(NSString *)key;

/// Writes, synchronises, and posts @c FBPSettingsDidChangeNotification.
- (void)commit;

/// Restores every option to its default, keeping onboarding state, then commits.
- (void)resetToDefaults;

@end

/// Shorthand used throughout the hooks.
static inline BOOL FBPEnabled(NSString *key) {
    return [FBPPrefs.shared boolForKey:key];
}

NS_ASSUME_NONNULL_END
