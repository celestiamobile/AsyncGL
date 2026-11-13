//
//  Copyright (c) Levin Li. All rights reserved.
//  Licensed under the MIT License.
//

#import "AsyncGLViewController.h"
#import "AsyncGLView+Private.h"
#import "AsyncGLExecutor+Private.h"
#include <os/lock.h>

#if TARGET_OS_OSX
@import QuartzCore;
#endif

API_AVAILABLE(macos(14.0), macCatalyst(16.0))
@interface AsyncGLDisplayLinkDriver : NSObject {
    os_unfair_lock _lock;
    __weak AsyncGLView *_view;
    // After startup, only the clock thread accesses the link and _running.
    CADisplayLink *_link;
    BOOL _running;
    // Configuration and run-loop handles are protected by _lock.
    CFRunLoopRef _runLoop;
    CFRunLoopSourceRef _controlSource;
    BOOL _paused;
    BOOL _stopped;
    CAFrameRateRange _frameRateRange;
}
@property (nonatomic, readonly) NSThread *thread;
- (instancetype)initWithView:(AsyncGLView *)view;
- (void)startWithDisplayLink:(CADisplayLink *)link;
- (void)updateWithPaused:(BOOL)paused frameRateRange:(CAFrameRateRange)range;
- (void)invalidate;
- (void)requestRender:(CADisplayLink *)link;
- (void)applyConfiguration;
@end

@implementation AsyncGLDisplayLinkDriver
- (instancetype)initWithView:(AsyncGLView *)view {
    if ((self = [super init])) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _view = view;
        _paused = YES;
        _frameRateRange = CAFrameRateRangeDefault;
    }
    return self;
}

- (void)startWithDisplayLink:(CADisplayLink *)link {
    if (link == nil) {
        NSLog(@"AsyncGL could not create a display link");
        return;
    }
    _link = link;
    __weak AsyncGLDisplayLinkDriver *weakSelf = self;
    _thread = [[NSThread alloc] initWithBlock:^{
        [weakSelf run];
    }];
    _thread.name = @"AsyncGL Display Link";
    _thread.qualityOfService = NSQualityOfServiceUserInteractive;
    [_thread start];
}

- (void)signalConfigurationChangeLocked {
    if (_controlSource != NULL) {
        CFRunLoopSourceSignal(_controlSource);
        CFRunLoopWakeUp(_runLoop);
    }
}

- (void)updateWithPaused:(BOOL)paused frameRateRange:(CAFrameRateRange)range {
    os_unfair_lock_lock(&_lock);
    _paused = paused;
    _frameRateRange = range;
    [self signalConfigurationChangeLocked];
    os_unfair_lock_unlock(&_lock);
}

- (void)invalidate {
    os_unfair_lock_lock(&_lock);
    _stopped = YES;
    [self signalConfigurationChangeLocked];
    os_unfair_lock_unlock(&_lock);
}

- (void)requestRender:(CADisplayLink *)link {
    os_unfair_lock_lock(&_lock);
    // Serialize submission with pause/invalidation, not just the flag check.
    if (!_stopped && !_paused)
        [_view requestRenderWithTargetTimestamp:link.targetTimestamp];
    os_unfair_lock_unlock(&_lock);
}

- (void)applyConfiguration {
    os_unfair_lock_lock(&_lock);
    BOOL stopped = _stopped;
    BOOL paused = _paused;
    CAFrameRateRange range = _frameRateRange;
    os_unfair_lock_unlock(&_lock);
    if (stopped) {
        _running = NO;
        [_link invalidate];
        CFRunLoopStop(CFRunLoopGetCurrent());
    } else {
        _link.preferredFrameRateRange = range;
        _link.paused = paused;
    }
}

static void AsyncGLApplyDisplayLinkConfiguration(void *info) API_AVAILABLE(macos(14.0), macCatalyst(16.0));
static void AsyncGLApplyDisplayLinkConfiguration(void *info) {
    [(__bridge AsyncGLDisplayLinkDriver *)info applyConfiguration];
}

