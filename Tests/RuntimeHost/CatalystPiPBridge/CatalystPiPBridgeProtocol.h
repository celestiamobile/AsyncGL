@import Foundation;
@import QuartzCore;

NS_ASSUME_NONNULL_BEGIN

@protocol CatalystPiPBridgeProtocol <NSObject>
@property (nonatomic, readonly, getter=isActive) BOOL active;
@property (nonatomic) BOOL playing;
@property (nonatomic, copy, nullable) void (^activeChanged)(BOOL active);
@property (nonatomic, copy, nullable) void (^playbackChanged)(BOOL playing);
@property (nonatomic, readonly) NSDictionary<NSString *, id> *geometry;
- (BOOL)startWithLayer:(CALayer *)layer
             uiWindow:(id)uiWindow
           sourceRect:(CGRect)sourceRect
         windowBounds:(CGRect)windowBounds
                error:(NSError * _Nullable * _Nullable)error;
- (void)stop;
- (void)terminateApplication;
@end

NS_ASSUME_NONNULL_END
