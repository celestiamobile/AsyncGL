@import CoreVideo;
#import "../AsyncGL/AsyncGLSampleBufferOutput.h"
#import "../AsyncGL/AsyncGLMirroringTarget.m"
#import "../AsyncGL/AsyncGLMirroringView.m"
#import "../AsyncGL/AsyncGLView.m"
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

int main(void) {
    @autoreleasepool {
        TestOutput(NO);
        TestOutput(YES);
        TestOutputLifecycle();
        TestResumeDuringOutputUpdate();
    }
    return 0;
}
