#import "Spinner.h"
#include <unistd.h>

#define SPINNER_TICK_INTERVAL (0.2)


@interface Spinner() {
    BOOL _enabled;
    BOOL _running;
    NSString *_label;
    NSThread *_thread;
    NSUInteger _frameIndex;
}
@end


@implementation Spinner

- (instancetype)init {
    if (self = [super init]) {
        _enabled = isatty(STDOUT_FILENO) ? YES : NO;
    }
    return self;
}

- (void)start:(NSString *)theLabel {
    @synchronized(self) {
        _label = [theLabel copy];
        if (!_enabled || _running) {
            return;
        }
        _running = YES;
        _thread = [[NSThread alloc] initWithTarget:self selector:@selector(run) object:nil];
        [_thread start];
    }
}

- (void)setLabel:(NSString *)theLabel {
    @synchronized(self) {
        _label = [theLabel copy];
    }
}

- (void)stop {
    NSThread *thread = nil;
    @synchronized(self) {
        if (!_running) {
            return;
        }
        _running = NO;
        thread = _thread;
        _thread = nil;
    }
    while (thread != nil && ![thread isFinished]) {
        [NSThread sleepForTimeInterval:0.01];
    }
    @synchronized(self) {
        fprintf(stdout, "\r\033[K");
        fflush(stdout);
    }
}

- (void)printLine:(NSString *)theLine {
    @synchronized(self) {
        if (_enabled && _running) {
            fprintf(stdout, "\r\033[K%s\n", [theLine UTF8String]);
        } else {
            fprintf(stdout, "%s\n", [theLine UTF8String]);
        }
        fflush(stdout);
    }
}


#pragma mark internal

- (void)run {
    NSArray *frames = [NSArray arrayWithObjects:@"⠋", @"⠙", @"⠹", @"⠸", @"⠼", @"⠴", @"⠦", @"⠧", @"⠇", @"⠏", nil];
    for (;;) {
        NSString *label = nil;
        @synchronized(self) {
            if (!_running) {
                return;
            }
            label = _label;
            NSString *frame = [frames objectAtIndex:(_frameIndex++ % [frames count])];
            fprintf(stdout, "\r\033[K%s %s", [frame UTF8String], [label UTF8String]);
            fflush(stdout);
        }
        [NSThread sleepForTimeInterval:SPINNER_TICK_INTERVAL];
    }
}
@end
