@import AsyncGL;
@import AVKit;
@import CoreVideo;
#import "AsyncGLView+Private.h"
#include <stdatomic.h>

#define PIP_PRIVATE_CATALYST (TARGET_OS_MACCATALYST && PIP_CATALYST_PRIVATE_SPI)
#define PIP_USES_PRIVATE (PIP_PRIVATE_SPI || PIP_PRIVATE_CATALYST)

#if PIP_PRIVATE_SPI
#import "../MacPiPPrivate/PrivatePiPPresenter.h"
#elif PIP_PRIVATE_CATALYST
#import "../CatalystPiPBridge/CatalystPiPBridgeProtocol.h"
#endif

#if HOST_ANGLE
@import libGLESv2;
#elif TARGET_OS_OSX || TARGET_OS_MACCATALYST
@import OpenGL.GL3;
#else
@import OpenGLES.ES3;
#endif

static NSArray *PiPRect(CGRect rect) {
    return @[@(rect.origin.x), @(rect.origin.y), @(rect.size.width), @(rect.size.height)];
}

static NSArray *PiPTransform(CATransform3D t) {
    return @[@(t.m11), @(t.m12), @(t.m13), @(t.m14),
             @(t.m21), @(t.m22), @(t.m23), @(t.m24),
             @(t.m31), @(t.m32), @(t.m33), @(t.m34),
             @(t.m41), @(t.m42), @(t.m43), @(t.m44)];
}

static NSDictionary *PiPLayerGeometry(CALayer *layer, NSUInteger depth) {
    if (layer == nil)
        return @{};
    NSMutableArray *children = [NSMutableArray array];
    if (depth > 0) {
        for (CALayer *child in layer.sublayers) {
            if (children.count == 12)
                break;
            [children addObject:PiPLayerGeometry(child, depth - 1)];
        }
    }
    return @{@"class": NSStringFromClass(layer.class),
        @"frame": PiPRect(layer.frame), @"bounds": PiPRect(layer.bounds),
        @"position": @[@(layer.position.x), @(layer.position.y)],
        @"anchorPoint": @[@(layer.anchorPoint.x), @(layer.anchorPoint.y)],
        @"contentsScale": @(layer.contentsScale), @"contentsRect": PiPRect(layer.contentsRect),
        @"geometryFlipped": @(layer.geometryFlipped),
        @"transform": PiPTransform(layer.transform),
        @"sublayerTransform": PiPTransform(layer.sublayerTransform),
        @"sublayers": children};
}

#if TARGET_OS_OSX
typedef NSView HostView;

@interface PiPVideoView : NSView
@property (nonatomic, readonly) AVSampleBufferDisplayLayer *displayLayer;
@end
@implementation PiPVideoView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        _displayLayer = [AVSampleBufferDisplayLayer layer];
        _displayLayer.frame = self.bounds;
        [self.layer addSublayer:_displayLayer];
    }
    return self;
}
- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.displayLayer.frame = self.bounds;
    [CATransaction commit];
}
@end
#else
typedef UIView HostView;
#endif

@interface PiPSource : AsyncGLView
@property (nonatomic) BOOL offscreenExperiment;
@end
@implementation PiPSource
- (BOOL)_allowsOffscreenRendering { return self.offscreenExperiment; }
@end

@interface PiPSuite : NSObject <AsyncGLViewDelegate, AVPictureInPictureSampleBufferPlaybackDelegate, AVPictureInPictureControllerDelegate> {
    atomic_uint_fast64_t _draws;
    atomic_uint_fast64_t _samples;
    atomic_uint_fast64_t _badSamples;
    atomic_int _sampleCount;
    atomic_bool _playing;
    atomic_uint_fast64_t _timeRangeQueries;
    atomic_uint_fast64_t _pausedQueries;
}
@property (nonatomic) HostView *container;
@property (nonatomic) PiPSource *source;
@property (nonatomic) AVSampleBufferDisplayLayer *displayLayer;
@property (nonatomic) AVPictureInPictureController *pip;
@property (nonatomic) dispatch_source_t clock;
@property (nonatomic) NSTimer *statusTimer;
@property (nonatomic) BOOL backgroundExperiment;
@property (nonatomic) BOOL stopping;
@property (nonatomic) BOOL renderingStopped;
@property (nonatomic) BOOL stopped;
@property (nonatomic) NSMutableArray<dispatch_block_t> *stopCompletions;
@property (atomic, copy) NSDictionary *sampleGeometry;
@property (nonatomic) CMVideoDimensions pipRenderSize;
@property (nonatomic) NSMutableArray<NSDictionary *> *geometryEvents;
@property (nonatomic) NSDictionary *lastActiveGeometry;
#if PIP_PRIVATE_SPI
@property (nonatomic) PrivatePiPPresenter *privatePiP;
#elif PIP_PRIVATE_CATALYST
@property (nonatomic) id<CatalystPiPBridgeProtocol> privatePiP;
#endif
#if PIP_USES_PRIVATE
@property (nonatomic, copy) NSString *pipError;
#endif
#if TARGET_OS_OSX
@property (nonatomic) NSTextField *statusLabel;
@property (nonatomic) NSView *videoContainer;
#else
@property (nonatomic) UILabel *statusLabel;
#endif
- (void)start;
- (void)stop;
- (void)stopWithCompletion:(dispatch_block_t)completion;
@end

