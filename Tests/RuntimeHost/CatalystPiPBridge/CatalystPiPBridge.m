#import "CatalystPiPBridgeProtocol.h"
#import "../MacPiPPrivate/PrivatePiPPresenter.h"

@protocol CatalystHostWindowSPI <NSObject>
- (id)_hostWindowForUIWindow:(id)window;
@end
@protocol CatalystWindowProxySPI <NSObject>
- (NSWindow *)attachedWindow;
@end

@interface CatalystPiPVideoView : NSView
@property (nonatomic) CALayer *videoLayer;
@end
@implementation CatalystPiPVideoView
- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.videoLayer.frame = self.bounds;
    [CATransaction commit];
}
@end

@interface CatalystPiPBridge : NSObject <CatalystPiPBridgeProtocol>
@property (nonatomic) BOOL playing;
@property (nonatomic, copy) void (^activeChanged)(BOOL);
@property (nonatomic, copy) void (^playbackChanged)(BOOL);
@property (nonatomic) PrivatePiPPresenter *presenter;
@property (nonatomic) CatalystPiPVideoView *videoView;
@property (nonatomic, weak) CALayer *originalParent;
@property (nonatomic) CGRect originalFrame;
@end

@implementation CatalystPiPBridge
- (BOOL)fail:(NSString *)message error:(NSError **)error {
    NSLog(@"CatalystPiPBridge: %@", message);
    if (error != NULL)
        *error = [NSError errorWithDomain:@"CatalystPiPBridge" code:1
            userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}

- (BOOL)isActive { return self.presenter.isActive; }

- (void)setPlaying:(BOOL)playing {
    NSAssert(NSThread.isMainThread, @"Private PiP playback must run on main");
    _playing = playing;
    self.presenter.playing = playing;
}

- (BOOL)startWithLayer:(CALayer *)layer uiWindow:(id)uiWindow
           sourceRect:(CGRect)sourceRect windowBounds:(CGRect)windowBounds error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Private PiP presentation must run on main");
    if (self.presenter != nil)
        return [self fail:@"This bridge already owns a PiP presentation." error:error];
    if (uiWindow == nil || layer.superlayer == nil || CGRectIsEmpty(sourceRect) || CGRectIsEmpty(windowBounds))
        return [self fail:@"PiP requires an attached, nonempty source layer and window." error:error];

    id delegate = NSApplication.sharedApplication.delegate;
    if (![delegate respondsToSelector:@selector(_hostWindowForUIWindow:)])
        return [self fail:@"Catalyst's native-window bridge is unavailable." error:error];
    id host = [(id<CatalystHostWindowSPI>)delegate _hostWindowForUIWindow:uiWindow];
    if ([host respondsToSelector:@selector(attachedWindow)])
        host = [(id<CatalystWindowProxySPI>)host attachedWindow];
    if (![host isKindOfClass:NSWindow.class])
        return [self fail:@"Catalyst did not return a native source window." error:error];
    NSWindow *window = host;
    NSView *parent = window.contentView;
    if (parent == nil || NSIsEmptyRect(parent.bounds))
        return [self fail:@"The native source window has no content view." error:error];

    CGFloat scaleX = parent.bounds.size.width / windowBounds.size.width;
    CGFloat scaleY = parent.bounds.size.height / windowBounds.size.height;
    CGFloat x = (sourceRect.origin.x - windowBounds.origin.x) * scaleX;
    CGFloat y = (sourceRect.origin.y - windowBounds.origin.y) * scaleY;
    NSSize size = NSMakeSize(sourceRect.size.width * scaleX, sourceRect.size.height * scaleY);
    if (!parent.isFlipped)
        y = parent.bounds.size.height - y - size.height;
    self.videoView = [[CatalystPiPVideoView alloc] initWithFrame:
        NSMakeRect(parent.bounds.origin.x + x, parent.bounds.origin.y + y, size.width, size.height)];
    self.videoView.wantsLayer = YES;
    self.videoView.videoLayer = layer;
    self.originalParent = layer.superlayer;
    self.originalFrame = layer.frame;
    [parent addSubview:self.videoView];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self.videoView.layer addSublayer:layer];
    layer.frame = self.videoView.bounds;
    [CATransaction commit];

    self.presenter = [PrivatePiPPresenter new];
    self.presenter.playing = self.playing;
    __weak CatalystPiPBridge *weakSelf = self;
    self.presenter.activeChanged = ^(BOOL active) {
        CatalystPiPBridge *bridge = weakSelf;
        if (bridge == nil)
            return;
        if (!active)
            [bridge restoreLayer];
        if (bridge.activeChanged != nil)
            bridge.activeChanged(active);
    };
    self.presenter.playbackChanged = ^(BOOL playing) {
        CatalystPiPBridge *bridge = weakSelf;
        if (bridge == nil)
            return;
        bridge->_playing = playing;
        if (bridge.playbackChanged != nil)
            bridge.playbackChanged(playing);
    };
    if (![self.presenter startWithView:self.videoView error:error]) {
        [self restoreLayer];
        return NO;
    }
    return YES;
}

- (void)restoreLayer {
    CALayer *layer = self.videoView.videoLayer;
    CALayer *parent = self.originalParent;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [layer removeFromSuperlayer];
    layer.frame = self.originalFrame;
    if (parent != nil)
        [parent addSublayer:layer];
    else
        NSLog(@"CatalystPiPBridge: original layer parent disappeared during PiP.");
    [CATransaction commit];
    self.videoView.videoLayer = nil;
    [self.videoView removeFromSuperview];
    self.videoView = nil;
    self.originalParent = nil;
    self.presenter = nil;
}

- (void)stop { [self.presenter stop]; }
- (void)terminateApplication { [NSApplication.sharedApplication terminate:self]; }

- (NSDictionary<NSString *, id> *)geometry {
    NSWindow *window = self.videoView.window;
    if (window == nil)
        return @{};
    NSRect frame = [self.videoView convertRect:self.videoView.bounds toView:nil];
    NSRect bounds = window.contentView.bounds;
    return @{@"videoFrameInWindow": @[@(frame.origin.x), @(frame.origin.y), @(frame.size.width), @(frame.size.height)],
        @"videoWindowContentBounds": @[@(bounds.origin.x), @(bounds.origin.y), @(bounds.size.width), @(bounds.size.height)]};
}
@end
