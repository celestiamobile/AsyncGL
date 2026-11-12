@import Cocoa;
@import QuartzCore;
@import OpenGL.GL3;

#include <stdatomic.h>

static _Atomic(NSUInteger) presentations;
static _Atomic(NSUInteger) uniformLookups;
static NSUInteger resolveStorageAllocations;
static BOOL failResolveStorage;
static GLubyte presentedPixels[4][4];
static CGLContextObj sourceContext;

static GLint CountUniformLookup(GLuint program, const GLchar *name) {
    ++uniformLookups;
    return glGetUniformLocation(program, name);
}

static void CountResolveStorage(GLenum target, GLenum format, GLsizei width, GLsizei height) {
    ++resolveStorageAllocations;
    glRenderbufferStorage(target, format, failResolveStorage ? -1 : width, height);
}

static void CaptureMirrorFlush(void) {
    if (CGLGetCurrentContext() == sourceContext) {
        glFlush();
        return;
    }
    GLint viewport[4];
    GLint readFramebuffer, drawFramebuffer;
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &readFramebuffer);
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &drawFramebuffer);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, drawFramebuffer);
    glGetIntegerv(GL_VIEWPORT, viewport);
    GLint width = viewport[2], height = viewport[3];
    glReadPixels(width / 4, height / 4, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, presentedPixels[0]);
    glReadPixels(3 * width / 4, height / 4, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, presentedPixels[1]);
    glReadPixels(width / 4, 3 * height / 4, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, presentedPixels[2]);
    glReadPixels(3 * width / 4, 3 * height / 4, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, presentedPixels[3]);
    ++presentations;
    glBindFramebuffer(GL_READ_FRAMEBUFFER, readFramebuffer);
    glFlush();
}

#define glFlush CaptureMirrorFlush
#define glGetUniformLocation CountUniformLookup
#import "../AsyncGL/AsyncGLMirroringTarget.m"
#undef glGetUniformLocation
#undef glFlush
#import "../AsyncGL/AsyncGLMirroringView.m"
#define glRenderbufferStorage CountResolveStorage
#import "../AsyncGL/AsyncGLView.m"
#undef glRenderbufferStorage

static void Check(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static void CheckGLError(NSString *operation) {
    GLenum error = glGetError();
    Check(error == GL_NO_ERROR, [NSString stringWithFormat:@"%@ produced GL error 0x%x", operation, error]);
}

static void CheckPixels(void) {
    const int colors[4][3] = {{255, 0, 0}, {0, 255, 0}, {0, 0, 255}, {64, 128, 191}};
    for (int index = 0; index < 4; ++index) {
        const GLubyte *pixel = presentedPixels[index];
        Check(abs(pixel[0] - colors[index][0]) <= 2 && abs(pixel[1] - colors[index][1]) <= 2 &&
              abs(pixel[2] - colors[index][2]) <= 2 && pixel[3] >= 253,
              [NSString stringWithFormat:@"Unexpected native mirrored pixel: %u %u %u %u",
                                         pixel[0], pixel[1], pixel[2], pixel[3]]);
    }
}

static void DrawOffMain(AsyncGLMirroringTarget *target, GLuint framebuffer, CGSize size, CGLContextObj context) {
    Check(CGLSetCurrentContext(NULL) == kCGLNoError, @"Could not release source context");
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            Check(CGLSetCurrentContext(context) == kCGLNoError, @"Worker could not bind source context");
            Check([target drawFromFramebuffer:framebuffer size:size], @"Source context restoration failed");
            Check(CGLGetCurrentContext() == context, @"Worker source context changed after mirroring");
            CheckGLError(@"Native mirroring");
            Check(CGLSetCurrentContext(NULL) == kCGLNoError, @"Worker could not release source context");
            dispatch_semaphore_signal(finished);
        }
    });
    Check(dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0,
          @"Native mirroring waited for the main thread");
    Check(CGLSetCurrentContext(context) == kCGLNoError, @"Could not reacquire source context");
}

