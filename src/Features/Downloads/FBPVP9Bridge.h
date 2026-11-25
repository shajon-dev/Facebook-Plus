// VP9 decode by borrowing Facebook's own bundled libavcodec, so a VP9 rung can
// be saved without shipping FFmpeg. Both frameworks are dlopen'd by exact
// bundle path and each symbol dladdr-checked: a flat dlsym(RTLD_DEFAULT) can
// reach a second, ABI-incompatible build in the same process (FBPDav1dBridge.h).
// Every struct is library-allocated, so a wrong offset is a read, not a write.

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// A plain C function so FBPDashManifest.m, which is UIKit- and
/// AVFoundation-free, can gate a VP9 rung on it. Resolved, not proven to decode.
extern BOOL FBPVP9ConversionIsAvailable(void);

/// Settle the symbol resolution off the main thread, so the first VP9 download
/// does not pay for it on the control queue. Idempotent.
extern void FBPVP9BridgePrewarm(void);

/// Turn the tier off for the rest of this process. Called when a decoded frame
/// does not match its track — the one signal that the borrowed build's layout
/// is not the one assumed here.
extern void FBPVP9BridgeMarkUnhealthy(void);

#ifdef __cplusplus
}
#endif

/// Takes the compressed access units demuxed from the file and returns NV12
/// (`420v`) buffers, the format both VideoToolbox encoders consume.
@interface FBPVP9Decoder : NSObject

/// nil when the borrowed decoder is unavailable or the context would not open.
- (nullable instancetype)init;

/// @c handler runs once per decoded frame (0, 1 or rarely more), with a buffer
/// owned by the callee for the call. NO only on a hard decoder error: "no frame
/// this call" is a normal YES, since VP9 alt-ref frames emit nothing.
- (BOOL)decodeAccessUnit:(const void *)bytes
                  length:(size_t)length
                 handler:(void (^)(CVPixelBufferRef pixelBuffer))handler;

/// Drain any frames the decoder is still holding. Call once at end of stream.
- (BOOL)flushWithHandler:(void (^)(CVPixelBufferRef pixelBuffer))handler;

@end

NS_ASSUME_NONNULL_END
