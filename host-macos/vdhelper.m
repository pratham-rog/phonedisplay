// vdhelper.m — PhoneDisplay host helper
//
// Milestone 1: creates a *real* virtual display on macOS (a second monitor)
//              using the private CGVirtualDisplay API — the same mechanism
//              DeskPad/BetterDisplay use. Personal use only; not App Store OK.
//
// Milestone 2: captures that display with ScreenCaptureKit, hardware-encodes
//              H.264 with VideoToolbox, and writes a framed NAL stream to
//              stdout for pdctl.py to serve over TCP.
//
// stdout protocol (stream mode — keep stdout strictly binary!):
//   line 1 : "PDH1 <width> <height> <fps> h264\n"
//   frames : uint32_be length | uint8 flags (bit0 = keyframe) | Annex-B NALs
//   cursor : uint32_be length | uint8 flags (0x02) | uint8 visible |
//            int32_be x | int32_be y      (9-byte payload, display pixels)
// all human-readable output goes to stderr in stream mode.
//
// stdin protocol (stream mode — input injection, e.g. from an S-Pen):
//   one command per line:  "I <kind> <buttons> <x> <y>\n"
//   kind 0 = move/hover, 1 = button down, 2 = button up
//   buttons bit0 = secondary button (pen side button → right click)
//   x/y = virtual-display pixels; posted as real macOS mouse events.
//   "F <fps>" caps the capture rate; "K" forces a keyframe on the next frame
//   (sent after a client connects so its delta chain starts clean).
//   Needs Accessibility permission for clicks (moves still work without).
//
// Build: ./build.sh
// Test : ./vdhelper --display-only --seconds 10
//        ./vdhelper --stream --seconds 10 > /tmp/out.h264

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <objc/message.h>
#import <signal.h>
#import <math.h>
#import <unistd.h>
#import <errno.h>
#import <pthread.h>
#import <stdatomic.h>
#include <time.h>

static FILE *gLog = NULL;   // stderr in stream mode, stdout otherwise

#pragma mark - Private API declarations (resolved at runtime)

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, assign) uint32_t serialNum;
@property (nonatomic, assign) uint32_t serialNumber;
@property (nonatomic, assign) uint32_t vendorID;
@property (nonatomic, assign) uint32_t productID;
@property (nonatomic, retain) NSString *name;
@property (nonatomic, assign) uint32_t maxPixelsWide;
@property (nonatomic, assign) uint32_t maxPixelsHigh;
@property (nonatomic, assign) CGPoint whitePoint;
@property (nonatomic, assign) CGPoint redPrimary;
@property (nonatomic, assign) CGPoint greenPrimary;
@property (nonatomic, assign) CGPoint bluePrimary;
@property (nonatomic, assign) CGSize sizeInMillimeters;
@property (nonatomic, retain) dispatch_queue_t queue;
@property (nonatomic, copy) void (^terminationHandler)(id);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, assign) BOOL hiDPI;
@property (nonatomic, retain) NSArray *modes;
@end

@interface CGVirtualDisplay : NSObject
@property (nonatomic, readonly) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

#pragma mark - Small utilities

static NSArray<NSString *> *activeDisplays(void)
{
    uint32_t count = 0;
    if (CGGetActiveDisplayList(0, NULL, &count) != kCGErrorSuccess || count == 0)
        return @[];
    if (count > 32) count = 32;
    CGDirectDisplayID ids[32];
    CGGetActiveDisplayList(count, ids, &count);

    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (uint32_t i = 0; i < count; i++) {
        CGRect b = CGDisplayBounds(ids[i]);
        [out addObject:[NSString stringWithFormat:@"  display %u: %.0fx%.0f at (%.0f,%.0f)%@",
                         ids[i], b.size.width, b.size.height, b.origin.x, b.origin.y,
                         CGDisplayIsMain(ids[i]) ? @"  [main]" : @""]];
    }
    return out;
}

static void printDisplays(const char *tag)
{
    NSArray<NSString *> *displays = activeDisplays();
    fprintf(gLog, "%s (%lu active):\n", tag, (unsigned long)displays.count);
    for (NSString *line in displays)
        fprintf(gLog, "%s\n", line.UTF8String);
    fflush(gLog);
}

