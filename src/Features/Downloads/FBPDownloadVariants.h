// Shared download-variant model, resolver, quality picker and DASH diagnostic.
// The two tiers never mix: a DASH ladder is the whole list, the progressive
// HD/SD pair the fallback. @c byteSize is the download, @c detail the saved file.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, FBPDownloadVariantTier) {
    FBPDownloadVariantTierProgressive = 0,
    FBPDownloadVariantTierSpherical,
    FBPDownloadVariantTierDash,
};

@interface FBPDownloadVariant : NSObject

@property (nonatomic, copy, readonly) NSURL *url;

/// DASH only. Saving @c url alone when this is set would write a silent video.
@property (nonatomic, copy, readonly, nullable) NSURL *audioURL;

@property (nonatomic, assign, readonly) BOOL needsMux;

/// AV1 or VP9: re-encode, not copy. Only YES where that is actually possible.
@property (nonatomic, assign, readonly) BOOL needsConversion;

@property (nonatomic, assign, readonly) FBPDownloadVariantTier tier;

/// "HD" / "SD" for the progressive pair, which must claim no resolution.
@property (nonatomic, copy, readonly) NSString *title;

@property (nonatomic, copy, readonly, nullable) NSString *detail;

/// The FBQualityLabel rung, not the pixel height despite the name: Facebook
/// encodes several rungs per resolution. 0 for a row that sits on no rung.
@property (nonatomic, assign, readonly) NSInteger pixelHeight;
@property (nonatomic, assign, readonly) long long bitRate;
@property (nonatomic, assign, readonly) long long byteSize;

@end

@interface FBPDownloadSource : NSObject

@property (nonatomic, strong, readonly, nullable) id item;
@property (nonatomic, strong, readonly, nullable) id playbackController;
@property (nonatomic, copy, readonly, nullable) NSString *videoID;
@property (nonatomic, copy, readonly) NSArray<FBPDownloadVariant *> *variants;

@property (nonatomic, copy, readonly, nullable) NSString *mediaTitle;

@property (nonatomic, copy, readonly, nullable) NSURL *thumbnailURL;

@end

#ifdef __cplusplus
extern "C" {
#endif

/// Checks the selector exists and returns an object before any objc_msgSend.
extern id _Nullable FBPDownloadSafeObjectGetter(id _Nullable object,
                                                NSString *getterName);

/// Reads and parses -DashPlaylist on every call, deliberately: the <BaseURL>s
/// carry a short-lived `oe=` signature, so a cached ladder is one of dead links.
extern NSArray<FBPDownloadVariant *> *
FBPDownloadVariantsForItem(id _Nullable item,
                           NSString *_Nullable *_Nullable videoIDOut);

extern FBPDownloadSource *
FBPDownloadSourceFromPlaybackController(id _Nullable playbackController);

typedef NSArray<FBPDownloadVariant *> *_Nullable (^FBPDownloadVariantRefresher)(void);

/// @param refresh Optional, and called on the pick because a sheet left open can
///   outlive the signed URL it was built from. Matched by title then pixel
///   height. Not called on the no-sheet path, which runs @c chosen synchronously.
extern void FBPDownloadPresentPicker(NSArray<FBPDownloadVariant *> *variants,
                                     UIViewController *_Nullable presenter,
                                     UIView *_Nullable sourceView,
                                     FBPDownloadVariantRefresher _Nullable refresh,
                                     void (^chosen)(FBPDownloadVariant *variant));

extern NSArray<FBPDownloadVariant *> *
FBPDownloadSingleVariant(NSURL *url, NSString *_Nullable title);

extern void FBPDownloadLogQualities(id _Nullable item,
                                    id _Nullable playbackController,
                                    NSArray<FBPDownloadVariant *> *variants);

extern void FBPDownloadInstallDiagnostic(void);

extern BOOL FBPDownloadQualityLoggingEnabled(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
