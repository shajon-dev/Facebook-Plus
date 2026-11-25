// Lossless video + audio muxer: two single-track files in, one MP4 out.
// Facebook's DASH ladder keeps video and audio apart; Photos takes only one MP4.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Errors

extern NSString *const FBPMediaMuxerErrorDomain;

/// Fine-grained because the caller shows different text for each case.
typedef NS_ENUM(NSInteger, FBPMediaMuxerError) {
    FBPMediaMuxerErrorBadArguments = 1,
    FBPMediaMuxerErrorVideoUnreadable,
    FBPMediaMuxerErrorAudioUnreadable,
    FBPMediaMuxerErrorNoVideoTrack,
    FBPMediaMuxerErrorNoAudioTrack,
    /// No CMFormatDescription on the track, hence no sourceFormatHint, and
    /// passthrough into an MP4 is then not permitted.
    FBPMediaMuxerErrorMissingFormatDescription,
    FBPMediaMuxerErrorSetupFailed,
    FBPMediaMuxerErrorReadFailed,
    FBPMediaMuxerErrorWriteFailed,
    FBPMediaMuxerErrorNoSamples,
    FBPMediaMuxerErrorCancelled,
};

#pragma mark - Muxer

/// Called once, on the main queue. On failure nothing is left at the output path.
typedef void (^FBPMediaMuxCompletion)(NSURL *_Nullable outputURL,
                                      NSError *_Nullable error);

@interface FBPMediaMuxer : NSObject

/// Stream-copy a video-only and an audio-only file into one MP4. Returns
/// immediately and works off the main thread; replaces any file at @c outputURL.
+ (void)muxVideoURL:(NSURL *)videoURL
           audioURL:(NSURL *)audioURL
          outputURL:(NSURL *)outputURL
         completion:(FBPMediaMuxCompletion)completion;

/// Each abandoned mux still fires its completion, with
/// @c FBPMediaMuxerErrorCancelled and no file left behind.
+ (void)cancelAll;

@end

NS_ASSUME_NONNULL_END
