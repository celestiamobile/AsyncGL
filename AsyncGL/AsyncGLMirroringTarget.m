//
//  Copyright (c) Levin Li. All rights reserved.
//  Licensed under the MIT License.
//

#include <os/lock.h>

#import "AsyncGLMirroring.h"

#if !defined(USE_EGL) && TARGET_OSX_OR_CATALYST
@class AsyncGLMirroringTarget;
@interface AsyncGLMirroringGLLayer : CAOpenGLLayer {
    os_unfair_lock _contextLock;
    CGLContextObj _renderContext;
}
@property (nonatomic) CGLContextObj renderContext;
@property (nonatomic, weak) NSThread *thread;
@property (nonatomic, weak) AsyncGLMirroringTarget *target;
- (CGLContextObj)copyRenderContext;
@end

@interface AsyncGLMirroringTarget ()
- (void)drawIntoCGLDrawable;
@end
#endif

static GLuint AsyncGLCompileMirrorShader(GLenum type, const char *source) {
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    GLint compiled = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (compiled != GL_TRUE) {
        GLchar message[512] = {0};
        glGetShaderInfoLog(shader, sizeof(message), NULL, message);
        NSLog(@"Mirroring shader compilation failed: %s", message);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

@implementation AsyncGLMirroringTarget {
    os_unfair_lock _lock;
    CGSize _size;
    BOOL _visible;
    NSUInteger _revision;
    NSUInteger _renderRevision;
    BOOL _failed;
    CGSize _textureSize;
    CGSize _surfaceSize;
    GLuint _texture;
    GLuint _framebuffer;
    GLuint _program;
    GLint _frameUniform;
    GLuint _vertexArray;
#ifdef USE_EGL
    EGLDisplay _display;
    EGLSurface _surface;
#elif TARGET_OSX_OR_CATALYST
    BOOL _didPresent;
    BOOL _didAttemptPresentation;
    BOOL _waitingForDrawable;
    GLsync _captureFence;
    GLsync _presentationFence;
#else
    GLuint _drawableFramebuffer;
    GLuint _colorbuffer;
#endif
}

+ (Class)layerClass {
#ifdef USE_EGL
    return [CAMetalLayer class];
#elif TARGET_OSX_OR_CATALYST
    return [AsyncGLMirroringGLLayer class];
#else
    return [CAEAGLLayer class];
#endif
}

- (instancetype)initWithLayer:(CALayer *)layer {
    if ((self = [super init])) {
        _layer = layer;
        _lock = OS_UNFAIR_LOCK_INIT;
#ifdef USE_EGL
        _surface = EGL_NO_SURFACE;
        _display = EGL_NO_DISPLAY;
#elif TARGET_OSX_OR_CATALYST
        ((AsyncGLMirroringGLLayer *)layer).asynchronous = NO;
#endif
    }
    return self;
}

- (void)updateSize:(CGSize)size visible:(BOOL)visible {
    os_unfair_lock_lock(&_lock);
    if (!CGSizeEqualToSize(_size, size) || _visible != visible) {
        _size = size;
        _visible = visible;
        ++_revision;
    }
    os_unfair_lock_unlock(&_lock);
}

- (BOOL)createProgram {
#if !defined(USE_EGL) && TARGET_OSX_OR_CATALYST
    const char *version = "#version 410 core\n";
    const char *precision = "";
#else
    const char *version = "#version 300 es\n";
    const char *precision = "precision mediump float;\n";
#endif
    const char *vertexSource =
        "out vec2 uv;\n"
        "void main() {\n"
        "  vec2 p = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));\n"
        "  uv = p;\n"
        "  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);\n"
        "}\n";
    const char *fragmentSource =
        "in vec2 uv;\n"
        "uniform sampler2D frame;\n"
        "out vec4 color;\n"
        "void main() { color = texture(frame, uv); }\n";
    NSString *vertexShader = [NSString stringWithFormat:@"%s%s", version, vertexSource];
    NSString *fragmentShader = [NSString stringWithFormat:@"%s%s%s", version, precision, fragmentSource];
    GLuint vertex = AsyncGLCompileMirrorShader(GL_VERTEX_SHADER, vertexShader.UTF8String);
    if (vertex == 0)
        return NO;
    GLuint fragment = AsyncGLCompileMirrorShader(GL_FRAGMENT_SHADER, fragmentShader.UTF8String);
    if (fragment == 0) {
        glDeleteShader(vertex);
        return NO;
    }
    _program = glCreateProgram();
    glAttachShader(_program, vertex);
    glAttachShader(_program, fragment);
    glLinkProgram(_program);
    glDeleteShader(vertex);
    glDeleteShader(fragment);
    GLint linked = GL_FALSE;
    glGetProgramiv(_program, GL_LINK_STATUS, &linked);
    if (linked != GL_TRUE) {
        GLchar message[512] = {0};
        glGetProgramInfoLog(_program, sizeof(message), NULL, message);
        NSLog(@"Mirroring program linking failed: %s", message);
        return NO;
    }
    _frameUniform = glGetUniformLocation(_program, "frame");
#if defined(USE_EGL) || !TARGET_OSX_OR_CATALYST
    glGenVertexArrays(1, &_vertexArray);
#endif
    return YES;
}

- (void)clearDrawable {
#ifdef USE_EGL
    if (_surface != EGL_NO_SURFACE) {
        if (!eglDestroySurface(_display, _surface))
            NSLog(@"Mirroring surface destruction failed: %d", eglGetError());
        _surface = EGL_NO_SURFACE;
    }
#elif TARGET_OSX_OR_CATALYST
    AsyncGLMirroringGLLayer *layer = (AsyncGLMirroringGLLayer *)_layer;
    layer.thread = nil;
    layer.target = nil;
    _waitingForDrawable = NO;
#else
    if (_drawableFramebuffer != 0)
        glDeleteFramebuffers(1, &_drawableFramebuffer);
    if (_colorbuffer != 0)
        glDeleteRenderbuffers(1, &_colorbuffer);
    _drawableFramebuffer = 0;
    _colorbuffer = 0;
#endif
    _surfaceSize = CGSizeZero;
}

- (void)clear {
    [self clearDrawable];
    if (_framebuffer != 0)
        glDeleteFramebuffers(1, &_framebuffer);
    if (_texture != 0)
        glDeleteTextures(1, &_texture);
    if (_vertexArray != 0) {
#if !defined(USE_EGL) && TARGET_OSX_OR_CATALYST
        CGLContextObj sourceContext = CGLGetCurrentContext();
        CGLContextObj presentationContext = [(AsyncGLMirroringGLLayer *)_layer copyRenderContext];
        CGLError error = CGLLockContext(presentationContext);
        if (error == kCGLNoError) {
            error = CGLSetCurrentContext(presentationContext);
            if (error == kCGLNoError)
                glDeleteVertexArrays(1, &_vertexArray);
            else
                NSLog(@"Binding the CGL mirroring context for cleanup failed: %d", error);
            error = CGLSetCurrentContext(sourceContext);
            if (error != kCGLNoError)
                NSLog(@"Restoring the source CGL context after cleanup failed: %d", error);
            error = CGLUnlockContext(presentationContext);
            if (error != kCGLNoError)
                NSLog(@"Unlocking the CGL mirroring context after cleanup failed: %d", error);
        } else {
            NSLog(@"Locking the CGL mirroring context for cleanup failed: %d", error);
        }
        CGLReleaseContext(presentationContext);
#else
        glDeleteVertexArrays(1, &_vertexArray);
#endif
    }
    if (_program != 0)
        glDeleteProgram(_program);
    _framebuffer = 0;
    _texture = 0;
    _vertexArray = 0;
    _program = 0;
    _textureSize = CGSizeZero;
}

#ifdef USE_EGL
- (BOOL)drawFromFramebuffer:(GLuint)framebuffer size:(CGSize)size display:(EGLDisplay)display config:(EGLConfig)config context:(EGLContext)context sourceSurface:(EGLSurface)sourceSurface {
#else
- (BOOL)drawFromFramebuffer:(GLuint)framebuffer size:(CGSize)size {
#endif
    os_unfair_lock_lock(&_lock);
    CGSize targetSize = _size;
    BOOL visible = _visible;
    NSUInteger revision = _revision;
    os_unfair_lock_unlock(&_lock);
    if (revision != _renderRevision) {
        _failed = NO;
        _renderRevision = revision;
    }
    if (!visible || targetSize.width < 1 || targetSize.height < 1) {
        [self clear];
        return YES;
    }
    if (_failed)
        return YES;

    // Preserve actual GL state as well as the caller's renderer-side caches.
    GLint program, vertexArray, readFramebuffer, drawFramebuffer, renderbuffer;
    GLint activeTexture, texture, sampler, unpackBuffer, viewport[4];
    GLboolean colorMask[4];
    GLboolean depth = glIsEnabled(GL_DEPTH_TEST);
    GLboolean blend = glIsEnabled(GL_BLEND);
    GLboolean cull = glIsEnabled(GL_CULL_FACE);
    GLboolean scissor = glIsEnabled(GL_SCISSOR_TEST);
    GLboolean discard = glIsEnabled(GL_RASTERIZER_DISCARD);
    GLboolean stencil = glIsEnabled(GL_STENCIL_TEST);
    GLboolean coverage = glIsEnabled(GL_SAMPLE_COVERAGE);
    GLboolean alphaCoverage = glIsEnabled(GL_SAMPLE_ALPHA_TO_COVERAGE);
#if !defined(USE_EGL) && TARGET_OSX_OR_CATALYST
    CGLContextObj sourceContext = CGLGetCurrentContext();
    GLint polygonMode[2], clipDistanceCount;
    GLboolean logicOp = glIsEnabled(GL_COLOR_LOGIC_OP);
    GLboolean sRGB = glIsEnabled(GL_FRAMEBUFFER_SRGB);
    glGetIntegerv(GL_POLYGON_MODE, polygonMode);
    glGetIntegerv(GL_MAX_CLIP_DISTANCES, &clipDistanceCount);
    GLboolean clipDistances[clipDistanceCount];
    for (GLint index = 0; index < clipDistanceCount; ++index) {
        clipDistances[index] = glIsEnabled(GL_CLIP_DISTANCE0 + index);
        glDisable(GL_CLIP_DISTANCE0 + index);
    }
    glDisable(GL_COLOR_LOGIC_OP);
    glDisable(GL_FRAMEBUFFER_SRGB);
    glPolygonMode(GL_FRONT_AND_BACK, GL_FILL);
#endif
    glGetIntegerv(GL_CURRENT_PROGRAM, &program);
    glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &vertexArray);
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &readFramebuffer);
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &drawFramebuffer);
    glGetIntegerv(GL_RENDERBUFFER_BINDING, &renderbuffer);
    glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &unpackBuffer);
    glGetIntegerv(GL_ACTIVE_TEXTURE, &activeTexture);
    glGetIntegerv(GL_VIEWPORT, viewport);
    glGetBooleanv(GL_COLOR_WRITEMASK, colorMask);
    glActiveTexture(GL_TEXTURE0);
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &texture);
    glGetIntegerv(GL_SAMPLER_BINDING, &sampler);
    glBindSampler(0, 0);
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_BLEND);
    glDisable(GL_CULL_FACE);
    glDisable(GL_SCISSOR_TEST);
    glDisable(GL_RASTERIZER_DISCARD);
    glDisable(GL_STENCIL_TEST);
    glDisable(GL_SAMPLE_COVERAGE);
    glDisable(GL_SAMPLE_ALPHA_TO_COVERAGE);
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);

    BOOL ready = YES;
    BOOL waitingForDrawable = NO;
