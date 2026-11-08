//
//  Copyright (c) Levin Li. All rights reserved.
//  Licensed under the MIT License.
//

#import <TargetConditionals.h>

#if !TARGET_OS_OSX
@import UIKit;
#else
@import Cocoa;
#endif

@import CoreMedia;

NS_ASSUME_NONNULL_BEGIN

#if !TARGET_OS_OSX
@interface AsyncGLView : UIView
#else
@interface AsyncGLView : NSView
#endif

#if TARGET_OS_OSX
@property (nonatomic) CGFloat contentScaleFactor;
#endif

// Experimental, opt-in offscreen rendering. Set on main; defaults to NO.
// Does not grant background GPU execution permission or schedule frames.
// Prefer the controller's matching property when using AsyncGLViewController.
@property (nonatomic) BOOL rendersWhileOffscreen;

// Call on main. Presents the source frame on its render thread without readback.
// Requires OpenGL ES 3 or native OpenGL core 4.1.
// Native desktop rendering must be initialized before starting mirroring.
// Starting a new mirror replaces the previous one.
#if TARGET_OS_OSX
- (NSView *)startMirroring;
#else
- (UIView *)startMirroring;
#endif
- (void)stopMirroring;

// Native GLES 3 / desktop GL 4.1, or ANGLE GLES 3 with IOSurface 2D texture support
// (Metal backend). Call on main; the handler runs on the
// render thread after GPU completion. Retain the sample if using it afterward.
// The handler must not wait for main or change GL state. Slow consumers cause
// frames to be dropped rather than growing an unbounded buffer queue.
// Maximum dimensions must be finite and between 1 and 4096 pixels. A new
// output replaces the old one; stop is asynchronous. Runtime failures log and
// suspend this output until it is replaced. This does not enable background GL.
- (BOOL)startSampleBufferOutputWithMaximumSize:(CGSize)maximumSize
                                      handler:(void (NS_SWIFT_SENDABLE ^)(CMSampleBufferRef sampleBuffer))handler
                                        error:(NSError * _Nullable * _Nullable)error;
- (void)stopSampleBufferOutput;

@end

NS_ASSUME_NONNULL_END
