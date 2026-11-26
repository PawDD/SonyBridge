#import <Foundation/Foundation.h>
#import "HeadphonesBridge.h"
#include <stdexcept>
#include <initializer_list>

@interface HeadphonesBridge (LifecycleTests)
- (void)connectDevice:(id)device completion:(void (^)(BOOL, NSString *))completion;
- (void)openDevice:(id)device completion:(void (^)(BOOL, NSString *))completion;
- (void)enqueueSessionWork:(dispatch_block_t)work;
@end

@interface LifecycleBridge : HeadphonesBridge
@property BOOL opened;
@property BOOL oldWorkFinished;
@end
@implementation LifecycleBridge
- (void)openDevice:(id)device completion:(void (^)(BOOL, NSString *))completion {
    if (!self.oldWorkFinished) throw std::runtime_error("new session opened before old work finished");
    self.opened = YES;
    completion(YES, nil);
}
@end

static void require(bool value, const char *message) {
    if (!value) throw std::runtime_error(message);
}

int main() {
    @autoreleasepool {
        {
            HeadphonesBridge *bridge = [HeadphonesBridge new];
            dispatch_queue_t queue = (dispatch_queue_t)[bridge valueForKey:@"cmdQueue"];
            dispatch_semaphore_t release = dispatch_semaphore_create(0);
            dispatch_async(queue, ^{ dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER); });
            __block BOOL staleCommandRan = NO;
            [bridge enqueueSessionWork:^{ staleCommandRan = YES; }];
            [bridge disconnect];
            dispatch_semaphore_signal(release);
            dispatch_sync(queue, ^{});
            require(!staleCommandRan, "disconnected session replayed queued work");
            __block BOOL freshCommandRan = NO;
            [bridge enqueueSessionWork:^{ freshCommandRan = YES; }];
            dispatch_sync(queue, ^{});
            require(freshCommandRan, "disconnect permanently disabled fresh session work");
        }
        for (bool cancel : {false, true}) {
            LifecycleBridge *bridge = [LifecycleBridge new];
            // Queue old-session work without opening any real Bluetooth channel.
            dispatch_queue_t queue = (dispatch_queue_t)[bridge valueForKey:@"cmdQueue"];
            dispatch_semaphore_t started = dispatch_semaphore_create(0);
            dispatch_semaphore_t release = dispatch_semaphore_create(0);
            dispatch_async(queue, ^{
                dispatch_semaphore_signal(started);
                dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER);
                bridge.oldWorkFinished = YES;
            });
            require(dispatch_semaphore_wait(started, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0,
                    "old-session work did not start");
            __block BOOL completed = NO;
            __block BOOL success = NO;
            [bridge connectDevice:nil completion:^(BOOL ok, NSString *error) {
                completed = YES;
                success = ok;
            }];
            require(!bridge.opened, "manual Connect bypassed the old-session queue");
            if (cancel) [bridge disconnect];
            dispatch_semaphore_signal(release);
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
            while (!completed && deadline.timeIntervalSinceNow > 0) {
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            }
            require(completed, "connection completion was not delivered");
            require(success == !cancel, "cancelled connection was reopened");
            require(bridge.opened == !cancel, "unexpected replacement-session open");
        }
        puts("macOS connection lifecycle tests passed");
    }
}
