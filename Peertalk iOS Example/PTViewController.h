#import <UIKit/UIKit.h>
#import "PTChannel.h"

@interface PTViewController : UIViewController <PTChannelDelegate, UITextFieldDelegate>

@property (weak) IBOutlet UITextView *outputTextView;
@property (weak) IBOutlet UITextField *inputTextField;

- (void)sendMessage:(NSString*)message;

@end