static BOOL writeAll(int fd, const void *bytes, size_t len)
{
    const uint8_t *p = bytes;
    while (len > 0) {
        ssize_t n = write(fd, p, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        p += n;
        len -= (size_t)n;
    }
    return YES;
}

#pragma mark - VDStreamer: ScreenCaptureKit → VideoToolbox → stdout

@interface VDStreamer : NSObject <SCStreamOutput, SCStreamDelegate>
// softwareCursor (default): the system cursor is NOT baked into the video;
// instead tiny cursor packets stream its position and the phone draws its
// own (scalable, smooth) pointer. Set NO for the old baked-in cursor.
@property (nonatomic, assign) BOOL softwareCursor;
- (BOOL)startWithDisplayID:(CGDirectDisplayID)displayID
                     width:(uint32_t)width
                    height:(uint32_t)height
                       fps:(uint32_t)fps
               bitrateMbps:(double)mbps;
- (void)ensureTargetMode;
@end

// Pen taps arrive as independent down/up commands, so the helper has to
// reconstruct macOS's click sequence itself: a second left-down close in time
// and space to the previous one must carry kCGMouseEventClickState = 2 (third
// = 3), otherwise every tap is a single click and double-click never works.
static CFAbsoluteTime monoNow(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (CFAbsoluteTime)ts.tv_sec + (CFAbsoluteTime)ts.tv_nsec / 1e9;
}

static CFTimeInterval doubleClickInterval(void)
{
    CFTimeInterval t = 0.5;
    CFPropertyListRef v = CFPreferencesCopyAppValue(
        CFSTR("com.apple.mouse.doubleClickThreshold"), kCFPreferencesAnyApplication);
    if (v) {
        if (CFGetTypeID(v) == CFNumberGetTypeID()) {
            double d = 0;
            if (CFNumberGetValue((CFNumberRef)v, kCFNumberDoubleType, &d) &&
                d >= 0.1 && d <= 2.0)
                t = d;
        }
        CFRelease(v);
    }
    return t;
}

@implementation VDStreamer {
    SCStream *_stream;
    VTCompressionSessionRef _vt;
    dispatch_queue_t _queue;
    pthread_mutex_t _outLock;
    int _outFd;
    uint32_t _fps;
    uint64_t _fedFrames;        // frames SCK handed us
    uint64_t _outFrames;        // frames VT encoded out
    uint64_t _lastFedStats, _lastOutStats;
    dispatch_source_t _statsTimer;
    SCStreamConfiguration *_cfg;   // kept for live reconfiguration
    uint32_t _captureFps;          // rate cap applied via stdin "F <fps>" (0 = CLI default)
    BOOL _firstFrame;
    _Atomic(bool) _forceKeyframe;   // set by stdin "K" (a client just joined)
    BOOL _loggedEncodeError;
    dispatch_source_t _synthTimer;
    uint32_t _synthWidth, _synthHeight;
    uint64_t _synthIndex;
    uint8_t *_synthRow;
    dispatch_source_t _cursorTimer;
    dispatch_queue_t _cursorQueue;
    CGDirectDisplayID _vdDisplayID;   // bounds are queried live (user can rearrange)
    uint32_t _vdWidth, _vdHeight;
    BOOL _haveLastCursor;
    BOOL _lastCursorVisible;
    int32_t _lastCursorX, _lastCursorY;
    CFTimeInterval _lastCursorSentAt;
    int _heldButton;          // -1 = none, 0 = left, 1 = right (input injection)
    int _leftClickCount;      // 1 = single, 2 = double, 3 = triple
    CFAbsoluteTime _lastLeftDownAt;
    CGPoint _lastLeftDownPoint;
    BOOL _loggedInject;
    BOOL _warnedNoAccess;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _queue = dispatch_queue_create("pd.stream", DISPATCH_QUEUE_SERIAL);
        pthread_mutex_init(&_outLock, NULL);
        _outFd = 1;  // stdout
        _firstFrame = YES;
        _softwareCursor = YES;   // phone draws its own scalable pointer
        _heldButton = -1;
    }
    return self;
}

#pragma mark encode output

static void vtOutputCallback(void *refcon, void *sourceRefCon,
                             OSStatus status, VTEncodeInfoFlags flags,
                             CMSampleBufferRef sbuf)
{
    @autoreleasepool {
        VDStreamer *streamer = (__bridge VDStreamer *)refcon;
        [streamer handleEncodedSampleBuffer:sbuf status:status];
    }
}

- (void)handleEncodedSampleBuffer:(CMSampleBufferRef)sbuf status:(OSStatus)status
{
    if (status != noErr || !sbuf || !CMSampleBufferDataIsReady(sbuf))
        return;
    _outFrames++;

    // keyframe? (no kCMSampleAttachmentKey_NotSync attachment => keyframe)
    BOOL keyframe = YES;
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sbuf, false);
    if (atts && CFArrayGetCount(atts) > 0) {
        NSDictionary *d = (__bridge NSDictionary *)CFArrayGetValueAtIndex(atts, 0);
        keyframe = !((NSNumber *)d[(__bridge NSString *)kCMSampleAttachmentKey_NotSync]).boolValue;
    }

    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sbuf);
    if (!bb) return;
    size_t totalLen = CMBlockBufferGetDataLength(bb);
    if (totalLen == 0) return;

    uint8_t *raw = malloc(totalLen);
    if (!raw) return;
    if (CMBlockBufferCopyDataBytes(bb, 0, totalLen, raw) != kCMBlockBufferNoErr) {
        free(raw);
        return;
    }

    static const uint8_t startCode[4] = { 0x00, 0x00, 0x00, 0x01 };
    NSMutableData *au = [NSMutableData dataWithCapacity:totalLen + 128];

    // On keyframes, prepend SPS/PPS as Annex-B so decoders can start anywhere.
    if (keyframe) {
        CMVideoFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sbuf);
        for (int i = 0; fmt && i < 2; i++) {
            const uint8_t *ps = NULL; size_t psLen = 0, paramCount = 0;
            int nalHdrLen = 0;
            if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, i, &ps, &psLen,
                                                                   &paramCount, &nalHdrLen) == noErr) {
                [au appendBytes:startCode length:4];
                [au appendBytes:ps length:psLen];
            }
        }
    }

    // AVCC length-prefixed NALs -> Annex-B start codes
    size_t off = 0;
    while (off + 4 <= totalLen) {
        uint32_t nalLen = ((uint32_t)raw[off] << 24) | ((uint32_t)raw[off + 1] << 16) |
                          ((uint32_t)raw[off + 2] << 8) | (uint32_t)raw[off + 3];
        off += 4;
        if (nalLen == 0 || off + nalLen > totalLen) break;
        [au appendBytes:startCode length:4];
        [au appendBytes:raw + off length:nalLen];
        off += nalLen;
    }
    free(raw);

    // frame header: uint32_be length | uint8 flags
    uint32_t len32 = (uint32_t)au.length;
    uint8_t hdr[5] = {
        (uint8_t)(len32 >> 24), (uint8_t)((len32 >> 16) & 0xFF),
        (uint8_t)((len32 >> 8) & 0xFF), (uint8_t)(len32 & 0xFF),
        (uint8_t)(keyframe ? 0x01 : 0x00)
    };

    pthread_mutex_lock(&_outLock);
    BOOL ok = writeAll(_outFd, hdr, 5) && writeAll(_outFd, au.bytes, au.length);
    pthread_mutex_unlock(&_outLock);

    if (!ok) {
        fprintf(stderr, "stdout write failed — consumer gone, exiting\n");
        exit(0);
    }
}

