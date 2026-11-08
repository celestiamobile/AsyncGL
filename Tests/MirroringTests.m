@import Cocoa;
@import QuartzCore;
@import libEGL;
@import libGLESv2;

#include <stdatomic.h>

static _Atomic(NSUInteger) presentations;
static GLubyte presentedPixels[4][4];

static EGLBoolean CaptureMirrorSwap(EGLDisplay display, EGLSurface surface) {
    EGLint width = 0, height = 0;
    eglQuerySurface(display, surface, EGL_WIDTH, &width);
    eglQuerySurface(display, surface, EGL_HEIGHT, &height);
    glReadPixels(width / 4, height / 4, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, presentedPixels[0]);
    glReadPixels(3 * width / 4, height / 4, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, presentedPixels[1]);
    glReadPixels(width / 4, 3 * height / 4, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, presentedPixels[2]);
    glReadPixels(3 * width / 4, 3 * height / 4, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, presentedPixels[3]);
    ++presentations;
    return eglSwapBuffers(display, surface);
}

#define eglSwapBuffers CaptureMirrorSwap
#import "../AsyncGL/AsyncGLMirroringTarget.m"
#undef eglSwapBuffers
#import "../AsyncGL/AsyncGLMirroringView.m"
#import "../AsyncGL/AsyncGLView.m"

static void Check(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static void CheckColor(const GLubyte *pixel, int red, int green, int blue) {
    Check(abs(pixel[0] - red) <= 2 && abs(pixel[1] - green) <= 2 &&
          abs(pixel[2] - blue) <= 2 && pixel[3] >= 253,
          [NSString stringWithFormat:@"Unexpected mirrored pixel: %u %u %u %u",
                                     pixel[0], pixel[1], pixel[2], pixel[3]]);
}

static void CheckGLError(NSString *operation) {
    GLenum error = glGetError();
    Check(error == GL_NO_ERROR, [NSString stringWithFormat:@"%@ produced GL error 0x%x", operation, error]);
}

static void DrawSource(CGSize size) {
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glDisable(GL_RASTERIZER_DISCARD);
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    glEnable(GL_SCISSOR_TEST);
    const GLfloat colors[4][4] = {
        {1, 0, 0, 1}, {0, 1, 0, 1}, {0, 0, 1, 1}, {1, 1, 0, 1}
    };
    for (int index = 0; index < 4; ++index) {
        glScissor((index & 1) * (GLsizei)size.width / 2,
                  (index >> 1) * (GLsizei)size.height / 2,
                  (GLsizei)size.width / 2, (GLsizei)size.height / 2);
        glClearColor(colors[index][0], colors[index][1], colors[index][2], 1);
        glClear(GL_COLOR_BUFFER_BIT);
    }
}

static void DrawMirrorOffMain(AsyncGLMirroringTarget *target, CGSize size,
                              EGLDisplay display, EGLConfig config,
                              EGLContext context, EGLSurface source) {
    Check(eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT),
          @"Could not release source context before worker rendering");
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        Check(![NSThread isMainThread], @"Mirror rendering must run off main");
        Check(eglMakeCurrent(display, source, source, context), @"Worker could not bind source context");
        Check([target drawFromFramebuffer:0 size:size display:display config:config
                                  context:context sourceSurface:source],
              @"Mirroring did not restore the source surface");
        Check(eglGetCurrentContext() == context &&
              eglGetCurrentSurface(EGL_DRAW) == source && eglGetCurrentSurface(EGL_READ) == source,
              @"Worker context or source surfaces were not restored");
        CheckGLError(@"Mirroring");
        Check(eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT),
              @"Could not release source context after worker rendering");
        dispatch_semaphore_signal(finished);
    });
    // No run-loop pumping: a synchronous main-thread dependency would deadlock.
    Check(dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0,
          @"Mirroring waited for the main thread");
    Check(eglMakeCurrent(display, source, source, context), @"Could not reacquire source context");
}