- (void)run {
    @autoreleasepool {
        CFRunLoopRef runLoop = CFRunLoopGetCurrent();
        CFRunLoopSourceContext context = {0};
        context.info = (__bridge void *)self;
        context.perform = AsyncGLApplyDisplayLinkConfiguration;
        CFRunLoopSourceRef source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context);
        if (source == NULL) {
            NSLog(@"AsyncGL could not create its display-link control source");
            [_link invalidate];
            _link = nil;
            return;
        }
        // The control source keeps the run loop alive even when the link is paused.
        CFRunLoopAddSource(runLoop, source, kCFRunLoopCommonModes);
        os_unfair_lock_lock(&_lock);
        _runLoop = runLoop;
        _controlSource = source;
        os_unfair_lock_unlock(&_lock);
        _running = YES;
        [self applyConfiguration];
        if (_running)
            [_link addToRunLoop:NSRunLoop.currentRunLoop forMode:NSRunLoopCommonModes];
        while (_running) {
            @autoreleasepool {
                [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:NSDate.distantFuture];
            }
        }
        os_unfair_lock_lock(&_lock);
        _runLoop = NULL;
        _controlSource = NULL;
        os_unfair_lock_unlock(&_lock);
        CFRunLoopRemoveSource(runLoop, source, kCFRunLoopCommonModes);
        CFRelease(source);
        _link = nil;
    }
}
@end

@interface AsyncGLViewController () <AsyncGLViewDelegate>

@property (nonatomic) AsyncGLExecutor *internalExecutor;

@property (nonatomic) NSInteger internalPreferredFramesPerSecond;
@property (nonatomic) AsyncGLDisplayLinkDriver *displayLinkDriver API_AVAILABLE(macos(14.0), macCatalyst(16.0));
#if !TARGET_OS_OSX
@property (nonatomic) CADisplayLink *displayLink;
@property (weak, nonatomic) UIWindowScene *internalWindowScene;
#else
@property (nonatomic) CVDisplayLinkRef cvDisplayLink;
@property (nonatomic) CADisplayLink *displayLink API_AVAILABLE(macos(14.0));
@property (weak, nonatomic) NSScreen *internalScreen;
#endif
@property (nonatomic) dispatch_source_t displaySource;
@property (nonatomic) BOOL msaaEnabled;
@property (atomic, getter=isReady) BOOL ready;
@property (nonatomic) AsyncGLAPI api;
@property (nonatomic) BOOL shuttingDown;
@property (nonatomic) BOOL resumeOffscreenAfterPreparation;
@property (nonatomic) BOOL displayLinkRenderable;
@end

@implementation AsyncGLViewController

#pragma mark - lifecycle

#if !TARGET_OS_OSX
- (instancetype)initWithMSAAEnabled:(BOOL)msaaEnabled initialFrameRate:(NSInteger)frameRate api:(AsyncGLAPI)api executor:(AsyncGLExecutor *)executor
#else
- (instancetype)initWithMSAAEnabled:(BOOL)msaaEnabled initialFrameRate:(NSInteger)frameRate api:(AsyncGLAPI)api executor:(AsyncGLExecutor *)executor
#endif
{
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _msaaEnabled = msaaEnabled;
        _paused = YES;
        _internalPreferredFramesPerSecond = frameRate;
        _displayLink = nil;
#if !TARGET_OS_OSX
        _internalWindowScene = nil;
        _pauseOnWillResignActive = YES;
        _resumeOnDidBecomeActive = YES;
#else
        _internalScreen = nil;
        _pauseOnWillResignActive = NO;
        _resumeOnDidBecomeActive = NO;
        _cvDisplayLink = NULL;
#endif
        _glView = nil;
        _ready = NO;
        _internalExecutor = executor;
        _api = api;
        [self _configureNotifications];
    }
    return self;
}

- (void)loadView
{
    if (_shuttingDown)
        [NSException raise:NSInternalInconsistencyException format:@"The controller has shut down"];
    _glView = [AsyncGLView new];
    _glView.api = _api;
    _glView.msaaEnabled = _msaaEnabled;
    [_glView commonSetup];
    _glView.rendersWhileOffscreen = _rendersWhileOffscreen;
    _glView.delegate = self;
    self.view = _glView;
    _internalExecutor.view = _glView;
    _paused ? [_glView pause] : [_glView resume];
}

- (void)dealloc
{
    [self invalidateDisplayLink];
    [_glView clear];
}

- (void)shutdown {
    [self shutdownWithCompletion:nil];
}

- (void)shutdownWithCompletion:(void (^)(void))completion {
    NSAssert([NSThread isMainThread], @"Shutdown must be requested on the main thread");
    if (!_shuttingDown) {
        _shuttingDown = YES;
        _rendersWhileOffscreen = NO;
        _resumeOffscreenAfterPreparation = NO;
        _glView.rendersWhileOffscreen = NO;
        self.ready = NO;
        [[NSNotificationCenter defaultCenter] removeObserver:self];
        [self invalidateDisplayLink];
    }
    if (_glView != nil) {
        [_glView clearWithDelegate:self completion:completion];
    } else if (completion != nil) {
        dispatch_async(dispatch_get_main_queue(), completion);
    }
}