#pragma mark - stats

// Every 2 s: how many frames ScreenCaptureKit delivered vs how many the
// encoder produced. Splits "capture is slow" from "encoder is slow".
- (void)startStatsTimer
{
    if (_statsTimer) return;
    // Own queue: under high frame rates the capture queue is continuously busy,
    // and a timer sharing it can starve for many seconds (seen at 110 fps).
    dispatch_queue_t statsQ = dispatch_queue_create("pd.stats", DISPATCH_QUEUE_SERIAL);
    _statsTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, statsQ);
    __weak VDStreamer *weakSelf = self;
    dispatch_source_set_timer(_statsTimer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                              2 * NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(_statsTimer, ^{
        VDStreamer *s = weakSelf;
        if (!s) return;
        double fedFps = (s->_fedFrames - s->_lastFedStats) / 2.0;
        double outFps = (s->_outFrames - s->_lastOutStats) / 2.0;
        s->_lastFedStats = s->_fedFrames;
        s->_lastOutStats = s->_outFrames;
        fprintf(stderr, "capture: fed %.1f fps, encoded %.1f fps\n", fedFps, outFps);
    });
    dispatch_resume(_statsTimer);
}

#pragma mark cursor packets

// Cursor packets share the frame framing: u32 length | u8 flags (0x02)
// | u8 visible | int32be x | int32be y. Coordinates are virtual-display
// pixels; pdctl forwards them untouched and the phone draws its own
// pointer, so cursor smoothness is independent of the video stream.

- (void)sendCursorPacketVisible:(BOOL)visible x:(int32_t)x y:(int32_t)y
{
    uint32_t len = 9;
    uint8_t hdr[5] = {
        (uint8_t)(len >> 24), (uint8_t)((len >> 16) & 0xFF),
        (uint8_t)((len >> 8) & 0xFF), (uint8_t)(len & 0xFF),
        0x02
    };
    uint8_t payload[9];
    payload[0] = visible ? 1 : 0;
    payload[1] = (uint8_t)(x >> 24); payload[2] = (uint8_t)((x >> 16) & 0xFF);
    payload[3] = (uint8_t)((x >> 8) & 0xFF); payload[4] = (uint8_t)(x & 0xFF);
    payload[5] = (uint8_t)(y >> 24); payload[6] = (uint8_t)((y >> 16) & 0xFF);
    payload[7] = (uint8_t)((y >> 8) & 0xFF); payload[8] = (uint8_t)(y & 0xFF);

    pthread_mutex_lock(&_outLock);
    BOOL ok = writeAll(_outFd, hdr, 5) && writeAll(_outFd, payload, 9);
    pthread_mutex_unlock(&_outLock);
    if (!ok) {
        fprintf(stderr, "stdout write failed — consumer gone, exiting\n");
        exit(0);
    }
}

- (void)pollCursor
{
    CGEventRef ev = CGEventCreate(NULL);
    if (!ev) return;
    CGPoint m = CGEventGetLocation(ev);   // global coords, top-left origin
    CFRelease(ev);

    CGRect vb = CGDisplayBounds(_vdDisplayID);   // follows arrangement changes
    double lx = m.x - vb.origin.x;
    double ly = m.y - vb.origin.y;
    BOOL inBounds = (lx >= -0.5 && lx < (double)_vdWidth &&
                     ly >= -0.5 && ly < (double)_vdHeight);

    int32_t x = 0, y = 0;
    if (inBounds) {
        x = (int32_t)llround(lx);
        y = (int32_t)llround(ly);
        if (x < 0) x = 0;
        if (x >= (int32_t)_vdWidth)  x = (int32_t)_vdWidth - 1;
        if (y < 0) y = 0;
        if (y >= (int32_t)_vdHeight) y = (int32_t)_vdHeight - 1;
    }

    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    BOOL changed = !_haveLastCursor || inBounds != _lastCursorVisible ||
                   (inBounds && (x != _lastCursorX || y != _lastCursorY));
    BOOL heartbeat = (now - _lastCursorSentAt) >= 1.0;   // keeps clients fresh
    if (!changed && !heartbeat) return;

    [self sendCursorPacketVisible:inBounds x:x y:y];
    _haveLastCursor = YES;
    _lastCursorVisible = inBounds;
    _lastCursorX = x;
    _lastCursorY = y;
    _lastCursorSentAt = now;
}

#pragma mark input injection (stdin → CGEventPost)

// stdin command, one per line: "I <kind> <buttons> <x> <y>"
//   kind 0 = move/hover, 1 = button down, 2 = button up
//   buttons bit0 set = pen side button → right click
// and "F <fps>" — live capture frame-rate cap (used by the phone's
// 60/90 fps selector; SCK is change-driven, so this never creates frames,
// it only stops capping below (or faster than) the display cadence).
- (void)handleStdinLine:(const char *)line
{
    if (line[0] == 'F') {
        [self setCaptureFpsLine:line];
        return;
    }
    if (line[0] == 'K') {
        // A client just finished its handshake. Force a keyframe on the next
        // captured frame so its live delta chain starts from a clean state,
        // even if a frame or two went by while its GOP was being sent.
        atomic_store(&_forceKeyframe, true);
        return;
    }
    [self injectInputLine:line];
}

- (void)setCaptureFpsLine:(const char *)line
{
    int fps = 0;
    if (sscanf(line, "F %d", &fps) != 1) return;
    [self setCaptureFps:(uint32_t)fps];
}