static void TestNativeMirroring(BOOL multisample) {
    const CGLPixelFormatAttribute attributes[] = {
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core, 0
    };
    CGLPixelFormatObj pixelFormat = NULL;
    GLint count = 0;
    Check(CGLChoosePixelFormat(attributes, &pixelFormat, &count) == kCGLNoError && count > 0,
          @"Could not select a desktop core 4.1 pixel format");
    CGLContextObj context = NULL;
    Check(CGLCreateContext(pixelFormat, NULL, &context) == kCGLNoError,
          @"Could not create a desktop core 4.1 context");
    CGLReleasePixelFormat(pixelFormat);
    Check(CGLSetCurrentContext(context) == kCGLNoError, @"Could not bind source context");
    sourceContext = context;

    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 20, 12)
                                                  styleMask:NSWindowStyleMaskBorderless
                                                    backing:NSBackingStoreBuffered defer:NO];
    [window orderFront:nil];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while ((window.occlusionState & NSWindowOcclusionStateVisible) == 0 && deadline.timeIntervalSinceNow > 0) {
        NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                          untilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]
                                             inMode:NSDefaultRunLoopMode dequeue:YES];
        if (event != nil)
            [NSApp sendEvent:event];
        [NSApp updateWindows];
    }
    Check((window.occlusionState & NSWindowOcclusionStateVisible) != 0, @"Native test window did not become visible");
    AsyncGLMirroringView *view = [[AsyncGLMirroringView alloc] initWithFrame:NSMakeRect(0, 0, 20, 12)];
    Check([view.target prepareWithCGLContext:context], @"Could not initialize the CGL presentation context");
    window.contentView = view;
    [view updateTarget];
    AsyncGLMirroringTarget *target = view.target;

    GLuint vertex = AsyncGLCompileMirrorShader(GL_VERTEX_SHADER,
        "#version 410 core\nvoid main() { gl_Position = vec4(0, 0, 0, 1); }\n");
    GLuint fragment = AsyncGLCompileMirrorShader(GL_FRAGMENT_SHADER,
        "#version 410 core\nout vec4 color;\nvoid main() { color = vec4(1); }\n");
    Check(vertex != 0 && fragment != 0, @"Could not compile caller shaders");
    GLuint program = glCreateProgram();
    glAttachShader(program, vertex);
    glAttachShader(program, fragment);
    glLinkProgram(program);
    glDeleteShader(vertex);
    glDeleteShader(fragment);
    GLint linked = GL_FALSE;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    Check(linked == GL_TRUE, @"Could not link caller program");

    GLuint sourceFramebuffer, colorbuffer, framebuffers[2], textures[2], sampler, vertexArray, unpackBuffer;
    glGenFramebuffers(1, &sourceFramebuffer);
    glGenRenderbuffers(1, &colorbuffer);
    glGenFramebuffers(2, framebuffers);
    glGenTextures(2, textures);
    glGenSamplers(1, &sampler);
    glGenVertexArrays(1, &vertexArray);
    glGenBuffers(1, &unpackBuffer);
    NSUInteger initialLookups = uniformLookups;
    for (int pass = 0; pass < 2; ++pass) {
        CGSize size = pass == 0 ? CGSizeMake(24, 16) : CGSizeMake(36, 20);
        CGSize targetSize = pass == 0 ? CGSizeMake(20, 12) : CGSizeMake(28, 16);
        [window setContentSize:NSMakeSize(targetSize.width, targetSize.height)];
        [view layoutSubtreeIfNeeded];
        [view updateTarget];

        glBindRenderbuffer(GL_RENDERBUFFER, colorbuffer);
        if (multisample)
            glRenderbufferStorageMultisample(GL_RENDERBUFFER, 4, GL_RGBA8, size.width, size.height);
        else
            glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, size.width, size.height);
        glBindFramebuffer(GL_FRAMEBUFFER, sourceFramebuffer);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, colorbuffer);
        Check(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, @"Source framebuffer is incomplete");
        glDisable(GL_RASTERIZER_DISCARD);
        glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
        glEnable(GL_SCISSOR_TEST);
        const GLfloat colors[4][4] = {{1, 0, 0, 1}, {0, 1, 0, 1}, {0, 0, 1, 1}, {.25, .5, .75, 1}};
        for (int index = 0; index < 4; ++index) {
            glScissor((index & 1) * (GLsizei)size.width / 2, (index >> 1) * (GLsizei)size.height / 2,
                      (GLsizei)size.width / 2, (GLsizei)size.height / 2);
            glClearColor(colors[index][0], colors[index][1], colors[index][2], 1);
            glClear(GL_COLOR_BUFFER_BIT);
        }

        glUseProgram(program);
        glBindVertexArray(vertexArray);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, framebuffers[0]);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, framebuffers[1]);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, textures[0]);
        glBindSampler(0, sampler);
        glActiveTexture(GL_TEXTURE3);
        glBindTexture(GL_TEXTURE_2D, textures[1]);
        glBindBuffer(GL_PIXEL_UNPACK_BUFFER, unpackBuffer);
        glBufferData(GL_PIXEL_UNPACK_BUFFER, 1, NULL, GL_STATIC_DRAW);
        glViewport(2, 3, 5, 7);
        glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
        glEnable(GL_RASTERIZER_DISCARD);
        glEnable(GL_COLOR_LOGIC_OP);
        glLogicOp(GL_XOR);
        glEnable(GL_FRAMEBUFFER_SRGB);
        glPolygonMode(GL_FRONT_AND_BACK, GL_LINE);
        glEnable(GL_CLIP_DISTANCE0);
        glEnable(GL_CLIP_DISTANCE7);
        CheckGLError(@"Caller state setup");

        if (pass == 0) {
            // The initial Core Animation transaction may not be published yet.
            DrawOffMain(target, sourceFramebuffer, size, context);
        }
        [CATransaction flush];
        NSUInteger before = presentations;
        DrawOffMain(target, sourceFramebuffer, size, context);
        Check(presentations == before + 1, @"The CGL mirror did not draw");
        Check(uniformLookups == initialLookups + 1, @"CGL mirroring must cache the uniform location across frames and resize");
        CheckPixels();
        GLint value, viewport[4], polygonMode[2];
        GLboolean mask[4];
        glGetIntegerv(GL_CURRENT_PROGRAM, &value);
        Check(value == program, @"Caller program was not restored");
        glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &value);
        Check(value == vertexArray, @"Caller VAO was not restored");
        glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &value);
        Check(value == framebuffers[0], @"Caller read framebuffer was not restored");
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &value);
        Check(value == framebuffers[1], @"Caller draw framebuffer was not restored");
        glGetIntegerv(GL_RENDERBUFFER_BINDING, &value);
        Check(value == colorbuffer, @"Caller renderbuffer was not restored");
        glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &value);
        Check(value == unpackBuffer, @"Caller pixel unpack buffer was not restored");
        glGetIntegerv(GL_ACTIVE_TEXTURE, &value);
        Check(value == GL_TEXTURE3, @"Caller active texture was not restored");
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &value);
        Check(value == textures[1], @"Caller active-unit texture was not restored");
        glActiveTexture(GL_TEXTURE0);
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &value);
        Check(value == textures[0], @"Caller texture zero was not restored");
        glGetIntegerv(GL_SAMPLER_BINDING, &value);
        Check(value == sampler, @"Caller sampler was not restored");
        glGetIntegerv(GL_VIEWPORT, viewport);
        Check(viewport[0] == 2 && viewport[1] == 3 && viewport[2] == 5 && viewport[3] == 7,
              @"Caller viewport was not restored");
        glGetBooleanv(GL_COLOR_WRITEMASK, mask);
        Check(!mask[0] && !mask[1] && !mask[2] && !mask[3], @"Caller color mask was not restored");
        glGetIntegerv(GL_POLYGON_MODE, polygonMode);
        Check(polygonMode[0] == GL_LINE && polygonMode[1] == GL_LINE, @"Caller polygon mode was not restored");
        Check(glIsEnabled(GL_RASTERIZER_DISCARD) && glIsEnabled(GL_COLOR_LOGIC_OP) &&
              glIsEnabled(GL_FRAMEBUFFER_SRGB) && glIsEnabled(GL_CLIP_DISTANCE0) &&
              glIsEnabled(GL_CLIP_DISTANCE7) && glIsEnabled(GL_SCISSOR_TEST),
              @"Caller desktop rasterization state was not restored");
        CheckGLError(@"Caller state verification");
    }

    view.hidden = YES;
    NSUInteger before = presentations;
    DrawOffMain(target, sourceFramebuffer, CGSizeMake(36, 20), context);
    Check(presentations == before, @"A hidden CGL mirror must not draw");
    view.hidden = NO;
    DrawOffMain(target, sourceFramebuffer, CGSizeMake(36, 20), context);
    Check(presentations == before + 1, @"The CGL mirror did not resume");
    CheckPixels();
    [target clear];
    glDeleteFramebuffers(1, &sourceFramebuffer);
    glDeleteRenderbuffers(1, &colorbuffer);
    glDeleteFramebuffers(2, framebuffers);
    glDeleteTextures(2, textures);
    glDeleteSamplers(1, &sampler);
    glDeleteVertexArrays(1, &vertexArray);
    glDeleteBuffers(1, &unpackBuffer);
    glUseProgram(0);
    glDeleteProgram(program);
    CheckGLError(@"Native mirroring cleanup");
    CGLSetCurrentContext(NULL);
    CGLReleaseContext(context);
    [window orderOut:nil];
    NSLog(@"PASS: CGL 4.1 %@ mirroring, live resizing, visibility and desktop GL state restoration",
          multisample ? @"4x MSAA" : @"single-sample");
}

