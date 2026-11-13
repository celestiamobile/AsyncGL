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

typedef NS_ENUM(NSUInteger, AsyncGLAPI);

@class AsyncGLExecutor;
@class AsyncGLView;

NS_ASSUME_NONNULL_BEGIN

#if !TARGET_OS_OSX
@interface AsyncGLViewController : UIViewController
#else
@interface AsyncGLViewController : NSViewController
#endif

@property (nonatomic) BOOL pauseOnWillResignActive;
@property (nonatomic) BOOL resumeOnDidBecomeActive;
@property (nonatomic, getter=isPaused) BOOL paused;
@property (nonatomic, nullable) AsyncGLView *glView;

// Experimental, opt-in rendering without a visible window, including during
// app inactivity. Set on main; defaults to NO. Uses an independent frame clock
// and suppresses automatic lifecycle pauses, but explicit paused=YES still wins.
// Enabling resumes a ready renderer; disabling restores normal lifecycle policy.
// The caller must ensure GPU execution is permitted. PiP does not itself grant
// background OpenGL/Metal permission on iOS.
@property (nonatomic) BOOL rendersWhileOffscreen;

// Opt-in native driver multithreading; no effect with EGL/ANGLE.
// Contexts still require serialized application access.
- (instancetype)initWithMSAAEnabled:(BOOL)msaaEnabled initialFrameRate:(NSInteger)frameRate api:(AsyncGLAPI)api multiThreaded:(BOOL)multiThreaded executor:(AsyncGLExecutor *)executor NS_DESIGNATED_INITIALIZER;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

- (BOOL)prepareGL:(CGSize)size samples:(NSInteger)samples NS_SWIFT_NONISOLATED;
- (void)drawGL:(CGSize)size NS_SWIFT_NONISOLATED;
// Called on the render thread. The timestamp is the display link's estimated
// presentation time in CACurrentMediaTime's time base; it may already be past.
// Zero means no display deadline (manual requests, offscreen timer, legacy clock).
// The default implementation calls drawGL: for existing subclasses.
- (void)drawGL:(CGSize)size targetTimestamp:(CFTimeInterval)targetTimestamp NS_SWIFT_NONISOLATED;
- (void)clearGL NS_SWIFT_NONISOLATED;

// Call on main before releasing the controller. Cleanup finishes asynchronously
// on the render thread, retaining the controller until clearGL returns.
- (void)shutdown;
// Completion runs on main after rendering and GL cleanup have finished.
- (void)shutdownWithCompletion:(void (^ _Nullable)(void))completion NS_SWIFT_NAME(shutdown(completion:));

- (void)setPreferredFramesPerSecond:(NSInteger)preferredFramesPerSecond API_AVAILABLE(ios(10.0), tvos(10.0), macos(14.0));

@end

NS_ASSUME_NONNULL_END