@implementation PiPSuite
- (void)start {
    atomic_init(&_draws, 0);
    atomic_init(&_samples, 0);
    atomic_init(&_badSamples, 0);
    atomic_init(&_sampleCount, 0);
    atomic_init(&_playing, true);
    atomic_init(&_timeRangeQueries, 0);
    atomic_init(&_pausedQueries, 0);
    self.geometryEvents = [NSMutableArray array];
    self.source = [[PiPSource alloc] initWithFrame:CGRectMake(12, 12, 256, 192)];
#if HOST_ANGLE
    self.source.api = AsyncGLAPIOpenGLES3;
#elif TARGET_OS_OSX || TARGET_OS_MACCATALYST
    self.source.api = AsyncGLAPIOpenGLCore41;
#else
    self.source.api = AsyncGLAPIOpenGLES3;
#endif
    self.source.msaaEnabled = YES;
    [self.source commonSetup];
    self.source.delegate = self;
    [self.container addSubview:self.source];
#if TARGET_OS_OSX
    PiPVideoView *videoView = [[PiPVideoView alloc] initWithFrame:NSMakeRect(280, 12, 256, 192)];
    [self.container addSubview:videoView];
    self.videoContainer = videoView;
    self.displayLayer = videoView.displayLayer;
    self.statusLabel = [NSTextField labelWithString:@"Preparing PiP"];
#else
    self.displayLayer = [AVSampleBufferDisplayLayer layer];
    self.displayLayer.frame = CGRectMake(280, 12, 256, 192);
    [self.container.layer addSublayer:self.displayLayer];
    self.statusLabel = [UILabel new];
    self.statusLabel.numberOfLines = 0;
    NSError *audioError = nil;
    if (![AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback error:&audioError] ||
        ![AVAudioSession.sharedInstance setActive:YES error:&audioError])
        NSLog(@"PIP_TEST audio session failed: %@", audioError);
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(resignActive)
        name:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(becomeActive)
        name:UIApplicationDidBecomeActiveNotification object:nil];
#endif
    self.displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    self.statusLabel.frame = CGRectMake(12, 220, 520, 70);
    [self.container addSubview:self.statusLabel];
    [self addButton:@"Start / stop PiP" action:@selector(togglePiP) frame:CGRectMake(12, 300, 180, 36)];
#if TARGET_OS_OSX
    [self addButton:@"Minimize window" action:@selector(minimizeWindow) frame:CGRectMake(200, 300, 180, 36)];
    [self addButton:@"Quit" action:@selector(quit) frame:CGRectMake(390, 300, 100, 36)];
#elif PIP_PRIVATE_CATALYST
    self.container.window.windowScene.title = @"AsyncGL ANGLE PiP (Catalyst private SPI)";
    [self addButton:@"Quit" action:@selector(quit) frame:CGRectMake(200, 300, 100, 36)];
#else
    [self addButton:@"Background experiment: OFF" action:@selector(toggleExperiment:) frame:CGRectMake(200, 300, 300, 36)];
#endif

    __weak PiPSuite *weakSelf = self;
    NSError *error = nil;
    if (![self.source startSampleBufferOutputWithMaximumSize:CGSizeMake(256, 192) handler:^(CMSampleBufferRef sample) {
        [weakSelf receiveSample:sample];
    } error:&error]) {
        NSLog(@"PIP_TEST output startup failed: %@", error);
        [self stop];
        return;
    }