#ifdef USE_EGL
    BOOL createdSurface = NO;
#endif
    if (_program == 0)
        ready = [self createProgram];
    if (ready && !CGSizeEqualToSize(size, _textureSize)) {
        if (_texture == 0)
            glGenTextures(1, &_texture);
        glBindTexture(GL_TEXTURE_2D, _texture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, (GLsizei)size.width, (GLsizei)size.height, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
        GLenum allocationError = glGetError();
        if (allocationError != GL_NO_ERROR) {
            NSLog(@"GL error allocating the mirroring texture: %u", allocationError);
            ready = NO;
        }
        if (_framebuffer == 0)
            glGenFramebuffers(1, &_framebuffer);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, _framebuffer);
        glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, _texture, 0);
        GLenum status = glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER);
        if (status != GL_FRAMEBUFFER_COMPLETE) {
            NSLog(@"Mirroring capture framebuffer is incomplete: %u", status);
            ready = NO;
        }
        _textureSize = size;
    }
    if (ready && !CGSizeEqualToSize(targetSize, _surfaceSize)) {
        [self clearDrawable];
#ifdef USE_EGL
        _display = display;
        _surface = eglCreateWindowSurface(display, config, (__bridge EGLNativeWindowType)_layer, NULL);
        if (_surface == EGL_NO_SURFACE) {
            NSLog(@"Mirroring surface creation failed: %d", eglGetError());
            ready = NO;
        } else {
            createdSurface = YES;
        }
#elif !TARGET_OSX_OR_CATALYST
        glGenRenderbuffers(1, &_colorbuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, _colorbuffer);
        ready = [[EAGLContext currentContext] renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer *)_layer];
        if (!ready) {
            NSLog(@"Mirroring drawable storage creation failed");
        } else {
            glGenFramebuffers(1, &_drawableFramebuffer);
            glBindFramebuffer(GL_DRAW_FRAMEBUFFER, _drawableFramebuffer);
            glFramebufferRenderbuffer(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _colorbuffer);
            GLenum status = glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER);
            if (status != GL_FRAMEBUFFER_COMPLETE) {
                NSLog(@"Mirroring drawable framebuffer is incomplete: %u", status);
                ready = NO;
            }
        }
