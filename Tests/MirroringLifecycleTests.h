@interface MirroringSourceView : AsyncGLView
@property (atomic) NSUInteger completedFrames;
@end

@implementation MirroringSourceView
- (void)render {
    [super render];
    self.completedFrames += 1;
}
@end

@interface MirroringSourceDelegate : NSObject <AsyncGLViewDelegate>
@end

@implementation MirroringSourceDelegate
- (BOOL)_prepareGL:(CGSize)size samples:(NSInteger)samples {
    return YES;
}
- (void)_drawGL:(CGSize)size {
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    glEnable(GL_SCISSOR_TEST);
    const GLfloat colors[4][4] = {{1, 0, 0, 1}, {0, 1, 0, 1}, {0, 0, 1, 1}, {1, 1, 0, 1}};
    for (int index = 0; index < 4; ++index) {
        glScissor((index & 1) * (GLsizei)size.width / 2, (index >> 1) * (GLsizei)size.height / 2,
                  (GLsizei)size.width / 2, (GLsizei)size.height / 2);
        glClearColor(colors[index][0], colors[index][1], colors[index][2], 1);
        glClear(GL_COLOR_BUFFER_BIT);
    }
}
- (void)_clearGL {}
- (void)_viewWillMoveToWindow:(NSWindow *)window {}
@end

static void PumpMirroringUntil(MirroringSourceView *source, BOOL (^finished)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!finished() && deadline.timeIntervalSinceNow > 0) {
        [source requestRender];
        NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                          untilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]
                                             inMode:NSDefaultRunLoopMode dequeue:YES];
        if (event != nil)
            [NSApp sendEvent:event];
        [NSApp updateWindows];
    }
    Check(finished(), @"Mirroring lifecycle operation timed out");
}

static void TestMirroringGeometry(void) {
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    container.wantsLayer = YES;
    AsyncGLMirroringView *mirror = [[AsyncGLMirroringView alloc] initWithFrame:NSMakeRect(18, 12, 104, 72)];
    [container addSubview:mirror];
    for (NSValue *frame in @[[NSValue valueWithRect:NSMakeRect(18, 12, 104, 72)],
                             [NSValue valueWithRect:NSMakeRect(40, 30, 128, 96)]]) {
        mirror.frame = frame.rectValue;
        [mirror updateTarget];
        Check(NSEqualRects(mirror.layer.frame, frame.rectValue),
              @"Updating a mirror moved its AppKit-managed hosting layer");
    }
}

static void TestMirroringLifecycle(void) {
    TestMirroringGeometry();
    MirroringSourceDelegate *delegate = [MirroringSourceDelegate new];
    MirroringSourceView *source = [[MirroringSourceView alloc] initWithFrame:NSMakeRect(0, 0, 32, 24)];
#ifdef USE_EGL
    source.api = AsyncGLAPIOpenGLES3;
#else
    source.api = AsyncGLAPIOpenGLCore41;
#endif
    source.msaaEnabled = YES;
    [source commonSetup];
    source.delegate = delegate;
    NSWindow *sourceWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 32, 24)
                                                       styleMask:NSWindowStyleMaskBorderless
                                                         backing:NSBackingStoreBuffered defer:NO];
    sourceWindow.contentView = source;
    [sourceWindow orderFront:nil];
    [source _checkViewState];
    PumpMirroringUntil(source, ^BOOL {
        [source.condition lock];
        BOOL ready = source.contextsCreated;
        [source.condition unlock];
        Check(!source.renderThread.finished, @"Source renderer initialization failed");
        return ready;
    });
#ifndef USE_EGL
    sourceContext = source.renderContext;
#endif
    NSView *mirror = [source startMirroring];
    NSWindow *mirrorWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 100, 28, 16)
                                                       styleMask:NSWindowStyleMaskBorderless
                                                         backing:NSBackingStoreBuffered defer:NO];
    mirrorWindow.contentView = mirror;
    [mirrorWindow orderFront:nil];
    [mirror layoutSubtreeIfNeeded];
    [CATransaction flush];
    [source _checkViewState];
    NSUInteger before = presentations;
    [source requestRender];
    PumpMirroringUntil(source, ^BOOL { return presentations > before; });
    Check(presentedPixels[0][0] >= 253 && presentedPixels[0][1] <= 2 &&
          presentedPixels[2][2] >= 253 && presentedPixels[2][0] <= 2,
          @"Public mirror API produced incorrect pixels or orientation");
    [mirrorWindow setContentSize:NSMakeSize(44, 32)];
    [mirror layoutSubtreeIfNeeded];
    [CATransaction flush];
    before = presentations;
    [source requestRender];
    PumpMirroringUntil(source, ^BOOL { return presentations > before; });

    [source stopMirroring];
    [mirror removeFromSuperview];
    NSUInteger completed = source.completedFrames;
    [source requestRender];
    PumpMirroringUntil(source, ^BOOL { return source.completedFrames > completed; });
    before = presentations;
    completed = source.completedFrames;
    [source requestRender];
    PumpMirroringUntil(source, ^BOOL { return source.completedFrames > completed; });
    Check(presentations == before, @"Stopped mirroring still presented frames");

    mirror = [source startMirroring];
    mirrorWindow.contentView = mirror;
    [mirror layoutSubtreeIfNeeded];
    [CATransaction flush];
    before = presentations;
    [source requestRender];
    PumpMirroringUntil(source, ^BOOL { return presentations > before; });
    [source clear];
    PumpMirroringUntil(source, ^BOOL { return source.renderThread.finished; });
    [mirrorWindow orderOut:nil];
    [sourceWindow orderOut:nil];
    NSLog(@"PASS: public mirror API start, live resize, stop, restart and active-mirror shutdown");
}
