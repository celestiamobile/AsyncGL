@import AppKit;
@import AVKit;
@import CoreMedia;
@import CoreVideo;
#include <math.h>
#include <string.h>

#if PIP_PRIVATE_SPI
#import "../MacPiPPrivate/PrivatePiPPresenter.h"

@interface CPUVideoView : NSView
@property (nonatomic) AVSampleBufferDisplayLayer *displayLayer;
@end
@implementation CPUVideoView
- (void)resizeVideoLayer {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.displayLayer.frame = self.bounds;
    [CATransaction commit];
}
- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self resizeVideoLayer];
}
- (void)layout {
    [super layout];
    [self resizeVideoLayer];
}
@end
#endif

static NSDictionary *LayerGeometry(CALayer *layer, NSUInteger depth) {
    if (layer == nil)
        return @{};
    NSMutableArray *children = [NSMutableArray array];
    if (depth > 0) {
        for (CALayer *child in layer.sublayers) {
            if (children.count == 12)
                break;
            [children addObject:LayerGeometry(child, depth - 1)];
        }
    }
    CATransform3D t = layer.transform;
    return @{@"class": NSStringFromClass(layer.class),
        @"frame": NSStringFromRect(layer.frame), @"bounds": NSStringFromRect(layer.bounds),
        @"position": NSStringFromPoint(layer.position), @"anchor": NSStringFromPoint(layer.anchorPoint),
        @"scale": @(layer.contentsScale), @"flipped": @(layer.geometryFlipped),
        @"transform": @[@(t.m11), @(t.m12), @(t.m13), @(t.m14),
            @(t.m21), @(t.m22), @(t.m23), @(t.m24),
            @(t.m31), @(t.m32), @(t.m33), @(t.m34),
            @(t.m41), @(t.m42), @(t.m43), @(t.m44)],
        @"sublayers": children};
}

static NSDictionary *ViewGeometry(NSView *view, NSUInteger depth) {
    if (view == nil)
        return @{};
    NSMutableArray *children = [NSMutableArray array];
    if (depth > 0) {
        for (NSView *child in view.subviews) {
            if (children.count == 16)
                break;
            [children addObject:ViewGeometry(child, depth - 1)];
        }
    }
    return @{@"class": NSStringFromClass(view.class),
        @"frame": NSStringFromRect(view.frame), @"bounds": NSStringFromRect(view.bounds),
        @"autoresizingMask": @(view.autoresizingMask),
        @"layer": LayerGeometry(view.layer, 2), @"subviews": children};
}

@interface MacPiP : NSObject <NSApplicationDelegate, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate>
@property (nonatomic) NSWindow *window;
@property (nonatomic) NSTextField *statusLabel;
@property (nonatomic) NSButton *formatButton;
@property (nonatomic) AVSampleBufferDisplayLayer *displayLayer;
@property (nonatomic) AVPictureInPictureController *pip;
@property (nonatomic) NSTimer *timer;
@property (nonatomic) NSUInteger frames;
@property (atomic) BOOL playing;
@property (nonatomic) CMVideoDimensions renderSize;
@property (nonatomic) BOOL failed;
@property (nonatomic) BOOL useNV12;
@property (nonatomic) NSTimeInterval lastReportTime;
@property (nonatomic) NSUInteger renderSizeChanges;
#if PIP_PRIVATE_SPI
@property (nonatomic) PrivatePiPPresenter *privatePiP;
@property (nonatomic) NSView *videoView;
@property (nonatomic) BOOL terminating;
#endif
@end

@implementation MacPiP
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSMenu *menu = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    [menu addItem:appItem];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:[@"Quit " stringByAppendingString:NSProcessInfo.processInfo.processName]
        action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    NSApp.mainMenu = menu;

    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 360, 330)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
#if PIP_PRIVATE_SPI
    self.window.title = @"Mac PiP - PRIVATE SPI (layout 3)";
    CPUVideoView *videoView = [[CPUVideoView alloc] initWithFrame:NSMakeRect(0, 0, 320, 240)];
    self.videoView = videoView;
#else
    self.window.title = @"Mac PiP - CPU geometry probe";
    NSView *videoView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 240)];
#endif
    self.useNV12 = YES;
    videoView.wantsLayer = YES;
    self.displayLayer = [AVSampleBufferDisplayLayer layer];
    self.displayLayer.frame = videoView.bounds;
    self.displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