- (void)setCaptureFps:(uint32_t)fps
{
    if (fps < 10) fps = 10;
    if (fps > 240) fps = 240;
    if (!_stream || !_cfg || _captureFps == fps) return;
    _captureFps = fps;
    _cfg.minimumFrameInterval = CMTimeMakeWithSeconds(0.9 / fps, 1000000);
    [_stream updateConfiguration:_cfg completionHandler:^(NSError *err) {
        if (err)
            fprintf(stderr, "capture rate %u fps: update failed: %s\n",
                    fps, err.localizedDescription.UTF8String);
        else
            fprintf(stderr, "capture rate → %u fps\n", fps);
    }];
    VTSessionSetProperty(_vt, kVTCompressionPropertyKey_ExpectedFrameRate,
                         (__bridge CFTypeRef)@(fps));
}

- (void)injectInputLine:(const char *)line
{
    int kind = -1, buttons = 0, x = 0, y = 0;
    if (sscanf(line, "I %d %d %d %d", &kind, &buttons, &x, &y) != 4) return;
    [self injectInputKind:kind buttons:buttons x:x y:y];
}

- (void)injectInputKind:(int)kind buttons:(int)buttons x:(int)x y:(int)y
{
    if (kind < 0 || kind > 2) return;
    if (!_loggedInject) {
        _loggedInject = YES;
        fprintf(stderr, "input: injecting events received from the phone\n");
    }

    if (x < 0) x = 0;
    if (x >= (int)_vdWidth)  x = (int)_vdWidth - 1;
    if (y < 0) y = 0;
    if (y >= (int)_vdHeight) y = (int)_vdHeight - 1;
    CGRect vb = CGDisplayBounds(_vdDisplayID);   // follows arrangement changes
    CGPoint pt = CGPointMake(vb.origin.x + x, vb.origin.y + y);

    CGEventType type;
    int button;                       // 0 = left, 1 = right
    if (kind == 1) {                  // button down: side button held → right
        button = (buttons & 1) ? 1 : 0;
        _heldButton = button;
        type = button ? kCGEventRightMouseDown : kCGEventLeftMouseDown;
    } else if (kind == 2) {           // button up
        button = _heldButton >= 0 ? _heldButton : 0;
        _heldButton = -1;
        type = button ? kCGEventRightMouseUp : kCGEventLeftMouseUp;
    } else {                          // move (a held button makes it a drag)
        button = _heldButton >= 0 ? _heldButton : 0;
        type = _heldButton == 1 ? kCGEventRightMouseDragged
             : _heldButton == 0 ? kCGEventLeftMouseDragged
             : kCGEventMouseMoved;
    }

    // Reconstruct the click sequence: 1 = single, 2 = double, 3 = triple.
    int clickState = 1;
    if (kind == 1 && button == 0) {
        CFAbsoluteTime now = monoNow();
        BOOL near = _leftClickCount > 0 &&
                    hypot(pt.x - _lastLeftDownPoint.x,
                          pt.y - _lastLeftDownPoint.y) <= 4.0;
        if (_leftClickCount > 0 && near &&
            now - _lastLeftDownAt <= doubleClickInterval())
            _leftClickCount = MIN(_leftClickCount + 1, 3);
        else
            _leftClickCount = 1;
        _lastLeftDownAt = now;
        _lastLeftDownPoint = pt;
        clickState = _leftClickCount;
    } else if (kind == 2 && button == 0) {
        clickState = _leftClickCount > 0 ? _leftClickCount : 1;
    } else if (kind == 1 || kind == 2) {
        _leftClickCount = 0;          // a right click ends a left-click sequence
    }

    if (CGPreflightPostEventAccess()) {
        CGEventRef ev = CGEventCreateMouseEvent(
            NULL, type, pt, button ? kCGMouseButtonRight : kCGMouseButtonLeft);
        if (!ev) return;
        // Without a click-state macOS delivers the events as hovers: the
        // pointer moves, but buttons/menus never activate. The state must
        // also advance for the second down of a double-click.
        CGEventSetIntegerValueField(ev, kCGMouseEventClickState, clickState);
        CGEventPost(kCGHIDEventTap, ev);
        CFRelease(ev);
    } else {
        // No Accessibility permission: posts are silently dropped by macOS,
        // but we can still move the visible pointer so position/hover stay
        // useful. Ask once — that is what triggers the system prompt.
        CGWarpMouseCursorPosition(pt);
        if (!_warnedNoAccess) {
            _warnedNoAccess = YES;
            fprintf(stderr,
                "input: macOS is not letting vdhelper post click events.\n"
                "       Grant Accessibility to the app running the stream\n"
                "       (System Settings > Privacy & Security > Accessibility),\n"
                "       then clicks work again — pointer moves work meanwhile.\n");
            CGRequestPostEventAccess();
        }
    }
}

#pragma mark SCStreamOutput / SCStreamDelegate

- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sbuf
                   ofType:(SCStreamOutputType)type
{
    if (type != SCStreamOutputTypeScreen) return;
    if (!_vt) return;

    // only complete frames
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sbuf, false);
    if (atts && CFArrayGetCount(atts) > 0) {
        NSDictionary *d = (__bridge NSDictionary *)CFArrayGetValueAtIndex(atts, 0);
        NSNumber *statusNum = d[SCStreamFrameInfoStatus];
        if (statusNum && statusNum.intValue != SCFrameStatusComplete)
            return;
    }

    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sbuf);
    if (!pb) return;

    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sbuf);
    CMTime dur = CMTimeMake(1, _fps > 0 ? (int32_t)_fps : 60);

    NSDictionary *props = nil;
    bool force = atomic_exchange(&_forceKeyframe, false);
    if (_firstFrame || force) {
        props = @{ (__bridge NSString *)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES };
        _firstFrame = NO;
    }

    _fedFrames++;
    OSStatus st = VTCompressionSessionEncodeFrame(
        _vt, pb, pts, dur,
        props ? (__bridge CFDictionaryRef)props : NULL,
        NULL, NULL);
    if (st != noErr && !_loggedEncodeError) {
        fprintf(stderr, "VTCompressionSessionEncodeFrame failed: %d\n", (int)st);
        _loggedEncodeError = YES;
    }
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error
{
    fprintf(stderr, "SCK stream stopped: %s\n", error.localizedDescription.UTF8String);
    exit(6);
}