#if !PIP_USES_PRIVATE
    if (AVPictureInPictureController.isPictureInPictureSupported) {
        AVPictureInPictureControllerContentSource *content = [[AVPictureInPictureControllerContentSource alloc]
            initWithSampleBufferDisplayLayer:self.displayLayer playbackDelegate:self];
        self.pip = [[AVPictureInPictureController alloc] initWithContentSource:content];
        self.pip.delegate = self;
        self.pip.requiresLinearPlayback = YES;
    } else {
        NSLog(@"PIP_TEST system PiP is unsupported on this device");
    }
#endif
    self.clock = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    dispatch_source_set_timer(self.clock, dispatch_time(DISPATCH_TIME_NOW, 0), NSEC_PER_SEC / 30, NSEC_PER_MSEC);
    dispatch_source_set_event_handler(self.clock, ^{
        PiPSuite *suite = weakSelf;
        if (suite != nil && atomic_load(&suite->_playing))
            [suite.source requestRender];
    });
    dispatch_resume(self.clock);
    self.statusTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        [weakSelf updateStatus];
    }];
}

- (void)addButton:(NSString *)title action:(SEL)action frame:(CGRect)frame {
#if TARGET_OS_OSX
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
#else
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
#endif
    button.frame = frame;
    [self.container addSubview:button];
}

- (void)toggleExperiment:(id)sender {
    self.backgroundExperiment = !self.backgroundExperiment;
    NSString *title = self.backgroundExperiment ? @"Background experiment: ON" : @"Background experiment: OFF";
#if TARGET_OS_OSX
    [(NSButton *)sender setTitle:title];
#else
    [(UIButton *)sender setTitle:title forState:UIControlStateNormal];
#endif
    [self updateOffscreenState];
}

#if TARGET_OS_OSX
- (void)minimizeWindow { [self.container.window miniaturize:self]; }
- (void)quit { [NSApp terminate:self]; }
#endif

#if PIP_PRIVATE_CATALYST
- (id<CatalystPiPBridgeProtocol>)makePrivateBridgeWithError:(NSError **)error {
    NSURL *url = [NSBundle.mainBundle.builtInPlugInsURL URLByAppendingPathComponent:@"CatalystPiPBridge.bundle"];
    NSBundle *bundle = url != nil ? [NSBundle bundleWithURL:url] : nil;
    if (bundle == nil) {
        *error = [NSError errorWithDomain:@"PiPHost" code:1 userInfo:
            @{NSLocalizedDescriptionKey: @"The Catalyst PiP AppKit bundle is missing."}];
        return nil;
    }
    if (![bundle loadAndReturnError:error])
        return nil;
    Class bridgeClass = bundle.principalClass;
    if (![bridgeClass conformsToProtocol:@protocol(CatalystPiPBridgeProtocol)]) {
        *error = [NSError errorWithDomain:@"PiPHost" code:2 userInfo:
            @{NSLocalizedDescriptionKey: @"The Catalyst PiP bundle has an incompatible principal class."}];
        return nil;
    }
    return [[bridgeClass alloc] init];
}
- (void)quit {
    NSError *error = nil;
    id<CatalystPiPBridgeProtocol> bridge = self.privatePiP ?: [self makePrivateBridgeWithError:&error];
    if (bridge == nil) {
        self.pipError = error.localizedDescription;
        NSLog(@"PIP_TEST private bridge unavailable for coordinated quit: %@", error);
        [self updateStatus];
        return;
    }
    [self stopWithCompletion:^{ [bridge terminateApplication]; }];
}
#endif

- (BOOL)isPiPActive {
#if PIP_USES_PRIVATE
    return self.privatePiP.isActive;
#else
    return self.pip.isPictureInPictureActive;
#endif
}

- (void)updateOffscreenState {
#if TARGET_OS_OSX || PIP_PRIVATE_CATALYST
    self.source.offscreenExperiment = !self.stopping && [self isPiPActive];
#else
    self.source.offscreenExperiment = !self.stopping && self.backgroundExperiment && [self isPiPActive];
#endif
    [self.source _checkViewState];
}

