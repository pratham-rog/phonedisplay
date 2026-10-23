// vdfpswin — a full-screen test-pattern window with Core Animation content.
//
// Why: CA animations are composited by the render server at the target
// display's refresh rate, so this window produces genuine 90/120 Hz content
// for stream testing — no browser, no automation permissions.
//
// build:  clang -fobjc-arc -framework Cocoa -framework QuartzCore -o vdfpswin vdfpswin.m
// run:    ./vdfpswin [width height]        (default: 3120x1440, PhoneDisplay)
// stop:   pkill -f vdfpswin

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

static CGImageRef makeBarsImage(CGFloat w, CGFloat h) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, (size_t)w, (size_t)h, 8, 0, cs,
                                             kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(cs);
    static const CGFloat pal[8][3] = {
        {0.91, 0.30, 0.24}, {0.95, 0.61, 0.07}, {0.95, 0.77, 0.06}, {0.18, 0.80, 0.44},
        {0.10, 0.74, 0.61}, {0.20, 0.60, 0.86}, {0.61, 0.35, 0.71}, {0.91, 0.26, 0.58},
    };
    int ncol = 16;
    CGFloat bw = w / ncol;
    for (int i = 0; i < ncol; i++) {
        const CGFloat *c = pal[i % 8];
        CGContextSetRGBFillColor(ctx, c[0], c[1], c[2], 1.0);
        CGContextFillRect(ctx, CGRectMake(i * bw, 0, bw + 1, h));
    }
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return img;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        uint32_t wantW = 3120, wantH = 1440;
        if (argc >= 3) { wantW = (uint32_t)atoi(argv[1]); wantH = (uint32_t)atoi(argv[2]); }

        NSScreen *target = nil;
        for (NSScreen *s in [NSScreen screens]) {
            if ((uint32_t)s.frame.size.width == wantW && (uint32_t)s.frame.size.height == wantH) {
                target = s;
                break;
            }
        }
        if (!target) {
            fprintf(stderr, "vdfpswin: no screen %ux%u — is the PhoneDisplay stream up?\n",
                    wantW, wantH);
            return 1;
        }

        NSRect f = target.frame;
        printf("vdfpswin: display %.0fx%.0f at (%.0f,%.0f)\n",
               f.size.width, f.size.height, f.origin.x, f.origin.y);
        fflush(stdout);

        NSWindow *win = [[NSWindow alloc] initWithContentRect:f
                                                    styleMask:NSWindowStyleMaskBorderless
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
        win.opaque = YES;
        win.backgroundColor = [NSColor blackColor];
        win.level = NSNormalWindowLevel;      // a normal backdrop; apps can cover it
        win.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                 NSWindowCollectionBehaviorStationary;
        win.releasedWhenClosed = NO;

        NSView *view = win.contentView;
        view.wantsLayer = YES;
        CALayer *root = view.layer;
        root.backgroundColor = NSColor.blackColor.CGColor;

        CGSize sz = f.size;

        // ---- 1) scrolling colour-bar sheet ---------------------------------
        // image has 16 bars; the palette repeats every 8 → animating by
        // exactly 8 bar-widths and looping is pixel-seamless.
        CGFloat bw = sz.width / 16.0;
        CGImageRef bars = makeBarsImage(sz.width, sz.height * 0.7);
        CALayer *sheet = [CALayer layer];
        sheet.frame = CGRectMake(0, 0, sz.width, sz.height * 0.7);
        sheet.contents = (__bridge_transfer id)bars;
        sheet.contentsGravity = kCAGravityResize;
        [root addSublayer:sheet];

        CABasicAnimation *scroll = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
        scroll.fromValue = @(0.0);
        scroll.toValue = @(-8.0 * bw);
        scroll.duration = 0.9;
        scroll.repeatCount = HUGE_VALF;
        scroll.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
        [sheet addAnimation:scroll forKey:@"scroll"];

        // ---- 2) bouncing ball (fast both-axis motion) ----------------------
        CALayer *ball = [CALayer layer];
        ball.frame = CGRectMake(0, 0, 108, 108);
        ball.cornerRadius = 54;
        ball.backgroundColor = NSColor.whiteColor.CGColor;
        [root addSublayer:ball];

        CABasicAnimation *bx = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
        bx.fromValue = @(80.0);
        bx.toValue = @(sz.width - 188.0);
        bx.duration = 0.55;
        bx.autoreverses = YES;
        bx.repeatCount = HUGE_VALF;
        bx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [ball addAnimation:bx forKey:@"bx"];

        CABasicAnimation *by = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
        by.fromValue = @(sz.height * 0.72 + 60.0);
        by.toValue = @(sz.height - 200.0);
        by.duration = 0.36;
        by.autoreverses = YES;
        by.repeatCount = HUGE_VALF;
        by.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [ball addAnimation:by forKey:@"by"];

        // ---- 3) rotating needle -------------------------------------------
        CALayer *needle = [CALayer layer];
        needle.frame = CGRectMake(0, 0, sz.width * 0.72, 16);
        needle.anchorPoint = CGPointMake(0.0, 0.5);
        needle.position = CGPointMake(sz.width / 2, sz.height * 0.86);
        needle.backgroundColor = NSColor.whiteColor.CGColor;
        needle.cornerRadius = 8;
        [root addSublayer:needle];

        CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        spin.fromValue = @(0.0);
        spin.toValue = @(2.0 * M_PI);
        spin.duration = 1.4;
        spin.repeatCount = HUGE_VALF;
        spin.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
        [needle addAnimation:spin forKey:@"spin"];

        [win orderFrontRegardless];
        [NSApp run];
    }
    return 0;
}
