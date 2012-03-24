#import "RIOFrameChannel.h"

#include <sys/socket.h>
#include <sys/ioctl.h>
#include <sys/un.h>
#include <err.h>
#include <fcntl.h>

@implementation RIOData

@synthesize dispatchData = dispatchData_;
@synthesize data = data_;
@synthesize length = length_;

- (id)initWithMappedDispatchData:(dispatch_data_t)mappedContiguousData data:(void*)data length:(size_t)length {
  if (!(self = [super init])) return nil;
  dispatchData_ = mappedContiguousData;
  if (dispatchData_) dispatch_retain(dispatchData_);
  data_ = data;
  length_ = length;
  return self;
}

- (void)dealloc {
  if (dispatchData_) dispatch_release(dispatchData_);
  data_ = NULL;
  length_ = 0;
}

@end

@interface RIOFrameChannel () {
  dispatch_io_t readingFromDispatchChannel_;
  id<RIOFrameChannelDelegate> delegate_;
}
- (id)initWithProtocol:(RIOFrameProtocol*)protocol delegate:(id<RIOFrameChannelDelegate>)delegate;
@end

@implementation RIOFrameChannel

@synthesize protocol = protocol_;

@synthesize shouldAcceptFrame = shouldAcceptFrame_;
@synthesize onFrame = onFrame_;
@synthesize onEnd = onEnd_;


+ (RIOFrameChannel*)channelWithDelegate:(id<RIOFrameChannelDelegate>)delegate {
  return [[RIOFrameChannel alloc] initWithProtocol:[RIOFrameProtocol sharedProtocolForQueue:dispatch_get_current_queue()] delegate:delegate];
}


- (id)initWithProtocol:(RIOFrameProtocol*)protocol delegate:(id<RIOFrameChannelDelegate>)delegate {
  if (!(self = [super init])) return nil;
  protocol_ = protocol;
  self.delegate = delegate;
  return self;
}


- (id)initWithProtocol:(RIOFrameProtocol*)protocol {
  if (!(self = [super init])) return nil;
  protocol_ = protocol;
  return self;
}


- (id)init {
  return [self initWithProtocol:[RIOFrameProtocol sharedProtocolForQueue:dispatch_get_current_queue()]];
}


- (void)dealloc {
  if (readingFromDispatchChannel_) dispatch_release(readingFromDispatchChannel_);
}


- (dispatch_io_t)readingFromDispatchChannel {
  return readingFromDispatchChannel_;
}


- (void)setReadingFromDispatchChannel:(dispatch_io_t)channel {
  dispatch_io_t prevChannel = readingFromDispatchChannel_;
  readingFromDispatchChannel_ = channel;
  if (readingFromDispatchChannel_) dispatch_retain(readingFromDispatchChannel_);
  if (prevChannel) dispatch_release(prevChannel);
}


- (id<RIOFrameChannelDelegate>)delegate {
  return delegate_;
}


- (void)setDelegate:(id<RIOFrameChannelDelegate>)delegate {
  delegate_ = delegate;
  
  if (delegate_) {
    self.onFrame = ^(RIOFrameChannel *channel, uint32_t type, uint32_t tag, RIOData *payload) {
      [delegate ioFrameChannel:channel didReceiveFrameOfType:type tag:tag payload:payload];
    };
  } else {
    self.onFrame = nil;
  }
  
  if (delegate_ && [delegate respondsToSelector:@selector(ioFrameChannel:shouldAcceptFrameOfType:tag:payloadSize:)]) {
    self.shouldAcceptFrame = ^BOOL(RIOFrameChannel *channel, uint32_t type, uint32_t tag, uint32_t payloadSize) {
      return [delegate ioFrameChannel:channel shouldAcceptFrameOfType:type tag:tag payloadSize:payloadSize];
    };
  } else {
    self.shouldAcceptFrame = nil;
  }
  
  if (delegate_ && [delegate respondsToSelector:@selector(ioFrameChannel:didEndWithError:)]) {
    self.onEnd = ^(RIOFrameChannel *channel, NSError *error) {
      [delegate ioFrameChannel:channel didEndWithError:error];
    };
  } else {
    self.onEnd = nil;
  }
}


//- (void)setFileDescriptor:(dispatch_fd_t)fd {
//  [self setReadingFromDispatchChannel:dispatch_io_create(DISPATCH_IO_STREAM, fd, protocol_.queue, ^(int error) {
//    close(fd);
//  })];
//}


#pragma mark - Connecting


- (void)connectToPort:(int)port overUSBHub:(RUSBHub*)usbHub deviceID:(NSNumber*)deviceID callback:(void(^)(NSError *error))callback {
  assert(protocol_ != NULL);
  [usbHub connectToDevice:deviceID port:port onStart:^(NSError *error, dispatch_io_t dispatchChannel) {
    if (!error) {
      [self startReadingFromChannel:dispatchChannel];
    }
    if (callback) callback(error);
  } onEnd:^(NSError *error) {
    if (self.onEnd) self.onEnd(self, error);
  }];
}