#if PIP_PRIVATE_SPI
    videoView.displayLayer = self.displayLayer;
#endif
    [videoView.layer addSublayer:self.displayLayer];
    [self.window.contentView addSubview:videoView];

    NSButton *button = [NSButton buttonWithTitle:@"Start / stop PiP" target:self action:@selector(togglePiP)];
    button.frame = NSMakeRect(12, 280, 180, 32);
    [self.window.contentView addSubview:button];
    self.formatButton = [NSButton buttonWithTitle:@"Format: NV12" target:self action:@selector(toggleFormat)];
    self.formatButton.frame = NSMakeRect(200, 280, 148, 32);
    [self.window.contentView addSubview:self.formatButton];
    self.statusLabel = [NSTextField labelWithString:@"Preparing CPU frames"];
    self.statusLabel.frame = NSMakeRect(12, 245, 336, 30);
    self.statusLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    [self.window.contentView addSubview:self.statusLabel];
    [self.window makeKeyAndOrderFront:nil];

#if !PIP_PRIVATE_SPI
    if (!AVPictureInPictureController.isPictureInPictureSupported) {
        [self fail:@"PiP unsupported" code:0];
        return;
    }
    AVPictureInPictureControllerContentSource *content = [[AVPictureInPictureControllerContentSource alloc]
        initWithSampleBufferDisplayLayer:self.displayLayer playbackDelegate:self];
    self.pip = [[AVPictureInPictureController alloc] initWithContentSource:content];
    self.pip.delegate = self;
    self.pip.requiresLinearPlayback = YES;
#endif
    self.playing = YES;
    __weak MacPiP *weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:1.0 / 30 repeats:YES block:^(NSTimer *timer) {
        [weakSelf tick];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}

- (void)fail:(NSString *)operation code:(NSInteger)code {
    self.failed = YES;
    self.formatButton.enabled = NO;
    [self.timer invalidate];
    self.statusLabel.stringValue = [NSString stringWithFormat:@"%@ failed: %ld", operation, (long)code];
    NSLog(@"MacPiP %@", self.statusLabel.stringValue);
}

- (CMSampleBufferRef)newSample CF_RETURNS_RETAINED {
    const size_t width = 320, height = 240;
    CVPixelBufferRef buffer = NULL;
    NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    OSType pixelFormat = self.useNV12 ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA;
    CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
        pixelFormat, (__bridge CFDictionaryRef)attributes, &buffer);
    if (result != kCVReturnSuccess) {
        [self fail:@"Pixel buffer creation" code:result];
        return NULL;
    }
    result = CVPixelBufferLockBaseAddress(buffer, 0);
    if (result != kCVReturnSuccess) {
        CFRelease(buffer);
        [self fail:@"Pixel buffer lock" code:result];
        return NULL;
    }
    const uint8_t colors[4][4] = {
        {255, 0, 0, 255}, {191, 127, (uint8_t)(self.frames % 256), 255},
        {0, 0, 255, 255}, {0, 255, 0, 255}
    };
    if (self.useNV12) {
        uint8_t yuv[4][3];
        for (NSUInteger i = 0; i < 4; ++i) {
            double r = colors[i][2] / 255.0, g = colors[i][1] / 255.0, b = colors[i][0] / 255.0;
            double y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
            yuv[i][0] = (uint8_t)lround(16 + 219 * y);
            yuv[i][1] = (uint8_t)lround(128 + 224 * (b - y) / 1.8556);
            yuv[i][2] = (uint8_t)lround(128 + 224 * (r - y) / 1.5748);
        }
        uint8_t *luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0);
        uint8_t *chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1);
        size_t lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
        size_t chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1);
        for (size_t y = 0; y < height; ++y) {
            NSUInteger quadrant = y >= height / 2 ? 2 : 0;
            memset(luma + y * lumaStride, yuv[quadrant][0], width / 2);
            memset(luma + y * lumaStride + width / 2, yuv[quadrant + 1][0], width / 2);
        }
        for (size_t y = 0; y < height / 2; ++y) {
            for (size_t x = 0; x < width / 2; ++x) {
                NSUInteger quadrant = (y >= height / 4 ? 2 : 0) + (x >= width / 4 ? 1 : 0);
                chroma[y * chromaStride + x * 2] = yuv[quadrant][1];
                chroma[y * chromaStride + x * 2 + 1] = yuv[quadrant][2];
            }
        }
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    } else {
        uint8_t *base = CVPixelBufferGetBaseAddress(buffer);
        size_t stride = CVPixelBufferGetBytesPerRow(buffer);
        for (size_t y = 0; y < height; ++y) {
            for (size_t x = 0; x < width; ++x) {
                const uint8_t *color = colors[(y >= height / 2 ? 2 : 0) + (x >= width / 2 ? 1 : 0)];
                memcpy(base + y * stride + x * 4, color, 4);
            }
        }
    }
    result = CVPixelBufferUnlockBaseAddress(buffer, 0);
    if (result != kCVReturnSuccess) {
        CFRelease(buffer);
        [self fail:@"Pixel buffer unlock" code:result];
        return NULL;
    }

    CMVideoFormatDescriptionRef format = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, buffer, &format);
    if (status != noErr) {
        CFRelease(buffer);
        [self fail:@"Video format creation" code:status];
        return NULL;
    }
    CMSampleTimingInfo timing = {CMTimeMake(1, 30), CMClockGetTime(CMClockGetHostTimeClock()), kCMTimeInvalid};
    CMSampleBufferRef sample = NULL;
    status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, buffer, format, &timing, &sample);
    CFRelease(format);
    CFRelease(buffer);
    if (status != noErr) {
        [self fail:@"Sample creation" code:status];
        return NULL;
    }
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, YES);
    CFMutableDictionaryRef attachment = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
    CFDictionarySetValue(attachment, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    return sample;
}