- (void)togglePiP {
    if (self.stopping)
        return;
#if PIP_USES_PRIVATE
    if (self.privatePiP.isActive) {
        [self.privatePiP stop];
        return;
    }
    if (atomic_load(&_samples) == 0) {
        NSLog(@"PIP_TEST private PiP is waiting for the first GPU sample");
        return;
    }
    NSError *error = nil;
#if PIP_PRIVATE_SPI
    PrivatePiPPresenter *presenter = [PrivatePiPPresenter new];
#else
    id<CatalystPiPBridgeProtocol> presenter = [self makePrivateBridgeWithError:&error];
#endif
    __weak PiPSuite *weakSelf = self;
    __weak __typeof__(presenter) weakPresenter = presenter;
    presenter.activeChanged = ^(BOOL active) {
        PiPSuite *suite = weakSelf;
        if (suite == nil || suite.privatePiP != weakPresenter)
            return;
        if (!active)
            suite.privatePiP = nil;
        [suite updateOffscreenState];
        if (active && !suite.stopping && atomic_load(&suite->_playing))
            [suite.source resume];
        [suite recordGeometryEvent:active ? @"Private PiP started" : @"Private PiP stopped"];
        [suite finishStopIfReady];
    };
    presenter.playbackChanged = ^(BOOL playing) {
        PiPSuite *suite = weakSelf;
        if (suite != nil && suite.privatePiP == weakPresenter && !suite.stopping)
            [suite applyPlaybackState:playing];
    };
    presenter.playing = atomic_load(&_playing);
    self.privatePiP = presenter;
    self.pipError = nil;
#if PIP_PRIVATE_SPI
    BOOL started = [presenter startWithView:self.videoContainer error:&error];
#else
    CGRect rect = [self.container convertRect:self.displayLayer.frame toView:nil];
    BOOL started = presenter != nil && [presenter startWithLayer:self.displayLayer
        uiWindow:self.container.window sourceRect:rect windowBounds:self.container.window.bounds error:&error];
#endif
    if (!started) {
        self.privatePiP = nil;
        self.pipError = error.localizedDescription;
        NSLog(@"PIP_TEST private PiP startup failed: %@", error);
        [self updateStatus];
    }
#else
    if (self.pip.isPictureInPictureActive)
        [self.pip stopPictureInPicture];
    else if (self.pip.isPictureInPicturePossible && atomic_load(&_samples) > 0)
        [self.pip startPictureInPicture];
    else
        NSLog(@"PIP_TEST PiP is not possible yet; supported=%d controller=%@ samples=%llu "
            "timeRangeQueries=%llu pausedQueries=%llu display status=%ld error=%@",
            AVPictureInPictureController.isPictureInPictureSupported, self.pip,
            (unsigned long long)atomic_load(&_samples),
            (unsigned long long)atomic_load(&_timeRangeQueries),
            (unsigned long long)atomic_load(&_pausedQueries),
            (long)self.displayLayer.status, self.displayLayer.error);
#endif
}

- (void)receiveSample:(CMSampleBufferRef)sample {
    CVPixelBufferRef buffer = CMSampleBufferGetImageBuffer(sample);
    BOOL valid = CVPixelBufferGetWidth(buffer) == 256 && CVPixelBufferGetHeight(buffer) == 192;
    CVReturn lockResult = CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    if (lockResult == kCVReturnSuccess) {
        const uint8_t *base = CVPixelBufferGetBaseAddress(buffer);
        size_t stride = CVPixelBufferGetBytesPerRow(buffer);
        // Pixel buffers are top-down BGRA; GL's bottom-left quadrant is red.
        const uint8_t *topLeft = base + 48 * stride + 64 * 4;
        const uint8_t *bottomLeft = base + 144 * stride + 64 * 4;
        const uint8_t *bottomRight = base + 144 * stride + 192 * 4;
        valid = valid && topLeft[0] > 250 && topLeft[1] < 3 && topLeft[2] < 3 &&
            bottomLeft[2] > 250 && bottomLeft[0] < 3 && bottomLeft[1] < 3 &&
            bottomRight[1] > 250 && bottomRight[0] < 3 && bottomRight[2] < 3;
        CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    } else {
        valid = NO;
    }
    if (atomic_fetch_add(&_samples, 1) == 0) {
        CMVideoFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
        CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format);
        CGSize presentation = CMVideoFormatDescriptionGetPresentationDimensions(format, YES, YES);
        self.sampleGeometry = @{
            @"bufferSize": @[@(CVPixelBufferGetWidth(buffer)), @(CVPixelBufferGetHeight(buffer))],
            @"formatSize": @[@(dimensions.width), @(dimensions.height)],
            @"presentationSize": @[@(presentation.width), @(presentation.height)],
            @"cleanAperture": PiPRect(CMVideoFormatDescriptionGetCleanAperture(format, YES))};
    }
    if (!valid)
        atomic_fetch_add(&_badSamples, 1);
    if (self.displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        NSLog(@"PIP_TEST display layer failed: %@", self.displayLayer.error);
        return;
    }
    if (self.displayLayer.readyForMoreMediaData)
        [self.displayLayer enqueueSampleBuffer:sample];
}

