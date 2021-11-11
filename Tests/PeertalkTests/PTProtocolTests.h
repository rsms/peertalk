#import <XCTest/XCTest.h>
#include <dispatch/dispatch.h>
#import "PTProtocol.h"
#import "PTPrivate.h"

@interface PTProtocolTests : XCTestCase {
  dispatch_fd_t socket_[2];
  dispatch_queue_t queue_[2];
  dispatch_io_t channel_[2];
  PTProtocol *protocol_[2];
}

@end