static void TestScreenshotResolve(void) {
    const CGLPixelFormatAttribute attributes[] = {
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core, 0
    };
    CGLPixelFormatObj format = NULL;
    CGLContextObj context = NULL;
    GLint count = 0;
    Check(CGLChoosePixelFormat(attributes, &format, &count) == kCGLNoError, @"Screenshot pixel format");
    Check(CGLCreateContext(format, NULL, &context) == kCGLNoError, @"Screenshot context");
    CGLReleasePixelFormat(format);
    Check(CGLSetCurrentContext(context) == kCGLNoError, @"Screenshot current context");
    AsyncGLView *view = [AsyncGLView new];
    view.renderContext = context;
    view.msaaEnabled = YES;
    GLuint framebuffer, colorbuffer, callerFramebuffer;
    glGenFramebuffers(1, &framebuffer);
    glGenRenderbuffers(1, &colorbuffer);
    glGenFramebuffers(1, &callerFramebuffer);
    view.framebuffer = framebuffer;
    view.renderColorbuffer = colorbuffer;
    glDisable(GL_SCISSOR_TEST);
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    NSUInteger initialAllocations = resolveStorageAllocations;
    GLuint resolveFramebuffer = 0, resolveColorbuffer = 0;
    for (int pass = 0; pass < 3; ++pass) {
        GLsizei width = pass < 2 ? 16 : 24;
        GLsizei height = pass < 2 ? 12 : 20;
        view.savedBufferSize = CGSizeMake(width, height);
        glBindRenderbuffer(GL_RENDERBUFFER, colorbuffer);
        glRenderbufferStorageMultisample(GL_RENDERBUFFER, 4, GL_RGBA8, width, height);
        glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, colorbuffer);
        Check(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, @"Screenshot source framebuffer");
        if (pass == 2) {
            failResolveStorage = YES;
            [view prepareForDrawing:^{
                glBindFramebuffer(GL_READ_FRAMEBUFFER, callerFramebuffer);
            } resolve:^{
                Check(NO, @"A failed resize must not deliver a screenshot from stale storage");
            }];
            failResolveStorage = NO;
            Check(CGSizeEqualToSize(view.resolveBufferSize, CGSizeZero),
                  @"A failed resize must invalidate the cached dimensions");
            GLint binding;
            glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &binding);
            Check(binding == callerFramebuffer, @"Failed resize must restore the read framebuffer");
            glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &binding);
            Check(binding == framebuffer, @"Failed resize must restore the draw framebuffer");
            glGetIntegerv(GL_RENDERBUFFER_BINDING, &binding);
            Check(binding == colorbuffer, @"Failed resize must restore the renderbuffer");
            CheckGLError(@"Handled screenshot allocation failure");
        }
        __block BOOL resolved = NO;
        [view prepareForDrawing:^{
            glClearColor(pass == 0 ? 1 : 0, pass == 1 ? 1 : 0, pass == 2 ? 1 : 0, 1);
            glClear(GL_COLOR_BUFFER_BIT);
            glBindFramebuffer(GL_READ_FRAMEBUFFER, callerFramebuffer);
        } resolve:^{
            GLubyte pixel[4] = {0};
            glReadPixels(width - 1, height - 1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
            Check(pixel[pass] == 255 && pixel[(pass + 1) % 3] == 0 && pixel[3] == 255,
                  @"Screenshot resolve must produce current pixels after reuse and resize");
            resolved = YES;
        }];
        Check(resolved, @"Screenshot resolve callback");
        Check(resolveStorageAllocations == initialAllocations + (pass < 2 ? 1 : 3),
              @"Screenshot resolve storage must reuse unchanged storage and retry failed resizing");
        if (pass == 0) {
            resolveFramebuffer = view.resolveFramebuffer;
            resolveColorbuffer = view.resolveColorbuffer;
        }
        Check(view.resolveFramebuffer == resolveFramebuffer && view.resolveColorbuffer == resolveColorbuffer,
              @"Screenshot resolve objects must be reused");
        GLint binding;
        glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &binding);
        Check(binding == callerFramebuffer, @"Screenshot must restore the read framebuffer");
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &binding);
        Check(binding == framebuffer, @"Screenshot must restore the draw framebuffer");
        glGetIntegerv(GL_RENDERBUFFER_BINDING, &binding);
        Check(binding == colorbuffer, @"Screenshot must restore the renderbuffer");
        CheckGLError(@"Screenshot resolve");
    }
    [view clearResources];
    Check(!glIsFramebuffer(resolveFramebuffer) && !glIsRenderbuffer(resolveColorbuffer),
          @"Screenshot resolve resources must be deleted during cleanup");
    glDeleteFramebuffers(1, &callerFramebuffer);
    CheckGLError(@"Screenshot cleanup");
    [view destroyRenderContext];
    NSLog(@"PASS: MSAA screenshot pixels, reuse, resize failure/recovery, bindings and cleanup");
}

#import "MirroringLifecycleTests.h"

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        TestNativeMirroring(NO);
        TestNativeMirroring(YES);
        TestScreenshotResolve();
        TestMirroringLifecycle();
    }
    return 0;
}
