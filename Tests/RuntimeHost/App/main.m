@import AsyncGL;
#import "AsyncGLView+Private.h"
#import "Capture.h"
#include <stdatomic.h>
#import <TargetConditionals.h>

#if HOST_ANGLE
@import libGLESv2;
#elif TARGET_OS_OSX || TARGET_OS_MACCATALYST
@import OpenGL.GL3;
#else
@import OpenGLES.ES3;
#endif

#if TARGET_OS_OSX
typedef NSView HostView;
#else
typedef UIView HostView;
#endif

@interface RuntimeSource : AsyncGLView
@property (atomic) NSUInteger completedFrames;
#if !TARGET_OS_OSX
@property (nonatomic) BOOL checksWindowState;
@property (nonatomic) NSString *windowMoveFailure;
#endif
@end
@implementation RuntimeSource
- (void)render {
    [super render];
    self.completedFrames += 1;
}
#if !TARGET_OS_OSX
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.checksWindowState &&
        [[self valueForKey:@"shouldRender"] boolValue] != (self.window != nil)) {
        self.windowMoveFailure = self.window == nil ?
            @"Detached source remained eligible to render" :
            @"Reattached source remained ineligible to render";
    }
}
#endif
@end

@interface RuntimeSuite : NSObject <AsyncGLViewDelegate> {
    _Atomic(NSUInteger) _draws;
    _Atomic(NSInteger) _samples;
}
@property (nonatomic) HostView *container;
@property (nonatomic) RuntimeSource *source;
@property (nonatomic) HostView *mirror;
@property (nonatomic) NSTimer *timer;
@property (nonatomic) NSMutableArray *results;
@property (nonatomic) NSInteger stage;
@property (nonatomic) NSInteger pass;
@property (nonatomic) NSUInteger captureBaseline;
@property (nonatomic) NSUInteger frameDeadline;
@property (nonatomic) NSDate *deadline;
@property (nonatomic) BOOL cleanupFinished;
@property (nonatomic) NSString *failure;
#if !TARGET_OS_OSX
@property (nonatomic) UIWindow *sourceWindow;
#endif
- (void)start;
@end

