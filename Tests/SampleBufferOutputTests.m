@import CoreVideo;
#import "../AsyncGL/AsyncGLSampleBufferOutput.h"
#import "../AsyncGL/AsyncGLMirroringTarget.m"
#import "../AsyncGL/AsyncGLMirroringView.m"
#ifndef USE_EGL
static BOOL failDriverThreading;
static CGLError EnableDriverThreading(CGLContextObj context, CGLContextEnable option) {
    return failDriverThreading && option == kCGLCEMPEngine ? kCGLBadState : CGLEnable(context, option);
}
#define CGLEnable EnableDriverThreading
#endif
#import "../AsyncGL/AsyncGLView.m"
#ifndef USE_EGL
#undef CGLEnable
#endif
#import "../AsyncGL/AsyncGLExecutor.m"
#import "../AsyncGL/AsyncGLViewController.m"
#include <stdatomic.h>
#include <unistd.h>

static void Check(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static void TestOutput(BOOL multisample) {
#ifdef USE_EGL
    EGLAttrib displayAttributes[] = {
        EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE
    };
    EGLDisplay display = eglGetPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE, NULL, displayAttributes);
    Check(display != EGL_NO_DISPLAY && eglInitialize(display, NULL, NULL), @"ANGLE display");
    const EGLint attributes[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_SAMPLE_BUFFERS, multisample ? 1 : 0, EGL_SAMPLES, multisample ? 4 : 0, EGL_NONE
    };
    EGLConfig config = NULL;
    EGLint count = 0;
    Check(eglChooseConfig(display, attributes, &config, 1, &count) && count == 1, @"ANGLE config");
    const EGLint contextAttributes[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttributes);
    const EGLint surfaceAttributes[] = {EGL_WIDTH, 32, EGL_HEIGHT, 24, EGL_NONE};
    EGLSurface surface = eglCreatePbufferSurface(display, config, surfaceAttributes);
    Check(context != EGL_NO_CONTEXT && surface != EGL_NO_SURFACE &&
        eglMakeCurrent(display, surface, surface, context), @"ANGLE current context");
#else
    CGLPixelFormatAttribute attributes[] = {
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core, 0
    };
    CGLPixelFormatObj format = NULL;
    CGLContextObj context = NULL;
    GLint count;
    Check(CGLChoosePixelFormat(attributes, &format, &count) == kCGLNoError, @"Pixel format");
    Check(CGLCreateContext(format, NULL, &context) == kCGLNoError, @"Context");
    CGLReleasePixelFormat(format);
    Check(CGLSetCurrentContext(context) == kCGLNoError, @"Current context");
#endif
    GLuint framebuffer, color, callerFramebuffer, texture, unpackBuffer;
#ifdef USE_EGL
    framebuffer = 0;
#else
    glGenFramebuffers(1, &framebuffer);
#endif
    glGenRenderbuffers(1, &color);
    glGenFramebuffers(1, &callerFramebuffer);
    glGenTextures(1, &texture);
    glGenBuffers(1, &unpackBuffer);
    NSMutableArray *heldBuffers = [NSMutableArray array];
    __block NSUInteger received = 0;
    __block CGSize expected;
    __block CMTime lastTime = kCMTimeInvalid;
    AsyncGLSampleBufferOutput *output = [[AsyncGLSampleBufferOutput alloc] initWithMaximumSize:CGSizeMake(8, 6)
        handler:^(CMSampleBufferRef sample) {
            CVPixelBufferRef buffer = CMSampleBufferGetImageBuffer(sample);
            Check(CVPixelBufferGetWidth(buffer) == expected.width &&
                CVPixelBufferGetHeight(buffer) == expected.height, @"Scaled dimensions");
            CMTime time = CMSampleBufferGetPresentationTimeStamp(sample);
            Check(CMTIME_IS_NUMERIC(time) && (!CMTIME_IS_VALID(lastTime) || CMTimeCompare(time, lastTime) > 0),
                @"Monotonic presentation timestamps");
            lastTime = time;
            Check(CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess, @"Pixel lock");
            const uint8_t *base = CVPixelBufferGetBaseAddress(buffer);
            size_t stride = CVPixelBufferGetBytesPerRow(buffer);
            const int colors[4][3] = {{255, 0, 0}, {191, 128, 64}, {0, 0, 255}, {0, 255, 0}};
            for (int i = 0; i < 4; ++i) {
                size_t x = (i & 1) ? 3 * (size_t)expected.width / 4 : (size_t)expected.width / 4;
                size_t y = (i >> 1) ? 3 * (size_t)expected.height / 4 : (size_t)expected.height / 4;
                const uint8_t *pixel = base + y * stride + x * 4;
                Check(abs(pixel[0] - colors[i][0]) <= 2 && abs(pixel[1] - colors[i][1]) <= 2 &&
                    abs(pixel[2] - colors[i][2]) <= 2 && pixel[3] >= 253, @"BGRA colors and top-down orientation");
            }
            CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
            [heldBuffers addObject:(__bridge id)buffer];
            received++;
        }];
    for (int pass = 0; pass < 2; ++pass) {
        CGSize size = pass == 0 ? CGSizeMake(16, 12) : CGSizeMake(24, 16);
        expected = pass == 0 ? CGSizeMake(8, 6) : CGSizeMake(8, 5);
#ifdef USE_EGL
        const EGLint resizedAttributes[] = {EGL_WIDTH, size.width, EGL_HEIGHT, size.height, EGL_NONE};
        EGLSurface resized = eglCreatePbufferSurface(display, config, resizedAttributes);
        Check(resized != EGL_NO_SURFACE && eglMakeCurrent(display, resized, resized, context), @"Resize source surface");
        Check(eglDestroySurface(display, surface), @"Retire source surface");
        surface = resized;
#endif
        glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
        glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
#ifndef USE_EGL
        glBindRenderbuffer(GL_RENDERBUFFER, color);
        if (multisample)
            glRenderbufferStorageMultisample(GL_RENDERBUFFER, 4, GL_RGBA8, size.width, size.height);
        else
            glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, size.width, size.height);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, color);
