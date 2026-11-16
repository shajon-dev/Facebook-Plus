// Implementation of the borrowed-libavcodec VP9 decoder. See FBPVP9Bridge.h for
// why this is safe where the dav1d borrow was not.

#import "FBPVP9Bridge.h"
#import "FBPlus.h"   // FBPLog -> the exportable diagnostic log

#import <dlfcn.h>
#import <stdatomic.h>

#pragma mark - Borrowed FFmpeg ABI

// ABI-frozen field offsets, 64-bit, FFmpeg 5.x–7.x. These are READ out of
// structs the library itself allocated (so the access is always in-bounds); a
// wrong value here is caught by the converter's first-frame cross-check, never a
// wild write. AVFrame: uint8_t *data[8] @0, int linesize[8] @64, uint8_t
// **extended_data @96, int width @104, int height @108, int nb_samples @112,
// int format @116. AVPacket (FFmpeg 5.0+): AVBufferRef *buf @0, int64 pts @8,
// int64 dts @16, uint8_t *data @24, int size @32.
enum {
    kAVFrameDataOffset     = 0,
    kAVFrameLinesizeOffset = 64,
    kAVFrameWidthOffset    = 104,
    kAVFrameHeightOffset   = 108,
    kAVFrameFormatOffset   = 116,
    kAVPacketDataOffset    = 24,
};

// Enum constants (not symbols): stable, append-only in FFmpeg.
static const int kFBPAVCodecIDVP9    = 167;  // AV_CODEC_ID_VP9
static const int kFBPAVPixFmtYUV420P = 0;    // AV_PIX_FMT_YUV420P
static const int kFBPAVPixFmtYUVJ420P = 12;  // AV_PIX_FMT_YUVJ420P (full-range 420)

typedef const void *(*fb_find_decoder)(int codecID);
typedef void *(*fb_alloc_context3)(const void *codec);
typedef int   (*fb_open2)(void *ctx, const void *codec, void **options);
typedef int   (*fb_send_packet)(void *ctx, const void *pkt);
typedef int   (*fb_receive_frame)(void *ctx, void *frame);
typedef void  (*fb_free_context)(void **ctx);
typedef void *(*fb_packet_alloc)(void);
typedef void  (*fb_packet_free)(void **pkt);
typedef int   (*fb_new_packet)(void *pkt, int size);
typedef void *(*fb_frame_alloc)(void);
typedef void  (*fb_frame_free)(void **frame);
typedef void  (*fb_frame_unref)(void *frame);

typedef struct {
    fb_find_decoder   find_decoder;
    fb_alloc_context3 alloc_context3;
    fb_open2          open2;
    fb_send_packet    send_packet;
    fb_receive_frame  receive_frame;
    fb_free_context   free_context;
    fb_packet_alloc   packet_alloc;
    fb_packet_free    packet_free;
    fb_new_packet     new_packet;
    fb_frame_alloc    frame_alloc;
    fb_frame_free     frame_free;
    fb_frame_unref    frame_unref;
    const void       *vp9Codec;   // avcodec_find_decoder(VP9)
} FBPVP9Syms;

static FBPVP9Syms gSyms;
static BOOL gResolved = NO;
static atomic_bool gUnhealthy = ATOMIC_VAR_INIT(false);

#pragma mark - Symbol resolution (pinned by path, proved by dladdr)

static NSString *FBPVP9FrameworkBinary(NSString *name) {
    // Facebook.app/Frameworks/<name>.framework/<name>
    NSString *fw = [NSString stringWithFormat:@"Frameworks/%@.framework/%@", name, name];
    return [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:fw];
}

// Resolve `symbol` from `handle` and require dladdr to place it inside a path
// containing `expectFramework`. Returns NULL on any failure, so one missing or
// mislocated symbol fails the whole tier.
static void *FBPVP9ResolveChecked(void *handle, const char *symbol,
                                  const char *expectFramework) {
    if (!handle) return NULL;
    void *ptr = dlsym(handle, symbol);
    if (!ptr) return NULL;
    Dl_info info;
    if (dladdr(ptr, &info) == 0 || info.dli_fname == NULL) return NULL;
    if (strstr(info.dli_fname, expectFramework) == NULL) return NULL;
    return ptr;
}

