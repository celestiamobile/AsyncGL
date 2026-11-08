#import "PrivatePiPPresenter.h"

@protocol PrivatePiPControllerSPI <NSObject>
- (void)setDelegate:(id)delegate;
- (void)setReplacementWindow:(NSWindow *)window;
- (void)setReplacementRect:(NSRect)rect;
- (void)setAspectRatio:(NSSize)size;
- (void)setPlaying:(BOOL)playing;
- (void)presentViewControllerAsPictureInPicture:(NSViewController *)controller;
- (void)dismissPictureInPictureWithCompletionHandler:(void (^)(void))completion;
@end

@interface PrivatePiPContentView : NSView
@property (nonatomic) NSView *videoView;
- (void)fitToSuperview;
@end
@implementation PrivatePiPContentView
- (void)resizeVideoView {
    if (self.videoView.superview != self)
        return;
    self.videoView.frame = self.bounds;
    self.videoView.needsLayout = YES;
    [self.videoView layoutSubtreeIfNeeded];
}
- (void)fitToSuperview {
    if (self.superview == nil || NSEqualRects(self.frame, self.superview.bounds))
        return;
    self.frame = self.superview.bounds;
    [self resizeVideoView];
}
- (void)viewDidMoveToSuperview {
    [super viewDidMoveToSuperview];
    [self fitToSuperview];
}
- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
    [super resizeSubviewsWithOldSize:oldSize];
    [self resizeVideoView];
}
@end

@interface PrivatePiPContentController : NSViewController
@end
@implementation PrivatePiPContentController
- (void)viewDidAppear {
    [super viewDidAppear];
    if ([self.view isKindOfClass:PrivatePiPContentView.class])
        [(PrivatePiPContentView *)self.view fitToSuperview];
}
@end

@interface PrivatePiPPresenter ()
@property (nonatomic, readwrite, getter=isActive) BOOL active;
@property (nonatomic) BOOL closing;
@property (nonatomic) NSViewController<PrivatePiPControllerSPI> *controller;
@property (nonatomic) NSViewController *contentController;
@property (nonatomic) NSView *videoView;
@property (nonatomic, weak) NSView *originalParent;
@property (nonatomic) NSRect originalFrame;
@property (nonatomic) NSAutoresizingMaskOptions originalAutoresizingMask;
@end

@implementation PrivatePiPPresenter
- (BOOL)fail:(NSString *)message error:(NSError **)error {
    NSLog(@"MacPiPPrivate: %@", message);
    if (error != NULL)
        *error = [NSError errorWithDomain:@"MacPiPPrivate" code:1
            userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}

- (BOOL)startWithView:(NSView *)view error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Private PiP presentation must run on main");
    if (self.controller != nil)
        return [self fail:@"This presenter already owns a PiP presentation." error:error];
    if (view.superview == nil || view.window == nil || NSIsEmptyRect(view.bounds))
        return [self fail:@"PiP requires an attached, nonempty video view." error:error];

    NSBundle *bundle = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/PIP.framework"];
    NSError *loadError = nil;
    if (bundle == nil || (!bundle.isLoaded && ![bundle loadAndReturnError:&loadError]))
        return [self fail:[NSString stringWithFormat:@"PIP.framework unavailable: %@", loadError] error:error];
    Class controllerClass = NSClassFromString(@"PIPViewController");
    if (controllerClass == Nil || ![controllerClass isSubclassOfClass:NSViewController.class])
        return [self fail:@"PIPViewController is unavailable." error:error];
    NSViewController<PrivatePiPControllerSPI> *controller = [[controllerClass alloc] init];
    NSArray<NSString *> *requiredSelectors = @[
        @"setDelegate:", @"setReplacementWindow:", @"setReplacementRect:",
        @"setAspectRatio:", @"setPlaying:", @"presentViewControllerAsPictureInPicture:",
        @"dismissPictureInPictureWithCompletionHandler:"
    ];
    for (NSString *name in requiredSelectors) {
        if (![controller respondsToSelector:NSSelectorFromString(name)])
            return [self fail:[@"Missing private selector: " stringByAppendingString:name] error:error];
    }

    self.originalParent = view.superview;
    self.originalFrame = view.frame;
    self.originalAutoresizingMask = view.autoresizingMask;
    self.videoView = view;
    self.controller = controller;
    [controller setDelegate:self];
    [controller setReplacementWindow:view.window];
    [controller setReplacementRect:[view convertRect:view.bounds toView:nil]];
    [controller setAspectRatio:view.bounds.size];
    [controller setPlaying:self.playing];

    self.contentController = [PrivatePiPContentController new];
    [view removeFromSuperview];
    view.frame = NSMakeRect(0, 0, self.originalFrame.size.width, self.originalFrame.size.height);
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    PrivatePiPContentView *contentView = [[PrivatePiPContentView alloc] initWithFrame:view.frame];
    contentView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    contentView.videoView = view;
    [contentView addSubview:view];
    self.contentController.view = contentView;
    self.active = YES;
    [controller presentViewControllerAsPictureInPicture:self.contentController];
    [contentView fitToSuperview];
    if (self.activeChanged != nil)
        self.activeChanged(YES);
    return YES;
}

- (void)setPlaying:(BOOL)playing {
    NSAssert(NSThread.isMainThread, @"Private PiP playback state must run on main");
    _playing = playing;
    [self.controller setPlaying:playing];
}

- (void)stop {
    NSAssert(NSThread.isMainThread, @"Private PiP dismissal must run on main");
    if (self.controller == nil || self.closing)
        return;
    self.closing = YES;
    __weak PrivatePiPPresenter *weakSelf = self;
    [self.controller dismissPictureInPictureWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf finish];
        });
    }];
}

- (void)restoreView {
    if (self.videoView == nil || self.videoView.superview == self.originalParent)
        return;
    if (self.originalParent == nil) {
        NSLog(@"MacPiPPrivate: original video parent disappeared during PiP.");
        return;
    }
    // Detach it from the controller before the PiP window tears its content down.
    self.contentController.view = [NSView new];
    [self.videoView removeFromSuperview];
    self.videoView.frame = self.originalFrame;
    self.videoView.autoresizingMask = self.originalAutoresizingMask;
    [self.originalParent addSubview:self.videoView];
    [self.videoView layoutSubtreeIfNeeded];
}

- (void)finish {
    NSAssert(NSThread.isMainThread, @"Private PiP restoration must run on main");
    if (self.controller == nil)
        return;
    [self restoreView];
    [self.controller setDelegate:nil];
    self.controller = nil;
    self.contentController = nil;
    self.videoView = nil;
    self.originalParent = nil;
    self.closing = NO;
    self.active = NO;
    if (self.activeChanged != nil)
        self.activeChanged(NO);
}

- (BOOL)pipShouldClose:(id)sender {
    return YES;
}
- (void)pipWillClose:(id)sender {
    if (NSThread.isMainThread) {
        self.closing = YES;
        [self restoreView];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.closing = YES;
            [self restoreView];
        });
    }
}
- (void)pipDidClose:(id)sender {
    dispatch_async(dispatch_get_main_queue(), ^{ [self finish]; });
}
- (void)changePlayback:(BOOL)playing {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.active || self.closing)
            return;
        self.playing = playing;
        if (self.playbackChanged != nil)
            self.playbackChanged(playing);
    });
}
- (void)pipActionPlay:(id)sender { [self changePlayback:YES]; }
- (void)pipActionPause:(id)sender { [self changePlayback:NO]; }
- (void)pipActionStop:(id)sender { [self changePlayback:NO]; }
@end
