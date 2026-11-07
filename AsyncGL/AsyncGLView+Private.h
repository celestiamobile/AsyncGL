//
//  Copyright (c) Levin Li. All rights reserved.
//  Licensed under the MIT License.
//

#import "AsyncGLAPI.h"
#import "AsyncGLView.h"

NS_ASSUME_NONNULL_BEGIN

@protocol AsyncGLViewDelegate <NSObject>

- (BOOL)_prepareGL:(CGSize)size samples:(NSInteger)samples;
- (void)_drawGL:(CGSize)size;
- (void)_clearGL;
#if !TARGET_OS_OSX
- (void)_viewWillMoveToWindow:(nullable UIWindow *)window;
#else
- (void)_viewWillMoveToWindow:(nullable NSWindow *)window;
#endif

@end

@interface AsyncGLView ()

@property (nonatomic) BOOL msaaEnabled;
@property (nonatomic) AsyncGLAPI api;
@property (nonatomic, weak) id<AsyncGLViewDelegate> delegate;

@property (nonatomic, readonly) NSThread *renderThread;

- (void)commonSetup;
- (void)requestRender;
- (void)enqueueTask:(void(^)(void))task;
- (void)enqueueTask:(void(^)(void))task requiringActiveContext:(BOOL)requiresActiveContext;
- (void)render;
- (void)clear;
- (void)clearWithDelegate:(nullable id<AsyncGLViewDelegate>)delegate;
- (void)clearWithDelegate:(nullable id<AsyncGLViewDelegate>)delegate completion:(void (^ _Nullable)(void))completion;
- (void)pause;
- (void)resume;
- (void)makeRenderContextCurrent;
- (void)prepareForDrawing:(void (NS_NOESCAPE ^ _Nullable)(void))draw resolve:(void (NS_NOESCAPE ^ _Nullable)(void))resolve NS_SWIFT_NONISOLATED;

@end

NS_ASSUME_NONNULL_END
