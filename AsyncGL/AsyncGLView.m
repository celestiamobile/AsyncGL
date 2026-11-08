//
//  Copyright (c) Levin Li. All rights reserved.
//  Licensed under the MIT License.
//

#include <os/lock.h>

#import "AsyncGLView+Private.h"
#import "AsyncGLMirroring.h"
#import "AsyncGLSampleBufferOutput.h"
#include <math.h>

typedef NS_OPTIONS(NSUInteger, AsyncGLViewEvent) {
    AsyncGLViewEventNone                = 0,
    AsyncGLViewEventCreateRenderContext = 1 << 0,
    AsyncGLViewEventDraw                = 1 << 1,
    AsyncGLViewEventPause               = 1 << 2,
    AsyncGLViewEventUpdateOutputs       = 1 << 3,
};

typedef NS_ENUM(NSUInteger, AsyncGLViewContextState) {
    AsyncGLViewContextStateNone,
    AsyncGLViewContextStateCreationRequested,
    AsyncGLViewContextStateMainContextCreated,
    AsyncGLViewContextStateRenderContextCreated,
    AsyncGLViewContextStateEnded,
    AsyncGLViewContextStateFailed,
};

#ifdef USE_EGL
#if TARGET_OS_OSX
@import QuartzCore.CAMetalLayer;
#endif
@import libGLESv2;
@import libEGL;

static EGLDisplay AsyncGLSharedDisplay = EGL_NO_DISPLAY;
static NSUInteger AsyncGLDisplayUsers = 0;

static EGLDisplay AsyncGLAcquireDisplay(void) {
    @synchronized ([AsyncGLView class]) {
        if (AsyncGLDisplayUsers == 0) {
            EGLAttrib attributes[] = { EGL_NONE };
            EGLDisplay display = eglGetPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE, NULL, attributes);
            if (display == EGL_NO_DISPLAY) {
                NSLog(@"eglGetPlatformDisplay() returned error %d", eglGetError());
                return EGL_NO_DISPLAY;
            }
            if (!eglInitialize(display, NULL, NULL)) {
                NSLog(@"eglInitialize() returned error %d", eglGetError());
                return EGL_NO_DISPLAY;
            }
            AsyncGLSharedDisplay = display;
        }
        ++AsyncGLDisplayUsers;
        return AsyncGLSharedDisplay;
    }
}

static void AsyncGLReleaseDisplay(EGLDisplay display) {
    @synchronized ([AsyncGLView class]) {
        NSCAssert(display == AsyncGLSharedDisplay && AsyncGLDisplayUsers > 0, @"Unbalanced EGL display release");
        if (--AsyncGLDisplayUsers == 0) {
            if (!eglTerminate(display))
                NSLog(@"eglTerminate() returned error %d", eglGetError());
            AsyncGLSharedDisplay = EGL_NO_DISPLAY;
        }
    }
}

#if DEBUG
typedef void (GL_APIENTRY *AsyncGLDebugMessageCallbackKHRProc)(GLDEBUGPROCKHR callback, const void *userParam);
typedef void (GL_APIENTRY *AsyncGLDebugMessageControlKHRProc)(GLenum source, GLenum type, GLenum severity, GLsizei count, const GLuint *ids, GLboolean enabled);
#endif

/* EGL rendering API */
typedef enum EGLRenderingAPI : int
{
    kEGLRenderingAPIOpenGLES2 = 2,
    kEGLRenderingAPIOpenGLES3 = 3,
} EGLRenderingAPI;

#if DEBUG
static void GL_APIENTRY AsyncGLKHRDebugCallback(GLenum source,
                                                GLenum type,
                                                GLuint id,
                                                GLenum severity,
                                                GLsizei length,
                                                const GLchar *message,
                                                const void *userParam) {
    const char *sourceStr;
    switch (source) {
        case GL_DEBUG_SOURCE_API_KHR:             sourceStr = "API"; break;
        case GL_DEBUG_SOURCE_WINDOW_SYSTEM_KHR:   sourceStr = "WINDOW_SYSTEM"; break;
        case GL_DEBUG_SOURCE_SHADER_COMPILER_KHR: sourceStr = "SHADER_COMPILER"; break;
        case GL_DEBUG_SOURCE_THIRD_PARTY_KHR:     sourceStr = "THIRD_PARTY"; break;
        case GL_DEBUG_SOURCE_APPLICATION_KHR:     sourceStr = "APPLICATION"; break;
        case GL_DEBUG_SOURCE_OTHER_KHR:           sourceStr = "OTHER"; break;
        default:                                  sourceStr = "UNKNOWN"; break;
    }
    const char *typeStr;
    switch (type) {
        case GL_DEBUG_TYPE_ERROR_KHR:               typeStr = "ERROR"; break;
        case GL_DEBUG_TYPE_DEPRECATED_BEHAVIOR_KHR: typeStr = "DEPRECATED"; break;
        case GL_DEBUG_TYPE_UNDEFINED_BEHAVIOR_KHR:  typeStr = "UNDEFINED"; break;
        case GL_DEBUG_TYPE_PORTABILITY_KHR:         typeStr = "PORTABILITY"; break;
        case GL_DEBUG_TYPE_PERFORMANCE_KHR:         typeStr = "PERFORMANCE"; break;
        case GL_DEBUG_TYPE_MARKER_KHR:              typeStr = "MARKER"; break;
        case GL_DEBUG_TYPE_PUSH_GROUP_KHR:          typeStr = "PUSH_GROUP"; break;
        case GL_DEBUG_TYPE_POP_GROUP_KHR:           typeStr = "POP_GROUP"; break;
        case GL_DEBUG_TYPE_OTHER_KHR:               typeStr = "OTHER"; break;
        default:                                    typeStr = "UNKNOWN"; break;
    }
    const char *severityStr;
    switch (severity) {
        case GL_DEBUG_SEVERITY_HIGH_KHR:         severityStr = "HIGH"; break;
        case GL_DEBUG_SEVERITY_MEDIUM_KHR:       severityStr = "MEDIUM"; break;
        case GL_DEBUG_SEVERITY_LOW_KHR:          severityStr = "LOW"; break;
        case GL_DEBUG_SEVERITY_NOTIFICATION_KHR: severityStr = "NOTIFICATION"; break;
        default:                                 severityStr = "UNKNOWN"; break;
    }
    NSLog(@"[GL_KHR_debug] source=%s type=%s id=%u severity=%s: %.*s",
          sourceStr, typeStr, id, severityStr, (int)length, message);
}
#endif

#else
#if TARGET_OSX_OR_CATALYST
@import OpenGL.GL;
@import OpenGL.GL3;
#else
@import OpenGLES.ES2;
@import OpenGLES.ES3;
#endif
#endif

#ifndef USE_EGL
#if TARGET_OSX_OR_CATALYST
@interface PassthroughGLLayer : CAOpenGLLayer
@property (nonatomic) CGLContextObj renderContext;
@property (nonatomic) CGLPixelFormatObj pixelFormat;
@property (nonatomic) GLuint sourceFramebuffer;
@property (nonatomic) GLsizei width;
@property (nonatomic) GLsizei height;
@property (nonatomic) NSThread *thread;
@end