#endif
        _surfaceSize = targetSize;
    }

    if (ready) {
        glBindFramebuffer(GL_READ_FRAMEBUFFER, framebuffer);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, _framebuffer);
        glBlitFramebuffer(0, 0, (GLsizei)size.width, (GLsizei)size.height,
                          0, 0, (GLsizei)size.width, (GLsizei)size.height,
                          GL_COLOR_BUFFER_BIT, GL_NEAREST);
        GLenum copyError = glGetError();
        if (copyError != GL_NO_ERROR) {
            NSLog(@"GL error copying the mirroring frame: %u", copyError);
            ready = NO;
        }
#ifdef USE_EGL
        if (ready) {
            ready = eglMakeCurrent(display, _surface, _surface, context);
            if (!ready)
                NSLog(@"Making mirroring surface current failed: %d", eglGetError());
            else if (createdSurface && !eglSwapInterval(display, 0)) {
                NSLog(@"Setting mirroring swap interval failed: %d", eglGetError());
                ready = NO;
            }
        }
#endif
    }
    if (ready) {
#if !defined(USE_EGL) && TARGET_OSX_OR_CATALYST
        AsyncGLMirroringGLLayer *layer = (AsyncGLMirroringGLLayer *)_layer;
        layer.thread = [NSThread currentThread];
        layer.target = self;
        _didPresent = NO;
        _didAttemptPresentation = NO;
        // Order shared-texture access in both contexts without a CPU wait.
        _captureFence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
        if (_captureFence == NULL) {
            NSLog(@"Creating the CGL capture fence failed: %u", glGetError());
            ready = NO;
        } else {
            glFlush();
            [_layer setNeedsDisplay];
            [_layer display];
            ready = _didPresent;
            if (!_didAttemptPresentation) {
                waitingForDrawable = YES;
                if (!_waitingForDrawable)
                    NSLog(@"The CGL mirroring drawable is not ready; retrying on the next frame");
            }
            _waitingForDrawable = waitingForDrawable;
        }
#else
#ifdef USE_EGL
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
#else
        glBindFramebuffer(GL_FRAMEBUFFER, _drawableFramebuffer);
#endif
        glViewport(0, 0, (GLsizei)targetSize.width, (GLsizei)targetSize.height);
        glUseProgram(_program);
        glUniform1i(_frameUniform, 0);
        glBindVertexArray(_vertexArray);
        glBindTexture(GL_TEXTURE_2D, _texture);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
#ifdef USE_EGL
        ready = eglSwapBuffers(display, _surface);
        if (!ready)
            NSLog(@"Mirroring swap failed: %d", eglGetError());
#else
        glBindRenderbuffer(GL_RENDERBUFFER, _colorbuffer);
        ready = [[EAGLContext currentContext] presentRenderbuffer:GL_RENDERBUFFER];
        if (!ready)
            NSLog(@"Mirroring presentation failed");
#endif
#endif
    }

    BOOL sourceRestored = YES;