#endif
        Check(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, @"Source framebuffer");
        GLint samples;
        glGetIntegerv(GL_SAMPLES, &samples);
        Check(samples == (multisample ? 4 : 0), @"Requested source MSAA mode");
#ifndef USE_EGL
        glDisable(GL_FRAMEBUFFER_SRGB);
#endif
        glEnable(GL_SCISSOR_TEST);
        const GLfloat colors[4][3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}, {.25, .5, .75}};
        for (int i = 0; i < 4; ++i) {
            glScissor((i & 1) * size.width / 2, (i >> 1) * size.height / 2, size.width / 2, size.height / 2);
            glClearColor(colors[i][0], colors[i][1], colors[i][2], 1);
            glClear(GL_COLOR_BUFFER_BIT);
        }
        glBindFramebuffer(GL_FRAMEBUFFER, callerFramebuffer);
        glActiveTexture(GL_TEXTURE3);
        glBindTexture(GL_TEXTURE_2D, texture);
        glBindBuffer(GL_PIXEL_UNPACK_BUFFER, unpackBuffer);
        glBufferData(GL_PIXEL_UNPACK_BUFFER, 1, NULL, GL_STATIC_DRAW);
#ifndef USE_EGL
        glEnable(GL_FRAMEBUFFER_SRGB);
#endif
        NSUInteger before = received;
        [output drawFromFramebuffer:framebuffer size:size];
        for (int attempt = 0; received == before && attempt < 1000; ++attempt) {
            @autoreleasepool {
                [output pollPendingFrames];
                usleep(1000);
            }
        }
        Check(received > before, @"Fence polling must deliver without a blocking finish");
        for (int frame = 0; frame < 12; ++frame) {
            @autoreleasepool {
                [output drawFromFramebuffer:framebuffer size:size];
                [output finishPendingWork];
            }
        }
        Check(received == before + 4, @"Consumer retention must cap the pool at four buffers");
        GLint value;
        glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &value);
        Check(value == callerFramebuffer, @"Read framebuffer preservation");
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &value);
        Check(value == callerFramebuffer, @"Draw framebuffer preservation");
        glGetIntegerv(GL_ACTIVE_TEXTURE, &value);
        Check(value == GL_TEXTURE3, @"Active texture preservation");
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &value);
        Check(value == texture, @"Texture preservation");
        glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &value);
        Check(value == unpackBuffer, @"Unpack buffer preservation");
        Check(glIsEnabled(GL_SCISSOR_TEST), @"Scissor state preservation");
