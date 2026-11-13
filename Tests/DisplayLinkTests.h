@interface TimestampDelegate : OutputLifecycleDelegate
@property (nonatomic) NSMutableArray<NSNumber *> *timestamps;
@property (nonatomic, copy) dispatch_block_t onDraw;
@end
@implementation TimestampDelegate
- (void)_drawGL:(CGSize)size targetTimestamp:(CFTimeInterval)timestamp {
    [self.timestamps addObject:@(timestamp)];
    if (self.onDraw != nil)
        self.onDraw();
    [super _drawGL:size];
}
@end

static void TestTargetTimestamps(void) {
    TimestampDelegate *delegate = [TimestampDelegate new];
    delegate.timestamps = [NSMutableArray array];
    __block atomic_bool holdDraw;
    __block atomic_bool drawEntered;
    atomic_init(&holdDraw, false);
    atomic_init(&drawEntered, false);
    dispatch_semaphore_t releaseDraw = dispatch_semaphore_create(0);
    delegate.onDraw = ^{
        if (atomic_exchange(&holdDraw, false)) {
            atomic_store(&drawEntered, true);
            Check(dispatch_semaphore_wait(releaseDraw, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0,
                  @"Timestamp draw gate timed out");
        }
    };
    OutputLifecycleView *view = [[OutputLifecycleView alloc] initWithFrame:NSMakeRect(0, 0, 32, 24)];
#ifdef USE_EGL
    view.api = AsyncGLAPIOpenGLES3;
#else
    view.api = AsyncGLAPIOpenGLCore41;
#endif
    __block atomic_uint updates;
    atomic_init(&updates, 0);
    view.afterOutputUpdate = ^{ atomic_fetch_add(&updates, 1); };
    [view commonSetup];
    view.delegate = delegate;
    [view createContexts];
    PumpUntil(^BOOL{ return view.contextState == AsyncGLViewContextStateRenderContextCreated; }, @"Timestamp context creation");
    [view pause];
    [view requestRenderWithTargetTimestamp:123];
    [view requestRenderWithTargetTimestamp:456];
    unsigned int previousUpdates = atomic_load(&updates);
    [view stopMirroring];
    PumpUntil(^BOOL{ return atomic_load(&updates) > previousUpdates; }, @"Paused output update");
    [view resume];
    PumpUntil(^BOOL{ return atomic_load(&delegate->draws) == 1; }, @"Coalesced timestamp draw");
    [view pause];
    Check([delegate.timestamps isEqualToArray:@[@456]],
          @"Coalescing and paused output updates must preserve the latest requested deadline");

    [view requestRenderWithTargetTimestamp:789];
    [view requestRender];
    [view resume];
    PumpUntil(^BOOL{ return atomic_load(&delegate->draws) == 2; }, @"Manual draw");
    [view pause];
    Check([delegate.timestamps isEqualToArray:@[@456, @0]], @"Manual draws must not inherit stale deadlines");

    NSError *error = nil;
    Check([view startSampleBufferOutputWithMaximumSize:CGSizeMake(8, 6)
        handler:^(CMSampleBufferRef sample) {} error:&error], @"Timestamp output startup");
    [view resume];
    PumpUntil(^BOOL{ return atomic_load(&delegate->draws) == 3; }, @"Output-triggered draw");
    [view pause];
    Check([delegate.timestamps isEqualToArray:@[@456, @0, @0]], @"Output-triggered draws have no display deadline");
    atomic_store(&holdDraw, true);
    [view requestRenderWithTargetTimestamp:111];
    [view resume];
    PumpUntil(^BOOL{ return atomic_load(&drawEntered); }, @"In-flight timestamp draw");
    [view requestRenderWithTargetTimestamp:222];
    dispatch_semaphore_signal(releaseDraw);
    PumpUntil(^BOOL{ return atomic_load(&delegate->draws) == 5; }, @"Next timestamp draw");
    [view pause];
    Check([delegate.timestamps isEqualToArray:@[@456, @0, @0, @111, @222]],
          @"A concurrent request must not overwrite an in-flight frame's deadline");
    __block BOOL stopped = NO;
    [view clearWithDelegate:delegate completion:^{ stopped = YES; }];
    PumpUntil(^{ return stopped; }, @"Timestamp shutdown");
    NSLog(@"PASS: targetTimestamp coalescing, in-flight isolation and unscheduled-frame sentinel");
}

@interface DisplayClockView : OutputLifecycleView {
@public
    atomic_uint requests;
}
@end
@implementation DisplayClockView
- (BOOL)_allowsOffscreenRendering { return self.rendersWhileOffscreen; }
- (void)requestRenderWithTargetTimestamp:(CFTimeInterval)timestamp {
    if (timestamp != 0)
        Check(!NSThread.isMainThread, @"Display-link callbacks must not run on main");
    atomic_fetch_add(&requests, 1);
    [super requestRenderWithTargetTimestamp:timestamp];
}
@end

@interface LegacyClockController : AsyncGLViewController {
@public
    atomic_uint frames;
}
@property (atomic) dispatch_semaphore_t frameSignal;
@end
@implementation LegacyClockController
- (void)loadView {
    DisplayClockView *view = [[DisplayClockView alloc] initWithFrame:NSMakeRect(0, 0, 32, 24)];
#ifdef USE_EGL
    view.api = AsyncGLAPIOpenGLES3;
#else
    view.api = AsyncGLAPIOpenGLCore41;
#endif
    [view commonSetup];
    view.delegate = self;
    self.glView = view;
    self.view = view;
    self.internalExecutor.view = view;
    self.isPaused ? [view pause] : [view resume];
}
- (void)drawGL:(CGSize)size {
    Check(NSThread.currentThread == self.glView.renderThread, @"Drawing must stay on the render thread");
    glClearColor(0, 1, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    atomic_fetch_add(&frames, 1);
    dispatch_semaphore_t signal = self.frameSignal;
    if (signal != nil)
        dispatch_semaphore_signal(signal);
}
@end

@interface TimestampClockController : LegacyClockController {
@public
    _Atomic(double) lastTimestamp;
}
@end
@implementation TimestampClockController
- (void)drawGL:(CGSize)size targetTimestamp:(CFTimeInterval)timestamp {
    atomic_store(&lastTimestamp, timestamp);
    [super drawGL:size targetTimestamp:timestamp];
}
@end

static void WaitForFrameWithMainBlocked(LegacyClockController *controller) {
    dispatch_semaphore_t frame = dispatch_semaphore_create(0);
    controller.frameSignal = frame;
    Check(dispatch_semaphore_wait(frame, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0,
          @"A display-linked frame must render while main is blocked");
    controller.frameSignal = nil;
}

static void TestDisplayLinkScheduling(void) {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    TimestampClockController *controller = [[TimestampClockController alloc]
        initWithMSAAEnabled:NO initialFrameRate:60 api:AsyncGLAPIOpenGLCore41 executor:[AsyncGLExecutor new]];
    [controller loadViewIfNeeded];
    DisplayClockView *view = (DisplayClockView *)controller.glView;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 32, 24)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    window.contentView = view;
    [window orderFront:nil];
    PumpUntil(^BOOL {
        NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:NSDate.distantPast
                                             inMode:NSDefaultRunLoopMode dequeue:YES];
        if (event != nil)
            [NSApp sendEvent:event];
        [NSApp updateWindows];
        [view _checkViewState];
        return controller.isReady && atomic_load(&controller->frames) > 0;
    }, @"Visible display clock startup");
    WaitForFrameWithMainBlocked(controller);
    Check(atomic_load(&controller->lastTimestamp) > 0, @"The public draw callback must receive a display deadline");

    controller.paused = YES;
    unsigned int frames = atomic_load(&controller->frames);
    unsigned int requests = atomic_load(&view->requests);
    [NSThread sleepForTimeInterval:0.05];
    Check(atomic_load(&controller->frames) == frames && atomic_load(&view->requests) == requests,
          @"Explicit pause must suppress clock requests and rendering");
    Check(!controller.displayLinkDriver.thread.finished, @"A paused clock must remain resumable");
    [controller setPreferredFramesPerSecond:30];
    controller.paused = NO;
    WaitForFrameWithMainBlocked(controller);

    view.hidden = YES;
    requests = atomic_load(&view->requests);
    [NSThread sleepForTimeInterval:0.05];
    Check(atomic_load(&view->requests) == requests && !controller.isPaused,
          @"Hidden views must stop clock requests without explicitly pausing");
    __block BOOL taskRan = NO;
    [controller.internalExecutor runTaskSynchronously:^{ taskRan = YES; }];
    Check(taskRan, @"Executor work must remain active while the view is hidden");
    view.hidden = NO;
    WaitForFrameWithMainBlocked(controller);

    [view setFrameSize:NSZeroSize];
    requests = atomic_load(&view->requests);
    [NSThread sleepForTimeInterval:0.05];
    Check(atomic_load(&view->requests) == requests, @"Zero-sized views must stop clock requests");
    [view setFrameSize:NSMakeSize(32, 24)];
    WaitForFrameWithMainBlocked(controller);

    NSThread *oldThread = controller.displayLinkDriver.thread;
    __weak AsyncGLDisplayLinkDriver *oldDriver = controller.displayLinkDriver;
    [controller setScreen:window.screen];
    PumpUntil(^BOOL{ return oldThread.finished && oldDriver == nil; }, @"Replaced clock must release its thread and target");
    WaitForFrameWithMainBlocked(controller);

    oldThread = controller.displayLinkDriver.thread;
    controller.rendersWhileOffscreen = YES;
    PumpUntil(^BOOL{ return oldThread.finished; }, @"Offscreen mode must retire the display clock");
    controller.rendersWhileOffscreen = NO;
    WaitForFrameWithMainBlocked(controller);
    oldThread = controller.displayLinkDriver.thread;
    __block BOOL stopped = NO;
    [controller shutdownWithCompletion:^{ stopped = YES; }];
    PumpUntil(^BOOL{ return stopped && oldThread.finished; }, @"Shutdown must retire the render and clock threads");
    requests = atomic_load(&view->requests);
    [NSThread sleepForTimeInterval:0.05];
    Check(atomic_load(&view->requests) == requests, @"Shutdown must prevent late frame requests");
    [window orderOut:nil];
    NSLog(@"PASS: blocked-main rendering, public timestamps, legacy draw fallback, hidden/zero-size idle, pause and clock replacement");
}

@interface ConfigurationClockDriver : AsyncGLDisplayLinkDriver {
@public
    atomic_bool appliedPause;
    atomic_int appliedRate;
}
@end
@implementation ConfigurationClockDriver
- (void)applyConfiguration {
    [super applyConfiguration];
    CADisplayLink *link = [self valueForKey:@"link"];
    atomic_store(&appliedPause, link.paused);
    atomic_store(&appliedRate, (int)link.preferredFrameRateRange.preferred);
}
@end

static void TestDisplayLinkConfigurationRaces(void) {
    DisplayClockView *view = [DisplayClockView new];
    ConfigurationClockDriver *driver = [[ConfigurationClockDriver alloc] initWithView:view];
    [driver updateWithPaused:YES frameRateRange:CAFrameRateRangeMake(15, 30, 30)];
    CADisplayLink *link = [NSScreen.mainScreen displayLinkWithTarget:driver selector:@selector(requestRender:)];
    [driver startWithDisplayLink:link];
    [driver updateWithPaused:YES frameRateRange:CAFrameRateRangeMake(10, 20, 20)];
    PumpUntil(^BOOL{ return atomic_load(&driver->appliedPause) && atomic_load(&driver->appliedRate) == 20; },
              @"Latest configuration must reach a paused clock thread");
    NSThread *thread = driver.thread;
    [driver invalidate];
    PumpUntil(^BOOL{ return thread.finished; }, @"Paused clock shutdown");
    NSMutableArray<NSThread *> *threads = [NSMutableArray array];
    for (NSUInteger index = 0; index < 30; ++index) {
        @autoreleasepool {
            AsyncGLDisplayLinkDriver *clock = [[AsyncGLDisplayLinkDriver alloc] initWithView:view];
            CADisplayLink *newLink = [NSScreen.mainScreen displayLinkWithTarget:clock selector:@selector(requestRender:)];
            [clock startWithDisplayLink:newLink];
            [threads addObject:clock.thread];
            [clock updateWithPaused:YES frameRateRange:CAFrameRateRangeMake(15, 30, 30)];
            [clock invalidate];
            [clock invalidate];
        }
    }
    PumpUntil(^BOOL {
        for (NSThread *clockThread in threads) {
            if (!clockThread.finished)
                return NO;
        }
        return YES;
    }, @"Immediate repeated invalidation must not strand starting clock threads");
    Check(atomic_load(&view->requests) == 0, @"Paused startup and invalidation must not submit frames");
    NSLog(@"PASS: clock configuration handoff, paused startup and immediate shutdown races");
}
