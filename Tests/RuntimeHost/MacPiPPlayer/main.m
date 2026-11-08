@import AppKit;
@import AVKit;
@import UniformTypeIdentifiers;

@interface PlayerView : NSView
@end
@implementation PlayerView
- (CALayer *)makeBackingLayer {
    return [AVPlayerLayer layer];
}
@end

@interface MacPiPPlayer : NSObject <NSApplicationDelegate, AVPictureInPictureControllerDelegate>
@property (nonatomic) NSWindow *window;
@property (nonatomic) AVPlayer *player;
@property (nonatomic) AVPictureInPictureController *pip;
@property (nonatomic) NSTextField *statusLabel;
@property (nonatomic) NSTimer *timer;
@property (nonatomic, copy) NSString *errorMessage;
@end

@implementation MacPiPPlayer
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSMenu *menu = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    [menu addItem:appItem];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:@"Quit MacPiPPlayer" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    NSApp.mainMenu = menu;

    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 640, 432)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Mac PiP - AVPlayerLayer";
    self.window.contentMinSize = NSMakeSize(400, 300);
    PlayerView *videoView = [[PlayerView alloc] initWithFrame:NSMakeRect(0, 0, 640, 360)];
    videoView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    videoView.wantsLayer = YES;
    AVPlayerLayer *layer = (AVPlayerLayer *)videoView.layer;
    layer.videoGravity = AVLayerVideoGravityResizeAspect;
    layer.backgroundColor = NSColor.blackColor.CGColor;
    self.player = [AVPlayer new];
    self.player.muted = YES;
    layer.player = self.player;
    [self.window.contentView addSubview:videoView];

    NSButton *openButton = [NSButton buttonWithTitle:@"Open movie..." target:self action:@selector(openMovie)];
    openButton.frame = NSMakeRect(12, 392, 156, 28);
    openButton.autoresizingMask = NSViewMinYMargin;
    [self.window.contentView addSubview:openButton];
    NSButton *pipButton = [NSButton buttonWithTitle:@"Start / stop PiP" target:self action:@selector(togglePiP)];
    pipButton.frame = NSMakeRect(180, 392, 180, 28);
    pipButton.autoresizingMask = NSViewMinYMargin;
    [self.window.contentView addSubview:pipButton];
    self.statusLabel = [NSTextField labelWithString:@"Open a local movie to compare AVPlayerLayer PiP."];
    self.statusLabel.frame = NSMakeRect(12, 364, 616, 28);
    self.statusLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [self.window.contentView addSubview:self.statusLabel];
    [self.window makeKeyAndOrderFront:nil];

    if (!AVPictureInPictureController.isPictureInPictureSupported) {
        [self fail:@"PiP is unsupported on this system."];
        return;
    }
    self.pip = [[AVPictureInPictureController alloc] initWithPlayerLayer:layer];
    self.pip.delegate = self;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(loopMovie:)
        name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
    __weak MacPiPPlayer *weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
        [weakSelf updateStatus];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}

- (void)fail:(NSString *)message {
    self.errorMessage = message;
    self.statusLabel.stringValue = message;
    NSLog(@"MacPiPPlayer %@", message);
}

- (void)openMovie {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[UTTypeMovie];
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK)
            return;
        self.errorMessage = nil;
        [self.player replaceCurrentItemWithPlayerItem:[AVPlayerItem playerItemWithURL:panel.URL]];
        [self.player play];
        [self updateStatus];
    }];
}

- (void)loopMovie:(NSNotification *)notification {
    if (notification.object == self.player.currentItem) {
        [self.player seekToTime:kCMTimeZero];
        [self.player play];
    }
}

- (void)updateStatus {
    AVPlayerItem *item = self.player.currentItem;
    if (self.errorMessage != nil)
        return;
    if (self.player.status == AVPlayerStatusFailed || item.status == AVPlayerItemStatusFailed) {
        NSError *error = self.player.error ?: item.error;
        [self fail:[NSString stringWithFormat:@"Movie playback failed: %@", error]];
        return;
    }
    if (item != nil)
        self.statusLabel.stringValue = [NSString stringWithFormat:@"AVPlayerLayer: %@ | PiP possible=%d active=%d",
            item.status == AVPlayerItemStatusReadyToPlay ? @"ready (muted, looping)" : @"loading",
            self.pip.isPictureInPicturePossible, self.pip.isPictureInPictureActive];
}

- (void)togglePiP {
    if (self.pip.isPictureInPictureActive)
        [self.pip stopPictureInPicture];
    else if (self.pip.isPictureInPicturePossible)
        [self.pip startPictureInPicture];
    else
        NSLog(@"MacPiPPlayer: open a playable movie and wait for PiP possible=1.");
}
- (void)pictureInPictureController:(AVPictureInPictureController *)controller failedToStartPictureInPictureWithError:(NSError *)error {
    [self fail:[NSString stringWithFormat:@"PiP could not start: %@", error]];
}
- (void)pictureInPictureController:(AVPictureInPictureController *)controller restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completion {
    [self.window deminiaturize:nil];
    [self.window makeKeyAndOrderFront:nil];
    completion(YES);
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.timer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self.pip stopPictureInPicture];
    [self.player pause];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        MacPiPPlayer *delegate = [MacPiPPlayer new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