@implementation RuntimeSuite
- (void)start {
    InstallRuntimeCapture();
    self.results = [NSMutableArray array];
    __weak RuntimeSuite *weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *timer) {
        [weakSelf tick];
    }];
    [self beginPass];
}
- (void)beginPass {
    _draws = 0;
    _samples = 0;
    self.cleanupFinished = NO;
    self.source = [[RuntimeSource alloc] initWithFrame:CGRectMake(12, 12, 128, 96)];
#if HOST_ANGLE
    self.source.api = AsyncGLAPIOpenGLES3;
#elif TARGET_OS_OSX || TARGET_OS_MACCATALYST
    self.source.api = AsyncGLAPIOpenGLCore41;
#else
    self.source.api = AsyncGLAPIOpenGLES3;
#endif
    self.source.msaaEnabled = self.pass == 1;
    [self.source commonSetup];
    self.source.delegate = self;
    [self.container addSubview:self.source];
    self.stage = 0;
    self.deadline = [NSDate dateWithTimeIntervalSinceNow:15];
}
- (void)nextStage:(NSInteger)stage {
    self.stage = stage;
    self.captureBaseline = LatestRuntimeCapture().count;
    self.deadline = [NSDate dateWithTimeIntervalSinceNow:15];
}
- (void)attachMirror {
    self.mirror = [self.source startMirroring];
    self.mirror.frame = CGRectMake(180, 12, 104, 72);
    [self.container addSubview:self.mirror];
    [self nextStage:1];
}
#if !TARGET_OS_OSX
- (void)moveSourceToContainer:(UIView *)container {
    self.source.checksWindowState = YES;
    [self.source removeFromSuperview];
    [container addSubview:self.source];
    self.source.checksWindowState = NO;
    if (self.source.windowMoveFailure != nil)
        self.failure = self.source.windowMoveFailure;
}
#endif
- (BOOL)validatePixels {
    RuntimeCapture frame = LatestRuntimeCapture();
    if (frame.error != GL_NO_ERROR) {
        self.failure = [NSString stringWithFormat:@"Mirror readback GL error 0x%x", frame.error];
        return NO;
    }
    const int colors[4][3] = {{255, 0, 0}, {0, 255, 0}, {0, 0, 255}, {64, 128, 191}};
    for (int index = 0; index < 4; ++index) {
        for (int component = 0; component < 3; ++component) {
            if (abs(frame.pixels[index][component] - colors[index][component]) > 2) {
                self.failure = [NSString stringWithFormat:@"Wrong mirror pixel %d: %u %u %u %u",
                    index, frame.pixels[index][0], frame.pixels[index][1], frame.pixels[index][2], frame.pixels[index][3]];
                return NO;
            }
        }
    }
    CGFloat scale = self.mirror.layer.contentsScale;
    if (frame.width != (int)(self.mirror.bounds.size.width * scale) ||
        frame.height != (int)(self.mirror.bounds.size.height * scale)) {
        self.failure = @"The mirror viewport did not follow the view's pixel size";
        return NO;
    }
    return YES;
}
- (void)tick {
    if (self.failure != nil) {
        [self finish:NO];
        return;
    }
    if (self.deadline.timeIntervalSinceNow <= 0) {
        self.failure = [NSString stringWithFormat:@"Timeout at stage %ld (MSAA %ld)", (long)self.stage, (long)self.pass];
        [self finish:NO];
        return;
    }
#if TARGET_OS_OSX
    [self.container layoutSubtreeIfNeeded];
#else
    [self.container layoutIfNeeded];
#endif
    [self.source requestRender];
    RuntimeCapture frame = LatestRuntimeCapture();
    BOOL captured = frame.count >= self.captureBaseline + 3;
    switch (self.stage) {
        case 0:
            if (_draws > 0) {
                if (self.pass == 1 && _samples < 2) {
                    self.failure = @"Requested MSAA was not enabled";
                    break;
                }
#if !TARGET_OS_OSX
                self.sourceWindow = [[UIWindow alloc] initWithWindowScene:self.container.window.windowScene];
                self.sourceWindow.frame = CGRectMake(0, 200, 180, 160);
                self.sourceWindow.rootViewController = [UIViewController new];
                [self moveSourceToContainer:self.sourceWindow.rootViewController.view];
                self.sourceWindow.hidden = NO;
#endif
                [self attachMirror];
            }
            break;
        case 1:
            if (captured && [self validatePixels]) {
                self.mirror.frame = CGRectMake(180, 12, 128, 96);
                self.source.frame = CGRectMake(12, 12, 144, 112);
                [self nextStage:2];
            }
            break;
        case 2:
            if (captured && [self validatePixels]) {
                self.mirror.hidden = YES;
                self.frameDeadline = self.source.completedFrames + 3;
                [self nextStage:3];
            }
            break;
        case 3:
            if (self.source.completedFrames >= self.frameDeadline) {
                self.frameDeadline = self.source.completedFrames + 3;
                [self nextStage:4];
            }
            break;
        case 4:
            if (self.source.completedFrames >= self.frameDeadline) {
                if (frame.count != self.captureBaseline)
                    self.failure = @"A hidden mirror still presented frames";
                self.mirror.hidden = NO;
                [self nextStage:5];
            }
            break;
        case 5:
            if (captured && [self validatePixels]) {
                [self.source stopMirroring];
                [self.mirror removeFromSuperview];
                self.mirror = nil;
                self.frameDeadline = self.source.completedFrames + 3;
                [self nextStage:6];
            }
            break;
        case 6:
            if (self.source.completedFrames >= self.frameDeadline) {
                self.frameDeadline = self.source.completedFrames + 3;
                [self nextStage:7];
            }
            break;
        case 7:
            if (self.source.completedFrames >= self.frameDeadline) {
                if (frame.count != self.captureBaseline)
                    self.failure = @"A stopped mirror still presented frames";
                [self attachMirror];
                [self nextStage:8];
            }
            break;
        case 8:
            if (captured && [self validatePixels]) {
#if !TARGET_OS_OSX
                [self moveSourceToContainer:self.container];
                self.sourceWindow.hidden = YES;
                self.sourceWindow = nil;
#endif
                [self nextStage:9];
            }
            break;
        case 9:
            if (captured && [self validatePixels]) {
                [self.source clearWithDelegate:self completion:^{ self.cleanupFinished = YES; }];
                [self nextStage:10];
            }
            break;
        case 10:
            if (self.cleanupFinished) {
                [self.results addObject:@{@"msaa": @(self.pass == 1), @"samples": @((NSInteger)_samples), @"passed": @YES}];
                [self.mirror removeFromSuperview];
                [self.source removeFromSuperview];
                self.mirror = nil;
                self.source = nil;
                if (self.pass == 0) {
                    self.pass = 1;
                    [self beginPass];
                } else {
                    [self finish:YES];
                }
            }
            break;
    }
}
- (void)finish:(BOOL)passed {
    [self.timer invalidate];
    self.timer = nil;
    if (!passed)
        [self.source clearWithDelegate:self];
#if TARGET_OS_MACCATALYST
    NSString *platform = @"Catalyst";
#elif TARGET_OS_OSX
    NSString *platform = @"macOS";
#else
    NSString *platform = @"iOS Simulator";
#endif
    NSDictionary *report = @{@"platform": platform, @"angle": @(HOST_ANGLE), @"passed": @(passed),
        @"cases": self.results, @"failure": self.failure ?: [NSNull null],
        @"os": NSProcessInfo.processInfo.operatingSystemVersionString,
        @"draws": @((NSUInteger)_draws), @"mirrorFrames": @(LatestRuntimeCapture().count)};
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:&error];
    NSString *directory = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *name = [NSString stringWithFormat:@"AsyncGL-%@-%@.json", platform, HOST_ANGLE ? @"ANGLE" : @"Native"];
    NSString *path = [directory stringByAppendingPathComponent:name];
    if (data == nil || ![data writeToFile:path options:NSDataWritingAtomic error:&error])
        NSLog(@"Could not write runtime test report: %@", error);
    NSLog(@"ASYNCGL_RUNTIME_RESULT %@", report);