#pragma mark start

- (BOOL)setupEncoderWidth:(uint32_t)width
                   height:(uint32_t)height
                      fps:(uint32_t)fps
              bitrateMbps:(double)mbps
{
    _fps = fps;

    // ---- VideoToolbox: H.264, low latency, hardware accelerated ---------
    // EnableLowLatencyRateControl: dedicated low-delay rate control on
    // Apple silicon (macOS 13+) — no encode-side frame buffering. The
    // (proper) combination with RealTime below keeps glass-to-glass low.
    NSDictionary *spec = @{
        (__bridge NSString *)kVTVideoEncoderSpecification_EnableLowLatencyRateControl: @YES
    };
    OSStatus st = VTCompressionSessionCreate(
        NULL, (int32_t)width, (int32_t)height, kCMVideoCodecType_H264,
        (__bridge CFDictionaryRef)spec, NULL, NULL, vtOutputCallback, (__bridge void *)self, &_vt);
    if (st != noErr || !_vt) {
        fprintf(stderr, "VTCompressionSessionCreate failed: %d\n", (int)st);
        return NO;
    }

    void (^setProp)(CFStringRef, id) = ^(CFStringRef key, id value) {
        VTSessionSetProperty(_vt, key, (__bridge CFTypeRef)value);
    };
    setProp(kVTCompressionPropertyKey_RealTime, @YES);
    setProp(kVTCompressionPropertyKey_ExpectedFrameRate, @(fps));
    setProp(kVTCompressionPropertyKey_AverageBitRate, @(mbps * 1e6));
    setProp(kVTCompressionPropertyKey_DataRateLimits, @[ @(mbps * 1e6 / 8.0 * 1.2), @1.0 ]);
    setProp(kVTCompressionPropertyKey_AllowFrameReordering, @NO);
    setProp(kVTCompressionPropertyKey_MaxKeyFrameInterval, @((int)fps * 2));
    setProp(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, @2.0);
    setProp(kVTCompressionPropertyKey_ProfileLevel, (__bridge id)kVTProfileLevel_H264_High_AutoLevel);
    setProp(kVTCompressionPropertyKey_H264EntropyMode, (__bridge id)kVTH264EntropyMode_CABAC);

    VTCompressionSessionPrepareToEncodeFrames(_vt);
    return YES;
}

- (BOOL)startWithDisplayID:(CGDirectDisplayID)displayID
                     width:(uint32_t)width
                    height:(uint32_t)height
                       fps:(uint32_t)fps
               bitrateMbps:(double)mbps
{
    if (![self setupEncoderWidth:width height:height fps:fps bitrateMbps:mbps])
        return NO;

    // ---- ScreenCaptureKit: locate our freshly created display -----------
    SCDisplay *target = nil;
    for (int attempt = 0; attempt < 20 && !target; attempt++) {
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block SCShareableContent *content = nil;
        __block NSError *err = nil;
        [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *c, NSError *e) {
            content = c;
            err = e;
            dispatch_semaphore_signal(sem);
        }];
        if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0) {
            fprintf(stderr, "SCK: timeout listing shareable content\n");
            return NO;
        }
        if (err) {
            fprintf(stderr, "SCK error: %s\n", err.localizedDescription.UTF8String);
            return NO;
        }
        for (SCDisplay *d in content.displays) {
            if (d.displayID == displayID) { target = d; break; }
        }
        if (!target) usleep(300000);  // let WindowServer register the new display
    }
    if (!target) {
        fprintf(stderr,
                "SCK: display %u not found in shareable content.\n"
                "     If macOS asked you to allow Screen Recording, grant it to your\n"
                "     terminal app (System Settings > Privacy & Security > Screen\n"
                "     Recording), then run again.\n", displayID);
        return NO;
    }

    SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:target excludingWindows:@[]];

    _cfg = [[SCStreamConfiguration alloc] init];
    _cfg.width = width;
    _cfg.height = height;
    _cfg.pixelFormat = kCVPixelFormatType_32BGRA;
    // Slightly under the nominal frame period: with the interval set exactly
    // at the display cadence (e.g. 1/90 on a 90 Hz panel), SCK rejects any
    // composite that arrives a hair early due to vsync jitter — measured ~8%
    // of frames lost (90 Hz panel delivered ~82.5 fps). A 10% margin below
    // the cadence accepts every composite (measured: steady 90.0 fps);
    // SCK is change-driven, so a lower gate never creates extra frames.
    _cfg.minimumFrameInterval = CMTimeMakeWithSeconds(0.9 / (fps > 0 ? fps : 60), 1000000);
    _cfg.queueDepth = 4;   // small: under overload SCK drops frames (good for
                           // latency) instead of buffering up to ~100ms of them
    _cfg.showsCursor = !_softwareCursor;
    _cfg.scalesToFit = NO;
    _cfg.colorSpaceName = kCGColorSpaceSRGB;

    _stream = [[SCStream alloc] initWithFilter:filter configuration:_cfg delegate:self];
    NSError *e = nil;
    if (![_stream addStreamOutput:self type:SCStreamOutputTypeScreen
              sampleHandlerQueue:_queue error:&e]) {
        fprintf(stderr, "SCK addStreamOutput: %s\n", e.localizedDescription.UTF8String);
        return NO;
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSError *startErr = nil;
    [_stream startCaptureWithCompletionHandler:^(NSError *err2) {
        startErr = err2;
        dispatch_semaphore_signal(sem);
    }];
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)) != 0
        || startErr) {
        fprintf(stderr, "SCK startCapture: %s\n",
                startErr ? startErr.localizedDescription.UTF8String : "timeout");
        return NO;
    }

    _vdDisplayID = displayID;
    _vdWidth = width;
    _vdHeight = height;

    // The stream, cursor and input mapping all assume exactly this pixel size.
    // macOS can restore a remembered mode at creation; pdctl also watches for
    // the user changing it in Displays and sends "M" to put it back.
    [self ensureTargetMode];

    if (_softwareCursor) {
        _cursorQueue = dispatch_queue_create("pd.cursor", DISPATCH_QUEUE_SERIAL);
        _cursorTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _cursorQueue);
        uint64_t interval = NSEC_PER_SEC / 60;
        dispatch_source_set_timer(_cursorTimer, DISPATCH_TIME_NOW, interval, interval / 2);
        __weak VDStreamer *weakSelf = self;
        dispatch_source_set_event_handler(_cursorTimer, ^{ [weakSelf pollCursor]; });
        dispatch_resume(_cursorTimer);
    }

    fprintf(stderr, "streaming started (H.264 %.0f Mbps%s)\n", mbps,
            _softwareCursor ? ", software cursor" : "");
    [self startStatsTimer];
    return YES;
}