@implementation PassthroughGLLayer
- (CGLPixelFormatObj)copyCGLPixelFormatForDisplayMask:(uint32_t)mask {
    return _pixelFormat != NULL ? CGLRetainPixelFormat(_pixelFormat) : NULL;
}

- (CGLContextObj)copyCGLContextForPixelFormat:(CGLPixelFormatObj)pf {
    return _renderContext != NULL ? CGLRetainContext(_renderContext) : NULL;
}

- (BOOL)canDrawInCGLContext:(CGLContextObj)ctx pixelFormat:(CGLPixelFormatObj)pf forLayerTime:(CFTimeInterval)t displayTime:(const CVTimeStamp *)ts {
    return [[NSThread currentThread] isEqual:_thread];
}

- (void)drawInCGLContext:(CGLContextObj)ctx pixelFormat:(CGLPixelFormatObj)pf forLayerTime:(CFTimeInterval)t displayTime:(const CVTimeStamp *)ts {
    CGLSetCurrentContext(ctx);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, _sourceFramebuffer);
    glBlitFramebuffer(0, 0, _width, _height, 0, 0, _width, _height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
    glFlush();
}
@end
#endif
#endif

@interface AsyncGLView () {
    BOOL _msaaEnabled;
}

@property (nonatomic) NSCondition *condition;
@property (nonatomic) os_unfair_lock renderLock;
@property (nonatomic) BOOL suspendedFlag;
@property (nonatomic) NSUInteger pauseTaskCount;
@property (nonatomic) AsyncGLViewEvent event;
@property (nonatomic) BOOL contextsCreated;
@property (nonatomic) BOOL initializationDeferred;
@property (nonatomic) BOOL didPrepareGL;
@property (nonatomic) BOOL cleanupStarted;
@property (nonatomic) BOOL cleanupFinished;
@property (nonatomic) NSMutableArray *shutdownCompletions;
@property (nonatomic) id<AsyncGLViewDelegate> cleanupDelegate;
@property (nonatomic) NSMutableArray *tasks;
@property (nonatomic) AsyncGLViewContextState contextState;
@property (nonatomic) BOOL requestExitThread;
@property (nonatomic) GLsizei sampleCount;
@property (nonatomic) AsyncGLMirroringTarget *mirroringTarget;
@property (nonatomic) AsyncGLMirroringTarget *activeMirroringTarget;
@property (nonatomic) AsyncGLSampleBufferOutput *sampleBufferOutput;
@property (nonatomic) AsyncGLSampleBufferOutput *activeSampleBufferOutput;
@property (nonatomic) BOOL shouldPresent;
#ifdef USE_EGL
@property (nonatomic) CAMetalLayer *metalLayer;
@property (nonatomic) EGLRenderingAPI internalAPI;
@property (nonatomic) EGLDisplay display;
@property (nonatomic) EGLSurface renderSurface;
@property (nonatomic) EGLConfig renderConfig;
@property (nonatomic) EGLContext renderContext;
#else
@property (nonatomic) GLuint framebuffer;
@property (nonatomic) GLuint depthBuffer;
@property (nonatomic) CGSize savedBufferSize;
#if !TARGET_OSX_OR_CATALYST
@property (nonatomic) GLuint sampleFramebuffer;
@property (nonatomic) GLuint sampleDepthbuffer;
@property (nonatomic) GLuint sampleColorbuffer;
@property (nonatomic) GLuint mainColorbuffer;
@property (nonatomic) EAGLRenderingAPI internalAPI;
@property (nonatomic) EAGLContext *renderContext;
@property (nonatomic) EAGLContext *mainContext;
@property (nonatomic) CAEAGLLayer *eaglLayer;
#else
@property (nonatomic) GLuint renderColorbuffer;
@property (nonatomic) CGLOpenGLProfile internalAPI;
@property (nonatomic) CGLContextObj renderContext;
@property (nonatomic) PassthroughGLLayer *glLayer;
#endif
#endif

@property (nonatomic) CGSize drawableSize;
@property (nonatomic) CGSize lastRenderSize;
@property (nonatomic) BOOL shouldRender;
@property (nonatomic) BOOL isObservingNotifications;
@end

@implementation AsyncGLView

#if !TARGET_OS_OSX
+ (Class)layerClass {
#ifdef USE_EGL
    return [CAMetalLayer class];
#else
#if TARGET_OS_MACCATALYST
    return [PassthroughGLLayer class];
#else
    return [CAEAGLLayer class];
#endif
#endif
}
#else
- (CALayer *)makeBackingLayer {
#ifdef USE_EGL
    return [CAMetalLayer layer];
#else
    return [PassthroughGLLayer layer];
#endif
}
#endif

#pragma mark - lifecycle/ui

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    return self;
}

- (void)pause {
    [_condition lock];
    BOOL flushContexts = _contextsCreated && !_requestExitThread;
    if (!_contextsCreated) {
        _suspendedFlag = YES;
    } else if (flushContexts && !_suspendedFlag && (_event & AsyncGLViewEventPause) == 0) {
        _pauseTaskCount = _tasks.count;
        _event |= AsyncGLViewEventPause;
        [_condition signal];
    }
    [_condition unlock];

#ifndef USE_EGL
#if !TARGET_OSX_OR_CATALYST
    if (flushContexts && [NSThread currentThread] != _renderThread) {
        [self makeMainContextCurrent];
        glFlush();
    }
#endif
#endif

    if ([NSThread currentThread] != _renderThread) {
        [_condition lock];
        while ((_event & AsyncGLViewEventPause) != 0)
            [_condition wait];
        [_condition unlock];
    }
}

- (void)finishPause {
    [self makeRenderContextCurrent];
    [_activeSampleBufferOutput finishPendingWork];
    glFlush();
    [_condition lock];
    _suspendedFlag = YES;
    _pauseTaskCount = 0;
    _event &= ~AsyncGLViewEventPause;
    [_condition broadcast];
    [_condition unlock];
}

- (void)resume {
    [_condition lock];
    _suspendedFlag = NO;
    [_condition signal];
    [_condition unlock];

    if (_contextState == AsyncGLViewContextStateRenderContextCreated)
        [self _checkViewState];
}

