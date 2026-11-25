// Minimal DASH MPD reader. The XML arrives inline from -DashPlaylist and each
// <Representation>'s <BaseURL> is one complete MP4 fetched with one unranged
// GET, so every byte range in the document is ignored. Never cache a parsed
// manifest: the signed <BaseURL>s expire. A regex scraper backs up NSXMLParser,
// which abandons a document at its first well-formedness error.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FBPDashRepresentation : NSObject

@property (nonatomic, copy, readonly) NSURL *url;

@property (nonatomic, copy, readonly, nullable) NSString *qualityLabel;

@property (nonatomic, copy, readonly, nullable) NSString *codecs;

@property (nonatomic, assign, readonly) NSInteger width;
@property (nonatomic, assign, readonly) NSInteger height;
@property (nonatomic, assign, readonly) long long bandwidth;

@property (nonatomic, assign, readonly) double frameRate;

@property (nonatomic, assign, readonly) NSInteger qualityRank;

/// The dedupe key; @c qualityRank only orders. Meta ships CRFs per resolution.
@property (nonatomic, copy, readonly, nullable) NSString *displayLabel;

/// AV1 or VP9: re-encode, not copy. Only YES where this device can convert.
@property (nonatomic, assign, readonly) BOOL needsConversion;

@end

@interface FBPDashManifest : NSObject

@property (nonatomic, copy, readonly) NSArray<FBPDashRepresentation *> *videoRepresentations;

@property (nonatomic, strong, readonly, nullable) FBPDashRepresentation *audioRepresentation;

/// Advisory. Never a reason to withhold the video ladder.
@property (nonatomic, assign, readonly) BOOL audioIsNotAAC;

@property (nonatomic, assign, readonly) NSTimeInterval duration;

@property (nonatomic, copy, readonly) NSArray<NSString *> *droppedNotes;

+ (nullable FBPDashManifest *)manifestFromXMLString:(nullable NSString *)xml;

@end

#ifdef __cplusplus
extern "C" {
#endif

extern NSTimeInterval FBPDashParseISODuration(NSString *_Nullable text);

extern NSInteger FBPDashRankFromQualityLabel(NSString *_Nullable label);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
