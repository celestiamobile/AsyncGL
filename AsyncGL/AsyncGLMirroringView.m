//
//  Copyright (c) Levin Li. All rights reserved.
//  Licensed under the MIT License.
//

#import "AsyncGLMirroring.h"

@implementation AsyncGLMirroringView
#if TARGET_OS_OSX
- (CALayer *)makeBackingLayer {
    return [[[AsyncGLMirroringTarget layerClass] alloc] init];
}

- (NSView *)hitTest:(NSPoint)point {
    return nil;
}
#endif

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
#if TARGET_OS_OSX
        self.layer = [self makeBackingLayer];
        self.wantsLayer = YES;
        self.layer.opaque = YES;
        [self setAccessibilityElement:NO];
#else
        self.userInteractionEnabled = NO;
        self.accessibilityElementsHidden = YES;
        self.opaque = YES;
#endif
        CALayer *drawableLayer;
#if TARGET_OS_OSX
        drawableLayer = self.layer;
#else
        // Drawable allocation may update layer contents on the render thread.
        // Keep the drawable separate from UIKit's view-managed backing layer.
        drawableLayer = [[[AsyncGLMirroringTarget layerClass] alloc] init];
        drawableLayer.opaque = YES;
        [self.layer addSublayer:drawableLayer];
#endif
#if !defined(USE_EGL) && !TARGET_OSX_OR_CATALYST
        ((CAEAGLLayer *)drawableLayer).drawableProperties = @{
            kEAGLDrawablePropertyRetainedBacking: @NO,
            kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8
        };
#endif
        _target = [[AsyncGLMirroringTarget alloc] initWithLayer:drawableLayer];
#if TARGET_OS_OSX
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowVisibilityChanged:) name:NSWindowDidChangeOcclusionStateNotification object:nil];
#else
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowVisibilityChanged:) name:UIWindowDidBecomeVisibleNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowVisibilityChanged:) name:UIWindowDidBecomeHiddenNotification object:nil];
#endif
    }
    return self;
}

- (void)updateTarget {
#if TARGET_OS_OSX
    if (self.window != nil)
        self.layer.contentsScale = self.window.backingScaleFactor;
    CGFloat scale = self.layer.contentsScale;
#else
    if (self.window != nil)
        self.contentScaleFactor = self.window.screen.scale;
    CGFloat scale = self.contentScaleFactor;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _target.layer.frame = self.bounds;
    _target.layer.contentsScale = scale;
    [CATransaction commit];
#endif
    CGSize size = CGSizeMake(self.bounds.size.width * scale, self.bounds.size.height * scale);
#ifdef USE_EGL
    ((CAMetalLayer *)_target.layer).drawableSize = size;
#endif
#if TARGET_OS_OSX
    [_target updateSize:size visible:self.window != nil && (self.window.occlusionState & NSWindowOcclusionStateVisible) != 0 && !self.hiddenOrHasHiddenAncestor];
#else
    [_target updateSize:size visible:self.window != nil && !self.window.hidden && !self.hidden];
#endif
}

- (void)windowVisibilityChanged:(NSNotification *)notification {
    if (notification.object == self.window)
        [self updateTarget];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#if TARGET_OS_OSX
- (void)layout {
    [super layout];
    [self updateTarget];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self updateTarget];
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    [self updateTarget];
}
#else
- (void)layoutSubviews {
    [super layoutSubviews];
    [self updateTarget];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self updateTarget];
}
#endif

- (void)setHidden:(BOOL)hidden {
    [super setHidden:hidden];
    [self updateTarget];
}
@end