#pragma mark - interfaces
#if TARGET_OS_OSX
- (NSView *)startMirroring {
#else
- (UIView *)startMirroring {
#endif
    NSAssert([NSThread isMainThread], @"Mirroring must be started on main");
#if !defined(USE_EGL) && TARGET_OSX_OR_CATALYST
    if (_api != AsyncGLAPIOpenGLCore41)
        [NSException raise:NSInternalInconsistencyException format:@"Mirroring requires OpenGL core 4.1"];
#else
    if (_api != AsyncGLAPIOpenGLES3)
        [NSException raise:NSInternalInconsistencyException format:@"Mirroring requires OpenGL ES 3"];
#endif
    AsyncGLMirroringView *view = [[AsyncGLMirroringView alloc] initWithFrame:CGRectZero];
    [_condition lock];
    if (_requestExitThread) {
        [_condition unlock];
        [NSException raise:NSInternalInconsistencyException format:@"The render thread has stopped"];
    }
#if !defined(USE_EGL) && TARGET_OSX_OR_CATALYST
    if (!_contextsCreated || _renderContext == NULL) {
        [_condition unlock];
        [NSException raise:NSInternalInconsistencyException format:@"Mirroring requires an initialized OpenGL renderer"];
    }
    if (![view.target prepareWithCGLContext:_renderContext]) {
        [_condition unlock];
        [NSException raise:NSInternalInconsistencyException format:@"The CGL mirroring context could not be created"];
    }
#endif
    _mirroringTarget = view.target;
    _event |= AsyncGLViewEventUpdateOutputs | AsyncGLViewEventDraw;
    [_condition signal];
    [_condition unlock];
    return view;
}

- (void)stopMirroring {
    NSAssert([NSThread isMainThread], @"Mirroring must be stopped on main");
    [_condition lock];
    _mirroringTarget = nil;
    _event |= AsyncGLViewEventUpdateOutputs;
    [_condition signal];
    [_condition unlock];
}

- (BOOL)startSampleBufferOutputWithMaximumSize:(CGSize)maximumSize
                                      handler:(void (^)(CMSampleBufferRef))handler
                                        error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Sample-buffer output must be started on main");
    NSString *reason = nil;
#ifdef USE_EGL
    if (_api != AsyncGLAPIOpenGLES3)
        reason = @"Sample-buffer output requires OpenGL ES 3.";
#elif TARGET_OSX_OR_CATALYST
    if (_api != AsyncGLAPIOpenGLCore41)
        reason = @"Sample-buffer output requires OpenGL core 4.1.";
#else
    if (_api != AsyncGLAPIOpenGLES3)
        reason = @"Sample-buffer output requires OpenGL ES 3.";
#endif
    if (!isfinite(maximumSize.width) || !isfinite(maximumSize.height) ||
        maximumSize.width < 1 || maximumSize.height < 1 ||
        maximumSize.width > 4096 || maximumSize.height > 4096 || handler == nil)
        reason = @"Sample-buffer output requires a handler and dimensions between 1 and 4096 pixels.";
    [_condition lock];
    if (_requestExitThread)
        reason = @"The render thread has stopped.";
    if (reason == nil) {
        _sampleBufferOutput = [[AsyncGLSampleBufferOutput alloc] initWithMaximumSize:maximumSize handler:handler];
        _event |= AsyncGLViewEventUpdateOutputs | AsyncGLViewEventDraw;
        [_condition signal];
    }
    [_condition unlock];
    if (reason != nil) {
        if (error != NULL)
            *error = [NSError errorWithDomain:@"AsyncGLSampleBufferOutput" code:1 userInfo:@{NSLocalizedDescriptionKey: reason}];
        NSLog(@"%@", reason);
        return NO;
    }
    return YES;
}

- (void)stopSampleBufferOutput {
    NSAssert(NSThread.isMainThread, @"Sample-buffer output must be stopped on main");
    [_condition lock];
    _sampleBufferOutput = nil;
    _event |= AsyncGLViewEventUpdateOutputs;
    [_condition signal];
    [_condition unlock];
}

- (void)makeRenderContextCurrent {
#ifdef USE_EGL
    eglMakeCurrent(_display, _renderSurface, _renderSurface, _renderContext);
#else
#if !TARGET_OSX_OR_CATALYST
    [EAGLContext setCurrentContext:_renderContext];
    glBindFramebuffer(GL_FRAMEBUFFER, _msaaEnabled ? _sampleFramebuffer : _framebuffer);
#else
    CGLSetCurrentContext(_renderContext);
    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
#endif
#endif
}

- (void)prepareForDrawing:(void (NS_NOESCAPE ^)(void))draw resolve:(void (NS_NOESCAPE ^)(void))resolve {
    [self makeRenderContextCurrent];
    if (draw != nil)
        draw();
#ifdef USE_EGL
    if (resolve != nil)
        resolve();
#else
    if (_msaaEnabled) {
        // Save current framebuffer binding
        GLint previousFramebuffer = 0;
        glGetIntegerv(GL_FRAMEBUFFER_BINDING, &previousFramebuffer);

        GLsizei width = (GLsizei)_savedBufferSize.width;
        GLsizei height = (GLsizei)_savedBufferSize.height;
#if TARGET_OSX_OR_CATALYST
        // CAOpenGLLayer manages its own framebuffer, so here we need to create a framebuffer on our own
        GLuint tempFramebuffer;
        GLuint tempRenderbuffer;
        glGenFramebuffers(1, &tempFramebuffer);
        glBindFramebuffer(GL_FRAMEBUFFER, tempFramebuffer);
        glGenRenderbuffers(1, &tempRenderbuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, tempRenderbuffer);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, width, height);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, tempRenderbuffer);

        GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        if (status != GL_FRAMEBUFFER_COMPLETE) {
            NSLog(@"framebuffer not complete %d", status);
        } else {
            glBindFramebuffer(GL_READ_FRAMEBUFFER, _framebuffer);
            glBindFramebuffer(GL_DRAW_FRAMEBUFFER, tempFramebuffer);
            glBlitFramebuffer(0, 0, width, height, 0, 0, width, height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
            glBindFramebuffer(GL_FRAMEBUFFER, tempFramebuffer);
            if (resolve != nil)
                resolve();
        }
        glDeleteFramebuffers(1, &tempFramebuffer);
        glDeleteRenderbuffers(1, &tempRenderbuffer);
#else
        glBindFramebuffer(GL_READ_FRAMEBUFFER, _sampleFramebuffer);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, _framebuffer);
        GLenum attachments[] = { GL_COLOR_ATTACHMENT0, GL_DEPTH_ATTACHMENT };
        if (_internalAPI == kEAGLRenderingAPIOpenGLES2) {
            glResolveMultisampleFramebufferAPPLE();
            glDiscardFramebufferEXT(GL_READ_FRAMEBUFFER, 2, attachments);
        } else {
            glBlitFramebuffer(0, 0, width, height, 0, 0, width, height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
            glInvalidateFramebuffer(GL_READ_FRAMEBUFFER, 2, attachments);
        }
        glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
        if (resolve != nil)
            resolve();
#endif

        // Restore previous framebuffer binding
        glBindFramebuffer(GL_FRAMEBUFFER, previousFramebuffer);
    } else {
        if (resolve != nil)
            resolve();
    }
#endif
}

- (void)clear {
    [self clearWithDelegate:nil];
}

- (void)clearWithDelegate:(id<AsyncGLViewDelegate>)delegate {
    [self clearWithDelegate:delegate completion:nil];
}

- (void)clearWithDelegate:(id<AsyncGLViewDelegate>)delegate completion:(void (^)(void))completion {
    [_condition lock];
    if (_cleanupFinished) {
        [_condition unlock];
        if (completion != nil)
            dispatch_async(dispatch_get_main_queue(), completion);
        return;
    }
    if (completion != nil)
        [_shutdownCompletions addObject:[completion copy]];
    if (!_cleanupStarted && _cleanupDelegate == nil && delegate != nil)
        _cleanupDelegate = delegate;
    _requestExitThread = YES;
    [_condition signal];
    [_condition unlock];
}

- (void)requestRender {
    [_condition lock];
    _event |= AsyncGLViewEventDraw;
    [_condition signal];
    [_condition unlock];
}

- (void)enqueueTask:(void (^)(void))task {
    [self enqueueTask:task requiringActiveContext:NO];
}