static void TestMirroring(BOOL multisample) {
    EGLDisplay display = AsyncGLAcquireDisplay();
    Check(display != EGL_NO_DISPLAY, @"Could not initialize ANGLE");
    const EGLint attributes[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT | EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_SAMPLE_BUFFERS, multisample ? 1 : 0,
        EGL_SAMPLES, multisample ? 4 : 0,
        EGL_NONE
    };
    EGLConfig config = NULL;
    EGLint count = 0;
    Check(eglChooseConfig(display, attributes, &config, 1, &count) && count > 0,
          @"Could not select the requested EGL sample count");
    const EGLint contextAttributes[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttributes);
    Check(context != EGL_NO_CONTEXT, @"Could not create ES3 context");

    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 20, 12)
                                                  styleMask:NSWindowStyleMaskBorderless
                                                    backing:NSBackingStoreBuffered defer:NO];
    NSView *view = window.contentView;
    view.wantsLayer = YES;
    CAMetalLayer *layer = [CAMetalLayer layer];
    view.layer = layer;
    layer.contentsScale = 1;
    [window orderFront:nil];
    AsyncGLMirroringTarget *target = [[AsyncGLMirroringTarget alloc] initWithLayer:layer];

    GLuint textures[2], vertexArray, sampler, unpackBuffer, framebuffers[2], renderbuffer;
    EGLSurface source = EGL_NO_SURFACE;
    for (int pass = 0; pass < 2; ++pass) {
        CGSize size = pass == 0 ? CGSizeMake(24, 16) : CGSizeMake(36, 20);
        CGSize targetSize = pass == 0 ? CGSizeMake(20, 12) : CGSizeMake(28, 16);
        if (source != EGL_NO_SURFACE) {
            eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
            eglDestroySurface(display, source);
        }
        EGLint pbufferAttributes[] = {
            EGL_WIDTH, (EGLint)size.width, EGL_HEIGHT, (EGLint)size.height, EGL_NONE
        };
        source = eglCreatePbufferSurface(display, config, pbufferAttributes);
        Check(source != EGL_NO_SURFACE, @"Could not create source pbuffer");
        Check(eglMakeCurrent(display, source, source, context), @"Could not bind source pbuffer");
        DrawSource(size);
        GLuint vertex = AsyncGLCompileMirrorShader(GL_VERTEX_SHADER,
            "#version 300 es\nvoid main() { gl_Position = vec4(0, 0, 0, 1); }\n");
        GLuint fragment = AsyncGLCompileMirrorShader(GL_FRAGMENT_SHADER,
            "#version 300 es\nprecision mediump float;\nout vec4 color;\nvoid main() { color = vec4(1); }\n");
        Check(vertex != 0 && fragment != 0, @"Could not compile caller shaders");
        GLuint sourceProgram = glCreateProgram();
        glAttachShader(sourceProgram, vertex);
        glAttachShader(sourceProgram, fragment);
        glLinkProgram(sourceProgram);
        glDeleteShader(vertex);
        glDeleteShader(fragment);
        GLint linked = GL_FALSE;
        glGetProgramiv(sourceProgram, GL_LINK_STATUS, &linked);
        Check(linked == GL_TRUE, @"Could not link caller shader program");
        [window setContentSize:NSMakeSize(targetSize.width, targetSize.height)];
        layer.drawableSize = targetSize;
        [target updateSize:targetSize visible:YES];

        glGenTextures(2, textures);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, textures[0]);
        glActiveTexture(GL_TEXTURE3);
        glBindTexture(GL_TEXTURE_2D, textures[1]);
        glGenVertexArrays(1, &vertexArray);
        glBindVertexArray(vertexArray);
        glUseProgram(sourceProgram);
        glGenFramebuffers(2, framebuffers);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, framebuffers[0]);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffers[1]);
        glGenRenderbuffers(1, &renderbuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, renderbuffer);
        glGenSamplers(1, &sampler);
        glBindSampler(0, sampler);
        glGenBuffers(1, &unpackBuffer);
        glBindBuffer(GL_PIXEL_UNPACK_BUFFER, unpackBuffer);
        glBufferData(GL_PIXEL_UNPACK_BUFFER, 1, NULL, GL_STATIC_DRAW);
        glViewport(2, 3, 5, 7);
        glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
        glEnable(GL_DEPTH_TEST);
        glEnable(GL_BLEND);
        glEnable(GL_CULL_FACE);
        glEnable(GL_STENCIL_TEST);
        glEnable(GL_RASTERIZER_DISCARD);
        glEnable(GL_SAMPLE_COVERAGE);
        glEnable(GL_SAMPLE_ALPHA_TO_COVERAGE);
        glSampleCoverage(0, GL_FALSE);
        CheckGLError(@"Source state setup");

        NSUInteger before = presentations;
        DrawMirrorOffMain(target, size, display, config, context, source);
        Check(presentations == before + 1, @"Mirroring did not present a frame");
        CheckColor(presentedPixels[0], 255, 0, 0);
        CheckColor(presentedPixels[1], 0, 255, 0);
        CheckColor(presentedPixels[2], 0, 0, 255);
        CheckColor(presentedPixels[3], 255, 255, 0);
        Check(eglGetCurrentContext() == context && eglGetCurrentSurface(EGL_DRAW) == source,
              @"Source context/surface changed after mirroring");
        GLint value, viewport[4];
        GLboolean mask[4];
        glGetIntegerv(GL_CURRENT_PROGRAM, &value);
        Check(value == sourceProgram, @"Caller shader program was not restored");
        glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &value);
        Check(value == framebuffers[0], @"Read framebuffer was not restored");
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &value);
        Check(value == framebuffers[1], @"Draw framebuffer was not restored");
        glGetIntegerv(GL_RENDERBUFFER_BINDING, &value);
        Check(value == renderbuffer, @"Renderbuffer was not restored");
        glGetIntegerv(GL_ACTIVE_TEXTURE, &value);
        Check(value == GL_TEXTURE3, @"Active texture unit was not restored");
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &value);
        Check(value == textures[1], @"Active-unit texture was not restored");
        glActiveTexture(GL_TEXTURE0);
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &value);
        Check(value == textures[0], @"Texture-zero binding was not restored");
        glGetIntegerv(GL_SAMPLER_BINDING, &value);
        Check(value == sampler, @"Sampler binding was not restored");
        glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &value);
        Check(value == unpackBuffer, @"Pixel unpack buffer was not restored");
        glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &value);
        Check(value == vertexArray, @"Vertex array was not restored");
        glGetIntegerv(GL_VIEWPORT, viewport);
        Check(viewport[0] == 2 && viewport[1] == 3 && viewport[2] == 5 && viewport[3] == 7,
              @"Viewport was not restored");
        glGetBooleanv(GL_COLOR_WRITEMASK, mask);
        Check(!mask[0] && !mask[1] && !mask[2] && !mask[3], @"Color mask was not restored");
        Check(glIsEnabled(GL_DEPTH_TEST) && glIsEnabled(GL_BLEND) && glIsEnabled(GL_CULL_FACE) &&
              glIsEnabled(GL_SCISSOR_TEST) && glIsEnabled(GL_STENCIL_TEST) &&
              glIsEnabled(GL_RASTERIZER_DISCARD) && glIsEnabled(GL_SAMPLE_COVERAGE) &&
              glIsEnabled(GL_SAMPLE_ALPHA_TO_COVERAGE), @"Rasterization state was not restored");
        CheckGLError(@"State verification");

        glDeleteTextures(2, textures);
        glDeleteVertexArrays(1, &vertexArray);
        glDeleteSamplers(1, &sampler);
        glDeleteBuffers(1, &unpackBuffer);
        glDeleteFramebuffers(2, framebuffers);
        glDeleteRenderbuffers(1, &renderbuffer);
        glUseProgram(0);
        glDeleteProgram(sourceProgram);
        glActiveTexture(GL_TEXTURE0);
    }
    [target updateSize:CGSizeMake(28, 16) visible:NO];
    NSUInteger before = presentations;
    DrawMirrorOffMain(target, CGSizeMake(36, 20), display, config, context, source);
    Check(presentations == before, @"A hidden mirror must not present");
    [target updateSize:CGSizeZero visible:YES];
    DrawMirrorOffMain(target, CGSizeMake(36, 20), display, config, context, source);
    Check(presentations == before, @"A zero-sized mirror must not present");
    [target updateSize:CGSizeMake(28, 16) visible:YES];
    DrawMirrorOffMain(target, CGSizeMake(36, 20), display, config, context, source);
    Check(presentations == before + 1, @"Mirroring did not resume after reattachment");
    CheckColor(presentedPixels[0], 255, 0, 0);
    CheckColor(presentedPixels[3], 255, 255, 0);
    [target clear];
    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroySurface(display, source);
    eglDestroyContext(display, context);
    AsyncGLReleaseDisplay(display);
    [window orderOut:nil];
    NSLog(@"PASS: %@ mirroring, resizing, visibility and GL state restoration",
          multisample ? @"4x MSAA" : @"single-sample");
}

#import "MirroringLifecycleTests.h"

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        TestMirroring(NO);
        TestMirroring(YES);
        TestMirroringLifecycle();
    }
    return 0;
}