static void FBPVP9ResolveOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *codecPath = FBPVP9FrameworkBinary(@"libavcodec");
        NSString *utilPath  = FBPVP9FrameworkBinary(@"libavutil");

        // dlopen the already-loaded host images by path; this pins the handle to
        // Facebook's own framework, so WebCore or anything else carrying ffmpeg
        // symbols can never be the one resolved.
        void *hc = dlopen(codecPath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        void *hu = dlopen(utilPath.fileSystemRepresentation,  RTLD_NOW | RTLD_LOCAL);
        if (!hc || !hu) {
            FBPLog(@"vp9: libavcodec/libavutil not dlopenable (codec=%d util=%d) — "
                   @"VP9 tier unavailable", hc != NULL, hu != NULL);
            return;
        }

        FBPVP9Syms s = {0};
        s.find_decoder   = (fb_find_decoder)  FBPVP9ResolveChecked(hc, "avcodec_find_decoder",  "libavcodec.framework");
        s.alloc_context3 = (fb_alloc_context3)FBPVP9ResolveChecked(hc, "avcodec_alloc_context3","libavcodec.framework");
        s.open2          = (fb_open2)         FBPVP9ResolveChecked(hc, "avcodec_open2",         "libavcodec.framework");
        s.send_packet    = (fb_send_packet)   FBPVP9ResolveChecked(hc, "avcodec_send_packet",   "libavcodec.framework");
        s.receive_frame  = (fb_receive_frame) FBPVP9ResolveChecked(hc, "avcodec_receive_frame", "libavcodec.framework");
        s.free_context   = (fb_free_context)  FBPVP9ResolveChecked(hc, "avcodec_free_context",  "libavcodec.framework");
        s.packet_alloc   = (fb_packet_alloc)  FBPVP9ResolveChecked(hc, "av_packet_alloc",       "libavcodec.framework");
        s.packet_free    = (fb_packet_free)   FBPVP9ResolveChecked(hc, "av_packet_free",        "libavcodec.framework");
        s.new_packet     = (fb_new_packet)    FBPVP9ResolveChecked(hc, "av_new_packet",         "libavcodec.framework");
        s.frame_alloc    = (fb_frame_alloc)   FBPVP9ResolveChecked(hu, "av_frame_alloc",        "libavutil.framework");
        s.frame_free     = (fb_frame_free)    FBPVP9ResolveChecked(hu, "av_frame_free",         "libavutil.framework");
        s.frame_unref    = (fb_frame_unref)   FBPVP9ResolveChecked(hu, "av_frame_unref",        "libavutil.framework");

        if (!s.find_decoder || !s.alloc_context3 || !s.open2 || !s.send_packet ||
            !s.receive_frame || !s.free_context || !s.packet_alloc ||
            !s.packet_free || !s.new_packet || !s.frame_alloc || !s.frame_free ||
            !s.frame_unref) {
            FBPLog(@"vp9: a required libavcodec/libavutil symbol was missing or "
                   @"outside the expected framework — VP9 tier unavailable");
            return;
        }

        const void *codec = s.find_decoder(kFBPAVCodecIDVP9);
        if (!codec) {
            FBPLog(@"vp9: avcodec_find_decoder(VP9) returned null — no VP9 decoder "
                   @"in this build; VP9 tier unavailable");
            return;
        }
        s.vp9Codec = codec;

        gSyms = s;
        gResolved = YES;
        FBPLog(@"vp9: borrowed decoder resolved from the host's libavcodec — "
               @"VP9 tier available");
    });
}

#pragma mark - Public C API

BOOL FBPVP9ConversionIsAvailable(void) {
    FBPVP9ResolveOnce();
    return gResolved && !atomic_load_explicit(&gUnhealthy, memory_order_relaxed);
}

void FBPVP9BridgePrewarm(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            FBPVP9ResolveOnce();
        });
    });
}

void FBPVP9BridgeMarkUnhealthy(void) {
    if (!atomic_exchange_explicit(&gUnhealthy, true, memory_order_relaxed)) {
        FBPLog(@"vp9: borrowed decode did not match the source — VP9 tier turned "
               @"off for this process (the host build's ffmpeg layout differs from "
               @"the one assumed)");
    }
}

#pragma mark - Field accessors (reads of library-allocated structs)

static inline void *FBPVP9PtrField(void *base, size_t offset) {
    return *(void **)((char *)base + offset);
}
static inline int FBPVP9IntField(void *base, size_t offset) {
    return *(int *)((char *)base + offset);
}

#pragma mark - Frame -> NV12 CVPixelBuffer