#ifdef USE_EGL
        Check(eglGetCurrentDisplay() == display && eglGetCurrentContext() == context &&
            eglGetCurrentSurface(EGL_DRAW) == surface && eglGetCurrentSurface(EGL_READ) == surface,
            @"EGL context and surfaces unchanged");
#else
        Check(glIsEnabled(GL_FRAMEBUFFER_SRGB), @"sRGB state preservation");
#endif
        Check(glGetError() == GL_NO_ERROR, @"GL errors");
        [heldBuffers removeAllObjects];
        [output drawFromFramebuffer:framebuffer size:size];
        [output finishPendingWork];
        Check(received > before + 4, @"Capture resumes when the consumer releases buffers");
        [heldBuffers removeAllObjects];
    }
    [output drawFromFramebuffer:framebuffer size:CGSizeMake(24, 16)];
    [output clear];
    [output clear];
    glDeleteBuffers(1, &unpackBuffer);
    glDeleteTextures(1, &texture);
    glDeleteFramebuffers(1, &callerFramebuffer);
    glDeleteFramebuffers(1, &framebuffer);
    glDeleteRenderbuffers(1, &color);
    Check(glGetError() == GL_NO_ERROR, @"Pending-frame cleanup");
#ifdef USE_EGL
    Check(eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT), @"Release EGL context");
    Check(eglDestroySurface(display, surface) && eglDestroyContext(display, context) && eglTerminate(display),
        @"EGL cleanup");
#else
    CGLSetCurrentContext(NULL);
    CGLReleaseContext(context);
#endif
    NSLog(@"PASS: %@ sample-buffer pixels, resizing, backpressure, GL state and cleanup", multisample ? @"4x MSAA" : @"single-sample");
}