- (void)enqueueTask:(void (^)(void))task requiringActiveContext:(BOOL)requiresActiveContext {
    [_condition lock];
    BOOL stopped = _requestExitThread || _renderThread.finished;
    BOOL uninitialized = requiresActiveContext && !_contextsCreated;
    BOOL paused = requiresActiveContext && (_suspendedFlag || (_event & AsyncGLViewEventPause) != 0);
    if (!stopped && !uninitialized && !paused) {
        [_tasks addObject:[task copy]];
        [_condition signal];
    }
    [_condition unlock];
    if (stopped || uninitialized || paused)
        [NSException raise:NSInternalInconsistencyException format:stopped ? @"The render thread has stopped" : (uninitialized ? @"The render context is not initialized" : @"Rendering is paused")];
}

- (void)updateOutputs {
    [_condition lock];
    AsyncGLMirroringTarget *target = _mirroringTarget;
    AsyncGLSampleBufferOutput *output = _sampleBufferOutput;
    [_condition unlock];
    if (_activeMirroringTarget != target) {
        [self makeRenderContextCurrent];
        [_activeMirroringTarget clear];
        _activeMirroringTarget = target;
    }
    if (_activeSampleBufferOutput != output) {
        [self makeRenderContextCurrent];
        [_activeSampleBufferOutput clear];
        _activeSampleBufferOutput = output;
    }
}

- (void)render {
    if (@available(iOS 18.0, tvOS 18.0, macOS 15.0, *)) {
        os_unfair_lock_lock_with_flags(&_renderLock, OS_UNFAIR_LOCK_FLAG_ADAPTIVE_SPIN);
    } else {
        os_unfair_lock_lock(&_renderLock);
    }
    CGSize size = _drawableSize;
    BOOL shouldRender = _shouldRender;
    BOOL shouldPresent = _shouldPresent;
    os_unfair_lock_unlock(&_renderLock);

    if (shouldRender) {
        if (!CGSizeEqualToSize(_lastRenderSize, size)) {
            _lastRenderSize = size;
            #ifndef USE_EGL
            #if !TARGET_OSX_OR_CATALYST
            [self makeMainContextCurrent];
            glBindRenderbuffer(GL_RENDERBUFFER, _mainColorbuffer);
            [_mainContext renderbufferStorage:GL_RENDERBUFFER fromDrawable:_eaglLayer];
            #endif
            #endif
        }

        [self makeRenderContextCurrent];
        [self _drawGL:size];
#ifdef USE_EGL
        [_activeSampleBufferOutput drawFromFramebuffer:0 size:size];
#else
        [_activeSampleBufferOutput drawFromFramebuffer:_framebuffer size:size];
#endif
        if (_activeMirroringTarget != nil) {
#ifdef USE_EGL
            if (![_activeMirroringTarget drawFromFramebuffer:0 size:size display:_display config:_renderConfig context:_renderContext sourceSurface:_renderSurface])
                return;
#else
            [_activeMirroringTarget drawFromFramebuffer:_framebuffer size:size];
#endif
        }
        if (!shouldPresent) {
            glFlush();
            return;
        }
    #ifdef USE_EGL
        eglSwapBuffers(_display, _renderSurface);
    #else
        glFlush();
    #if !TARGET_OSX_OR_CATALYST
        glBindRenderbuffer(GL_RENDERBUFFER, _mainColorbuffer);
        [_renderContext presentRenderbuffer:GL_RENDERBUFFER];
    #else
        [_glLayer display];
    #endif
    #endif
    }
}

#pragma mark - private methods
- (void)commonSetup {
    _drawableSize = CGSizeZero;
    _lastRenderSize = CGSizeZero;
    _shouldRender = NO;
    _shouldPresent = NO;
    _contextsCreated = NO;
    _contextState = AsyncGLViewContextStateNone;
    _requestExitThread = NO;
    _tasks = [NSMutableArray array];
    _shutdownCompletions = [NSMutableArray array];
    _isObservingNotifications = NO;
    _sampleCount = 0;
#ifdef USE_EGL
    _internalAPI = _api == AsyncGLAPIOpenGLES3 ? kEGLRenderingAPIOpenGLES3 : kEGLRenderingAPIOpenGLES2;
    _display = EGL_NO_DISPLAY;
    _renderSurface = EGL_NO_SURFACE;
    _renderContext = EGL_NO_CONTEXT;
#else
#if !TARGET_OSX_OR_CATALYST
    _internalAPI = _api == AsyncGLAPIOpenGLES3 ? kEAGLRenderingAPIOpenGLES3 : kEAGLRenderingAPIOpenGLES2;
    _mainContext = nil;
    _renderContext = nil;
    _mainColorbuffer = 0;
    _sampleFramebuffer = 0;
    _sampleDepthbuffer = 0;
    _sampleColorbuffer = 0;
#else
    switch (_api)
    {
    case AsyncGLAPIOpenGLCore32:
        _internalAPI = kCGLOGLPVersion_GL3_Core;
        break;
    case AsyncGLAPIOpenGLCore41:
        _internalAPI = kCGLOGLPVersion_GL4_Core;
        break;
    case AsyncGLAPIOpenGLLegacy:
    default:
        _internalAPI = kCGLOGLPVersion_Legacy;
    }
    _renderContext = NULL;
    _renderColorbuffer = 0;
#endif
    _framebuffer = 0;
    _depthBuffer = 0;
    _savedBufferSize = CGSizeZero;
#endif

#if TARGET_OS_OSX
    self.wantsLayer = YES;
#endif

    // Set layer properties
    self.layer.opaque = YES;
#if !TARGET_OS_OSX
    self.layer.backgroundColor = [[UIColor blackColor] CGColor];
#else
    self.layer.backgroundColor = [[NSColor blackColor] CGColor];
#endif

#ifdef USE_EGL
    _metalLayer = (CAMetalLayer *)self.layer;
#elif TARGET_OSX_OR_CATALYST
    _glLayer = (PassthroughGLLayer *)self.layer;
    _glLayer.asynchronous = YES;
#else
    _eaglLayer = (CAEAGLLayer *)self.layer;
    if ([_eaglLayer respondsToSelector:NSSelectorFromString(@"setLowLatency:")])
        [_eaglLayer setValue:@(YES) forKey:@"lowLatency"];
#endif

    _event = AsyncGLViewEventNone;
    _condition = [[NSCondition alloc] init];
    _renderLock = OS_UNFAIR_LOCK_INIT;
    _renderThread = [[NSThread alloc] initWithTarget:self selector:@selector(renderThreadMain) object:nil];
#ifndef USE_EGL
#if TARGET_OSX_OR_CATALYST
    _glLayer.thread = _renderThread;
#endif
#endif
    [_renderThread setThreadPriority:1.0];
    [_renderThread setQualityOfService:NSOperationQualityOfServiceUserInteractive];
    [_renderThread start];
}