- (void)updateStatus {
#if PIP_USES_PRIVATE
    NSString *pipStatus = self.pipError ?: [NSString stringWithFormat:@"PiP private ready=%d active=%d",
        !self.stopping && atomic_load(&_samples) > 0, [self isPiPActive]];
#else
    NSString *pipStatus = [NSString stringWithFormat:@"PiP possible=%d active=%d",
        self.pip.isPictureInPicturePossible, [self isPiPActive]];
#endif
    NSString *text = [NSString stringWithFormat:@"draws=%llu samples=%llu bad=%llu MSAA=%d\n%@",
        (unsigned long long)atomic_load(&_draws), (unsigned long long)atomic_load(&_samples),
        (unsigned long long)atomic_load(&_badSamples), atomic_load(&_sampleCount),
        pipStatus];
#if TARGET_OS_OSX
    self.statusLabel.stringValue = text;
#else
    self.statusLabel.text = text;
#endif
    NSLog(@"PIP_TEST %@", text);
    [self writeReport];
}

- (void)writeReport {
    NSMutableDictionary *report = [@{@"samples": @(atomic_load(&_samples)), @"draws": @(atomic_load(&_draws)),
        @"badSamples": @(atomic_load(&_badSamples)), @"msaaSamples": @(atomic_load(&_sampleCount)),
        @"pipActive": @([self isPiPActive]),
        @"backgroundExperiment": @(self.backgroundExperiment)} mutableCopy];
    report[@"diagnosticRevision"] = @6;
    report[@"stopped"] = @(self.stopped);
#if PIP_USES_PRIVATE
    report[@"pipBackend"] = @"PrivateSPI";
    report[@"pipReady"] = @(!self.stopping && atomic_load(&_samples) > 0);
    if (self.pipError != nil)
        report[@"pipError"] = self.pipError;
#else
    report[@"pipBackend"] = @"AVKit";
    report[@"pipSupported"] = @(AVPictureInPictureController.isPictureInPictureSupported);
    report[@"pipControllerCreated"] = @(self.pip != nil);
    report[@"pipPossible"] = @(self.pip.isPictureInPicturePossible);
    report[@"timeRangeQueries"] = @(atomic_load(&_timeRangeQueries));
    report[@"pausedQueries"] = @(atomic_load(&_pausedQueries));
#endif
#if TARGET_OS_MACCATALYST
    report[@"platform"] = @"Mac Catalyst";
#elif TARGET_OS_OSX
    report[@"platform"] = @"macOS";
#else
    report[@"platform"] = @"iOS";
#endif
    report[@"displayStatus"] = @(self.displayLayer.status);
    if (self.displayLayer.error != nil)
        report[@"displayError"] = self.displayLayer.error.localizedDescription;
    report[@"timestamp"] = @(NSDate.date.timeIntervalSince1970);
#if HOST_ANGLE
    report[@"backend"] = @"ANGLE";
#else
    report[@"backend"] = @"Native";
#endif
    report[@"geometry"] = [self geometrySnapshot];
    report[@"geometryEvents"] = self.geometryEvents ?: @[];
    if ([self isPiPActive])
        self.lastActiveGeometry = report[@"geometry"];
    if (self.lastActiveGeometry != nil)
        report[@"lastActiveGeometry"] = self.lastActiveGeometry;
#if TARGET_OS_OSX
    report[@"minimized"] = @(self.container.window.isMiniaturized);
    report[@"windowVisible"] = @((self.container.window.occlusionState & NSWindowOcclusionStateVisible) != 0);
#else
    report[@"background"] = @(UIApplication.sharedApplication.applicationState == UIApplicationStateBackground);
#endif
    NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
        stringByAppendingPathComponent:@"AsyncGL-PiP.json"];
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:&error];
    if (data == nil || ![data writeToFile:path options:NSDataWritingAtomic error:&error])
        NSLog(@"PIP_TEST report failed: %@", error);
}

