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

NS_ASSUME_NONNULL_BEGIN

#if !TARGET_OS_OSX
@interface AsyncGLView : UIView
#else
@interface AsyncGLView : NSView
#endif

#if TARGET_OS_OSX
@property (nonatomic) CGFloat contentScaleFactor;
#endif

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

@end

NS_ASSUME_NONNULL_END
