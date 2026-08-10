/*
 Spinner — an animated single-line status indicator for long-running terminal
 phases. Renders only when stdout is a TTY; otherwise every method is a no-op
 (printLine: falls back to plain printf) so piped/logged output is unchanged.
*/

#import <Foundation/Foundation.h>

@interface Spinner : NSObject

// Starts the spinner with the given status label (no-op if already running;
// the label is updated either way).
- (void)start:(NSString *)theLabel;

// Updates the status label shown next to the spinner. Thread-safe.
- (void)setLabel:(NSString *)theLabel;

// Stops the spinner and clears its line.
- (void)stop;

// Prints a permanent line of output without corrupting the spinner line;
// the spinner redraws beneath it on its next tick.
- (void)printLine:(NSString *)theLine;
@end