- (NSDictionary *)geometrySnapshot {
    NSMutableDictionary *geometry = [@{@"timestamp": @(NSDate.date.timeIntervalSince1970),
        @"active": @([self isPiPActive]),
        @"sample": self.sampleGeometry ?: @{},
        @"videoGravity": self.displayLayer.videoGravity,
        @"videoLayer": PiPLayerGeometry(self.displayLayer, 3),
        @"parentLayer": PiPLayerGeometry(self.displayLayer.superlayer, 0)} mutableCopy];
#if TARGET_OS_OSX
    geometry[@"videoFrameInWindow"] = PiPRect([self.videoContainer convertRect:self.videoContainer.bounds toView:nil]);
    NSWindow *videoWindow = self.videoContainer.window;
    if (videoWindow != nil) {
        geometry[@"videoWindowFrame"] = PiPRect(videoWindow.frame);
        geometry[@"videoWindowContentBounds"] = PiPRect(videoWindow.contentView.bounds);
    }
#endif
#if PIP_PRIVATE_CATALYST
    geometry[@"privateBridge"] = self.privatePiP.geometry ?: @{};
#endif
#if !PIP_USES_PRIVATE
    geometry[@"renderSizePixels"] = @[@(self.pipRenderSize.width), @(self.pipRenderSize.height)];
#endif
    return geometry;
}

- (void)recordGeometryEvent:(NSString *)event {
    NSAssert(NSThread.isMainThread, @"Record PiP geometry on main");
    if (self.geometryEvents.count == 16)
        [self.geometryEvents removeObjectAtIndex:0];
    [self.geometryEvents addObject:@{@"event": event, @"geometry": [self geometrySnapshot]}];
    [self writeReport];
}

- (void)stop {
    [self stopWithCompletion:nil];
}

- (void)stopWithCompletion:(dispatch_block_t)completion {
    NSAssert(NSThread.isMainThread, @"PiP host shutdown must run on main");
    if (self.stopped) {
        if (completion != nil)
            dispatch_async(dispatch_get_main_queue(), completion);
        return;
    }
    if (completion != nil) {
        if (self.stopCompletions == nil)
            self.stopCompletions = [NSMutableArray array];
        [self.stopCompletions addObject:[completion copy]];
    }
    if (self.stopping)
        return;
    self.stopping = YES;
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self.statusTimer invalidate];
    if (self.clock != nil)
        dispatch_source_cancel(self.clock);
#if PIP_USES_PRIVATE
    [self.privatePiP stop];
#else
    [self.pip stopPictureInPicture];
#endif
    self.source.offscreenExperiment = NO;
    [self.source clearWithDelegate:self completion:^{
        [self.displayLayer flushAndRemoveImage];
        self.renderingStopped = YES;
        [self finishStopIfReady];
    }];
}

- (void)finishStopIfReady {
    if (!self.stopping || self.stopped || !self.renderingStopped)
        return;
#if PIP_USES_PRIVATE
    if (self.privatePiP.isActive)
        return;
#endif
    self.stopped = YES;
    [self writeReport];
    NSArray<dispatch_block_t> *completions = [self.stopCompletions copy];
    [self.stopCompletions removeAllObjects];
    for (dispatch_block_t completion in completions)
        completion();
}

#if !TARGET_OS_OSX
- (void)resignActive {
    if (!self.source.offscreenExperiment)
        [self.source pause];
}
- (void)becomeActive {
    [self.source _checkViewState];
    if (!self.stopping && atomic_load(&_playing))
        [self.source resume];
}
#endif

