//
//  Copyright (c) Levin Li. All rights reserved.
//  Licensed under the MIT License.
//

#import "AsyncGLSampleBufferOutput.h"
@import CoreVideo;
#include <math.h>
#include <string.h>

#ifndef USE_EGL
#if TARGET_OSX_OR_CATALYST
typedef CVOpenGLTextureCacheRef OutputTextureCache;
typedef CVOpenGLTextureRef OutputTexture;
#else
typedef CVOpenGLESTextureCacheRef OutputTextureCache;
typedef CVOpenGLESTextureRef OutputTexture;
#endif
#endif

@interface AsyncGLPendingSample : NSObject {
@public
    CVPixelBufferRef pixelBuffer;
#ifdef USE_EGL
    EGLDisplay display;
    EGLSurface surface;
    GLuint texture;
    BOOL bound;
#else
    OutputTexture texture;
#endif
    GLsync fence;
    CMTime timestamp;
}
- (void)clear;
@end

@implementation AsyncGLPendingSample
- (void)clear {
#ifdef USE_EGL
    if (bound) {
        if (!eglReleaseTexImage(display, surface, EGL_BACK_BUFFER))
            NSLog(@"AsyncGL sample-buffer texture cleanup failed: %d", eglGetError());
        glFinish();
    }
    if (surface != EGL_NO_SURFACE && !eglDestroySurface(display, surface))
        NSLog(@"AsyncGL sample-buffer surface cleanup failed: %d", eglGetError());
    if (texture != 0)
        glDeleteTextures(1, &texture);
    bound = NO;
    surface = EGL_NO_SURFACE;
    texture = 0;
#else
    if (texture != NULL)
        CFRelease(texture);
    texture = NULL;
#endif
    if (pixelBuffer != NULL)
        CFRelease(pixelBuffer);
    pixelBuffer = NULL;
}
- (void)dealloc {
    [self clear];
}
@end

@implementation AsyncGLSampleBufferOutput {
    CGSize _maximumSize;
    void (^_handler)(CMSampleBufferRef);
#ifdef USE_EGL
    EGLDisplay _display;
    EGLConfig _config;
#else
    OutputTextureCache _cache;
#endif
    CVPixelBufferPoolRef _pool;
    CGSize _outputSize;
    CGSize _captureSize;
    GLuint _captureTexture;
    GLuint _captureFramebuffer;
    GLuint _outputFramebuffer;
    NSMutableArray<AsyncGLPendingSample *> *_pending;
    BOOL _failed;
}

- (instancetype)initWithMaximumSize:(CGSize)size handler:(void (^)(CMSampleBufferRef))handler {
    if ((self = [super init])) {
        _maximumSize = size;
        _handler = [handler copy];
        _pending = [NSMutableArray array];
    }
    return self;
}

- (BOOL)fail:(NSString *)operation code:(NSInteger)code {
    NSLog(@"AsyncGL sample-buffer output failed during %@: %ld", operation, (long)code);
    _failed = YES;
    return NO;
}

- (BOOL)hasPendingFrames {
    return !_failed && _pending.count > 0;
}

- (void)pollPendingFrames {
    if ([self hasPendingFrames])
        [self deliverCompletedFrames];
}

- (BOOL)deliverCompletedFrames {
    while (_pending.count > 0) {
        AsyncGLPendingSample *frame = _pending.firstObject;
        GLenum status = glClientWaitSync(frame->fence, 0, 0);
        if (status == GL_TIMEOUT_EXPIRED)
            break;
        if (status == GL_WAIT_FAILED)
            return [self fail:@"GPU fence wait" code:glGetError()];
        glDeleteSync(frame->fence);
        frame->fence = NULL;

        CMVideoFormatDescriptionRef format = NULL;
        OSStatus result = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, frame->pixelBuffer, &format);
        if (result != noErr)
            return [self fail:@"format description" code:result];
        CMSampleTimingInfo timing = {kCMTimeInvalid, frame->timestamp, kCMTimeInvalid};
        CMSampleBufferRef sample = NULL;
        result = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, frame->pixelBuffer, format, &timing, &sample);
        CFRelease(format);
        if (result != noErr)
            return [self fail:@"sample creation" code:result];
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, YES);
        CFMutableDictionaryRef attachment = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(attachment, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        _handler(sample);
        CFRelease(sample);
        [frame clear];
        [_pending removeObjectAtIndex:0];
    }
    return YES;
}