@interface OutputLifecycleView : AsyncGLView
@property (nonatomic, copy) dispatch_block_t afterOutputUpdate;
@end
@implementation OutputLifecycleView
- (BOOL)_allowsOffscreenRendering { return YES; }
- (void)updateOutputs {
    [super updateOutputs];
    if (self.afterOutputUpdate != nil)
        self.afterOutputUpdate();
}
#ifdef USE_EGL
- (BOOL)createRenderContext {
    self.display = AsyncGLAcquireDisplay();
    Check(self.display != EGL_NO_DISPLAY, @"Lifecycle EGL display");
    const EGLint attributes[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE
    };
    EGLConfig config = NULL;
    EGLint count = 0;
    Check(eglChooseConfig(self.display, attributes, &config, 1, &count) && count == 1, @"Lifecycle EGL config");
    self.renderConfig = config;
    const EGLint contextAttributes[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    self.renderContext = eglCreateContext(self.display, config, EGL_NO_CONTEXT, contextAttributes);
    const EGLint surfaceAttributes[] = {EGL_WIDTH, 32, EGL_HEIGHT, 24, EGL_NONE};
    self.renderSurface = eglCreatePbufferSurface(self.display, config, surfaceAttributes);
    Check(self.renderContext != EGL_NO_CONTEXT && self.renderSurface != EGL_NO_SURFACE, @"Lifecycle EGL resources");
    [self makeRenderContextCurrent];
    return [self setupGL:CGSizeMake(32, 24)];
}
#endif
@end

@interface OutputLifecycleDelegate : NSObject <AsyncGLViewDelegate> {
@public
    atomic_uint draws;
    atomic_uint samples;
    atomic_bool queuedTaskRan;
}
@property (nonatomic) BOOL requiresQueuedTaskBeforeDraw;
@end
@implementation OutputLifecycleDelegate
- (BOOL)_prepareGL:(CGSize)size samples:(NSInteger)count { return YES; }
- (void)_drawGL:(CGSize)size {
    if (self.requiresQueuedTaskBeforeDraw)
        Check(atomic_load(&queuedTaskRan), @"Resumed drawing must follow queued work");
    glClearColor(1, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    atomic_fetch_add(&draws, 1);
}
- (void)_clearGL {}
- (void)_viewWillMoveToWindow:(NSWindow *)window {}
@end

static void PumpUntil(BOOL (^finished)(void), NSString *message) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
    while (!finished() && deadline.timeIntervalSinceNow > 0) {
        @autoreleasepool {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
        }
    }
    Check(finished(), message);
}

@interface DriverThreadingController : AsyncGLViewController
@property (nonatomic) BOOL expectedThreading;
@property (atomic) BOOL checkedThreading;
@end

@implementation DriverThreadingController
- (BOOL)prepareGL:(CGSize)size samples:(NSInteger)samples {
#ifdef USE_EGL
    Check(eglGetCurrentContext() != EGL_NO_CONTEXT, @"Driver threading must be a no-op with EGL");
#else
    GLint enabled = GL_FALSE;
    Check(CGLIsEnabled(CGLGetCurrentContext(), kCGLCEMPEngine, &enabled) == kCGLNoError &&
          (enabled != GL_FALSE) == self.expectedThreading, @"Controller must configure the render context's driver threading");
#endif
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    Check(glGetError() == GL_NO_ERROR, @"Driver threading must preserve rendering");
    self.checkedThreading = YES;
    return YES;
}
@end

static void TestDriverThreading(BOOL enabled, BOOL failEnable) {
#ifdef USE_EGL
    AsyncGLAPI api = AsyncGLAPIOpenGLES3;
#else
    AsyncGLAPI api = AsyncGLAPIOpenGLCore41;
    failDriverThreading = failEnable;
#endif
    DriverThreadingController *controller = [[DriverThreadingController alloc]
        initWithMSAAEnabled:NO initialFrameRate:60 api:api multiThreaded:enabled executor:[AsyncGLExecutor new]];
    controller.expectedThreading = enabled;
    [controller loadView];
    AsyncGLView *view = controller.glView;
    view.frame = NSMakeRect(0, 0, 32, 24);
    [view createContexts];
    if (failEnable) {
        PumpUntil(^BOOL{ return view.contextState == AsyncGLViewContextStateFailed; }, @"Driver threading failure must stop initialization");
        Check(!controller.checkedThreading && !controller.isReady, @"Driver threading failure must not report successful preparation");
    } else {
        PumpUntil(^BOOL{ return view.contextState == AsyncGLViewContextStateRenderContextCreated && controller.isReady; },
                  @"Driver threading context initialization");
        Check(controller.checkedThreading, @"Driver threading must be configured before prepareGL");
    }
    __block BOOL stopped = NO;
    [controller shutdownWithCompletion:^{ stopped = YES; }];
    PumpUntil(^BOOL{ return stopped; }, @"Driver threading controller shutdown");
#ifndef USE_EGL
    failDriverThreading = NO;
#endif
    NSLog(@"PASS: driver threading %@%@", enabled ? @"enabled" : @"disabled",
          failEnable ? @" rejects initialization failure" : @"");
}

static void TestOutputLifecycle(void) {
    OutputLifecycleDelegate *delegate = [OutputLifecycleDelegate new];
    atomic_init(&delegate->draws, 0);
    atomic_init(&delegate->samples, 0);
    atomic_init(&delegate->queuedTaskRan, false);
    OutputLifecycleView *view = [[OutputLifecycleView alloc] initWithFrame:NSMakeRect(0, 0, 32, 24)];
#ifdef USE_EGL
    view.api = AsyncGLAPIOpenGLES3;
#else
    view.api = AsyncGLAPIOpenGLCore41;
#endif
    [view commonSetup];
    view.delegate = delegate;
    [view createContexts];
    PumpUntil(^BOOL{ return view.contextState == AsyncGLViewContextStateRenderContextCreated; }, @"Lifecycle context creation");

    __weak AsyncGLMirroringTarget *mirrorTarget;
    @autoreleasepool {
        AsyncGLMirroringView *mirror = (AsyncGLMirroringView *)[view startMirroring];
        mirrorTarget = mirror.target;
    }
    PumpUntil(^BOOL{ return atomic_load(&delegate->draws) == 1; }, @"Initial mirroring draw");
    NSThread *renderThread = view.renderThread;
    void (^handler)(CMSampleBufferRef) = ^(CMSampleBufferRef sample) {
        Check(NSThread.currentThread == renderThread, @"Delivery must remain on the render thread");
        atomic_fetch_add(&delegate->samples, 1);
    };
    NSError *error = nil;
    Check([view startSampleBufferOutputWithMaximumSize:CGSizeMake(16, 12) handler:handler error:&error],
        @"Lifecycle output startup");
    PumpUntil(^BOOL{ return atomic_load(&delegate->samples) == 1; }, @"One captured frame must deliver without another draw");
    Check(atomic_load(&delegate->draws) == 2, @"Fence polling must not draw extra frames");

    [view pause];
    [view enqueueTask:^{ atomic_store(&delegate->queuedTaskRan, true); }];
    __weak AsyncGLSampleBufferOutput *oldOutput;
    __weak AsyncGLSampleBufferOutput *replacement;
    @autoreleasepool {
        oldOutput = view.activeSampleBufferOutput;
        Check(oldOutput != nil, @"The first output must have been activated");
        Check([view startSampleBufferOutputWithMaximumSize:CGSizeMake(16, 12)
            handler:^(CMSampleBufferRef sample) { Check(NO, @"A paused replacement must not capture"); } error:&error],
            @"Paused replacement startup");
        replacement = view.sampleBufferOutput;
    }
    PumpUntil(^BOOL{ return oldOutput == nil; }, @"Replacing while paused must retire the previous output");
    [view stopSampleBufferOutput];
    [view stopMirroring];
    PumpUntil(^BOOL{ return replacement == nil && mirrorTarget == nil; }, @"Stopping while paused must retire both outputs");
    Check(atomic_load(&delegate->draws) == 2 && !atomic_load(&delegate->queuedTaskRan),
        @"Retirement must not resume drawing or queued work");

    Check([view startSampleBufferOutputWithMaximumSize:CGSizeMake(16, 12) handler:handler error:&error],
        @"Restart while paused");
    [view resume];
    PumpUntil(^BOOL{ return atomic_load(&delegate->samples) == 2; }, @"Resume must preserve the queued output draw");
    Check(atomic_load(&delegate->queuedTaskRan), @"Resume must run the deferred task");
    [view pause];
    __block BOOL stopped = NO;
    [view clearWithDelegate:delegate completion:^{ stopped = YES; }];
    PumpUntil(^{ return stopped; }, @"Shutdown after paused output work");
    NSLog(@"PASS: idle sample delivery, paused replacement/stop, mirroring retirement and resume");
}

static void TestResumeDuringOutputUpdate(void) {
    OutputLifecycleDelegate *delegate = [OutputLifecycleDelegate new];
    atomic_init(&delegate->draws, 0);
    atomic_init(&delegate->samples, 0);
    atomic_init(&delegate->queuedTaskRan, false);
    delegate.requiresQueuedTaskBeforeDraw = YES;
    OutputLifecycleView *view = [[OutputLifecycleView alloc] initWithFrame:NSMakeRect(0, 0, 32, 24)];
#ifdef USE_EGL
    view.api = AsyncGLAPIOpenGLES3;
#else
    view.api = AsyncGLAPIOpenGLCore41;
#endif
    __block atomic_bool holdUpdate;
    __block atomic_bool updateEntered;
    atomic_init(&holdUpdate, false);
    atomic_init(&updateEntered, false);
    dispatch_semaphore_t releaseUpdate = dispatch_semaphore_create(0);
    view.afterOutputUpdate = ^{
        if (atomic_exchange(&holdUpdate, false)) {
            atomic_store(&updateEntered, true);
            Check(dispatch_semaphore_wait(releaseUpdate, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0,
                @"Output-update gate timed out");
        }
    };
    [view commonSetup];
    view.delegate = delegate;
    [view createContexts];
    PumpUntil(^BOOL{ return view.contextState == AsyncGLViewContextStateRenderContextCreated; }, @"Resume-race context creation");
    [view pause];
    [view enqueueTask:^{ atomic_store(&delegate->queuedTaskRan, true); }];
    atomic_store(&holdUpdate, true);
    NSError *error = nil;
    Check([view startSampleBufferOutputWithMaximumSize:CGSizeMake(16, 12)
        handler:^(CMSampleBufferRef sample) { atomic_fetch_add(&delegate->samples, 1); } error:&error],
        @"Resume-race output startup");
    PumpUntil(^BOOL{ return atomic_load(&updateEntered); }, @"Paused iteration must reach output update");
    [view resume];
    dispatch_semaphore_signal(releaseUpdate);
    PumpUntil(^BOOL{ return atomic_load(&delegate->samples) > 0; }, @"Resumed frame delivery");
    [view pause];
    Check(atomic_load(&delegate->draws) == 1 && atomic_load(&delegate->samples) == 1,
        @"A preserved draw must execute exactly once");
    __block BOOL stopped = NO;
    [view clearWithDelegate:delegate completion:^{ stopped = YES; }];
    PumpUntil(^{ return stopped; }, @"Resume-race shutdown");
    NSLog(@"PASS: resume during paused output update preserves task ordering and one draw");
}

static void TestExecutorBatches(void) {
    OutputLifecycleDelegate *delegate = [OutputLifecycleDelegate new];
    atomic_init(&delegate->draws, 0);
    atomic_init(&delegate->samples, 0);
    atomic_init(&delegate->queuedTaskRan, false);
    OutputLifecycleView *view = [[OutputLifecycleView alloc] initWithFrame:NSMakeRect(0, 0, 32, 24)];
#ifdef USE_EGL
    view.api = AsyncGLAPIOpenGLES3;
#else
    view.api = AsyncGLAPIOpenGLCore41;
#endif
    [view commonSetup];
    view.delegate = delegate;
    [view createContexts];
    PumpUntil(^BOOL{ return view.contextState == AsyncGLViewContextStateRenderContextCreated; }, @"Batch context creation");
    NSMutableArray<NSNumber *> *order = [NSMutableArray array];
    __block atomic_uint completed;
    __block atomic_bool gateEntered;
    __block atomic_bool paused;
    atomic_init(&completed, 0);
    atomic_init(&gateEntered, false);
    atomic_init(&paused, false);
    dispatch_semaphore_t releaseGate = dispatch_semaphore_create(0);
    dispatch_block_t gate = ^{
        atomic_store(&gateEntered, true);
        Check(dispatch_semaphore_wait(releaseGate, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0,
              @"Executor batch gate timed out");
    };
    [view enqueueTask:gate];
    PumpUntil(^BOOL{ return atomic_load(&gateEntered); }, @"Initial executor gate");
    [view enqueueTask:^{
        [order addObject:@1];
        atomic_fetch_add(&completed, 1);
        [view enqueueTask:^{
            [order addObject:@3];
            atomic_fetch_add(&completed, 1);
        }];
    }];
    [view enqueueTask:^{
        [order addObject:@2];
        atomic_fetch_add(&completed, 1);
    }];
    dispatch_semaphore_signal(releaseGate);
    PumpUntil(^BOOL{ return atomic_load(&completed) == 3; }, @"Nested submissions must run in the next batch");

    atomic_store(&gateEntered, false);
    [view enqueueTask:gate];
    PumpUntil(^BOOL{ return atomic_load(&gateEntered); }, @"Pause executor gate");
    [view enqueueTask:^{
        [order addObject:@4];
        atomic_fetch_add(&completed, 1);
    }];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [view pause];
        atomic_store(&paused, true);
    });
    PumpUntil(^BOOL{
        [view.condition lock];
        BOOL pending = (view.event & AsyncGLViewEventPause) != 0;
        [view.condition unlock];
        return pending;
    }, @"Pause must snapshot the accepted task prefix");
    [view enqueueTask:^{
        [order addObject:@5];
        atomic_fetch_add(&completed, 1);
    }];
    dispatch_semaphore_signal(releaseGate);
    PumpUntil(^BOOL{ return atomic_load(&paused); }, @"Pause must drain its accepted task prefix");
    Check(atomic_load(&completed) == 4, @"Tasks submitted after pause must remain deferred");
    [view resume];
    PumpUntil(^BOOL{ return atomic_load(&completed) == 5; }, @"Resume must drain the remaining batch");

    atomic_store(&gateEntered, false);
    [view enqueueTask:gate];
    PumpUntil(^BOOL{ return atomic_load(&gateEntered); }, @"Shutdown executor gate");
    [view enqueueTask:^{
        [order addObject:@6];
        atomic_fetch_add(&completed, 1);
    }];
    __block BOOL stopped = NO;
    [view clearWithDelegate:delegate completion:^{ stopped = YES; }];
    dispatch_semaphore_signal(releaseGate);
    PumpUntil(^{ return stopped; }, @"Batch shutdown");
    Check(atomic_load(&completed) == 6 && [order isEqualToArray:@[@1, @2, @3, @4, @5, @6]],
          @"Batch swapping must preserve FIFO, exactly-once execution and active shutdown draining");
    NSLog(@"PASS: executor batch ordering, nested submissions, pause cutoff, resume and shutdown draining");
}

@interface FrameClockTestView : AsyncGLView
@property (nonatomic) NSUInteger frames;
@property (nonatomic) BOOL workerPaused;
@end

@implementation FrameClockTestView
- (void)requestRender { self.frames += 1; }
- (void)pause { self.workerPaused = YES; }
- (void)resume { self.workerPaused = NO; }
- (void)clear {}
- (void)clearWithDelegate:(id<AsyncGLViewDelegate>)delegate completion:(void (^)(void))completion {
    if (completion != nil)
        completion();
}
@end

@interface FrameClockPreparationController : AsyncGLViewController
@property (nonatomic, copy) BOOL (^preparation)(void);
@property (nonatomic) BOOL simulateActiveWindow;
@end

@implementation FrameClockPreparationController
- (BOOL)prepareGL:(CGSize)size samples:(NSInteger)samples {
    return self.preparation();
}
- (BOOL)shouldPauseForCurrentLifecycle {
    return self.simulateActiveWindow ? NO : [super shouldPauseForCurrentLifecycle];
}
@end

static void TestOffscreenPreparation(BOOL pauseDuringPreparation, BOOL disableDuringPreparation) {
    FrameClockPreparationController *controller = [[FrameClockPreparationController alloc]
        initWithMSAAEnabled:NO initialFrameRate:60 api:AsyncGLAPIOpenGLES3 multiThreaded:NO executor:[AsyncGLExecutor new]];
    FrameClockTestView *view = [FrameClockTestView new];
    view.workerPaused = YES;
    controller.glView = view;
    controller.simulateActiveWindow = disableDuringPreparation;
    controller.rendersWhileOffscreen = YES;

    __block atomic_bool entered;
    __block atomic_bool finished;
    atomic_init(&entered, false);
    atomic_init(&finished, false);
    dispatch_semaphore_t releasePreparation = dispatch_semaphore_create(0);
    controller.preparation = ^BOOL{
        atomic_store(&entered, true);
        Check(dispatch_semaphore_wait(releasePreparation, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0,
              @"Preparation gate timed out");
        return YES;
    };
    __weak FrameClockPreparationController *weakController = controller;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        Check([weakController _prepareGL:CGSizeMake(32, 24) samples:0], @"Controller preparation failed");
        atomic_store(&finished, true);
    });
    PumpUntil(^BOOL{ return atomic_load(&entered); }, @"Preparation must reach its gate");
    if (pauseDuringPreparation) {
        controller.paused = YES;
        controller.rendersWhileOffscreen = YES;
    }
    if (disableDuringPreparation)
        controller.rendersWhileOffscreen = NO;
    dispatch_semaphore_signal(releasePreparation);
    PumpUntil(^BOOL{ return atomic_load(&finished); }, @"Preparation must finish");
    if (pauseDuringPreparation) {
        Check(controller.isPaused && view.workerPaused, @"Preparation must preserve a newer explicit pause");
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        Check(view.frames == 0, @"Preparation must not restart an explicitly paused clock");
        if (!disableDuringPreparation)
            controller.paused = NO;
    }
    if (disableDuringPreparation) {
        Check(controller.isPaused == pauseDuringPreparation && view.workerPaused == pauseDuringPreparation,
              @"Disabling during preparation must restore active-window rendering unless explicitly paused");
    } else {
        PumpUntil(^BOOL{ return view.frames > 0; }, @"Offscreen rendering must start when resume is requested");
    }
    [controller shutdown];
    NSLog(@"PASS: %@ during preparation %@", disableDuringPreparation ? @"offscreen disable" : @"offscreen startup",
          pauseDuringPreparation ? @"preserves explicit pause" : @"resumes automatically");
}