- (void)ensureTargetMode
{
    if (!_vdDisplayID) return;
    CGDisplayModeRef cur = CGDisplayCopyDisplayMode(_vdDisplayID);
    if (cur) {
        BOOL rightSize = CGDisplayModeGetPixelWidth(cur) == _vdWidth &&
                         CGDisplayModeGetPixelHeight(cur) == _vdHeight;
        CFRelease(cur);
        if (rightSize) return;
    }
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(_vdDisplayID, NULL);
    if (!modes) return;
    CGDisplayModeRef want = NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(modes); i++) {
        CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        if (CGDisplayModeGetPixelWidth(m) == _vdWidth &&
            CGDisplayModeGetPixelHeight(m) == _vdHeight) {
            want = m;
            break;
        }
    }
    if (want) {
        CGError e = CGDisplaySetDisplayMode(_vdDisplayID, want, NULL);
        fprintf(stderr, "display mode restored to %ux%u (%s)\n", _vdWidth, _vdHeight,
                e == kCGErrorSuccess ? "ok" : "failed");
    } else {
        fprintf(stderr, "warning: display mode %ux%u is not offered\n", _vdWidth, _vdHeight);
    }
    CFRelease(modes);
}

#pragma mark synthetic test source

- (BOOL)startSyntheticWithWidth:(uint32_t)width
                         height:(uint32_t)height
                            fps:(uint32_t)fps
                    bitrateMbps:(double)mbps
{
    if (![self setupEncoderWidth:width height:height fps:fps bitrateMbps:mbps])
        return NO;

    _synthWidth = width;
    _synthHeight = height;
    _synthRow = malloc((size_t)width * 4);

    _synthTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    uint64_t interval = NSEC_PER_SEC / (fps > 0 ? fps : 60);
    dispatch_source_set_timer(_synthTimer, DISPATCH_TIME_NOW, interval, 0);
    __weak VDStreamer *weakSelf = self;
    dispatch_source_set_event_handler(_synthTimer, ^{ [weakSelf emitSyntheticFrame]; });
    dispatch_resume(_synthTimer);

    fprintf(stderr, "synthetic stream started (test pattern, no screen capture)\n");
    [self startStatsTimer];
    return YES;
}