- (BOOL)prepareForSize:(CGSize)size {
#ifdef USE_EGL
    if (_config == NULL) {
        _display = eglGetCurrentDisplay();
        const char *extensions = eglQueryString(_display, EGL_EXTENSIONS);
        const char *extension = "EGL_ANGLE_iosurface_client_buffer";
        const char *match = extensions != NULL ? strstr(extensions, extension) : NULL;
        size_t length = strlen(extension);
        if (match == NULL || (match != extensions && match[-1] != ' ') ||
            (match[length] != ' ' && match[length] != '\0'))
            return [self fail:@"missing EGL_ANGLE_iosurface_client_buffer" code:EGL_BAD_MATCH];
        const EGLint attributes[] = {
            EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
            EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
            EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
            EGL_SAMPLE_BUFFERS, 0, EGL_SAMPLES, 0,
            EGL_BIND_TO_TEXTURE_RGBA, EGL_TRUE,
            EGL_NONE
        };
        EGLint count = 0;
        if (!eglChooseConfig(_display, attributes, &_config, 1, &count))
            return [self fail:@"IOSurface EGL config" code:eglGetError()];
        if (count == 0)
            return [self fail:@"no IOSurface EGL config" code:EGL_BAD_CONFIG];
        EGLint target = 0;
        if (!eglGetConfigAttrib(_display, _config, EGL_BIND_TO_TEXTURE_TARGET_ANGLE, &target))
            return [self fail:@"IOSurface texture target query" code:eglGetError()];
        if (target != EGL_TEXTURE_2D)
            return [self fail:@"IOSurface output requires a 2D texture target (ANGLE Metal)" code:EGL_BAD_MATCH];
    }
#else
    if (_cache == NULL) {
#if TARGET_OSX_OR_CATALYST
        CGLContextObj context = CGLGetCurrentContext();
        CVReturn result = CVOpenGLTextureCacheCreate(kCFAllocatorDefault, NULL, context, CGLGetPixelFormat(context), NULL, &_cache);
#else
        CVReturn result = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, EAGLContext.currentContext, NULL, &_cache);
#endif
        if (result != kCVReturnSuccess)
            return [self fail:@"texture cache creation" code:result];
    }
#endif
    CGFloat scale = MIN(1, MIN(_maximumSize.width / size.width, _maximumSize.height / size.height));
    CGSize outputSize = CGSizeMake(MAX(1, floor(size.width * scale)), MAX(1, floor(size.height * scale)));
    if (!CGSizeEqualToSize(outputSize, _outputSize)) {
        if (_pool != NULL) {
            CFRelease(_pool);
            _pool = NULL;
        }
        NSDictionary *attributes = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @((NSInteger)outputSize.width),
            (id)kCVPixelBufferHeightKey: @((NSInteger)outputSize.height),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
#ifdef USE_EGL
            (id)kCVPixelBufferMetalCompatibilityKey: @YES,
#elif TARGET_OSX_OR_CATALYST
            (id)kCVPixelBufferOpenGLCompatibilityKey: @YES,
            (id)kCVPixelBufferIOSurfaceOpenGLFBOCompatibilityKey: @YES,
#else
            (id)kCVPixelBufferOpenGLESCompatibilityKey: @YES,
            (id)kCVPixelBufferIOSurfaceOpenGLESFBOCompatibilityKey: @YES,
#endif
        };
        CVReturn result = CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attributes, &_pool);
        if (result != kCVReturnSuccess)
            return [self fail:@"pixel buffer pool creation" code:result];
        _outputSize = outputSize;
    }
    if (_captureFramebuffer == 0) {
        glGenFramebuffers(1, &_captureFramebuffer);
        glGenFramebuffers(1, &_outputFramebuffer);
        glGenTextures(1, &_captureTexture);
    }
    if (!CGSizeEqualToSize(size, _captureSize)) {
        glBindTexture(GL_TEXTURE_2D, _captureTexture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, (GLsizei)size.width, (GLsizei)size.height, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, _captureFramebuffer);
        glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, _captureTexture, 0);
        GLenum status = glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER);
        if (status != GL_FRAMEBUFFER_COMPLETE)
            return [self fail:@"capture framebuffer" code:status];
        _captureSize = size;
    }
    return YES;
}

