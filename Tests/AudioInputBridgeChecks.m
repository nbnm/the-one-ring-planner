#import "RPAudioInput.h"

// Dynamic Objective-C stand-ins exercise AVAudioEngine's exception boundary
// without requesting microphone permission or opening any real audio device.
@interface RPTestInput : NSObject
@property(nonatomic, strong) AVAudioFormat *hardwareFormat;
@property(nonatomic, strong) AVAudioFormat *requestedFormat;
@property(nonatomic) BOOL failInstall;
@property(nonatomic) BOOL failRemove;
@property(nonatomic) NSUInteger removals;
@end
@implementation RPTestInput
- (AVAudioFormat *)inputFormatForBus:(AVAudioNodeBus)bus { return self.hardwareFormat; }
- (AVAudioFormat *)outputFormatForBus:(AVAudioNodeBus)bus {
    return [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:1];
}
- (void)installTapOnBus:(AVAudioNodeBus)bus bufferSize:(AVAudioFrameCount)size format:(AVAudioFormat *)format block:(AVAudioNodeTapBlock)block {
    self.requestedFormat = format;
    if (self.failInstall) [NSException raise:@"AudioRouteChanged" format:@"Failed to create tap due to format mismatch"];
}
- (void)removeTapOnBus:(AVAudioNodeBus)bus {
    self.removals++;
    if (self.failRemove) [NSException raise:@"DeviceUnavailable" format:@"Device disconnected"];
}
@end

@interface RPTestEngine : NSObject
@property(nonatomic, strong) RPTestInput *inputNode;
@property(nonatomic) BOOL failPrepare;
@property(nonatomic) BOOL failStart;
@property(nonatomic) BOOL failStop;
@property(nonatomic) NSUInteger stops;
@property(nonatomic) NSUInteger starts;
@property(nonatomic, getter=isRunning) BOOL running;
@end
@implementation RPTestEngine
- (instancetype)init {
    if ((self = [super init])) {
        _inputNode = [[RPTestInput alloc] init];
        _inputNode.hardwareFormat = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:16000 channels:1];
    }
    return self;
}
- (void)prepare { if (self.failPrepare) [NSException raise:@"PrepareFailed" format:@"Route changed during preparation"]; }
- (BOOL)startAndReturnError:(NSError **)error {
    self.starts++;
    if (!self.failStart) { self.running = YES; return YES; }
    if (error) *error = [NSError errorWithDomain:@"FakeAudioDevice" code:42 userInfo:nil];
    return NO;
}
- (void)stop {
    self.stops++;
    self.running = NO;
    if (self.failStop) [NSException raise:@"StopFailed" format:@"Device unavailable during stop"];
}
@end

static NSUInteger failures = 0;
static void check(BOOL value, NSString *message) {
    printf("%s %s\n", value ? "PASS" : "FAIL", message.UTF8String);
    if (!value) failures++;
}
static RPAudioInput *capture(RPTestEngine *engine) { return [[RPAudioInput alloc] initWithEngine:(AVAudioEngine *)engine]; }
static BOOL start(RPAudioInput *input, NSError **error) {
    return [input startWithBufferSize:4096 handler:^(AVAudioPCMBuffer *buffer, AVAudioTime *time) {} error:error];
}

int main(void) {
    @autoreleasepool {
        RPTestEngine *engine = [[RPTestEngine alloc] init];
        RPAudioInput *input = capture(engine);
        NSError *error = nil;
        check(start(input, &error) && engine.inputNode.requestedFormat.sampleRate == 16000,
              @"Microphone tap uses native 16 kHz input despite cached 44.1 kHz output");
        check(!start(input, &error) && error.code == 2 && engine.stops == 0,
              @"Duplicate start returns an error without stopping the active microphone");
        [input stop]; [input stop];
        check(engine.inputNode.removals == 1 && engine.stops == 1, @"Stop is idempotent and releases the tap once");

        engine = [[RPTestEngine alloc] init]; engine.inputNode.failInstall = YES; input = capture(engine); error = nil;
        check(!start(input, &error) && [error.domain isEqualToString:@"com.t1a.planner.audio-input"] && engine.stops == 1,
              @"Native format exceptions become recoverable errors before reaching Swift concurrency");

        engine = [[RPTestEngine alloc] init]; engine.failPrepare = YES; input = capture(engine); error = nil;
        check(!start(input, &error) && error != nil && engine.inputNode.removals == 1 && engine.stops == 1,
              @"Preparation exception cleans up an installed tap and engine");

        engine = [[RPTestEngine alloc] init]; engine.failStart = YES; input = capture(engine); error = nil;
        check(!start(input, &error) && [error.domain isEqualToString:@"FakeAudioDevice"] && engine.inputNode.removals == 1,
              @"Ordinary engine errors preserve their diagnostic and clean up the tap");

        engine = [[RPTestEngine alloc] init]; engine.inputNode.hardwareFormat = nil; input = capture(engine); error = nil;
        check(!start(input, &error) && error.code == 3 && engine.inputNode.requestedFormat == nil,
              @"Missing input format fails without installing an invalid tap");

        engine = [[RPTestEngine alloc] init]; input = capture(engine); error = nil;
        BOOL began = start(input, &error);
        engine.failStop = YES; engine.inputNode.failRemove = YES;
        [input stop];
        check(began && engine.stops == 1 && engine.inputNode.removals == 1,
              @"Device-disconnect cleanup exceptions cannot escape into Swift");

        engine = [[RPTestEngine alloc] init]; input = capture(engine); error = nil;
        began = start(input, &error); engine.running = NO;
        engine.inputNode.hardwareFormat = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:1];
        [[NSNotificationCenter defaultCenter] postNotificationName:AVAudioEngineConfigurationChangeNotification object:engine];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
        check(began && engine.starts == 2 && engine.inputNode.requestedFormat.sampleRate == 48000,
              @"A route change restarts a stopped engine with the new hardware format");
        [input stop];

        engine = [[RPTestEngine alloc] init]; input = capture(engine); error = nil;
        began = start(input, &error); engine.running = NO;
        [[NSNotificationCenter defaultCenter] postNotificationName:AVAudioEngineConfigurationChangeNotification object:engine];
        [input stop];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
        check(began && engine.starts == 1, @"Stopping cancels pending route recovery and cannot reopen the microphone");

        engine = [[RPTestEngine alloc] init]; input = capture(engine); error = nil;
        __block NSUInteger reported = 0;
        input.onFailure = ^(NSError *failure) { if (failure) reported++; };
        began = start(input, &error); engine.running = NO; engine.failPrepare = YES;
        [[NSNotificationCenter defaultCenter] postNotificationName:AVAudioEngineConfigurationChangeNotification object:engine];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
        check(began && reported == 1 && engine.stops >= 1, @"Failed route recovery reports one recoverable error and releases capture");
        printf("Audio input boundary: %lu checks, %lu failures\n", (unsigned long)11, (unsigned long)failures);
    }
    return failures ? 1 : 0;
}