- (void)invalidateDisplayLink {
    if (_displaySource != nil) {
        dispatch_source_cancel(_displaySource);
        _displaySource = nil;
    }
    if (@available(macOS 14.0, *)) {
        [_displayLinkDriver invalidate];
        _displayLinkDriver = nil;
    }
    _displayLink = nil;

#if TARGET_OS_OSX
    if (_cvDisplayLink != NULL) {
        CVDisplayLinkStop(_cvDisplayLink);
        CVDisplayLinkRelease(_cvDisplayLink);
        _cvDisplayLink = NULL;
    }
#endif
}

#pragma mark - private methods

- (void)requestRender
{
    [_glView requestRender];
}

#if TARGET_OS_OSX
static CVReturn displayCallback(CVDisplayLinkRef displayLink,
    const CVTimeStamp *inNow, const CVTimeStamp *inOutputTime,
    CVOptionFlags flagsIn, CVOptionFlags *flagsOut,
    void *displayLinkContext)
{
    AsyncGLViewController *vc = (__bridge AsyncGLViewController *)displayLinkContext;
    [vc requestRender];
    return kCVReturnSuccess;
}
#endif

#if !TARGET_OS_OSX
- (CADisplayLink *)_createDisplayLink
{
    UIWindowScene *scene = self.internalWindowScene;
    BOOL externalDisplay = [scene.session.role isEqualToString:UIWindowSceneSessionRoleExternalDisplayNonInteractive] ||
        [scene.session.role isEqualToString:UIWindowSceneSessionRoleExternalDisplay];
    CADisplayLink *link = nil;
    if (@available(iOS 27.0, tvOS 27.0, visionOS 27, *)) {
        // Scene-bound links can stop ticking on noninteractive external displays.
        // Keep automatic scene retargeting for application windows only.
        if (!externalDisplay)
            link = [scene displayLinkWithTarget:_displayLinkDriver selector:@selector(requestRender:)];
    }
    if (link == nil)
        link = [scene.screen displayLinkWithTarget:_displayLinkDriver selector:@selector(requestRender:)];
    if (link == nil)
        link = [CADisplayLink displayLinkWithTarget:_displayLinkDriver selector:@selector(requestRender:)];
    return link;
}
#endif

#pragma mark - getters/setters

- (void)setRendersWhileOffscreen:(BOOL)rendersWhileOffscreen {
    NSAssert(NSThread.isMainThread, @"Offscreen rendering must be configured on main");
    if (_rendersWhileOffscreen == rendersWhileOffscreen)
        return;
    if (_shuttingDown)
        [NSException raise:NSInternalInconsistencyException format:@"The controller has shut down"];
    BOOL restoreStartupPolicy = !rendersWhileOffscreen && _resumeOffscreenAfterPreparation;
    _rendersWhileOffscreen = rendersWhileOffscreen;
    _resumeOffscreenAfterPreparation = rendersWhileOffscreen && !_ready;
    _glView.rendersWhileOffscreen = rendersWhileOffscreen;
#if !TARGET_OS_OSX
    [self setWindowScene:_internalWindowScene];
#else
    [self setScreen:_internalScreen];
#endif
    if (_ready || restoreStartupPolicy)
        self.paused = !rendersWhileOffscreen && [self shouldPauseForCurrentLifecycle];
}

- (BOOL)shouldPauseForCurrentLifecycle {
#if !TARGET_OS_OSX
    return _internalWindowScene == nil ||
        (_pauseOnWillResignActive && UIApplication.sharedApplication.applicationState != UIApplicationStateActive);
#else
    return _internalScreen == nil || (_pauseOnWillResignActive && !NSApp.isActive);
#endif
}

- (void)updateOffscreenFrameRate {
    if (_displaySource == nil)
        return;
    NSInteger rate = _internalPreferredFramesPerSecond;
    if (rate <= 0) {
#if !TARGET_OS_OSX
        rate = self.internalWindowScene.screen.maximumFramesPerSecond;
#else
        if (@available(macOS 12.0, *))
            rate = self.internalScreen.maximumFramesPerSecond;
#endif
        if (rate <= 0)
            rate = 60;
    }
    uint64_t interval = MAX(1, NSEC_PER_SEC / (uint64_t)rate);
    dispatch_source_set_timer(_displaySource, _paused ? DISPATCH_TIME_FOREVER : DISPATCH_TIME_NOW,
                             interval, MIN(NSEC_PER_MSEC, interval / 10));
}

