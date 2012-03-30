#import "PTChannel.h"

#include <sys/ioctl.h>
#include <sys/un.h>
#include <err.h>
#include <fcntl.h>

@implementation PTData

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

#define kConnStateNone 0
#define kConnStateConnecting 1
#define kConnStateConnected 2
#define kConnStateListening 3


@interface PTChannel () {
  union dispatchObj {
    dispatch_io_t channel;
    dispatch_source_t source;
  } dispatchObj_;
  id<PTChannelDelegate> delegate_;
  char connState_;
}
- (id)initWithProtocol:(PTProtocol*)protocol delegate:(id<PTChannelDelegate>)delegate;
- (BOOL)acceptIncomingConnection:(dispatch_fd_t)serverSocketFD;
@end

@implementation PTChannel

@synthesize protocol = protocol_;

@synthesize shouldAcceptFrame = shouldAcceptFrame_;
@synthesize onFrame = onFrame_;
@synthesize onEnd = onEnd_;
@synthesize onAccept = onAccept_;


+ (PTChannel*)channelWithDelegate:(id<PTChannelDelegate>)delegate {
  return [[PTChannel alloc] initWithProtocol:[PTProtocol sharedProtocolForQueue:dispatch_get_current_queue()] delegate:delegate];
}


- (id)initWithProtocol:(PTProtocol*)protocol delegate:(id<PTChannelDelegate>)delegate {
  if (!(self = [super init])) return nil;
  protocol_ = protocol;
  self.delegate = delegate;
  return self;
}


- (id)initWithProtocol:(PTProtocol*)protocol {
  if (!(self = [super init])) return nil;
  protocol_ = protocol;
  return self;
}


- (id)init {
  return [self initWithProtocol:[PTProtocol sharedProtocolForQueue:dispatch_get_current_queue()]];
}


- (void)dealloc {
  if (dispatchObj_.channel) dispatch_release(dispatchObj_.channel);
  else if (dispatchObj_.source) dispatch_release(dispatchObj_.source);
}


- (BOOL)isConnected {
  return connState_ == kConnStateConnecting || connState_ == kConnStateConnected;
}


- (BOOL)isListening {
  return connState_ == kConnStateListening;
}


- (void)setConnState:(char)connState {
  connState_ = connState;
}


- (void)setDispatchChannel:(dispatch_io_t)channel {
  assert(connState_ == kConnStateConnecting || connState_ == kConnStateConnected || connState_ == kConnStateNone);
  dispatch_io_t prevChannel = dispatchObj_.channel;
  if (prevChannel != channel) {
    dispatchObj_.channel = channel;
    if (dispatchObj_.channel) dispatch_retain(dispatchObj_.channel);
    if (prevChannel) dispatch_release(prevChannel);
    if (!dispatchObj_.channel && !dispatchObj_.source) {
      connState_ = kConnStateNone;
    }
  }
}


- (void)setDispatchSource:(dispatch_source_t)source {
  assert(connState_ == kConnStateListening || connState_ == kConnStateNone);
  dispatch_source_t prevSource = dispatchObj_.source;
  if (prevSource != source) {
    dispatchObj_.source = source;
    if (dispatchObj_.source) dispatch_retain(dispatchObj_.source);
    if (prevSource) dispatch_release(prevSource);
    if (!dispatchObj_.channel && !dispatchObj_.source) {
      connState_ = kConnStateNone;
    }
  }
}


- (id<PTChannelDelegate>)delegate {
  return delegate_;
}


- (void)setDelegate:(id<PTChannelDelegate>)delegate {
  delegate_ = delegate;
  
  if (delegate_) {
    self.onFrame = ^(PTChannel *channel, uint32_t type, uint32_t tag, PTData *payload) {
      [delegate ioFrameChannel:channel didReceiveFrameOfType:type tag:tag payload:payload];
    };
  } else {
    self.onFrame = nil;
  }
  
  if (delegate_ && [delegate respondsToSelector:@selector(ioFrameChannel:shouldAcceptFrameOfType:tag:payloadSize:)]) {
    self.shouldAcceptFrame = ^BOOL(PTChannel *channel, uint32_t type, uint32_t tag, uint32_t payloadSize) {
      return [delegate ioFrameChannel:channel shouldAcceptFrameOfType:type tag:tag payloadSize:payloadSize];
    };
  } else {
    self.shouldAcceptFrame = nil;
  }
  
  if (delegate_ && [delegate respondsToSelector:@selector(ioFrameChannel:didEndWithError:)]) {
    self.onEnd = ^(PTChannel *channel, NSError *error) {
      [delegate ioFrameChannel:channel didEndWithError:error];
    };
  } else {
    self.onEnd = nil;
  }
  
  if (delegate_ && [delegate respondsToSelector:@selector(ioFrameChannel:didAcceptConnection:)]) {
    self.onAccept = ^(PTChannel *serverChannel, PTChannel *channel) {
      [delegate ioFrameChannel:serverChannel didAcceptConnection:channel];
    };
  } else {
    self.onAccept = nil;
  }
}