- (void)renderThreadMain {
    while (YES) {
        @autoreleasepool {
            AsyncGLViewEvent event = AsyncGLViewEventNone;
            BOOL needsDrawn = NO;

            [_condition lock];
            while (!_requestExitThread &&
                   (_event & (AsyncGLViewEventCreateRenderContext | AsyncGLViewEventUpdateOutputs)) == 0 &&
                   (_suspendedFlag || (_event == AsyncGLViewEventNone && !(_contextsCreated && _tasks.count > 0)))) {
                if (_contextsCreated && !_suspendedFlag && [_activeSampleBufferOutput hasPendingFrames]) {
                    if (![_condition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]])
                        break;
                } else {
                    [_condition wait];
                }
            }

            BOOL requestExitThread = _requestExitThread;
            event = _event;
            // Servicing output changes must not consume a draw queued during pause.
            _event &= AsyncGLViewEventPause | (_suspendedFlag ? AsyncGLViewEventDraw : 0);
            if (_suspendedFlag)
                event &= ~AsyncGLViewEventDraw;

            BOOL paused = (event & AsyncGLViewEventPause) != 0;
            BOOL canRunTasks = _contextsCreated && !_suspendedFlag;
            NSArray *tasks = nil;
            NSUInteger taskCount = canRunTasks ? (paused ? _pauseTaskCount : _tasks.count) : 0;
            if (taskCount > 0) {
                NSRange range = NSMakeRange(0, taskCount);
                tasks = [_tasks subarrayWithRange:range];
                [_tasks removeObjectsInRange:range];
            }
            NSArray *discardedTasks = nil;
            if (requestExitThread && _tasks.count > 0) {
                discardedTasks = [_tasks copy];
                [_tasks removeAllObjects];
            }

            [_condition unlock];

            if (requestExitThread) {
                if (canRunTasks)
                    [self runTasks:tasks];
                if (paused)
                    [self finishPause];
                if (discardedTasks.count > 0)
                    NSLog(@"Discarding %lu deferred tasks during shutdown", (unsigned long)discardedTasks.count);
                [self clearGL];
                dispatch_sync(dispatch_get_main_queue(), ^{
                    self.contextState = AsyncGLViewContextStateEnded;
                });
                break;
            }

            if ((event & AsyncGLViewEventCreateRenderContext) != 0) {
                if ([self createRenderContext]) {
                    [_condition lock];
                    _contextsCreated = YES;
                    [_condition unlock];
                    // Main may be waiting for pause; do not make initialization wait for main again.
                    dispatch_async(dispatch_get_main_queue(), ^{
                        self.contextState = AsyncGLViewContextStateRenderContextCreated;
                        [self _startObservingViewStateNotifications];
                        [self _checkViewState];
                    });
                }
                else if (_initializationDeferred) {
                    [self _clearGL];
                    _initializationDeferred = NO;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        self.contextState = AsyncGLViewContextStateCreationRequested;
                        [self _checkViewState];
                    });
                }
                else {
                    [_condition lock];
                    _requestExitThread = YES;
                    NSArray *discardedTasks = [_tasks copy];
                    [_tasks removeAllObjects];
                    [_condition unlock];
                    if (discardedTasks.count > 0)
                        NSLog(@"Discarding %lu tasks because context creation failed", (unsigned long)discardedTasks.count);
                    [self clearGL];
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        self.contextState = AsyncGLViewContextStateFailed;
                    });
                    break;
                }
            }

            if (_contextsCreated) {
                [self updateOutputs];
                if ((event & AsyncGLViewEventDraw) != 0 && !paused)
                    needsDrawn = YES;

                [self runTasks:tasks];
            }
            if (paused)
                [self finishPause];

            [_condition lock];
            BOOL canRender = !_suspendedFlag && (_event & AsyncGLViewEventPause) == 0 && !_requestExitThread;
            needsDrawn = needsDrawn && canRender;
            [_condition unlock];
            if (needsDrawn)
                [self render];
            if (canRender && [_activeSampleBufferOutput hasPendingFrames]) {
                [self makeRenderContextCurrent];
                [_activeSampleBufferOutput pollPendingFrames];
            }
        }
    }
    [_condition lock];
    _cleanupFinished = YES;
    NSArray *completions = [_shutdownCompletions copy];
    [_shutdownCompletions removeAllObjects];
    [_condition unlock];
    dispatch_async(dispatch_get_main_queue(), ^{
        for (void (^completion)(void) in completions)
            completion();
    });
}

- (void)runTasks:(NSArray *)tasks {
    if (tasks.count == 0)
        return;
    [self makeRenderContextCurrent];
    for (void (^task)(void) in tasks)
        task();
}

#pragma mark - context creation
#ifdef USE_EGL
- (EGLContext)createEGLContextWithDisplay:(EGLDisplay)display api:(EGLRenderingAPI)api sharedContext:(EGLContext)sharedContext config:(EGLConfig*)config depthSize:(EGLint)depthSize msaa:(BOOL*)msaa {
    EGLint multisampleAttribs[] = {
        EGL_RENDERABLE_TYPE, api == kEGLRenderingAPIOpenGLES3 ? EGL_OPENGL_ES3_BIT : EGL_OPENGL_ES2_BIT,
        EGL_BLUE_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_RED_SIZE, 8,
        EGL_DEPTH_SIZE, depthSize,
        EGL_SAMPLES, 4,
        EGL_SAMPLE_BUFFERS, 1,
        EGL_NONE
    };
    EGLint attribs[] = {
        EGL_RENDERABLE_TYPE, api == kEGLRenderingAPIOpenGLES3 ? EGL_OPENGL_ES3_BIT : EGL_OPENGL_ES2_BIT,
        EGL_BLUE_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_RED_SIZE, 8,
        EGL_DEPTH_SIZE, depthSize,
        EGL_NONE
    };

    EGLConfig configs[64];
    EGLint numConfigs;
    EGLint format;
    if (*msaa) {
        // Try MSAA config first
        if (eglChooseConfig(display, multisampleAttribs, configs, sizeof(configs) / sizeof(EGLConfig), &numConfigs)) {
            for (EGLint i = 0; i < numConfigs; ++i) {
                if (eglGetConfigAttrib(display, configs[i], EGL_NATIVE_VISUAL_ID, &format)) {
                    *config = configs[i];
                    break;
                } else {
                    NSLog(@"eglGetConfigAttrib() returned error %d", eglGetError());
                }
            }
        } else {
            NSLog(@"eglChooseConfig() returned error %d", eglGetError());
        }
    }

    // Fallback to non-MSAA config if MSAA not requested or unavailable
    if (*config == EGL_NO_CONTEXT) {
        if (!eglChooseConfig(display, attribs, configs, sizeof(configs) / sizeof(EGLConfig), &numConfigs)) {
            NSLog(@"eglChooseConfig() returned error %d", eglGetError());
            return EGL_NO_CONTEXT;
        }

        for (EGLint i = 0; i < numConfigs; ++i) {
            if (eglGetConfigAttrib(display, configs[i], EGL_NATIVE_VISUAL_ID, &format)) {
                *config = configs[i];
                break;
            } else {
                NSLog(@"eglGetConfigAttrib() returned error %d", eglGetError());
            }
        }
    }

    if (*config == EGL_NO_CONTEXT) {
        NSLog(@"No suitable EGLConfig found");
        return EGL_NO_CONTEXT;
    }

    // Init context
    int ctxMajorVersion = 2;
    int ctxMinorVersion = 0;
    switch (api)
    {
        case kEGLRenderingAPIOpenGLES2:
            ctxMajorVersion = 2;
            ctxMinorVersion = 0;
            break;
        case kEGLRenderingAPIOpenGLES3:
            ctxMajorVersion = 3;
            ctxMinorVersion = 0;
            break;
        default:
            NSLog(@"Unknown GL ES API %d", api);
            return EGL_NO_CONTEXT;
    }
    EGLint ctxAttribs[] = {
        EGL_CONTEXT_MAJOR_VERSION, ctxMajorVersion,
        EGL_CONTEXT_MINOR_VERSION, ctxMinorVersion,
#if DEBUG
        EGL_CONTEXT_FLAGS_KHR, EGL_CONTEXT_OPENGL_DEBUG_BIT_KHR,
#endif
        EGL_NONE,
    };

    EGLContext eglContext = eglCreateContext(display, *config, sharedContext, ctxAttribs);
    if (eglContext == EGL_NO_CONTEXT) {
        NSLog(@"eglCreateContext() returned error %d", eglGetError());
        return EGL_NO_CONTEXT;
    }
    return eglContext;
}
#endif