- (BOOL)_prepareGL:(CGSize)size samples:(NSInteger)samples {
    atomic_store(&_sampleCount, (int)samples);
    return YES;
}
- (void)_drawGL:(CGSize)size {
    uint64_t frame = atomic_fetch_add(&_draws, 1);
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    glEnable(GL_SCISSOR_TEST);
    const GLfloat colors[4][3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}, {(frame % 60) / 60.0f, .5f, .75f}};
    for (int i = 0; i < 4; ++i) {
        glScissor((i & 1) * (GLsizei)size.width / 2, (i >> 1) * (GLsizei)size.height / 2,
            (GLsizei)size.width / 2, (GLsizei)size.height / 2);
        glClearColor(colors[i][0], colors[i][1], colors[i][2], 1);
        glClear(GL_COLOR_BUFFER_BIT);
    }
    glDisable(GL_SCISSOR_TEST);
}
- (void)_clearGL {}
#if TARGET_OS_OSX
- (void)_viewWillMoveToWindow:(NSWindow *)window {}
#else
- (void)_viewWillMoveToWindow:(UIWindow *)window {}
#endif
- (void)pictureInPictureController:(AVPictureInPictureController *)controller setPlaying:(BOOL)playing {
    [self applyPlaybackState:playing];
}
- (void)applyPlaybackState:(BOOL)playing {
    atomic_store(&_playing, playing);
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL canRender = !self.stopping;
#if !TARGET_OS_OSX
        canRender = canRender && (UIApplication.sharedApplication.applicationState == UIApplicationStateActive ||
            self.source.offscreenExperiment);
#endif
        (playing && canRender) ? [self.source resume] : [self.source pause];
        [self.pip invalidatePlaybackState];
    });
}
- (CMTimeRange)pictureInPictureControllerTimeRangeForPlayback:(AVPictureInPictureController *)controller {
    atomic_fetch_add(&_timeRangeQueries, 1);
    return CMTimeRangeMake(kCMTimeZero, kCMTimePositiveInfinity);
}
- (BOOL)pictureInPictureControllerIsPlaybackPaused:(AVPictureInPictureController *)controller {
    atomic_fetch_add(&_pausedQueries, 1);
    return !atomic_load(&_playing);
}
- (void)pictureInPictureController:(AVPictureInPictureController *)controller didTransitionToRenderSize:(CMVideoDimensions)size {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.pipRenderSize = size;
        [self recordGeometryEvent:@"render size changed"];
    });
}
- (void)pictureInPictureController:(AVPictureInPictureController *)controller skipByInterval:(CMTime)interval completionHandler:(void (^)(void))completion {
    completion();
}
- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)controller {
    [self updateOffscreenState];
#if TARGET_OS_OSX
    if (atomic_load(&_playing) && !self.stopping)
#else
    if (atomic_load(&_playing) && !self.stopping &&
        (self.source.offscreenExperiment || UIApplication.sharedApplication.applicationState == UIApplicationStateActive))
#endif
        [self.source resume];
    [self recordGeometryEvent:@"PiP started"];
}
- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)controller {
    [self updateOffscreenState];
#if !TARGET_OS_OSX
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive)
        [self.source pause];
#endif
    [self recordGeometryEvent:@"PiP stopped"];
}
- (void)pictureInPictureController:(AVPictureInPictureController *)controller failedToStartPictureInPictureWithError:(NSError *)error {
    NSLog(@"PIP_TEST PiP startup failed: %@", error);
}
- (void)pictureInPictureController:(AVPictureInPictureController *)controller restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completion {
    completion(self.container.window != nil);
}
@end

#if TARGET_OS_OSX
@interface PiPAppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic) NSWindow *window;
@property (nonatomic) PiPSuite *suite;
@end
@implementation PiPAppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(80, 80, 560, 370)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
#if PIP_PRIVATE_SPI
    self.window.title = @"AsyncGL ANGLE PiP (private SPI)";
#else
    self.window.title = @"AsyncGL PiP prototype";
#endif
    [self.window orderFront:nil];
    self.suite = [PiPSuite new];
    self.suite.container = self.window.contentView;
    [self.suite start];
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    [self.suite stopWithCompletion:^{
        [sender replyToApplicationShouldTerminate:YES];
    }];
    return NSTerminateLater;
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
@end
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        PiPAppDelegate *delegate = [PiPAppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
#else
@interface RuntimeSceneDelegate : NSObject <UIWindowSceneDelegate>
@property (nonatomic) UIWindow *window;
@property (nonatomic) PiPSuite *suite;
@end
@implementation RuntimeSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = UIColor.systemBackgroundColor;
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];
    self.suite = [PiPSuite new];
    self.suite.container = root.view;
}
- (void)sceneDidBecomeActive:(UIScene *)scene {
    if (self.suite.source == nil)
        [self.suite start];
    [self.suite becomeActive];
}
- (void)sceneWillResignActive:(UIScene *)scene { [self.suite resignActive]; }
- (void)sceneDidDisconnect:(UIScene *)scene { [self.suite stop]; }
@end
@interface PiPAppDelegate : NSObject <UIApplicationDelegate>
@end
@implementation PiPAppDelegate
@end
int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(PiPAppDelegate.class));
    }
}
#endif