//- (void)setFileDescriptor:(dispatch_fd_t)fd {
//  [self setDispatchChannel:dispatch_io_create(DISPATCH_IO_STREAM, fd, protocol_.queue, ^(int error) {
//    close(fd);
//  })];
//}


#pragma mark - Connecting


- (void)connectToPort:(int)port overUSBHub:(PTUSBHub*)usbHub deviceID:(NSNumber*)deviceID callback:(void(^)(NSError *error))callback {
  assert(protocol_ != NULL);
  if (connState_ != kConnStateNone) {
    if (callback) callback([NSError errorWithDomain:NSPOSIXErrorDomain code:EPERM userInfo:nil]);
    return;
  }
  connState_ = kConnStateConnecting;
  [usbHub connectToDevice:deviceID port:port onStart:^(NSError *err, dispatch_io_t dispatchChannel) {
    NSError *error = err;
    if (!error) {
      [self startReadingFromConnectedChannel:dispatchChannel error:&error];
    } else {
      connState_ = kConnStateNone;
    }
    if (callback) callback(error);
  } onEnd:^(NSError *error) {
    if (self.onEnd) self.onEnd(self, error);
  }];
}


- (void)connectToPort:(in_port_t)port IPv4Address:(in_addr_t)address callback:(void(^)(NSError *error))callback {
  assert(protocol_ != NULL);
  if (connState_ != kConnStateNone) {
    if (callback) callback([NSError errorWithDomain:NSPOSIXErrorDomain code:EPERM userInfo:nil]);
    return;
  }
  connState_ = kConnStateConnecting;
  
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
    if (callback) callback([[NSError alloc] initWithDomain:@"PTError" code:0 userInfo:nil]);
    return;
  }
  
  // Success
  NSError *err = nil;
  [self startReadingFromConnectedChannel:dispatchChannel error:&err];
  if (callback) callback(err);
}


#pragma mark - Listening and serving