- (void)createContexts {
    [_condition lock];
    BOOL stopped = _requestExitThread;
    [_condition unlock];
    if (stopped)
        return;
    CGSize size = [self pixelSize];
    if (size.width < 1 || size.height < 1) {
        _contextState = AsyncGLViewContextStateCreationRequested;
        return;
    }
#ifdef USE_EGL
    _contextState = AsyncGLViewContextStateMainContextCreated;

    [_condition lock];
    _event |= AsyncGLViewEventCreateRenderContext;
    [_condition signal];
    [_condition unlock];
#else
#if !TARGET_OSX_OR_CATALYST
    _mainContext = [[EAGLContext alloc] initWithAPI:_internalAPI];
    if (_mainContext == nil) {
        _contextState = AsyncGLViewContextStateFailed;
        return;
    }

    _contextState = AsyncGLViewContextStateMainContextCreated;
    [_condition lock];
    _event = AsyncGLViewEventCreateRenderContext;
    [_condition signal];
    [_condition unlock];
#else
    const CGLPixelFormatAttribute attr[] = {
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)_internalAPI,
        kCGLPFADoubleBuffer, 0
    };
    CGLPixelFormatObj pixelFormat = NULL;
    GLint npix;
    CGLError error = CGLChoosePixelFormat(attr, &pixelFormat, &npix);
    if (pixelFormat == NULL) {
        _contextState = AsyncGLViewContextStateFailed;
        return;
    }

    CGLContextObj mainContext = NULL;
    error = CGLCreateContext(pixelFormat, NULL, &mainContext);
    if (mainContext == NULL) {
        CGLReleasePixelFormat(pixelFormat);
        _contextState = AsyncGLViewContextStateFailed;
        return;
    }

    _glLayer.pixelFormat = pixelFormat;
    _glLayer.renderContext = mainContext;

    _contextState = AsyncGLViewContextStateMainContextCreated;
    [_condition lock];
    _event = AsyncGLViewEventCreateRenderContext;
    [_condition signal];
    [_condition unlock];
#endif
#endif
}

- (CGSize)pixelSize {
    CGSize size = self.frame.size;
    CGFloat scale = self.layer.contentsScale;
    return CGSizeMake(size.width * scale, size.height * scale);
}

- (BOOL)createRenderContext {
#ifdef USE_EGL
    _display = AsyncGLAcquireDisplay();
    if (_display == EGL_NO_DISPLAY)
        return NO;

    _renderContext = [self createEGLContextWithDisplay:_display api:_internalAPI sharedContext:EGL_NO_CONTEXT config:&_renderConfig depthSize:24 msaa:&_msaaEnabled];

    if (_msaaEnabled) {
        EGLint numSamples;
        if (eglGetConfigAttrib(_display, _renderConfig, EGL_SAMPLES, &numSamples) && numSamples > 1)
            _sampleCount = (GLsizei)numSamples;
    }

    if (_renderContext == EGL_NO_CONTEXT)
        return NO;

    __block CGSize size;
    __block EGLSurface renderSurface = EGL_NO_SURFACE;
    dispatch_sync(dispatch_get_main_queue(), ^{
        size = [self pixelSize];
        if (size.width >= 1 && size.height >= 1)
            renderSurface = eglCreateWindowSurface(_display, _renderConfig, (__bridge EGLNativeWindowType)(_metalLayer), NULL);
    });
    _renderSurface = renderSurface;
    if (size.width < 1 || size.height < 1) {
        _initializationDeferred = YES;
        return NO;
    }

    if (_renderSurface == EGL_NO_SURFACE) {
        NSLog(@"eglCreateWindowSurface() returned error %d", eglGetError());
        return NO;
    }

    [self makeRenderContextCurrent];
    eglSwapInterval(_display, 0);

#if DEBUG
    const char *extensions = (const char *)glGetString(GL_EXTENSIONS);
    if (extensions != NULL && strstr(extensions, "GL_KHR_debug") != NULL) {
        AsyncGLDebugMessageCallbackKHRProc debugMessageCallback = (AsyncGLDebugMessageCallbackKHRProc)eglGetProcAddress("glDebugMessageCallbackKHR");
        AsyncGLDebugMessageControlKHRProc debugMessageControl = (AsyncGLDebugMessageControlKHRProc)eglGetProcAddress("glDebugMessageControlKHR");
        if (debugMessageCallback != NULL) {
            glEnable(GL_DEBUG_OUTPUT_KHR);
            glEnable(GL_DEBUG_OUTPUT_SYNCHRONOUS_KHR);
            debugMessageCallback(AsyncGLKHRDebugCallback, NULL);
            if (debugMessageControl != NULL)
                debugMessageControl(GL_DONT_CARE, GL_DONT_CARE, GL_DONT_CARE, 0, NULL, GL_TRUE);
        }
    }
#endif

    return [self setupGL:size];
#else
#if !TARGET_OSX_OR_CATALYST
    _renderContext = [[EAGLContext alloc] initWithAPI:_mainContext.API sharegroup:_mainContext.sharegroup];
    if (_renderContext == nil)
        return NO;

    __block CGSize size;
    dispatch_sync(dispatch_get_main_queue(), ^{
        size = [self pixelSize];
        if (size.width >= 1 && size.height >= 1) {
            [self makeMainContextCurrent];
            [self createMainBuffers];
        }
    });
    if (size.width < 1 || size.height < 1) {
        _initializationDeferred = YES;
        return NO;
    }

    [self makeRenderContextCurrent];

    if (_msaaEnabled) {
        GLint numSamples;
        glGetIntegerv(GL_MAX_SAMPLES, &numSamples);
        if (numSamples > 1)
            _sampleCount = MIN(numSamples, 4);
        else
            _msaaEnabled = NO;
    }

    return [self createRenderBuffers:size];
#else
    const CGLPixelFormatAttribute attr[] = {
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)_internalAPI,
        0
    };
    CGLPixelFormatObj pixelFormat = NULL;
    GLint npix;
    CGLError error = CGLChoosePixelFormat(attr, &pixelFormat, &npix);
    if (!pixelFormat)
        return NO;

    error = CGLCreateContext(pixelFormat, _glLayer.renderContext, &_renderContext);
    CGLReleasePixelFormat(pixelFormat);
    if (!_renderContext)
        return NO;

    [self makeRenderContextCurrent];

    if (_msaaEnabled) {
        glEnable(GL_MULTISAMPLE);
        GLint numSamples;
        glGetIntegerv(GL_MAX_SAMPLES, &numSamples);
        if (numSamples > 1)
            _sampleCount = MIN(numSamples, 4);
        else
            _msaaEnabled = NO;
    }

    __block CGSize size;
    dispatch_sync(dispatch_get_main_queue(), ^{
        size = [self pixelSize];
    });
    if (size.width < 1 || size.height < 1) {
        _initializationDeferred = YES;
        return NO;
    }
    glGenRenderbuffers(1, &_renderColorbuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, _renderColorbuffer);
    return [self createRenderBuffers:size];
