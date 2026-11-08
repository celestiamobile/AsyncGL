#import "Capture.h"
#import <TargetConditionals.h>
#import <objc/runtime.h>
#import <os/lock.h>
#include <dlfcn.h>

#if HOST_ANGLE
@import libEGL;
@import libGLESv2;
#elif TARGET_OS_OSX || TARGET_OS_MACCATALYST
@import OpenGL.GL3;
#else
@import OpenGLES.ES3;
@import OpenGLES.EAGL;
#endif

static os_unfair_lock captureLock = OS_UNFAIR_LOCK_INIT;
static RuntimeCapture capture;
static _Thread_local BOOL drawingMirror;

static void ReadMirrorPixels(void) {
    RuntimeCapture frame = {0};
    GLint viewport[4], readFramebuffer, drawFramebuffer;
    glGetIntegerv(GL_VIEWPORT, viewport);
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &readFramebuffer);
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &drawFramebuffer);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, drawFramebuffer);
    frame.width = viewport[2];
    frame.height = viewport[3];
    for (int index = 0; index < 4; ++index) {
        GLint x = (index & 1) ? 3 * frame.width / 4 : frame.width / 4;
        GLint y = (index >> 1) ? 3 * frame.height / 4 : frame.height / 4;
        glReadPixels(x, y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, frame.pixels[index]);
    }
    frame.error = glGetError();
    glBindFramebuffer(GL_READ_FRAMEBUFFER, readFramebuffer);
    os_unfair_lock_lock(&captureLock);
    frame.count = capture.count + 1;
    capture = frame;
    os_unfair_lock_unlock(&captureLock);
}

RuntimeCapture LatestRuntimeCapture(void) {
    os_unfair_lock_lock(&captureLock);
    RuntimeCapture result = capture;
    os_unfair_lock_unlock(&captureLock);
    return result;
}

#if HOST_ANGLE
static BOOL (*originalDraw)(id, SEL, GLuint, CGSize, EGLDisplay, EGLConfig, EGLContext, EGLSurface);
static BOOL CaptureDraw(id target, SEL selector, GLuint framebuffer, CGSize size,
                        EGLDisplay display, EGLConfig config, EGLContext context, EGLSurface surface) {
    drawingMirror = YES;
    BOOL result = originalDraw(target, selector, framebuffer, size, display, config, context, surface);
    drawingMirror = NO;
    return result;
}

EGLBoolean eglSwapBuffers(EGLDisplay display, EGLSurface surface) {
    static PFNEGLSWAPBUFFERSPROC originalSwap;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"libEGL.framework/libEGL"];
        void *library = dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL);
        NSCAssert(library != NULL, @"Could not open the embedded EGL framework: %s", dlerror());
        originalSwap = (PFNEGLSWAPBUFFERSPROC)dlsym(library, "eglSwapBuffers");
        NSCAssert(originalSwap != NULL && originalSwap != eglSwapBuffers, @"Could not resolve the real EGL swap");
    });
    if (drawingMirror)
        ReadMirrorPixels();
    return originalSwap(display, surface);
}

#elif TARGET_OS_OSX || TARGET_OS_MACCATALYST
static void (*originalDraw)(id, SEL);
static void CaptureDraw(id target, SEL selector) {
    originalDraw(target, selector);
    ReadMirrorPixels();
}
#else
static BOOL (*originalDraw)(id, SEL, GLuint, CGSize);
static BOOL (*originalPresent)(id, SEL, NSUInteger);
static BOOL CaptureDraw(id target, SEL selector, GLuint framebuffer, CGSize size) {
    drawingMirror = YES;
    BOOL result = originalDraw(target, selector, framebuffer, size);
    drawingMirror = NO;
    return result;
}
static BOOL CapturePresent(id context, SEL selector, NSUInteger target) {
    if (drawingMirror)
        ReadMirrorPixels();
    return originalPresent(context, selector, target);
}
#endif

void InstallRuntimeCapture(void) {
    Class target = NSClassFromString(@"AsyncGLMirroringTarget");
    NSCAssert(target != Nil, @"The compiled AsyncGL mirroring target was not linked");
#if HOST_ANGLE
    SEL selector = NSSelectorFromString(@"drawFromFramebuffer:size:display:config:context:sourceSurface:");
#elif TARGET_OS_OSX || TARGET_OS_MACCATALYST
    SEL selector = NSSelectorFromString(@"drawIntoCGLDrawable");
#else
    SEL selector = NSSelectorFromString(@"drawFromFramebuffer:size:");
    Method present = class_getInstanceMethod([EAGLContext class], @selector(presentRenderbuffer:));
    NSCAssert(present != NULL, @"EAGL presentation is unavailable");
    originalPresent = (void *)method_setImplementation(present, (IMP)CapturePresent);
#endif
    Method draw = class_getInstanceMethod(target, selector);
    NSCAssert(draw != NULL, @"The requested backend was not compiled into AsyncGL");
    originalDraw = (void *)method_setImplementation(draw, (IMP)CaptureDraw);
}