#ifdef USE_EGL
    sourceRestored = eglMakeCurrent(display, sourceSurface, sourceSurface, context);
    if (!sourceRestored)
        NSLog(@"Restoring source surface after mirroring failed: %d", eglGetError());
#elif TARGET_OSX_OR_CATALYST
    CGLError contextError = CGLSetCurrentContext(sourceContext);
    sourceRestored = contextError == kCGLNoError;
    if (!sourceRestored)
        NSLog(@"Restoring source context after mirroring failed: %d", contextError);
    if (sourceRestored) {
        if (_presentationFence != NULL) {
            glWaitSync(_presentationFence, 0, GL_TIMEOUT_IGNORED);
            glDeleteSync(_presentationFence);
            _presentationFence = NULL;
        }
        if (_captureFence != NULL) {
            glDeleteSync(_captureFence);
            _captureFence = NULL;
        }
    }
#endif
    glUseProgram(program);
    glBindVertexArray(vertexArray);
    glBindTexture(GL_TEXTURE_2D, texture);
    glBindSampler(0, sampler);
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER, unpackBuffer);
    glActiveTexture(activeTexture);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, readFramebuffer);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, drawFramebuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, renderbuffer);
    glViewport(viewport[0], viewport[1], viewport[2], viewport[3]);
    glColorMask(colorMask[0], colorMask[1], colorMask[2], colorMask[3]);
    if (depth) glEnable(GL_DEPTH_TEST);
    if (blend) glEnable(GL_BLEND);
    if (cull) glEnable(GL_CULL_FACE);
    if (scissor) glEnable(GL_SCISSOR_TEST);
    if (discard) glEnable(GL_RASTERIZER_DISCARD);
    if (stencil) glEnable(GL_STENCIL_TEST);
    if (coverage) glEnable(GL_SAMPLE_COVERAGE);
    if (alphaCoverage) glEnable(GL_SAMPLE_ALPHA_TO_COVERAGE);
