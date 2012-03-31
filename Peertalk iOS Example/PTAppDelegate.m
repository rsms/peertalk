#import "PTAppDelegate.h"

@interface PTAppDelegate ()
@end

@implementation PTAppDelegate

@synthesize window = window_;


- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  [[UIApplication sharedApplication] setStatusBarStyle:UIStatusBarStyleBlackOpaque animated:NO];
  return YES;
}


//- (void)applicationWillTerminate:(UIApplication *)application {
//}


@end