- (BOOL)captureFramebuffer:(GLuint)framebuffer size:(CGSize)size {
    if (![self prepareForSize:size])
        return NO;
    AsyncGLPendingSample *frame = [AsyncGLPendingSample new];
    NSDictionary *limits = @{(id)kCVPixelBufferPoolAllocationThresholdKey: @4};
    CVReturn result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, _pool,
        (__bridge CFDictionaryRef)limits, &frame->pixelBuffer);
    if (result == kCVReturnWouldExceedAllocationThreshold)
        return YES;
    if (result != kCVReturnSuccess)
        return [self fail:@"pixel buffer allocation" code:result];

    GLenum target;
    GLuint name;
#ifdef USE_EGL
    IOSurfaceRef ioSurface = CVPixelBufferGetIOSurface(frame->pixelBuffer);
    if (ioSurface == NULL)
        return [self fail:@"pixel buffer has no IOSurface" code:kCVReturnInvalidPixelBufferAttributes];
    const EGLint attributes[] = {
        EGL_WIDTH, (EGLint)_outputSize.width, EGL_HEIGHT, (EGLint)_outputSize.height,
        EGL_IOSURFACE_PLANE_ANGLE, 0,
        EGL_TEXTURE_TARGET, EGL_TEXTURE_2D,
        EGL_TEXTURE_INTERNAL_FORMAT_ANGLE, GL_BGRA_EXT,
        EGL_TEXTURE_FORMAT, EGL_TEXTURE_RGBA,
        EGL_TEXTURE_TYPE_ANGLE, GL_UNSIGNED_BYTE,
        EGL_IOSURFACE_USAGE_HINT_ANGLE, EGL_IOSURFACE_WRITE_HINT_ANGLE,
        EGL_NONE
    };
    frame->display = _display;
    frame->surface = eglCreatePbufferFromClientBuffer(_display, EGL_IOSURFACE_ANGLE,
        (EGLClientBuffer)ioSurface, _config, attributes);
    if (frame->surface == EGL_NO_SURFACE)
        return [self fail:@"IOSurface EGL surface" code:eglGetError()];
    glGenTextures(1, &frame->texture);
    glBindTexture(GL_TEXTURE_2D, frame->texture);
    if (!eglBindTexImage(_display, frame->surface, EGL_BACK_BUFFER))
        return [self fail:@"IOSurface texture binding" code:eglGetError()];
    frame->bound = YES;
    target = GL_TEXTURE_2D;
    name = frame->texture;
#elif TARGET_OSX_OR_CATALYST
    result = CVOpenGLTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _cache, frame->pixelBuffer, NULL, &frame->texture);
    if (result != kCVReturnSuccess)
        return [self fail:@"OpenGL pixel buffer texture" code:result];
    target = CVOpenGLTextureGetTarget(frame->texture);
    name = CVOpenGLTextureGetName(frame->texture);
#else
    result = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _cache, frame->pixelBuffer,
        NULL, GL_TEXTURE_2D, GL_RGBA, (GLsizei)_outputSize.width, (GLsizei)_outputSize.height,
        GL_BGRA, GL_UNSIGNED_BYTE, 0, &frame->texture);
    if (result != kCVReturnSuccess)
        return [self fail:@"OpenGL ES pixel buffer texture" code:result];
    target = CVOpenGLESTextureGetTarget(frame->texture);
    name = CVOpenGLESTextureGetName(frame->texture);
#endif
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, _outputFramebuffer);
    glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, target, name, 0);
    GLenum status = glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE)
        return [self fail:@"output framebuffer" code:status];

    // Resolve before scaling/flipping, which cannot be combined with MSAA resolve.
    glBindFramebuffer(GL_READ_FRAMEBUFFER, framebuffer);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, _captureFramebuffer);
    glBlitFramebuffer(0, 0, (GLsizei)size.width, (GLsizei)size.height,
        0, 0, (GLsizei)size.width, (GLsizei)size.height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, _captureFramebuffer);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, _outputFramebuffer);
    glBlitFramebuffer(0, 0, (GLsizei)size.width, (GLsizei)size.height,
        0, (GLsizei)_outputSize.height, (GLsizei)_outputSize.width, 0, GL_COLOR_BUFFER_BIT, GL_LINEAR);
    GLenum error = glGetError();