- (void)startOffscreenClock {
    _displaySource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    __weak AsyncGLViewController *weakSelf = self;
    dispatch_source_set_event_handler(_displaySource, ^{
        AsyncGLViewController *controller = weakSelf;
        if (controller != nil && !controller.isPaused && !controller.shuttingDown)
            [controller requestRender];
    });
    [self updateOffscreenFrameRate];
    dispatch_resume(_displaySource);
}

- (void)setPaused:(BOOL)paused
{
    // A newer pause/resume request supersedes the deferred offscreen startup.
    _resumeOffscreenAfterPreparation = NO;
    _paused = paused;
    [self updateOffscreenFrameRate];

    if (@available(macOS 14.0, *))
        [self updateDisplayLinkConfiguration];
#if TARGET_OS_OSX
    if (_cvDisplayLink != NULL)
        paused || !_displayLinkRenderable ? CVDisplayLinkStop(_cvDisplayLink) : CVDisplayLinkStart(_cvDisplayLink);
#endif

    paused ? [_glView pause] : [_glView resume];
}

#pragma mark - AsyncGLViewDelegate
- (BOOL)_prepareGL:(CGSize)size samples:(NSInteger)samples
{
    if (![self prepareGL:size samples:samples])
        return NO;

    dispatch_sync(dispatch_get_main_queue(), ^{
        if (self.shuttingDown)
            return;
#if !TARGET_OS_OSX
        [self setWindowScene:self.internalWindowScene];
#else
        [self setScreen:self.internalScreen];
#endif
        self.ready = YES;
        BOOL shouldResume = self.rendersWhileOffscreen && self.resumeOffscreenAfterPreparation;
        self.resumeOffscreenAfterPreparation = NO;
        if (shouldResume)
            self.paused = NO;
    });
    return YES;
}

- (void)_drawGL:(CGSize)size
{
    [self drawGL:size];
}

- (void)_drawGL:(CGSize)size targetTimestamp:(CFTimeInterval)targetTimestamp {
    [self drawGL:size targetTimestamp:targetTimestamp];
}

- (void)_renderabilityChanged:(BOOL)renderable {
    _displayLinkRenderable = renderable;
    if (@available(macOS 14.0, *))
        [self updateDisplayLinkConfiguration];
#if TARGET_OS_OSX
    else if (_cvDisplayLink != NULL)
        _paused || !renderable ? CVDisplayLinkStop(_cvDisplayLink) : CVDisplayLinkStart(_cvDisplayLink);
#endif
}

- (void)_clearGL
{
    [self clearGL];
}

- (void)clearGL
{
}

#if !TARGET_OS_OSX
- (void)_viewWillMoveToWindow:(UIWindow *)window {
    UIWindowScene *windowScene = [window windowScene];
    [self setWindowScene:windowScene];
    if (!_rendersWhileOffscreen)
        [self setPaused:windowScene == nil];
}
#else
- (void)_viewWillMoveToWindow:(NSWindow *)window {
    NSScreen *screen = [window screen];
    [self setScreen:screen];
    if (!_rendersWhileOffscreen)
        [self setPaused:screen == nil];
}
#endif

- (BOOL)prepareGL:(CGSize)rect samples:(NSInteger)samples
{
    return YES;
}

- (void)drawGL:(CGSize)rect
{
    [NSException raise:NSInternalInconsistencyException format:@"You must override %@ in a subclass", NSStringFromSelector(_cmd)];
}

- (void)drawGL:(CGSize)size targetTimestamp:(CFTimeInterval)targetTimestamp {
    [self drawGL:size];
}

- (void)setPreferredFramesPerSecond:(NSInteger)preferredFramesPerSecond {
    _internalPreferredFramesPerSecond = preferredFramesPerSecond;
    [self updateOffscreenFrameRate];
#if TARGET_OS_OSX
    if (@available(macOS 14.0, *))
#endif
        [self updateDisplayLinkConfiguration];
}