static void TestOffscreenFrameClock(void) {
    AsyncGLExecutor *executor = [AsyncGLExecutor new];
    AsyncGLViewController *controller = [[AsyncGLViewController alloc]
        initWithMSAAEnabled:NO initialFrameRate:60 api:AsyncGLAPIOpenGLES3 multiThreaded:NO executor:executor];
    FrameClockTestView *view = [FrameClockTestView new];
    controller.glView = view;
    controller.ready = YES;
    controller.pauseOnWillResignActive = YES;
    controller.rendersWhileOffscreen = YES;
    PumpUntil(^BOOL{ return view.frames > 0; }, @"Offscreen clock must render without a window");
    Check(view.rendersWhileOffscreen && !view.workerPaused, @"Offscreen mode must enable and resume the source");

    [controller _pauseByNotification];
    [controller _viewWillMoveToWindow:nil];
    Check(!controller.isPaused && !view.workerPaused, @"PiP must survive inactivity and window detachment");

    controller.paused = YES;
    NSUInteger frames = view.frames;
    [controller _viewWillMoveToWindow:nil];
    Check(controller.isPaused && view.workerPaused, @"Window detachment must preserve an explicit offscreen pause");
    [controller _resumeByNotification];
    Check(controller.isPaused && view.workerPaused, @"App activation must preserve an explicit offscreen pause");
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    Check(view.workerPaused && view.frames == frames, @"Lifecycle changes must leave the explicitly paused clock stopped");

    controller.rendersWhileOffscreen = NO;
    Check(controller.isPaused && !view.rendersWhileOffscreen, @"Disabling must restore windowless suspension");
    controller.rendersWhileOffscreen = YES;
    PumpUntil(^BOOL{ return view.frames > frames; }, @"Offscreen rendering must restart");
    [controller shutdown];
    frames = view.frames;
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    Check(!controller.rendersWhileOffscreen && !view.rendersWhileOffscreen && view.frames == frames,
          @"Shutdown must stop offscreen drawing and cancel its clock");
    NSLog(@"PASS: offscreen clock, inactivity, detachment, explicit pause, restart and shutdown");
}

#import "DisplayLinkTests.h"

int main(void) {
    @autoreleasepool {
        TestDriverThreading(NO, NO);
        TestDriverThreading(YES, NO);
#ifndef USE_EGL
        TestDriverThreading(YES, YES);
#endif
        TestOutput(NO);
        TestOutput(YES);
        TestOutputLifecycle();
        TestResumeDuringOutputUpdate();
        TestExecutorBatches();
        TestTargetTimestamps();
        TestDisplayLinkScheduling();
        TestDisplayLinkConfigurationRaces();
        TestOffscreenFrameClock();
        TestOffscreenPreparation(NO, NO);
        TestOffscreenPreparation(YES, NO);
        TestOffscreenPreparation(NO, YES);
        TestOffscreenPreparation(YES, YES);
    }
    return 0;
}