// Build a 420v (8-bit bi-planar video-range 4:2:0) pixel buffer from a planar
// YUV420P AVFrame, interleaving the U/V planes into the single CbCr plane. The
// caller owns the returned buffer. nil on an unsupported pixel format or an
// allocation failure.
static CVPixelBufferRef FBPVP9PixelBufferFromFrame(void *frame) {
    int format = FBPVP9IntField(frame, kAVFrameFormatOffset);
    if (format != kFBPAVPixFmtYUV420P && format != kFBPAVPixFmtYUVJ420P) {
        return NULL;   // 10-bit / 4:2:2 / 4:4:4 are not handled; decline the rung
    }

    int width  = FBPVP9IntField(frame, kAVFrameWidthOffset);
    int height = FBPVP9IntField(frame, kAVFrameHeightOffset);
    // Sanity gate before any pointer is dereferenced: a layout mismatch shows up
    // here as nonsense dimensions, and we refuse rather than read planes.
    if (width < 16 || width > 8192 || height < 16 || height > 8192) return NULL;

    const uint8_t *srcY = FBPVP9PtrField(frame, kAVFrameDataOffset + 0 * sizeof(void *));
    const uint8_t *srcU = FBPVP9PtrField(frame, kAVFrameDataOffset + 1 * sizeof(void *));
    const uint8_t *srcV = FBPVP9PtrField(frame, kAVFrameDataOffset + 2 * sizeof(void *));
    int strideY = FBPVP9IntField(frame, kAVFrameLinesizeOffset + 0 * (int)sizeof(int));
    int strideU = FBPVP9IntField(frame, kAVFrameLinesizeOffset + 1 * (int)sizeof(int));
    int strideV = FBPVP9IntField(frame, kAVFrameLinesizeOffset + 2 * (int)sizeof(int));
    if (!srcY || !srcU || !srcV ||
        strideY < width || strideU < width / 2 || strideV < width / 2) {
        return NULL;
    }

    CVPixelBufferRef pb = NULL;
    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVReturn cr = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                      (__bridge CFDictionaryRef)attrs, &pb);
    if (cr != kCVReturnSuccess || !pb) return NULL;

    CVPixelBufferLockBaseAddress(pb, 0);

    uint8_t *dstY = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    size_t dstStrideY = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    for (int row = 0; row < height; row++) {
        memcpy(dstY + (size_t)row * dstStrideY,
               srcY + (size_t)row * strideY, (size_t)width);
    }

    uint8_t *dstUV = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    size_t dstStrideUV = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    int chromaW = width / 2;
    int chromaH = height / 2;
    for (int row = 0; row < chromaH; row++) {
        uint8_t *d = dstUV + (size_t)row * dstStrideUV;
        const uint8_t *u = srcU + (size_t)row * strideU;
        const uint8_t *v = srcV + (size_t)row * strideV;
        for (int col = 0; col < chromaW; col++) {
            d[2 * col + 0] = u[col];
            d[2 * col + 1] = v[col];
        }
    }

    CVPixelBufferUnlockBaseAddress(pb, 0);

    // Tag HD-typical colour so the encoder does not guess; VP9 web content Meta
    // serves is 8-bit 4:2:0 BT.709. Purely cosmetic — a wrong tag never crashes.
    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey,
                          kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey,
                          kCVImageBufferColorPrimaries_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey,
                          kCVImageBufferTransferFunction_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    return pb;
}

#pragma mark - Decoder object

@implementation FBPVP9Decoder {
    void *_ctx;    // AVCodecContext *
    void *_frame;  // AVFrame *
}

- (instancetype)init {
    if (!FBPVP9ConversionIsAvailable()) return nil;
    if ((self = [super init])) {
        _ctx = gSyms.alloc_context3(gSyms.vp9Codec);
        if (!_ctx) return nil;
        if (gSyms.open2(_ctx, gSyms.vp9Codec, NULL) < 0) {
            gSyms.free_context(&_ctx);
            return nil;
        }
        _frame = gSyms.frame_alloc();
        if (!_frame) {
            gSyms.free_context(&_ctx);
            return nil;
        }
    }
    return self;
}

- (void)dealloc {
    if (_frame) gSyms.frame_free(&_frame);
    if (_ctx)   gSyms.free_context(&_ctx);
}

// Drain every frame the decoder can give right now.
- (void)drainInto:(void (^)(CVPixelBufferRef))handler {
    while (gSyms.receive_frame(_ctx, _frame) == 0) {
        CVPixelBufferRef pb = FBPVP9PixelBufferFromFrame(_frame);
        gSyms.frame_unref(_frame);
        if (pb) {
            if (handler) handler(pb);
            CVPixelBufferRelease(pb);
        }
    }
}

- (BOOL)decodeAccessUnit:(const void *)bytes
                  length:(size_t)length
                 handler:(void (^)(CVPixelBufferRef))handler {
    if (!_ctx || !_frame || length == 0 || length > INT_MAX) return NO;

    void *pkt = gSyms.packet_alloc();
    if (!pkt) return NO;
    if (gSyms.new_packet(pkt, (int)length) < 0) {   // allocates buf + padding
        gSyms.packet_free(&pkt);
        return NO;
    }
    void *dst = FBPVP9PtrField(pkt, kAVPacketDataOffset);
    if (!dst) { gSyms.packet_free(&pkt); return NO; }
    memcpy(dst, bytes, length);

    int sent = gSyms.send_packet(_ctx, pkt);
    gSyms.packet_free(&pkt);
    if (sent < 0) return NO;          // decoder rejected the access unit

    [self drainInto:handler];
    return YES;
}

- (BOOL)flushWithHandler:(void (^)(CVPixelBufferRef))handler {
    if (!_ctx || !_frame) return NO;
    gSyms.send_packet(_ctx, NULL);    // NULL packet = end of stream
    [self drainInto:handler];
    return YES;
}

@end
