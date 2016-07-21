#import <Cocoa/Cocoa.h>
#import "PTChannel.h"

static const NSTimeInterval PTAppReconnectDelay = 1.0;

@interface PTAppDelegate : NSObject <NSApplicationDelegate, PTChannelDelegate>

@property (assign) IBOutlet NSWindow *window;
@property (assign) IBOutlet NSTextField *inputTextField;
@property (assign) IBOutlet NSTextView *outputTextView;

- (IBAction)sendMessage:(id)sender;

@end