- (void)connectToPort:(in_port_t)port atIPv4Address:(in_addr_t)address callback:(void(^)(NSError *error))callback {
  assert(protocol_ != NULL);
  int error = 0;
  
  // Create socket
  dispatch_fd_t fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd == -1) {
    perror("socket");
    error = errno;
    if (callback) callback([[NSError alloc] initWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
    return;
  }
  
  // Connect socket
  struct sockaddr_in addr;
  bzero((char *)&addr, sizeof(addr));
  
  addr.sin_family = AF_INET;
  addr.sin_port = htons(port);
  //addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  //addr.sin_addr.s_addr = htonl(INADDR_ANY);
  addr.sin_addr.s_addr = htonl(address);
  
  // prevent SIGPIPE
	int on = 1;
	setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
  
  // int socket, const struct sockaddr *address, socklen_t address_len
  if (connect(fd, (const struct sockaddr *)&addr, sizeof(addr)) == -1) {
    perror("connect");
    error = errno;
    close(fd);
    if (callback) callback([[NSError alloc] initWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
    return;
  }
  
  dispatch_io_t dispatchChannel = dispatch_io_create(DISPATCH_IO_STREAM, fd, protocol_.queue, ^(int error) {
    close(fd);
    if (self.onEnd) self.onEnd(self, error == 0 ? nil : [[NSError alloc] initWithDomain:NSPOSIXErrorDomain code:error userInfo:nil]);
  });
  
  if (!dispatchChannel) {
    close(fd);
    if (callback) callback([[NSError alloc] initWithDomain:@"RIOError" code:0 userInfo:nil]);
    return;
  }
  
  // Success
  [self startReadingFromChannel:dispatchChannel];
  if (callback) callback(nil);
}


#pragma mark - Closing the channel


- (void)close {
  if (readingFromDispatchChannel_) {
    dispatch_io_close(readingFromDispatchChannel_, DISPATCH_IO_STOP);
    [self setReadingFromDispatchChannel:NULL];
  }
}


- (void)cancel {
  if (readingFromDispatchChannel_) {
    dispatch_io_close(readingFromDispatchChannel_, 0);
    [self setReadingFromDispatchChannel:NULL];
  }
}


#pragma mark - Reading


- (void)startReadingFromChannel:(dispatch_io_t)channel {
  [self close];
  
  // helper
  BOOL(^handleError)(NSError*,BOOL) = ^BOOL(NSError *error, BOOL isEOS) {
    if (error) {
      NSLog(@"Error while communicating: %@", error);
      [self close];
      return YES;
    } else if (isEOS) {
      [self cancel];
      return YES;
    }
    return NO;
  };
  
  [self setReadingFromDispatchChannel:channel];
  
  [protocol_ readFramesOverChannel:channel onFrame:^(NSError *error, uint32_t type, uint32_t tag, uint32_t payloadSize, dispatch_block_t resumeReadingFrames) {
    if (handleError(error, type == RIOFrameTypeEndOfStream)) {
      return;
    }
    
    BOOL accepted = (channel == readingFromDispatchChannel_) && (shouldAcceptFrame_ ? shouldAcceptFrame_(self, type, tag, payloadSize) : YES);
    
    if (!payloadSize) {
      if (accepted && onFrame_) {
        onFrame_(self, type, tag, nil);
      } else {
        // simply ignore the frame
      }
    } else {
      // has payload
      if (!accepted) {
        // Read and discard payload, ignoring frame
        [protocol_ readAndDiscardDataOfSize:payloadSize overChannel:channel callback:^(NSError *error, BOOL endOfStream) {
          if (!handleError(error, endOfStream)) {
            resumeReadingFrames();
          }
        }];
      } else {
        [protocol_ readPayloadOfSize:payloadSize overChannel:channel callback:^(NSError *error, dispatch_data_t contiguousData, const uint8_t *buffer, size_t bufferSize) {
          if (handleError(error, bufferSize == 0)) {
            return;
          }
          
          if (onFrame_) {
            RIOData *payload = [[RIOData alloc] initWithMappedDispatchData:contiguousData data:(void*)buffer length:bufferSize];
            onFrame_(self, type, tag, payload);
          }
          
          resumeReadingFrames();
        }];
      }
    }
  }];
}


#pragma mark - Sending

- (void)sendFrameOfType:(uint32_t)frameType tag:(uint32_t)tag withPayload:(dispatch_data_t)payload callback:(void(^)(NSError *error))callback {
  [protocol_ sendFrameOfType:frameType tag:tag withPayload:payload overChannel:readingFromDispatchChannel_ callback:callback];
}


@end


@implementation RIODeviceFrameChannel
@synthesize deviceID = deviceID_;
@end