- (void)listenOnPort:(in_port_t)port IPv4Address:(in_addr_t)address callback:(void(^)(NSError *error))callback {
  if (connState_ != kConnStateNone) {
    if (callback) callback([NSError errorWithDomain:NSPOSIXErrorDomain code:EPERM userInfo:nil]);
    return;
  }
  
  assert(dispatchObj_.source == nil);
  
  // Create socket
  dispatch_fd_t fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd == -1) {
    if (callback) callback([NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
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
  
  socklen_t socklen = sizeof(addr);
  
  int on = 1;
  
  if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on)) == -1) {
    close(fd);
    if (callback) callback([NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
    return;
  }
  
  if (fcntl(fd, F_SETFL, O_NONBLOCK) == -1) {
    close(fd);
    if (callback) callback([NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
    return;
  }
  
  if (bind(fd, (struct sockaddr*)&addr, socklen) != 0) {
    close(fd);
    if (callback) callback([NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
    return;
  }
  
  if (listen(fd, 512) != 0) {
    close(fd);
    if (callback) callback([NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]);
    return;
  }
  
  [self setDispatchSource:dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, protocol_.queue)];
  
  dispatch_source_set_event_handler(dispatchObj_.source, ^{
    unsigned long nconns = dispatch_source_get_data(dispatchObj_.source);
    while ([self acceptIncomingConnection:fd] && --nconns);
  });
  
  dispatch_source_set_cancel_handler(dispatchObj_.source, ^{
    // Captures *self*, effectively holding a reference to *self* until cancelled.
    dispatchObj_.source = nil;
    close(fd);
    if (self.onEnd) self.onEnd(self, nil);
  });
  
  dispatch_resume(dispatchObj_.source);
  //NSLog(@"%@ opened on fd #%d", self, fd);
  
  connState_ = kConnStateListening;
  if (callback) callback(nil);
}


- (BOOL)acceptIncomingConnection:(dispatch_fd_t)serverSocketFD {
  struct sockaddr_in addr;
  socklen_t addrLen = sizeof(addr);
  dispatch_fd_t clientSocketFD = accept(serverSocketFD, (struct sockaddr*)&addr, &addrLen);
  
  if (clientSocketFD == -1) {
    perror("accept()");
    return NO;
  }
  
  // prevent SIGPIPE
	int on = 1;
	setsockopt(clientSocketFD, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
  
  if (fcntl(clientSocketFD, F_SETFL, O_NONBLOCK) == -1) {
    perror("fcntl(.. O_NONBLOCK)");
    close(clientSocketFD);
    return NO;
  }
  
  if (delegate_ && self.onAccept) {
    PTChannel *channel = [[PTChannel alloc] initWithProtocol:protocol_ delegate:delegate_];
    dispatch_io_t dispatchChannel = dispatch_io_create(DISPATCH_IO_STREAM, clientSocketFD, protocol_.queue, ^(int error) {
      // Important note: This block captures *self*, thus a reference is held to
      // *self* until the fd is truly closed.
      close(clientSocketFD);
      if (channel.onEnd) channel.onEnd(channel, error == 0 ? nil : [[NSError alloc] initWithDomain:NSPOSIXErrorDomain code:error userInfo:nil]);
    });
    
    [channel setConnState:kConnStateConnected];
    [channel setDispatchChannel:dispatchChannel];
    
    self.onAccept(self, channel);
    
    NSError *err = nil;
    if (![channel startReadingFromConnectedChannel:dispatchChannel error:&err]) {
      NSLog(@"startReadingFromConnectedChannel failed in accept: %@", err);
    }
  } else {
    close(clientSocketFD);
  }
  return YES;
}


#pragma mark - Closing the channel


- (void)close {
  if (connState_ == kConnStateConnecting && dispatchObj_.channel) {
    dispatch_io_close(dispatchObj_.channel, DISPATCH_IO_STOP);
    [self setDispatchChannel:NULL];
  } else if (connState_ == kConnStateListening && dispatchObj_.source) {
    dispatch_source_cancel(dispatchObj_.source);
  }
}


- (void)cancel {
  if (connState_ == kConnStateConnecting && dispatchObj_.channel) {
    dispatch_io_close(dispatchObj_.channel, 0);
    [self setDispatchChannel:NULL];
  } else if (connState_ == kConnStateListening && dispatchObj_.source) {
    dispatch_source_cancel(dispatchObj_.source);
  }
}


#pragma mark - Reading


- (BOOL)startReadingFromConnectedChannel:(dispatch_io_t)channel error:(__autoreleasing NSError**)error {
  if (connState_ != kConnStateNone && connState_ != kConnStateConnecting && connState_ != kConnStateConnected) {
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EPERM userInfo:nil];
    return NO;
  }
  
  if (dispatchObj_.channel != channel) {
    [self close];
    [self setDispatchChannel:channel];
  }
  
  connState_ = kConnStateConnected;
  
  // helper
  BOOL(^handleError)(NSError*,BOOL) = ^BOOL(NSError *error, BOOL isEOS) {
    if (error) {
      //NSLog(@"Error while communicating: %@", error);
      [self close];
      return YES;
    } else if (isEOS) {
      [self cancel];
      return YES;
    }
    return NO;
  };
  
  [protocol_ readFramesOverChannel:channel onFrame:^(NSError *error, uint32_t type, uint32_t tag, uint32_t payloadSize, dispatch_block_t resumeReadingFrames) {
    if (handleError(error, type == PTFrameTypeEndOfStream)) {
      return;
    }
    
    BOOL accepted = (channel == dispatchObj_.channel) && (shouldAcceptFrame_ ? shouldAcceptFrame_(self, type, tag, payloadSize) : YES);
    
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
            PTData *payload = [[PTData alloc] initWithMappedDispatchData:contiguousData data:(void*)buffer length:bufferSize];
            onFrame_(self, type, tag, payload);
          }
          
          resumeReadingFrames();
        }];
      }
    }
  }];
  
  return YES;
}


#pragma mark - Sending

- (void)sendFrameOfType:(uint32_t)frameType tag:(uint32_t)tag withPayload:(dispatch_data_t)payload callback:(void(^)(NSError *error))callback {
  if (connState_ == kConnStateConnecting || connState_ == kConnStateConnected) {
    [protocol_ sendFrameOfType:frameType tag:tag withPayload:payload overChannel:dispatchObj_.channel callback:callback];
  } else if (callback) {
    callback([NSError errorWithDomain:NSPOSIXErrorDomain code:EPERM userInfo:nil]);
  }
}

#pragma mark - NSObject

- (NSString*)description {
  return [NSString stringWithFormat:@"<PTChannel: %p (%@) %@>", self, (  connState_ == kConnStateConnecting ? @"connecting"
                                                                       : connState_ == kConnStateConnected  ? @"connected" 
                                                                       : connState_ == kConnStateListening  ? @"listening"
                                                                       :                                      @"closed"), protocol_];
}


@end


@implementation PTDeviceChannel
@synthesize deviceID = deviceID_;
@end
