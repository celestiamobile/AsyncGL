@import AppKit;

NS_ASSUME_NONNULL_BEGIN

// Test-only adapter for undocumented PIP.framework SPI. Not for App Store builds.
@interface PrivatePiPPresenter : NSObject
@property (nonatomic, readonly, getter=isActive) BOOL active;
@property (nonatomic) BOOL playing;
@property (nonatomic, copy, nullable) void (^activeChanged)(BOOL active);
@property (nonatomic, copy, nullable) void (^playbackChanged)(BOOL playing);
- (BOOL)startWithView:(NSView *)view error:(NSError * _Nullable * _Nullable)error;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
