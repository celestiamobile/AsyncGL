//
//  Copyright (c) Levin Li. All rights reserved.
//  Licensed under the MIT License.
//

#import "AsyncGLView.h"

@import QuartzCore;

#if TARGET_OS_OSX || TARGET_OS_MACCATALYST
#define TARGET_OSX_OR_CATALYST 1
#else
#define TARGET_OSX_OR_CATALYST 0
#endif

#if __has_include(<libEGL/libEGL.h>) && __has_include(<libGLESv2/libGLESv2.h>)
#define USE_EGL
@import libEGL;
@import libGLESv2;
#elif TARGET_OSX_OR_CATALYST
@import OpenGL.GL;
@import OpenGL.GL3;
#else
@import OpenGLES.ES2;
@import OpenGLES.ES3;
#endif

@interface AsyncGLMirroringTarget : NSObject
@property (nonatomic, strong, readonly) CALayer *layer;
+ (Class)layerClass;
- (instancetype)initWithLayer:(CALayer *)layer;
- (void)updateSize:(CGSize)size visible:(BOOL)visible;
#ifdef USE_EGL
- (BOOL)drawFromFramebuffer:(GLuint)framebuffer size:(CGSize)size display:(EGLDisplay)display config:(EGLConfig)config context:(EGLContext)context sourceSurface:(EGLSurface)sourceSurface;
#else
- (BOOL)drawFromFramebuffer:(GLuint)framebuffer size:(CGSize)size;
#if TARGET_OSX_OR_CATALYST
- (BOOL)prepareWithCGLContext:(CGLContextObj)context;
#endif
#endif
- (void)clear;
@end

#if TARGET_OS_OSX
@interface AsyncGLMirroringView : NSView
#else
@interface AsyncGLMirroringView : UIView
#endif
@property (nonatomic, strong, readonly) AsyncGLMirroringTarget *target;
@end
