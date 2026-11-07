//
//  AsyncGLExecutor.m
//  AsyncGL
//
//  Created by Levin Li on 2023/1/10.
//

#import "AsyncGLExecutor+Private.h"
#import "AsyncGLView+Private.h"

@implementation AsyncGLExecutor

- (instancetype)init {
    self = [super init];
    if (self)
        _view = nil;
    return self;
}

- (void)runTaskAsynchronously:(void(^)(void))task {
    [[self requiredView] enqueueTask:task];
}

- (void)runTaskSynchronously:(void(^)(void))task {
    AsyncGLView *view = [self requiredView];
    if ([NSThread currentThread] == view.renderThread) {
        task();
        return;
    }
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [view enqueueTask:^{
        task();
        dispatch_semaphore_signal(semaphore);
    } requiringActiveContext:YES];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
}

- (AsyncGLView *)requiredView {
    AsyncGLView *view = _view;
    if (view == nil)
        [NSException raise:NSInternalInconsistencyException format:@"The executor is not attached to a view"];
    return view;
}

- (void)makeRenderContextCurrent {
    assert(_view != nil);
    [_view makeRenderContextCurrent];
}

- (void)prepareForDrawing:(void (NS_NOESCAPE ^)(void))draw resolve:(void (NS_NOESCAPE ^)(void))resolve {
    assert(_view != nil);
    [_view prepareForDrawing:draw resolve:resolve];
}

@end