#if !defined(USE_EGL) && TARGET_OSX_OR_CATALYST
    if (logicOp) glEnable(GL_COLOR_LOGIC_OP);
    if (sRGB) glEnable(GL_FRAMEBUFFER_SRGB);
    glPolygonMode(GL_FRONT_AND_BACK, polygonMode[0]);
    for (GLint index = 0; index < clipDistanceCount; ++index) {
        if (clipDistances[index])
            glEnable(GL_CLIP_DISTANCE0 + index);
    }
#endif
    if (!ready && !waitingForDrawable) {
        _failed = YES;
        if (sourceRestored)
            [self clear];
    }
    return sourceRestored;
}

#if !defined(USE_EGL) && TARGET_OSX_OR_CATALYST
- (BOOL)prepareWithCGLContext:(CGLContextObj)context {
    const CGLPixelFormatAttribute attributes[] = {
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core,
        kCGLPFADoubleBuffer, 0
    };
    CGLPixelFormatObj pixelFormat = NULL;
    GLint count = 0;
    CGLError error = CGLChoosePixelFormat(attributes, &pixelFormat, &count);
    if (error != kCGLNoError || count < 1) {
        NSLog(@"Selecting the CGL mirroring pixel format failed: %d", error);
        return NO;
    }
    CGLContextObj presentationContext = NULL;
    error = CGLCreateContext(pixelFormat, context, &presentationContext);
    CGLReleasePixelFormat(pixelFormat);
    if (error != kCGLNoError) {
        NSLog(@"Creating the shared CGL mirroring context failed: %d", error);
        return NO;
    }
    ((AsyncGLMirroringGLLayer *)_layer).renderContext = presentationContext;
    CGLReleaseContext(presentationContext);
    return YES;
}

