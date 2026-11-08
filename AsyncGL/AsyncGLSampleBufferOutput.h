//
//  Copyright (c) Levin Li. All rights reserved.
//  Licensed under the MIT License.
//

#import "AsyncGLMirroring.h"

@interface AsyncGLSampleBufferOutput : NSObject
- (instancetype)initWithMaximumSize:(CGSize)size handler:(void (^)(CMSampleBufferRef))handler;
- (void)drawFromFramebuffer:(GLuint)framebuffer size:(CGSize)size;
- (BOOL)hasPendingFrames;
- (void)pollPendingFrames;
- (void)finishPendingWork;
- (void)clear;
@end
