// VP9 decode by borrowing Facebook's own bundled libavcodec, so a VP9 rung can
// be saved — without this tweak shipping one byte of FFmpeg.
//
// Why this is safe where the dav1d tier (FBPDav1dBridge.h) is not
// ------------------------------------------------------------------------
// Three things that stopped the dav1d borrow are answered here:
//
//  1. WHICH image answers. The dav1d symbols resolve out of two different builds
//     in one process (FBSharedFramework 1.5.1 and WebCore 1.0.0) under
//     dlsym(RTLD_DEFAULT), so a flat lookup returns a mixture. Here the two
//     libraries are dlopen'd by their exact bundle path
//     (Facebook.app/Frameworks/libavcodec.framework/libavcodec and libavutil),
//     every symbol is resolved against THAT handle, and dladdr is used to prove
//     each one lands inside the expected framework. WebCore can never answer.
//
//  2. A CLEAN decode API, not a struct the caller fills. libavcodec's borrowed
//     surface is the nine-symbol send-packet / receive-frame loop
//     (avcodec_find_decoder → alloc_context3 → open2 → send_packet →
//     receive_frame), all allocated by the library itself (av_packet_alloc,
//     av_frame_alloc), so this file never guesses a struct SIZE — only the
//     offsets of a few ABI-frozen early fields it READS back out of a frame the
//     library produced (data/linesize/width/height/format) and the packet's
//     data pointer the library allocated. Those fields sit at the very front of
//     AVFrame/AVPacket and have not moved across FFmpeg 5.x–7.x. Confirmed
//     identical between Facebook 587 and 588 (same exported API, same ffmpeg 7.x
//     from the av_frame_side_data_* symbol set).
//
//  3. A RUNTIME proof, not a static assumption. A wrong offset here is a bad
//     READ, never a wild write: the only struct this file writes into is one the
//     library allocated and sized. And the converter that drives this
//     (FBPVP9Converter) cross-checks the first decoded frame's width/height
//     against the track's own natural size before copying a pixel; on any
//     mismatch it calls FBPVP9BridgeMarkUnhealthy() and the tier declines for
//     the rest of the process. So a future Facebook build that moved these
//     fields would turn VP9 rungs off, never crash the host.
//
// This is why VP9 support needs no shipped FFmpeg and cannot collide with the
// host's libavcodec: nothing is linked, nothing is injected, the host's own
// already-loaded decoder is borrowed by path. See FBPMediaConverter.h for the
// AV1 sibling and [[ffmpeg-vs-avfoundation]] for the collision that shipping a
// framework would have caused.

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// YES when the borrowed VP9 decoder has resolved and has not been marked
/// unhealthy by a failed self-check. A plain C function so FBPDashManifest.m —
/// which is UIKit-free and AVFoundation-free — can gate a VP9 rung on it exactly
/// as it does FBPMediaConversionIsAvailable for AV1.
///
/// "Resolved" means: both frameworks dlopen'd by path, every one of the nine
/// decode symbols found inside the expected framework (proved with dladdr), and
/// avcodec_find_decoder answering for VP9. It does NOT mean a frame has been
/// decoded — that proof is the converter's first-frame check, which flips the
/// tier off through FBPVP9BridgeMarkUnhealthy if it ever fails.
extern BOOL FBPVP9ConversionIsAvailable(void);

/// Settle the symbol resolution off the main thread, so the first VP9 download
/// does not pay for it on the control queue. Idempotent.
extern void FBPVP9BridgePrewarm(void);

/// Turn the tier off for the rest of this process. Called by FBPVP9Converter
/// when a decoded frame does not match the track it came from — the one signal
/// that the borrowed build's layout is not the one assumed here.
extern void FBPVP9BridgeMarkUnhealthy(void);

#ifdef __cplusplus
}
#endif

/// A one-shot VP9 decoder over the borrowed libavcodec. Feed it the compressed
/// access units demuxed from the file (each MP4 sample is one VP9 superframe)
/// and it hands back NV12 (`420v`, 8-bit bi-planar video-range) pixel buffers —
/// the exact format FBPMediaConverter's AV1 path produces and both VideoToolbox
/// encoders consume, so the encode side is shared unchanged.
@interface FBPVP9Decoder : NSObject

/// nil when the borrowed decoder is unavailable (see FBPVP9ConversionIsAvailable)
/// or the VP9 AVCodecContext could not be opened.
- (nullable instancetype)init;

/// Decode one compressed VP9 access unit. @c handler is called once per decoded
/// frame (0, 1 or — rarely — more), with a pixel buffer owned by the callee for
/// the duration of the call. Returns NO only on a hard decoder error; "produced
/// no frame this call" is a normal YES (VP9 alt-ref frames emit nothing).
- (BOOL)decodeAccessUnit:(const void *)bytes
                  length:(size_t)length
                 handler:(void (^)(CVPixelBufferRef pixelBuffer))handler;

/// Drain any frames the decoder is still holding. Call once at end of stream.
- (BOOL)flushWithHandler:(void (^)(CVPixelBufferRef pixelBuffer))handler;

@end

NS_ASSUME_NONNULL_END