#endif
#endif
}

#ifndef USE_EGL
#pragma mark - buffer creation
#if !TARGET_OSX_OR_CATALYST
- (void)createMainBuffers {
    glGenRenderbuffers(1, &_mainColorbuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, _mainColorbuffer);
    [_mainContext renderbufferStorage:GL_RENDERBUFFER fromDrawable:_eaglLayer];
}
#endif

- (BOOL)createRenderBuffers:(CGSize)size {
    glGenFramebuffers(1, &_framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);

#if TARGET_OSX_OR_CATALYST
    glGenRenderbuffers(1, &_depthBuffer);

    [self updateBuffersSize:size];

    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _renderColorbuffer);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, _depthBuffer);
#else
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _mainColorbuffer);

    if (_msaaEnabled) {
        glGenRenderbuffers(1, &_sampleColorbuffer);
        glGenRenderbuffers(1, &_sampleDepthbuffer);

        [self updateBuffersSize:size];

        glGenFramebuffers(1, &_sampleFramebuffer);
        glBindFramebuffer(GL_FRAMEBUFFER, _sampleFramebuffer);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _sampleColorbuffer);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, _sampleDepthbuffer);

        // Check sampleFramebuffer
        GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        if (status != GL_FRAMEBUFFER_COMPLETE) {
            NSLog(@"framebuffer not complete %d", status);
            return NO;
        }

        // Bind back
        glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
    } else {
        glGenRenderbuffers(1, &_depthBuffer);

        [self updateBuffersSize:size];

        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, _depthBuffer);
    }
#endif

    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        NSLog(@"framebuffer not complete %d", status);
        return NO;
    }

#if TARGET_OSX_OR_CATALYST
    _glLayer.sourceFramebuffer = _framebuffer;
#endif

    return [self setupGL:size];
}

#if !TARGET_OSX_OR_CATALYST
- (void)makeMainContextCurrent {
    [EAGLContext setCurrentContext:_mainContext];
}
#endif
#endif

- (void)updateBuffersSize:(CGSize)size {
#ifndef USE_EGL
    if (CGSizeEqualToSize(_savedBufferSize, size))
        return;

    _savedBufferSize = size;

    GLsizei width = (GLsizei)size.width;
    GLsizei height = (GLsizei)size.height;

#if TARGET_OSX_OR_CATALYST
    if (_msaaEnabled) {
        glBindRenderbuffer(GL_RENDERBUFFER, _renderColorbuffer);
        glRenderbufferStorageMultisample(GL_RENDERBUFFER, _sampleCount, GL_RGBA8, width, height);
        glBindRenderbuffer(GL_RENDERBUFFER, _depthBuffer);
        glRenderbufferStorageMultisample(GL_RENDERBUFFER, _sampleCount, GL_DEPTH_COMPONENT24, width, height);
    } else {
        glBindRenderbuffer(GL_RENDERBUFFER, _renderColorbuffer);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, width, height);
        glBindRenderbuffer(GL_RENDERBUFFER, _depthBuffer);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, width, height);
    }

    _glLayer.width = width;
    _glLayer.height = height;
#else
    if (_msaaEnabled) {
        glBindRenderbuffer(GL_RENDERBUFFER, _sampleColorbuffer);
        glRenderbufferStorageMultisample(GL_RENDERBUFFER, _sampleCount, GL_RGBA8_OES, width, height);
        glBindRenderbuffer(GL_RENDERBUFFER, _sampleDepthbuffer);
        glRenderbufferStorageMultisample(GL_RENDERBUFFER, _sampleCount, GL_DEPTH_COMPONENT24, width, height);
    } else {
        glBindRenderbuffer(GL_RENDERBUFFER, _depthBuffer);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, width, height);
    }
#endif
#endif
}

#pragma mark - internal implementation
- (BOOL)setupGL:(CGSize)size {
    _didPrepareGL = YES;
    return [_delegate _prepareGL:size samples:(NSInteger)_sampleCount];
}

- (void)_drawGL:(CGSize)size
{
    [self updateBuffersSize:size];

#if TARGET_OSX_OR_CATALYST || defined(USE_EGL)
    [_delegate _drawGL:size];
#else
    if (_msaaEnabled) {
        GLsizei width = (GLsizei)size.width;
        GLsizei height = (GLsizei)size.height;
        glBindFramebuffer(GL_FRAMEBUFFER, _sampleFramebuffer);

        [_delegate _drawGL:size];

        glBindFramebuffer(GL_READ_FRAMEBUFFER, _sampleFramebuffer);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, _framebuffer);

        GLenum attachments[] = { GL_COLOR_ATTACHMENT0, GL_DEPTH_ATTACHMENT };
        if (_internalAPI == kEAGLRenderingAPIOpenGLES2) {
            glResolveMultisampleFramebufferAPPLE();
            glDiscardFramebufferEXT(GL_READ_FRAMEBUFFER, 2, attachments);
        } else {
            glBlitFramebuffer(0, 0, width, height, 0, 0, width, height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
            glInvalidateFramebuffer(GL_READ_FRAMEBUFFER, 2, attachments);
        }
    } else {
        [_delegate _drawGL:size];
    }
#endif
}

#pragma mark - clear
- (void)clearGL {
    [_condition lock];
    _cleanupStarted = YES;
    __block id<AsyncGLViewDelegate> delegate = _cleanupDelegate ?: _delegate;
    _cleanupDelegate = nil;
    _mirroringTarget = nil;
    _sampleBufferOutput = nil;
    [_condition unlock];
    if (_activeSampleBufferOutput != nil) {
        [self makeRenderContextCurrent];
        [_activeSampleBufferOutput clear];
        _activeSampleBufferOutput = nil;
    }
    if (_activeMirroringTarget != nil) {
        [self makeRenderContextCurrent];
        [_activeMirroringTarget clear];
        _activeMirroringTarget = nil;
    }
    if (_didPrepareGL) {
        [self makeRenderContextCurrent];
        [delegate _clearGL];
    }

    [self _clearGL];
    dispatch_async(dispatch_get_main_queue(), ^{
        delegate = nil;
    });
}

- (void)_clearGL {
    BOOL canUseContext = _renderContext != NULL;
#ifdef USE_EGL
    canUseContext = canUseContext && _renderSurface != EGL_NO_SURFACE;
#endif
    if (canUseContext) {
        [self makeRenderContextCurrent];
        glFlush();
        [self clearResources];
    }
    [self destroyRenderContext];

    dispatch_sync(dispatch_get_main_queue(), ^{
        [self _stopObservingViewStateNotifications];
        [self destroyMainContext];
    });
}