#if !TARGET_OS_OSX
- (void)setWindowScene:(UIWindowScene *)windowScene
{
    _internalWindowScene = windowScene;
    [self invalidateDisplayLink];
    if (_shuttingDown)
        return;
    if (_rendersWhileOffscreen) {
        [self startOffscreenClock];
        return;
    }
    if (windowScene == nil)
        return;

    _displayLinkDriver = [[AsyncGLDisplayLinkDriver alloc] initWithView:_glView];
    _displayLink = [self _createDisplayLink];
    [self updateDisplayLinkConfiguration];
    [_displayLinkDriver startWithDisplayLink:_displayLink];
}
#else
- (void)setScreen:(NSScreen *)screen
{
    _internalScreen = screen;
    [self invalidateDisplayLink];
    if (_shuttingDown)
        return;
    if (_rendersWhileOffscreen) {
        [self startOffscreenClock];
        return;
    }
    if (screen == nil)
        return;
    if (@available(macOS 14.0, *)) {
        _displayLinkDriver = [[AsyncGLDisplayLinkDriver alloc] initWithView:_glView];
        _displayLink = [screen displayLinkWithTarget:_displayLinkDriver selector:@selector(requestRender:)];
        if (_displayLink == nil)
            _displayLink = [self.view displayLinkWithTarget:_displayLinkDriver selector:@selector(requestRender:)];
        [self updateDisplayLinkConfiguration];
        [_displayLinkDriver startWithDisplayLink:_displayLink];
    } else {
        NSNumber *directDisplayIDNumber = screen.deviceDescription[@"NSScreenNumber"];
        if (directDisplayIDNumber != nil)
            CVDisplayLinkCreateWithCGDisplay((CGDirectDisplayID)[directDisplayIDNumber unsignedIntValue], &self->_cvDisplayLink);
        else
            CVDisplayLinkCreateWithActiveCGDisplays(&self->_cvDisplayLink);
        CVDisplayLinkSetOutputCallback(self.cvDisplayLink, displayCallback, (__bridge void *)(self));
        if (!_paused && _displayLinkRenderable)
            CVDisplayLinkStart(self.cvDisplayLink);
    }
}
#endif

#pragma mark - private methods
- (void)_configureNotifications
{
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];

#if !TARGET_OS_OSX
    [center addObserver:self selector:@selector(_pauseByNotification) name:UIApplicationWillResignActiveNotification object:nil];
    [center addObserver:self selector:@selector(_resumeByNotification) name:UIApplicationDidBecomeActiveNotification object:nil];
    [center addObserver:self selector:@selector(_windowDidMoveToScreen:) name:@"UIWindowDidMoveToScreenNotification" object:nil];
#else
    [center addObserver:self selector:@selector(_pauseByNotification) name:NSApplicationWillResignActiveNotification object:nil];
    [center addObserver:self selector:@selector(_resumeByNotification) name:NSApplicationDidBecomeActiveNotification object:nil];
    [center addObserver:self selector:@selector(_windowDidMoveToScreen:) name:NSWindowDidChangeScreenNotification object:nil];
#endif

}

- (void)_pauseByNotification
{
    if (_pauseOnWillResignActive && !_rendersWhileOffscreen)
        [self setPaused:YES];
}

- (void)_resumeByNotification
{
    if (_rendersWhileOffscreen)
        return;
#if !TARGET_OS_OSX
    if (_resumeOnDidBecomeActive && _internalWindowScene != nil)
#else
    if (_resumeOnDidBecomeActive && _internalScreen != nil)
#endif
        [self setPaused:NO];
}

- (void)_windowDidMoveToScreen:(NSNotification *)notification
{
    if (![[notification object] isEqual:[[self view] window]])
        return;

#if !TARGET_OS_OSX
    UIWindowScene *windowScene = [[[self view] window] windowScene];
    [self setWindowScene:windowScene];
    if (!_rendersWhileOffscreen)
        [self setPaused:windowScene == nil];
#else
    NSScreen *screen = [[[self view] window] screen];
    [self setScreen:screen];
    if (!_rendersWhileOffscreen)
        [self setPaused:screen == nil];
#endif
}

- (void)updateDisplayLinkConfiguration API_AVAILABLE(macos(14.0), macCatalyst(16.0)) {
    NSInteger preferredFramesPerSecond = _internalPreferredFramesPerSecond;
    CAFrameRateRange range;
    if (preferredFramesPerSecond >= 0) {
        range = CAFrameRateRangeMake(preferredFramesPerSecond / 2, preferredFramesPerSecond, preferredFramesPerSecond);
    } else {
#if !TARGET_OS_OSX
        CGFloat maxFramesPerSecond = [self.internalWindowScene.screen maximumFramesPerSecond];
#else
        CGFloat maxFramesPerSecond = [self.internalScreen maximumFramesPerSecond];
#endif
        range = CAFrameRateRangeMake(maxFramesPerSecond / 2, maxFramesPerSecond, maxFramesPerSecond);
    }
    [_displayLinkDriver updateWithPaused:_paused || !_displayLinkRenderable frameRateRange:range];
}

@end