- (void)tick {
    if (self.displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        NSLog(@"MacPiP display error: %@", self.displayLayer.error);
        [self fail:@"Video display" code:self.displayLayer.error.code];
        return;
    }
    if (self.playing && self.displayLayer.readyForMoreMediaData) {
        CMSampleBufferRef sample = [self newSample];
        if (sample == NULL)
            return;
        [self.displayLayer enqueueSampleBuffer:sample];
        CFRelease(sample);
        ++self.frames;
    }
    [self updateStatus];
    if (NSDate.date.timeIntervalSince1970 - self.lastReportTime >= 1)
        [self writeGeometryReport];
}

- (void)writeGeometryReport {
    self.lastReportTime = NSDate.date.timeIntervalSince1970;
    NSMutableArray *windows = [NSMutableArray array];
    for (NSWindow *window in NSApp.windows) {
        if (windows.count == 8)
            break;
        [windows addObject:@{@"class": NSStringFromClass(window.class),
            @"number": @(window.windowNumber), @"visible": @(window.isVisible),
            @"frame": NSStringFromRect(window.frame), @"backingScale": @(window.backingScaleFactor),
            @"contentView": ViewGeometry(window.contentView, 6)}];
    }
    NSDictionary *report = @{@"revision": @1, @"timestamp": @(self.lastReportTime),
        @"os": NSProcessInfo.processInfo.operatingSystemVersionString,
        @"active": @([self isPiPActive]), @"frames": @(self.frames),
        @"format": self.useNV12 ? @"NV12" : @"BGRA",
        @"renderSize": @[@(self.renderSize.width), @(self.renderSize.height)],
        @"renderSizeChanges": @(self.renderSizeChanges),
        @"sourceLayer": LayerGeometry(self.displayLayer, 4), @"windows": windows};
    NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
        stringByAppendingPathComponent:[NSProcessInfo.processInfo.processName stringByAppendingString:@"-Geometry.json"]];
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:&error];
    if (data == nil || ![data writeToFile:path options:NSDataWritingAtomic error:&error])
        NSLog(@"MacPiP geometry report failed: %@", error);
}

- (void)updateStatus {
#if PIP_PRIVATE_SPI
    if (!self.failed)
        self.statusLabel.stringValue = [NSString stringWithFormat:@"PRIVATE SPI frames=%lu active=%d\nvideo layer=%.0fx%.0f",
            (unsigned long)self.frames, [self isPiPActive],
            self.displayLayer.bounds.size.width, self.displayLayer.bounds.size.height];
#else
    if (!self.failed)
        self.statusLabel.stringValue = [NSString stringWithFormat:@"CPU frames=%lu possible=%d active=%d\nAVKit render size=%dx%d",
            (unsigned long)self.frames, self.pip.isPictureInPicturePossible, self.pip.isPictureInPictureActive,
            self.renderSize.width, self.renderSize.height];
#endif
}

