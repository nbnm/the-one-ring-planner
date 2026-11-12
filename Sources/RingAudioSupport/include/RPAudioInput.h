#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Contains AVAudioEngine's Objective-C exceptions before they can unwind a Swift task.
@interface RPAudioInput : NSObject
@property(nonatomic, copy, nullable) void (^onFailure)(NSError *error);
- (instancetype)initWithEngine:(AVAudioEngine *)engine;
- (BOOL)startWithBufferSize:(AVAudioFrameCount)bufferSize
                  handler:(AVAudioNodeTapBlock)handler
                    error:(NSError * _Nullable * _Nullable)error;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