#if TARGET_OS_OSX
    self.container.window.title = passed ? @"AsyncGL: PASS" : [@"AsyncGL: FAIL " stringByAppendingString:self.failure];
#else
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(12, 150, 600, 80)];
    label.numberOfLines = 0;
    label.text = passed ? @"AsyncGL: PASS (single-sample and MSAA)" : [@"AsyncGL: FAIL " stringByAppendingString:self.failure];
    [self.container addSubview:label];
#endif
}
- (BOOL)_prepareGL:(CGSize)size samples:(NSInteger)samples {
    _samples = samples;
    return YES;
}
- (void)_drawGL:(CGSize)size {
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    glEnable(GL_SCISSOR_TEST);
    const GLfloat colors[4][4] = {{1, 0, 0, 1}, {0, 1, 0, 1}, {0, 0, 1, 1}, {.25, .5, .75, 1}};
    for (int index = 0; index < 4; ++index) {
        glScissor((index & 1) * (GLsizei)size.width / 2, (index >> 1) * (GLsizei)size.height / 2,
                  (GLsizei)size.width / 2, (GLsizei)size.height / 2);
        glClearColor(colors[index][0], colors[index][1], colors[index][2], 1);
        glClear(GL_COLOR_BUFFER_BIT);
    }
    glDisable(GL_SCISSOR_TEST);
    ++_draws;
}
- (void)_clearGL {}
#if TARGET_OS_OSX
- (void)_viewWillMoveToWindow:(NSWindow *)window {}
#else
- (void)_viewWillMoveToWindow:(UIWindow *)window {
    // Match AsyncGLViewController's pause/resume behavior during reparenting.
    window == nil ? [self.source pause] : [self.source resume];
}
#endif
@end

#if TARGET_OS_OSX
@interface RuntimeAppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic) NSWindow *window;
@property (nonatomic) RuntimeSuite *suite;
@end
@implementation RuntimeAppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(80, 80, 400, 260)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"AsyncGL runtime tests";
    [self.window orderFront:nil];
    self.suite = [RuntimeSuite new];
    self.suite.container = self.window.contentView;
    [self.suite start];
}
@end
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        RuntimeAppDelegate *delegate = [RuntimeAppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
#else
@interface RuntimeSceneDelegate : NSObject <UIWindowSceneDelegate>
@property (nonatomic) UIWindow *window;
@property (nonatomic) RuntimeSuite *suite;
@end
@implementation RuntimeSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = UIColor.systemBackgroundColor;
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];
    self.suite = [RuntimeSuite new];
    self.suite.container = root.view;
}
- (void)sceneDidBecomeActive:(UIScene *)scene {
    if (self.suite.timer == nil && self.suite.results == nil)
        [self.suite start];
}
@end
@interface RuntimeAppDelegate : NSObject <UIApplicationDelegate>
@end
@implementation RuntimeAppDelegate
@end
int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([RuntimeAppDelegate class]));
    }
}
#endif