- (BOOL)isPiPActive {
#if PIP_PRIVATE_SPI
    return self.privatePiP.isActive;
#else
    return self.pip.isPictureInPictureActive;
#endif
}

- (void)togglePiP {
    if (self.failed)
        return;
#if PIP_PRIVATE_SPI
    if (self.privatePiP.isActive) {
        [self.privatePiP stop];
        return;
    }
    PrivatePiPPresenter *presenter = [PrivatePiPPresenter new];
    __weak MacPiP *weakSelf = self;
    __weak PrivatePiPPresenter *weakPresenter = presenter;
    presenter.activeChanged = ^(BOOL active) {
        MacPiP *suite = weakSelf;
        if (suite == nil || suite.privatePiP != weakPresenter)
            return;
        suite.formatButton.enabled = !active && !suite.failed;
        if (!active) {
            suite.privatePiP = nil;
            if (suite.terminating)
                [NSApp replyToApplicationShouldTerminate:YES];
        }
        [suite updateStatus];
    };
    presenter.playbackChanged = ^(BOOL playing) {
        MacPiP *suite = weakSelf;
        if (suite != nil && suite.privatePiP == weakPresenter)
            suite.playing = playing;
    };
    presenter.playing = self.playing;
    self.privatePiP = presenter;
    NSError *error = nil;
    if (![presenter startWithView:self.videoView error:&error]) {
        self.privatePiP = nil;
        NSLog(@"MacPiPPrivate start failed: %@", error);
        [self fail:error.localizedDescription code:error.code];
    }
#else
    if (self.pip.isPictureInPictureActive)
        [self.pip stopPictureInPicture];
    else if (self.pip.isPictureInPicturePossible) {
        self.formatButton.enabled = NO;
        [self.pip startPictureInPicture];
    } else
        NSLog(@"MacPiP is not possible yet; display status=%ld", (long)self.displayLayer.status);
#endif
}

- (void)toggleFormat {
    self.useNV12 = !self.useNV12;
    self.formatButton.title = self.useNV12 ? @"Format: NV12" : @"Format: BGRA";
    [self.displayLayer flushAndRemoveImage];
    [self.pip invalidatePlaybackState];
}
- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)controller {
    self.formatButton.enabled = !self.failed;
}
- (void)pictureInPictureController:(AVPictureInPictureController *)controller setPlaying:(BOOL)playing {
    self.playing = playing;
}
- (BOOL)pictureInPictureControllerIsPlaybackPaused:(AVPictureInPictureController *)controller {
    return !self.playing;
}
- (CMTimeRange)pictureInPictureControllerTimeRangeForPlayback:(AVPictureInPictureController *)controller {
    return CMTimeRangeMake(kCMTimeZero, kCMTimePositiveInfinity);
}
- (void)pictureInPictureController:(AVPictureInPictureController *)controller didTransitionToRenderSize:(CMVideoDimensions)size {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.renderSize = size;
        ++self.renderSizeChanges;
        NSLog(@"MacPiP render size=%dx%d", size.width, size.height);
        [self updateStatus];
    });
}
- (void)pictureInPictureController:(AVPictureInPictureController *)controller skipByInterval:(CMTime)interval completionHandler:(void (^)(void))completion {
    completion();
}
- (void)pictureInPictureController:(AVPictureInPictureController *)controller failedToStartPictureInPictureWithError:(NSError *)error {
    NSLog(@"MacPiP could not start: %@", error);
    [self fail:@"PiP start" code:error.code];
}
- (void)pictureInPictureController:(AVPictureInPictureController *)controller restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completion {
    [self.window deminiaturize:nil];
    [self.window makeKeyAndOrderFront:nil];
    completion(YES);
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.timer invalidate];
    [self.pip stopPictureInPicture];
    [self.displayLayer flushAndRemoveImage];
}
#if PIP_PRIVATE_SPI
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    if (!self.privatePiP.isActive)
        return NSTerminateNow;
    self.terminating = YES;
    [self.privatePiP stop];
    return NSTerminateLater;
}
#endif
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        MacPiP *delegate = [MacPiP new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