- (void)clearResources {
#ifndef USE_EGL
    if (_depthBuffer != 0) {
        glDeleteRenderbuffers(1, &_depthBuffer);
        _depthBuffer = 0;
    }

#if !TARGET_OSX_OR_CATALYST
    if (_sampleFramebuffer != 0) {
        glDeleteFramebuffers(1, &_sampleFramebuffer);
        _sampleFramebuffer = 0;
    }

    if (_sampleDepthbuffer != 0) {
        glDeleteRenderbuffers(1, &_sampleDepthbuffer);
        _sampleDepthbuffer = 0;
    }

    if (_sampleColorbuffer != 0) {
        glDeleteRenderbuffers(1, &_sampleColorbuffer);
        _sampleColorbuffer = 0;
    }
#endif

    if (_framebuffer != 0) {
        glDeleteFramebuffers(1, &_framebuffer);
        _framebuffer = 0;
    }

#if TARGET_OSX_OR_CATALYST
    if (_renderColorbuffer != 0) {
        glDeleteRenderbuffers(1, &_renderColorbuffer);
        _renderColorbuffer = 0;
    }
#endif
#endif
}

- (void)destroyMainContext {
#ifndef USE_EGL
#if TARGET_OSX_OR_CATALYST
    _glLayer.sourceFramebuffer = 0;
    if (_glLayer.renderContext != NULL) {
        CGLReleaseContext(_glLayer.renderContext);
        _glLayer.renderContext = NULL;
    }
    if (_glLayer.pixelFormat != NULL) {
        CGLReleasePixelFormat(_glLayer.pixelFormat);
        _glLayer.pixelFormat = NULL;
    }
#else
    if (_mainContext == nil)
        return;
    [self makeMainContextCurrent];
    glFlush();

    if (_mainColorbuffer != 0) {
        glDeleteRenderbuffers(1, &_mainColorbuffer);
        _mainColorbuffer = 0;
    }

    _mainContext = nil;
#endif
#endif
}

- (void)destroyRenderContext {
#ifdef USE_EGL
    if (_renderSurface != EGL_NO_SURFACE) {
        eglDestroySurface(_display, _renderSurface);
        _renderSurface = EGL_NO_SURFACE;
    }

    if (_renderContext != EGL_NO_CONTEXT) {
        eglMakeCurrent(_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        eglDestroyContext(_display, _renderContext);
        _renderContext = EGL_NO_CONTEXT;
    }

    if (_display != EGL_NO_DISPLAY) {
        AsyncGLReleaseDisplay(_display);
        _display = EGL_NO_DISPLAY;
    }
    _renderConfig = NULL;
#else
#if TARGET_OSX_OR_CATALYST
    if (_renderContext != NULL) {
        if (CGLGetCurrentContext() == _renderContext)
            CGLSetCurrentContext(NULL);
        CGLReleaseContext(_renderContext);
    }
    _renderContext = NULL;
#else
    _renderContext = nil;
#endif
#endif
}

#pragma mark - view checker
- (BOOL)_allowsOffscreenRendering {
    return NO;
}

- (void)_startObservingViewStateNotifications {
    if (_isObservingNotifications)
        return;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
#if TARGET_OS_OSX
    [center addObserver:self selector:@selector(_checkViewState) name:NSViewFrameDidChangeNotification object:self];
    [center addObserver:self selector:@selector(_handleWindowOcclusionStateChanged:) name:NSWindowDidChangeOcclusionStateNotification object:nil];
#else
    [center addObserver:self selector:@selector(_checkViewState) name:UIApplicationWillEnterForegroundNotification object:nil];
    [center addObserver:self selector:@selector(_checkViewState) name:UIApplicationDidEnterBackgroundNotification object:nil];
#endif
    _isObservingNotifications = YES;
}

- (void)_stopObservingViewStateNotifications {
    if (!_isObservingNotifications)
        return;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
#if TARGET_OS_OSX
    [center removeObserver:self name:NSViewFrameDidChangeNotification object:self];
    [center removeObserver:self name:NSWindowDidChangeOcclusionStateNotification object:self];
#else
    [center removeObserver:self name:UIApplicationWillEnterForegroundNotification object:nil];
    [center removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
#endif
    _isObservingNotifications = NO;
}

- (void)_checkViewState {
    if (_contextState == AsyncGLViewContextStateCreationRequested)
        [self createContexts];
    if (_contextState != AsyncGLViewContextStateRenderContextCreated)
        return;

    CGSize frameSize = self.frame.size;
    BOOL shouldRender = frameSize.width > 0.0f && frameSize.height > 0.0f && !self.isHidden && self.window;
#if !TARGET_OS_OSX
    shouldRender = shouldRender && ([[UIApplication sharedApplication] applicationState] != UIApplicationStateBackground);
#else
    shouldRender = shouldRender && ([[self window] occlusionState] & NSWindowOcclusionStateVisible);
#endif

    CGFloat scale = self.layer.contentsScale;
    CGSize newSize = CGSizeMake(frameSize.width * scale, frameSize.height * scale);

    if (@available(iOS 18.0, tvOS 18.0, macOS 15.0, *)) {
        os_unfair_lock_lock_with_flags(&_renderLock, OS_UNFAIR_LOCK_FLAG_ADAPTIVE_SPIN);
    } else {
        os_unfair_lock_lock(&_renderLock);
    }
    _drawableSize = newSize;
    _shouldPresent = shouldRender;
    _shouldRender = shouldRender || ([self _allowsOffscreenRendering] && frameSize.width > 0 && frameSize.height > 0);
    os_unfair_lock_unlock(&_renderLock);
}

#if !TARGET_OS_OSX
- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self _checkViewState];
}

- (void)layoutSubviews {
    [super layoutSubviews];

    [self _checkViewState];
}
#else
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self _checkViewState];
}

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self _checkViewState];
}
#endif

- (void)setContentScaleFactor:(CGFloat)contentScaleFactor {
#if TARGET_OS_OSX
    self.layer.contentsScale = contentScaleFactor;
#else
    [super setContentScaleFactor:contentScaleFactor];
#endif

    [self _checkViewState];
}

#if TARGET_OS_OSX
- (void)_handleWindowOcclusionStateChanged:(NSNotification *)notification
{
    if ([notification object] != [self window]) return;

    [self _checkViewState];
}
#endif

- (void)setHidden:(BOOL)hidden {
    [super setHidden:hidden];

    [self _checkViewState];
}

#if !TARGET_OS_OSX
- (void)willMoveToWindow:(UIWindow *)newWindow {
    [super willMoveToWindow:newWindow];
#else
- (void)viewWillMoveToWindow:(NSWindow *)newWindow {
    [super viewWillMoveToWindow:newWindow];
#endif
    if (newWindow && _contextState == AsyncGLViewContextStateNone) {
        _contextState = AsyncGLViewContextStateCreationRequested;
        [self createContexts];
    }

    [self _checkViewState];
    [_delegate _viewWillMoveToWindow:newWindow];
}

@end