- (void)emitSyntheticFrame
{
    if (!_vt || !_synthRow) return;

    CVPixelBufferRef pb = NULL;
    NSDictionary *attrs = @{ (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{} };
    if (CVPixelBufferCreate(kCFAllocatorDefault, _synthWidth, _synthHeight,
                            kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess || !pb)
        return;

    // colors in B,G,R order (matches BGRA pixel format)
    static const uint8_t bars[8][3] = {
        {255,255,255},  // white
        {255,255,0  },  // cyan
        {0,  255,255},  // yellow
        {0,  255,0  },  // green
        {255,0,  255},  // magenta
        {0,  0,  255},  // red
        {255,0,  0  },  // blue
        {0,  0,  0  }   // black
    };

    uint32_t shift = (uint32_t)((_synthIndex * 4) % _synthWidth);
    for (uint32_t x = 0; x < _synthWidth; x++) {
        uint32_t bx = x + shift;
        if (bx >= _synthWidth) bx -= _synthWidth;
        const uint8_t *c = bars[(bx * 8) / _synthWidth];
        _synthRow[x * 4 + 0] = c[0];
        _synthRow[x * 4 + 1] = c[1];
        _synthRow[x * 4 + 2] = c[2];
        _synthRow[x * 4 + 3] = 255;
    }

    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
    size_t stride = CVPixelBufferGetBytesPerRow(pb);
    for (uint32_t y = 0; y < _synthHeight; y++)
        memcpy(base + (size_t)y * stride, _synthRow, (size_t)_synthWidth * 4);

    // moving white box so motion is obvious
    uint32_t boxX = (uint32_t)((_synthIndex * 12) % (_synthWidth > 120 ? _synthWidth - 120 : 1));
    uint32_t boxY = _synthHeight > 100 ? _synthHeight / 2 - 50 : 0;
    for (uint32_t y = boxY; y < boxY + 100 && y < _synthHeight; y++) {
        uint8_t *row = base + (size_t)y * stride;
        memset(row + (size_t)boxX * 4, 0xFF, 100 * 4);
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);

    CMTime pts = CMTimeMake((int64_t)(_synthIndex * (1000.0 / _fps)), 1000);
    CMTime dur = CMTimeMake(1, (int32_t)_fps);
    NSDictionary *props = nil;
    bool force = atomic_exchange(&_forceKeyframe, false);
    if (_firstFrame || force) {
        props = @{ (__bridge NSString *)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES };
        _firstFrame = NO;
    }
    VTCompressionSessionEncodeFrame(_vt, pb, pts, dur,
                                    props ? (__bridge CFDictionaryRef)props : NULL, NULL, NULL);
    CVPixelBufferRelease(pb);
    _synthIndex++;
}

@end

static VDStreamer *gStreamer = nil;
static CGVirtualDisplay *gDisplay = nil;
static dispatch_source_t gInputSource = nil;   // must outlive main()'s scope

#pragma mark - main

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        gLog = stdout;

        // Launched by double-click (Finder) or without arguments? Refuse to
        // create a display nobody asked for — pdctl always passes options.
        if (argc == 1) {
            fprintf(stderr,
                "vdhelper is driven by pdctl; do not launch it directly.\n"
                "  python3 pdctl.py display      # virtual monitor only\n"
                "  python3 pdctl.py stream ...   # monitor + stream to the phone\n");
            return 64;
        }

        // ---- defaults / options ------------------------------------------
        uint32_t width = 1920, height = 1080;
        double refresh = 60.0;
        double inches  = 6.5;      // pretend the panel is phone-sized (sets DPI)
        BOOL hidpi     = NO;
        int seconds    = 0;        // >0: exit automatically (for testing)
        uint32_t fps   = 60;
        double bitrate = 10.0;     // Mbps
        BOOL streamMode = NO;
        BOOL syntheticMode = NO;
        BOOL hwCursor = NO;
        NSString *name = @"PhoneDisplay";

        for (int i = 1; i < argc; i++) {
            NSString *a = @(argv[i]);
            #define ARG() ((i + 1 < argc) ? @(argv[++i]) : nil)
            if      ([a isEqualToString:@"--width"])   width   = (uint32_t)ARG().intValue;
            else if ([a isEqualToString:@"--height"])  height  = (uint32_t)ARG().intValue;
            else if ([a isEqualToString:@"--refresh"]) refresh = ARG().doubleValue;
            else if ([a isEqualToString:@"--inches"])  inches  = ARG().doubleValue;
            else if ([a isEqualToString:@"--seconds"]) seconds = ARG().intValue;
            else if ([a isEqualToString:@"--fps"])     fps     = (uint32_t)ARG().intValue;
            else if ([a isEqualToString:@"--bitrate"]) bitrate = ARG().doubleValue;
            else if ([a isEqualToString:@"--name"])    name    = ARG();
            else if ([a isEqualToString:@"--hidpi"])   hidpi   = YES;
            else if ([a isEqualToString:@"--stream"])  streamMode = YES;
            else if ([a isEqualToString:@"--hw-cursor"]) hwCursor = YES;
            else if ([a isEqualToString:@"--synthetic"]) { syntheticMode = YES; streamMode = YES; }
            else if ([a isEqualToString:@"--display-only"]) { /* milestone 1 default */ }
            else {
                fprintf(stderr, "usage: vdhelper [--stream] [--synthetic] [--width N] [--height N]\n"
                                "                [--refresh Hz] [--fps N] [--bitrate Mbps] [--inches D]\n"
                                "                [--hidpi] [--name S] [--seconds N] [--hw-cursor]\n");
                return 64;
            }
            #undef ARG
        }

        if (streamMode)
            gLog = stderr;   // stdout is reserved for the binary frame stream

        // ---- availability check (skipped for the synthetic test source) ----
        if (!syntheticMode &&
            (!NSClassFromString(@"CGVirtualDisplayDescriptor") ||
             !NSClassFromString(@"CGVirtualDisplay"))) {
            fprintf(stderr,
                "error: CGVirtualDisplay private API not available on this macOS version.\n"
                "       (Plan B would be a DriverKit system extension — more involved.)\n");
            return 2;
        }

        fprintf(gLog, "PhoneDisplay host helper\n");

        CGDirectDisplayID did = 0;   // set when a virtual display is created
        if (!syntheticMode) {
        printDisplays("before");

        // ---- build descriptor ---------------------------------------------
        Class descCls = NSClassFromString(@"CGVirtualDisplayDescriptor");
        CGVirtualDisplayDescriptor *desc = [[descCls alloc] init];

        desc.name = name;

        // Required on modern macOS: a *unique* display identity.
        // Duplicate vendor/product/serial combinations are rejected (init → nil).
        // Derive it from the name and size instead of randomizing: macOS keys
        // the remembered arrangement (and mode) by this identity, so a random
        // serial made every run look like a brand-new monitor and reset the
        // user's layout. Different names/sizes still get different identities.
        uint32_t serial = 2166136261u;                      // FNV-1a
        for (const char *p = name.UTF8String; p && *p; p++)
            serial = (serial ^ (uint8_t)*p) * 16777619u;
        serial ^= width  * 73856093u;
        serial ^= height * 19349663u;
        serial &= 0x7FFFFFFF;
        if (serial == 0) serial = 1;
        desc.vendorID     = 0x5044;  // 'PD'
        desc.productID    = 0x0001;
        desc.serialNumber = serial;
        desc.serialNum    = serial;

        // Offer a few resolutions up to the max so the user can pick in
        // System Settings; the first mode is the default.
        desc.maxPixelsWide = width;
        desc.maxPixelsHigh = height;

        // Phone-sized panel: compute physical mm from pixel size + diagonal.
        double diagPx    = sqrt((double)width * width + (double)height * height);
        double widthMm   = inches * 25.4 * (double)width  / diagPx;
        double heightMm  = inches * 25.4 * (double)height / diagPx;
        desc.sizeInMillimeters = CGSizeMake(widthMm, heightMm);

        // sRGB-ish primaries (same values virtual-display projects commonly use)
        desc.whitePoint   = CGPointMake(0.950, 1.000);
        desc.redPrimary   = CGPointMake(0.454, 0.242);
        desc.greenPrimary = CGPointMake(0.135, 0.658);
        desc.bluePrimary  = CGPointMake(0.156, 0.058);

        desc.queue = dispatch_get_main_queue();
        desc.terminationHandler = ^(id d) {
            fprintf(gLog, "virtual display terminated by system\n");
            exit(7);   // pdctl sees the exit and recreates the display
        };

        // ---- create display ------------------------------------------------
        CGVirtualDisplay *display =
            [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:desc];
        if (!display) {
            fprintf(stderr, "error: failed to create virtual display\n");
            return 3;
        }

        // ---- apply mode(s) -------------------------------------------------
        CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
        settings.hiDPI = hidpi;
        settings.modes = @[
            [[NSClassFromString(@"CGVirtualDisplayMode") alloc]
                initWithWidth:width height:height refreshRate:refresh]
        ];

        BOOL ok = NO;
        if ([display respondsToSelector:@selector(applySettings:)])
            ok = [display applySettings:settings];
        else if ([display respondsToSelector:NSSelectorFromString(@"apply:")])
            ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(display, NSSelectorFromString(@"apply:"), settings);

        did = display.displayID;
        CGRect db = CGDisplayBounds(did);
        fprintf(gLog, "virtual display created: id=%u  %ux%u @ %.0fHz%s  (%.0fmm x %.0fmm panel)\n",
                did, (unsigned)db.size.width, (unsigned)db.size.height, refresh,
                hidpi ? " HiDPI" : "", widthMm, heightMm);
        fprintf(gLog, "applySettings: %s\n", ok ? "ok" : "returned NO (display may still be active)");

        usleep(500000);  // give WindowServer a beat to register it
        printDisplays("after ");
        gDisplay = display;
        }   // !syntheticMode

        // ---- streaming: header line on stdout, then encode ------------------
        if (streamMode) {
            if (fps == 0) fps = 60;
            printf("PDH1 %u %u %u h264 %u\n", width, height, fps, did);
            fflush(stdout);

            VDStreamer *streamer = [[VDStreamer alloc] init];
            streamer.softwareCursor = !hwCursor;
            BOOL started = syntheticMode
                ? [streamer startSyntheticWithWidth:width height:height fps:fps bitrateMbps:bitrate]
                : [streamer startWithDisplayID:did width:width height:height fps:fps bitrateMbps:bitrate];
            if (!started)
                return 4;
            gStreamer = streamer;

            if (!syntheticMode) {
                // ---- input injection: commands arrive on stdin --------------
                // NOTE: the source must be kept alive (gInputSource) — a local
                // would be ARC-released when this scope ends, silently
                // cancelling the source so the handler never fires.
                dispatch_queue_t inQ = dispatch_queue_create("pd.input", DISPATCH_QUEUE_SERIAL);
                gInputSource = dispatch_source_create(
                    DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, inQ);
                NSMutableData *inBuf = [NSMutableData data];
                dispatch_source_set_event_handler(gInputSource, ^{
                    uint8_t tmp[4096];
                    ssize_t n = read(STDIN_FILENO, tmp, sizeof(tmp));
                    if (n <= 0) {
                        // pdctl is gone (closed its end of the pipe, or died).
                        // Do not linger as a phantom display: remove it now.
                        fprintf(stderr, "stdin closed — host gone, exiting\n");
                        exit(0);
                    }
                    [inBuf appendBytes:tmp length:(NSUInteger)n];
                    while (true) {
                        const void *nl = memchr(inBuf.bytes, '\n', inBuf.length);
                        if (!nl) break;
                        size_t len = (const uint8_t *)nl - (const uint8_t *)inBuf.bytes;
                        if (len > sizeof(tmp) - 1) len = sizeof(tmp) - 1;
                        char line[4096];
                        memcpy(line, inBuf.bytes, len);
                        line[len] = '\0';
                        [gStreamer handleStdinLine:line];
                        [inBuf replaceBytesInRange:NSMakeRange(0, len + 1)
                                         withBytes:NULL length:0];
                    }
                    if (inBuf.length > 65536) [inBuf setLength:0];   // garbage guard
                });
                dispatch_resume(gInputSource);

                BOOL canPost = CGPreflightPostEventAccess();
                fprintf(gLog, "input injection armed (Accessibility post access: %s)\n",
                        canPost ? "granted" : "NOT granted yet — clicks need it");
                if (!canPost) CGRequestPostEventAccess();
            }
        }

        // ---- stay alive while the display should exist ---------------------
        signal(SIGINT, SIG_IGN);
        signal(SIGTERM, SIG_IGN);
        signal(SIGPIPE, SIG_IGN);

        dispatch_source_t sigint = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(sigint, ^{ fprintf(gLog, "\nsignal: removing display\n"); exit(0); });
        dispatch_resume(sigint);

        dispatch_source_t sigterm = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(sigterm, ^{ fprintf(gLog, "\nsignal: removing display\n"); exit(0); });
        dispatch_resume(sigterm);

        if (seconds > 0) {
            fprintf(gLog, "will exit automatically in %d seconds\n", seconds);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)seconds * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{ exit(0); });
        } else {
            fprintf(gLog, "holding — press Ctrl-C to stop\n");
        }
        fflush(gLog);

        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