#ifdef USE_EGL
    // Publish the IOSurface before fencing; its contents are undefined while bound.
    if (!eglReleaseTexImage(_display, frame->surface, EGL_BACK_BUFFER))
        return [self fail:@"IOSurface texture release" code:eglGetError()];
    frame->bound = NO;
#endif
    if (error != GL_NO_ERROR) {
        glFinish();
        return [self fail:@"frame copy" code:error];
    }
    frame->timestamp = CMClockGetTime(CMClockGetHostTimeClock());
    frame->fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    if (frame->fence == NULL) {
        glFinish();
        return [self fail:@"GPU fence creation" code:glGetError()];
    }
    [_pending addObject:frame];
    glFlush();
    return YES;
}

- (void)drawFromFramebuffer:(GLuint)framebuffer size:(CGSize)size {
    if (_failed || size.width < 1 || size.height < 1)
        return;
    GLint readFramebuffer, drawFramebuffer, activeTexture, texture, unpackBuffer;
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &readFramebuffer);
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &drawFramebuffer);
    glGetIntegerv(GL_ACTIVE_TEXTURE, &activeTexture);
    glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &unpackBuffer);
    glActiveTexture(GL_TEXTURE0);
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &texture);
    GLboolean scissor = glIsEnabled(GL_SCISSOR_TEST);
    glDisable(GL_SCISSOR_TEST);
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
#if !defined(USE_EGL) && TARGET_OSX_OR_CATALYST
    GLint rectangle;
    glGetIntegerv(GL_TEXTURE_BINDING_RECTANGLE, &rectangle);
    GLboolean sRGB = glIsEnabled(GL_FRAMEBUFFER_SRGB);
    glDisable(GL_FRAMEBUFFER_SRGB);
#endif
    if ([self deliverCompletedFrames] && _pending.count < 3)
        [self captureFramebuffer:framebuffer size:size];
#if !defined(USE_EGL) && TARGET_OSX_OR_CATALYST
    if (_cache != NULL)
        CVOpenGLTextureCacheFlush(_cache, 0);
    glBindTexture(GL_TEXTURE_RECTANGLE, rectangle);
    if (sRGB)
        glEnable(GL_FRAMEBUFFER_SRGB);
#elif !defined(USE_EGL)
    if (_cache != NULL)
        CVOpenGLESTextureCacheFlush(_cache, 0);
#endif
    glBindTexture(GL_TEXTURE_2D, texture);
    glActiveTexture(activeTexture);
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER, unpackBuffer);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, readFramebuffer);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, drawFramebuffer);
    if (scissor)
        glEnable(GL_SCISSOR_TEST);
}

- (void)finishPendingWork {
    if (_pending.count > 0) {
        glFinish();
        if (!_failed)
            [self deliverCompletedFrames];
    }
}

- (void)clear {
    if (_pending.count > 0)
        glFinish();
    for (AsyncGLPendingSample *frame in _pending) {
        if (frame->fence != NULL)
            glDeleteSync(frame->fence);
        frame->fence = NULL;
        [frame clear];
    }
    [_pending removeAllObjects];
    if (_captureFramebuffer != 0)
        glDeleteFramebuffers(1, &_captureFramebuffer);
    if (_outputFramebuffer != 0)
        glDeleteFramebuffers(1, &_outputFramebuffer);
    if (_captureTexture != 0)
        glDeleteTextures(1, &_captureTexture);
    _captureFramebuffer = _outputFramebuffer = _captureTexture = 0;
#ifdef USE_EGL
    _display = EGL_NO_DISPLAY;
    _config = NULL;
#else
    if (_cache != NULL) {
        CFRelease(_cache);
        _cache = NULL;
    }
#endif
    if (_pool != NULL) {
        CFRelease(_pool);
        _pool = NULL;
    }
    _captureSize = _outputSize = CGSizeZero;
}
@end
