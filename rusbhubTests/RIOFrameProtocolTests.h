#import <SenTestingKit/SenTestingKit.h>
#include <dispatch/dispatch.h>
#import "RIOFrameProtocol.h"

@interface RIOFrameProtocolTests : SenTestCase {
  dispatch_fd_t socket_[2];
  dispatch_queue_t queue_[2];
  dispatch_io_t channel_[2];
  RIOFrameProtocol *protocol_[2];
}

@end
