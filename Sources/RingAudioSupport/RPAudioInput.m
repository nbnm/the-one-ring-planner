#import "RPAudioInput.h"

@interface RPAudioInput ()
@property(nonatomic, strong, nullable) AVAudioEngine *engine;
@property(nonatomic, strong, nullable) AVAudioInputNode *input;
@property(nonatomic) BOOL hasTap;
@property(nonatomic) BOOL wantsRecording;
@property(nonatomic) NSUInteger routeGeneration;
@property(nonatomic) NSUInteger routeRestarts;
@property(nonatomic) NSTimeInterval lastRestart;
@property(nonatomic) AVAudioFrameCount bufferSize;
@property(nonatomic, copy, nullable) AVAudioNodeTapBlock handler;
@property(nonatomic, strong, nullable) id observer;
@end

@implementation RPAudioInput
- (instancetype)initWithEngine:(AVAudioEngine *)engine {
    if ((self = [super init])) { _engine = engine; }
    return self;
}

- (BOOL)startWithBufferSize:(AVAudioFrameCount)bufferSize
                  handler:(AVAudioNodeTapBlock)handler
                    error:(NSError **)error {
    if (self.wantsRecording) {
        if (error) *error = [NSError errorWithDomain:@"com.t1a.planner.audio-input" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"The microphone is already recording."}];
        return NO;
    }
    self.wantsRecording = YES;
    self.bufferSize = bufferSize; self.handler = handler;
    self.routeRestarts = 0; self.lastRestart = 0;
    NSError *failure = nil;
    if ([self installAndStart:&failure]) return YES;
    [self stop];
    if (error) *error = failure;
    return NO;
}

- (BOOL)installAndStart:(NSError **)error {
    NSError *failure = nil;
    @try {
        if (!self.engine) self.engine = [[AVAudioEngine alloc] init];
        if (!self.observer) {
            __weak RPAudioInput *weakSelf = self;
            self.observer = [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioEngineConfigurationChangeNotification
                object:self.engine queue:nil usingBlock:^(NSNotification *notification) {
                    // Never make Core Audio's notification thread wait on the UI.
                    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf scheduleRouteRecovery]; });
                }];
        }
        self.input = self.engine.inputNode;
        // The cached output format can retain 44.1 kHz after a headset switches
        // to a 16 kHz microphone route. The input bus describes the hardware.
        AVAudioFormat *format = [self.input inputFormatForBus:0];
        if (format.sampleRate <= 0 || format.channelCount == 0) {
            failure = [NSError errorWithDomain:@"com.t1a.planner.audio-input" code:3
                userInfo:@{NSLocalizedDescriptionKey: @"No microphone input is available. Check your input device in System Settings → Sound, then try again."}];
        } else {
            [self.input installTapOnBus:0 bufferSize:self.bufferSize format:format block:self.handler];
            self.hasTap = YES;
            [self.engine prepare];
            if ([self.engine startAndReturnError:&failure]) return YES;
        }
    } @catch (NSException *exception) {
        failure = [NSError errorWithDomain:@"com.t1a.planner.audio-input" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"The microphone’s audio format changed while recording was starting. Check your input device in System Settings → Sound, then try again.",
                       NSLocalizedFailureReasonErrorKey: exception.reason ?: @"Audio input configuration failed."}];
    }
    if (error) *error = failure ?: [NSError errorWithDomain:@"com.t1a.planner.audio-input" code:4
        userInfo:@{NSLocalizedDescriptionKey: @"The microphone could not start. Check your input device and try again."}];
    return NO;
}

- (void)scheduleRouteRecovery {
    if (!self.wantsRecording) return;
    NSUInteger generation = ++self.routeGeneration;
    __weak RPAudioInput *weakSelf = self;
    // Bluetooth input/output route changes often arrive as a short burst.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        RPAudioInput *self = weakSelf;
        if (!self || !self.wantsRecording || generation != self.routeGeneration) return;
        @try { if (self.engine.isRunning) return; } @catch (NSException *exception) {}
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (now - self.lastRestart > 10) self.routeRestarts = 0;
        self.lastRestart = now;
        NSError *failure = nil;
        if (++self.routeRestarts <= 3) {
            [self detachInput];
            if ([self installAndStart:&failure]) return;
        }
        void (^failed)(NSError *) = self.onFailure;
        [self stop];
        if (failed) failed(failure ?: [NSError errorWithDomain:@"com.t1a.planner.audio-input" code:5
            userInfo:@{NSLocalizedDescriptionKey: @"The microphone keeps disconnecting. Captured audio is saved. Check your input device, then start a new recording."}]);
    });
}

- (void)detachInput {
    // Each cleanup is independent: an unavailable device must not prevent the
    // engine and tap from being released after a failed start.
    @try { if (self.hasTap) [self.input removeTapOnBus:0]; } @catch (NSException *exception) {}
    self.hasTap = NO;
    @try { [self.engine stop]; } @catch (NSException *exception) {}
    self.input = nil;
}

- (void)stop {
    self.wantsRecording = NO; self.routeGeneration++;
    if (self.observer) [[NSNotificationCenter defaultCenter] removeObserver:self.observer];
    self.observer = nil;
    [self detachInput];
    self.handler = nil;
    self.engine = nil;
}
- (void)dealloc { [self stop]; }
@end