- (void)drawIntoCGLDrawable {
    _didAttemptPresentation = YES;
    glWaitSync(_captureFence, 0, GL_TIMEOUT_IGNORED);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_BLEND);
    glDisable(GL_CULL_FACE);
    glDisable(GL_SCISSOR_TEST);
    glDisable(GL_RASTERIZER_DISCARD);
    glDisable(GL_STENCIL_TEST);
    glDisable(GL_SAMPLE_COVERAGE);
    glDisable(GL_SAMPLE_ALPHA_TO_COVERAGE);
    glDisable(GL_COLOR_LOGIC_OP);
    glDisable(GL_FRAMEBUFFER_SRGB);
    GLint clipDistanceCount;
    glGetIntegerv(GL_MAX_CLIP_DISTANCES, &clipDistanceCount);
    for (GLint index = 0; index < clipDistanceCount; ++index)
        glDisable(GL_CLIP_DISTANCE0 + index);
    glPolygonMode(GL_FRONT_AND_BACK, GL_FILL);
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    glActiveTexture(GL_TEXTURE0);
    glBindSampler(0, 0);
    glViewport(0, 0, (GLsizei)_surfaceSize.width, (GLsizei)_surfaceSize.height);
    glUseProgram(_program);
    glUniform1i(_frameUniform, 0);
    if (_vertexArray == 0)
        glGenVertexArrays(1, &_vertexArray);
    glBindVertexArray(_vertexArray);
    glBindTexture(GL_TEXTURE_2D, _texture);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    _presentationFence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    glFlush();
    GLenum error = glGetError();
    _didPresent = error == GL_NO_ERROR && _presentationFence != NULL;
    if (!_didPresent)
        NSLog(@"Drawing or fencing the CGL mirroring frame failed: %u", error);
}
#endif
@end

#if !defined(USE_EGL) && TARGET_OSX_OR_CATALYST
@implementation AsyncGLMirroringGLLayer
- (CGLContextObj)copyRenderContext {
    os_unfair_lock_lock(&_contextLock);
    CGLContextObj context = _renderContext != NULL ? CGLRetainContext(_renderContext) : NULL;
    os_unfair_lock_unlock(&_contextLock);
    return context;
}

- (CGLContextObj)renderContext {
    return _renderContext;
}

- (void)setRenderContext:(CGLContextObj)context {
    if (context != NULL)
        CGLRetainContext(context);
    os_unfair_lock_lock(&_contextLock);
    CGLContextObj previous = _renderContext;
    _renderContext = context;
    os_unfair_lock_unlock(&_contextLock);
    if (previous != NULL)
        CGLReleaseContext(previous);
}

- (void)dealloc {
    if (_renderContext != NULL)
        CGLReleaseContext(_renderContext);
}

- (CGLPixelFormatObj)copyCGLPixelFormatForDisplayMask:(uint32_t)mask {
    CGLContextObj context = [self copyRenderContext];
    CGLPixelFormatObj pixelFormat = context != NULL ? CGLRetainPixelFormat(CGLGetPixelFormat(context)) : NULL;
    if (context != NULL)
        CGLReleaseContext(context);
    return pixelFormat;
}

- (CGLContextObj)copyCGLContextForPixelFormat:(CGLPixelFormatObj)pixelFormat {
    return [self copyRenderContext];
}

- (BOOL)canDrawInCGLContext:(CGLContextObj)context pixelFormat:(CGLPixelFormatObj)pixelFormat forLayerTime:(CFTimeInterval)time displayTime:(const CVTimeStamp *)displayTime {
    return context == _renderContext && _target != nil && [NSThread currentThread] == _thread;
}

- (void)drawInCGLContext:(CGLContextObj)context pixelFormat:(CGLPixelFormatObj)pixelFormat forLayerTime:(CFTimeInterval)time displayTime:(const CVTimeStamp *)displayTime {
    [_target drawIntoCGLDrawable];
    [super drawInCGLContext:context pixelFormat:pixelFormat forLayerTime:time displayTime:displayTime];
}
@end
#endif
