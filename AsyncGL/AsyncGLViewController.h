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

#if !TARGET_OS_OSX
- (instancetype)initWithMSAAEnabled:(BOOL)msaaEnabled initialFrameRate:(NSInteger)frameRate api:(AsyncGLAPI)api executor:(AsyncGLExecutor *)executor NS_DESIGNATED_INITIALIZER;
#else
- (instancetype)initWithMSAAEnabled:(BOOL)msaaEnabled initialFrameRate:(NSInteger)frameRate api:(AsyncGLAPI)api executor:(AsyncGLExecutor *)executor NS_DESIGNATED_INITIALIZER;
#endif
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil bundle:(nullable NSBundle *)nibBundleOrNil NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

- (BOOL)prepareGL:(CGSize)size samples:(NSInteger)samples NS_SWIFT_NONISOLATED;
- (void)drawGL:(CGSize)size NS_SWIFT_NONISOLATED;
- (void)clearGL NS_SWIFT_NONISOLATED;

// Call on main before releasing the controller. Cleanup finishes asynchronously
// on the render thread, retaining the controller until clearGL returns.
- (void)shutdown;

- (void)setPreferredFramesPerSecond:(NSInteger)preferredFramesPerSecond API_AVAILABLE(ios(10.0), tvos(10.0), macos(14.0));

@end

NS_ASSUME_NONNULL_END
