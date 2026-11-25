// Two-stream download: fetch a DASH video rung and its audio, mux them, hand
// back one file. Foundation-only and never touches Photos; the caller saves it.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Errors

extern NSString *const FBPDashDownloadErrorDomain;

extern NSString *const FBPDashDownloadStatusCodeKey;

/// Video and audio are separate cases because a 403 on either is the expired
/// signed URL, which re-tapping fixes. The cause is in @c NSUnderlyingErrorKey
/// and the status, as an NSNumber, under @c FBPDashDownloadStatusCodeKey.
typedef NS_ENUM(NSInteger, FBPDashDownloadError) {
    FBPDashDownloadErrorBadArguments = 1,
    FBPDashDownloadErrorVideoHTTP,
    FBPDashDownloadErrorAudioHTTP,
    FBPDashDownloadErrorVideoTransport,
    FBPDashDownloadErrorAudioTransport,
    FBPDashDownloadErrorTemporaryFile,
    FBPDashDownloadErrorMux,
    FBPDashDownloadErrorConvert,
    FBPDashDownloadErrorCancelled,
};

#pragma mark - Progress

/// Converting replaces Merging, never follows it: one pass writes both tracks.
typedef NS_ENUM(NSInteger, FBPDashDownloadStage) {
    FBPDashDownloadStageFetching = 1,
    FBPDashDownloadStageMerging,
    FBPDashDownloadStageConverting,
};

typedef void (^FBPDashDownloadProgress)(FBPDashDownloadStage stage, float fraction);

/// Main queue, exactly once. On failure or cancellation nothing is left on disk.
typedef void (^FBPDashDownloadCompletion)(NSURL *_Nullable outputURL,
                                          NSError *_Nullable error);

#pragma mark - Download

@interface FBPDashDownload : NSObject

/// Each @c <BaseURL> is one complete file, so an unranged GET is the whole story
/// despite @c SegmentBase ranges. A nil @c audioURL is a silent video: success.
+ (nullable instancetype)startWithVideoURL:(nullable NSURL *)videoURL
                                  audioURL:(nullable NSURL *)audioURL
                                 outputURL:(nullable NSURL *)outputURL
                                  progress:(nullable FBPDashDownloadProgress)progress
                                completion:(FBPDashDownloadCompletion)completion;

/// Re-encodes the picture, for an AV1 rung Photos refuses. @c sourceBitRate is
/// the representation's own manifest @c bandwidth, or 0 when it stated none.
+ (nullable instancetype)startWithVideoURL:(nullable NSURL *)videoURL
                                  audioURL:(nullable NSURL *)audioURL
                                 outputURL:(nullable NSURL *)outputURL
                              convertVideo:(BOOL)convertVideo
                             sourceBitRate:(long long)sourceBitRate
                                  progress:(nullable FBPDashDownloadProgress)progress
                                completion:(FBPDashDownloadCompletion)completion;

- (void)cancel;

/// NO until the completion has fired. Read from the main queue.
@property (nonatomic, assign, readonly) BOOL finished;

@end

#pragma mark - Reporting

#ifdef __cplusplus
extern "C" {
#endif

/// A finished, localized sentence. nil for a cancellation and for a nil error.
extern NSString *_Nullable FBPDashDownloadMessageForError(NSError *_Nullable error);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
