#import "PTProtocolTests.h"

#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <sys/un.h>
#include <err.h>

#define PTAssertNotNULL(x) do { if ((x) == NULL) XCTFail(@"%s == NULL", #x); } while(0)

static const uint32_t PTFrameTypeTestPing = UINT32_MAX - 1;
static const uint32_t PTFrameTypeTestPingReply = PTFrameTypeTestPing - 1;

@implementation PTProtocolTests

- (void)setUp {
  [super setUp];
  // Set-up code here.
  
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, socket_) == -1) {
    XCTFail(@"socketpair");
  }
  
  queue_[0] = dispatch_queue_create("PTProtocolTests.queue_[0]", DISPATCH_QUEUE_SERIAL);
  PTAssertNotNULL(queue_[0]);
  channel_[0] = dispatch_io_create(DISPATCH_IO_STREAM, socket_[0], queue_[0], ^(int error) {
    close(socket_[0]);
  });
  PTAssertNotNULL(channel_[0]);
  
  queue_[1] = dispatch_queue_create("PTProtocolTests.queue_[1]", DISPATCH_QUEUE_SERIAL);
  PTAssertNotNULL(queue_[1]);
  channel_[1] = dispatch_io_create(DISPATCH_IO_STREAM, socket_[1], queue_[1], ^(int error) {
    close(socket_[1]);
  });
  PTAssertNotNULL(channel_[1]);
  
  protocol_[0] = [[PTProtocol alloc] initWithDispatchQueue:queue_[0]];
  protocol_[1] = [[PTProtocol alloc] initWithDispatchQueue:queue_[1]];
}

- (void)tearDown {
  dispatch_io_close(channel_[0], DISPATCH_IO_STOP);
#if PT_DISPATCH_RETAIN_RELEASE
  dispatch_release(channel_[0]);
  dispatch_release(queue_[0]);
#endif
  
  dispatch_io_close(channel_[1], DISPATCH_IO_STOP);
#if PT_DISPATCH_RETAIN_RELEASE
  dispatch_release(channel_[1]);
  dispatch_release(queue_[1]);
#endif
  
  protocol_[0] = nil;
  protocol_[1] = nil;
  
  [super tearDown];
}

#pragma mark -
#pragma mark Helpers

- (void)write:(dispatch_data_t)data callback:(void(^)())callback {
  dispatch_io_write(channel_[0], 0, data, queue_[0], ^(bool done, dispatch_data_t data, int error) {
    if (done) {
      XCTAssertEqual(error, (int)0, @"Expected error == 0");
      callback();
    }
  });
}


- (void)readFromOffset:(off_t)offset length:(size_t)length callback:(void(^)(dispatch_data_t contiguousData, const uint8_t *data, size_t size))callback {
  __block dispatch_data_t allData = NULL;
  dispatch_io_read(channel_[1], offset, length, queue_[1], ^(bool done, dispatch_data_t data, int error) {
    //NSLog(@"dispatch_io_read: done=%d data=%p error=%d", done, data, error);
    if (data) {
      if (!allData) {
        allData = data;
#if PT_DISPATCH_RETAIN_RELEASE
        dispatch_retain(allData);
#endif
      } else {
#if PT_DISPATCH_RETAIN_RELEASE
        dispatch_data_t allDataPrev = allData;
#endif
        allData = dispatch_data_create_concat(allData, data);
#if PT_DISPATCH_RETAIN_RELEASE
        dispatch_release(allDataPrev);
#endif
      }
    }
    
    if (done) {
      XCTAssertEqual(error, (int)0, @"Expected error == 0");
      PTAssertNotNULL(allData);
      
      uint8_t *buffer = NULL;
      size_t bufferSize = 0;
      dispatch_data_t contiguousData = dispatch_data_create_map(allData, (const void **)&buffer, &bufferSize);
      PTAssertNotNULL(contiguousData);
      callback(contiguousData, buffer, bufferSize);
#if PT_DISPATCH_RETAIN_RELEASE
      dispatch_release(contiguousData);
#endif
    }
  });
}


- (void)waitForSemaphore:(dispatch_semaphore_t)sem milliseconds:(uint64_t)ms {
  if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, ms * 1000000LL)) != 0L) {
    XCTFail(@"Timeout in dispatch_semaphore_wait");
  }
}


- (void)readFrameWithClient:(int)clientIndex
          expectedFrameType:(uint32_t)expectedFrameType
           expectedFrameTag:(uint32_t)expectedFrameTag
        expectedPayloadSize:(uint32_t)expectedPayloadSize
                   callback:(void(^)(dispatch_data_t contiguousData, const uint8_t *buffer, size_t bufferSize))callback {
  [protocol_[clientIndex] readFrameOverChannel:channel_[clientIndex] callback:^(NSError *error, uint32_t receivedFrameType, uint32_t receivedFrameTag, uint32_t receivedPayloadSize) {
    if (error) XCTFail(@"readFrameOverChannel failed: %@", error);
    XCTAssertEqual(receivedFrameType, expectedFrameType);
    XCTAssertEqual(receivedFrameTag, expectedFrameTag);
    XCTAssertEqual(receivedPayloadSize, expectedPayloadSize);
    
    if (expectedPayloadSize != 0) {
      [protocol_[clientIndex] readPayloadOfSize:receivedPayloadSize overChannel:channel_[clientIndex] callback:^(NSError *error, dispatch_data_t contiguousData, const uint8_t *buffer, size_t bufferSize) {
        PTAssertNotNULL(contiguousData);
        PTAssertNotNULL(buffer);
        XCTAssertEqual((uint32_t)bufferSize, receivedPayloadSize);
        callback(contiguousData, buffer, bufferSize);
      }];
    } else {
      callback(nil, nil, 0);
    }
  }];
}


#pragma mark -
#pragma mark Test cases


- (void)test1_basic_data_exchange_to_verify_socket_pair {
  dispatch_semaphore_t sem1 = dispatch_semaphore_create(0);
  
  const char *testMessage = "HELLO";
  size_t testMessageSize = strlen(testMessage);
  
  // Write
  char *testMessageBytes = strdup(testMessage);
  dispatch_data_t data = dispatch_data_create((const void*)testMessageBytes, testMessageSize, queue_[0], ^{
    free(testMessageBytes);
  });
  [self write:data callback:^{}];
  
  // Read
  [self readFromOffset:0 length:testMessageSize callback:^(dispatch_data_t contiguousData, const uint8_t *data, size_t size) {
    if (memcmp((const void *)testMessage, (const void *)data, size) != 0) {
      XCTFail(@"Received data differs from sent data");
    }
    dispatch_semaphore_signal(sem1);
  }];
  
  [self waitForSemaphore:sem1 milliseconds:1000];
}


- (void)test2_protocol_transmit_frame {
  dispatch_semaphore_t sem1 = dispatch_semaphore_create(0);

  uint32_t frameTag = PTFrameNoTag;
  uint32_t payloadSize = 0;

  [protocol_[0] sendFrameOfType:PTFrameTypeTestPing tag:frameTag withPayload:nil overChannel:channel_[0] callback:^(NSError *error) {
    if (error) XCTFail(@"sendFrameOfType failed: %@", error);
  }];

  [protocol_[1] readFrameOverChannel:channel_[1] callback:^(NSError *error, uint32_t receivedFrameType, uint32_t receivedFrameTag, uint32_t receivedPayloadSize) {
    if (error) XCTFail(@"readFrameOverChannel failed: %@", error);
    XCTAssertEqual(receivedFrameType, PTFrameTypeTestPing);
    XCTAssertEqual(receivedFrameTag, frameTag);
    XCTAssertEqual(receivedPayloadSize, payloadSize);
    
    dispatch_semaphore_signal(sem1);
  }];
  
  [self waitForSemaphore:sem1 milliseconds:1000];
}


- (void)test3_protocol_echo_frame {
  dispatch_semaphore_t sem1 = dispatch_semaphore_create(0);

  uint32_t frameTag = [protocol_[0] newTag];
  uint32_t payloadSize = 0;
  
  // Send frame on channel 0
  [protocol_[0] sendFrameOfType:PTFrameTypeTestPing tag:frameTag withPayload:nil overChannel:channel_[0] callback:^(NSError *error) {
    if (error) XCTFail(@"sendFrameOfType failed: %@", error);
  }];
  
  // Read frame on channel 1
  [protocol_[1] readFrameOverChannel:channel_[1] callback:^(NSError *error, uint32_t receivedFrameType, uint32_t receivedFrameTag, uint32_t receivedPayloadSize) {
    if (error) XCTFail(@"readFrameOverChannel failed: %@", error);
    XCTAssertEqual(receivedFrameType, PTFrameTypeTestPing);
    XCTAssertEqual(receivedFrameTag, frameTag);
    XCTAssertEqual(receivedPayloadSize, payloadSize);
    
    // Reply on channel 1
    [protocol_[1] sendFrameOfType:PTFrameTypeTestPingReply tag:receivedFrameTag withPayload:nil overChannel:channel_[1] callback:^(NSError *error) {
      if (error) XCTFail(@"sendFrameOfType failed: %@", error);
    }];
  }];
  
  // Read reply on channel 0 (we expect a reply)
  [protocol_[0] readFrameOverChannel:channel_[0] callback:^(NSError *error, uint32_t receivedFrameType, uint32_t receivedFrameTag, uint32_t receivedPayloadSize) {
    if (error) XCTFail(@"readFrameOverChannel failed: %@", error);
    XCTAssertEqual(receivedFrameType, PTFrameTypeTestPingReply);
    XCTAssertEqual(receivedFrameTag, frameTag);
    XCTAssertEqual(receivedPayloadSize, payloadSize);
    // Test case complete
    dispatch_semaphore_signal(sem1);
  }];
  
  [self waitForSemaphore:sem1 milliseconds:1000];
}


- (void)test4_protocol_transmit_frame_with_payload {
  dispatch_semaphore_t sem1 = dispatch_semaphore_create(0);
  
  NSString *textMessage = @"¡HELLO! This is ünt unicoded méssage";
  NSData *payloadData = [textMessage dataUsingEncoding:NSUTF8StringEncoding];
  dispatch_data_t payload = [payloadData createReferencingDispatchData];
  
  [protocol_[0] sendFrameOfType:PTFrameTypeTestPing tag:PTFrameNoTag withPayload:payload overChannel:channel_[0] callback:^(NSError *error) {
    if (error) XCTFail(@"sendFrameOfType failed: %@", error);
  }];
  
  [self readFrameWithClient:1 expectedFrameType:PTFrameTypeTestPing expectedFrameTag:PTFrameNoTag expectedPayloadSize:(uint32_t)dispatch_data_get_size(payload) callback:^(dispatch_data_t contiguousData, const uint8_t *buffer, size_t bufferSize) {
    
    if (memcmp((const void *)payloadData.bytes, (const void *)buffer, bufferSize) != 0) {
      XCTFail(@"Received payload differs from sent payload");
    }
    
    NSString *receivedTextMessage = [[NSString alloc] initWithBytes:buffer length:bufferSize encoding:NSUTF8StringEncoding];
    if (![textMessage isEqualToString:receivedTextMessage]) {
      XCTFail(@"Received payload interpreted as UTF-8 text differs from sent text");
    }
    //else NSLog(@"Received payload as UTF-8 string: \"%@\"", receivedTextMessage);
    
    dispatch_semaphore_signal(sem1);
  }];
  
  [self waitForSemaphore:sem1 milliseconds:1000];
}


- (void)test5_protocol_transmit_multiple_frames {
  dispatch_semaphore_t sem1 = dispatch_semaphore_create(0);
  
  const int totalNumberOfFrames = 20;
  uint32_t frameTypes[totalNumberOfFrames];
  uint32_t tags[totalNumberOfFrames];
  
  for (int i = 0; i < totalNumberOfFrames; ++i ) {
    frameTypes[i] = PTFrameTypeTestPing - i; // note: PTFrameTypeTest* are adjusted to UINT32_MAX, thus we subtract to avoid overflow
    tags[i] = [protocol_[0] newTag];
    [protocol_[0] sendFrameOfType:frameTypes[i] tag:tags[i] withPayload:nil overChannel:channel_[0] callback:^(NSError *error) {
      if (error) XCTFail(@"sendFrameOfType failed: %@", error);
    }];
  }
  
  // The following is safe (instead of using readFramesOverChannel:onFrame:)
  // since we know there are no payloads involved.
  for (int i = 0; i < totalNumberOfFrames; ++i ) {
    [self readFrameWithClient:1 expectedFrameType:frameTypes[i] expectedFrameTag:tags[i] expectedPayloadSize:0 callback:^(dispatch_data_t contiguousData, const uint8_t *buffer, size_t bufferSize) {
      dispatch_semaphore_signal(sem1);
    }];
  }
  
  // Classic "join" pattern to wait for all reads to finish
  for (int i = 0; i < totalNumberOfFrames; ++i ) {
    [self waitForSemaphore:sem1 milliseconds:100];
  }
}


- (void)test6_protocol_transmit_multiple_frames_with_payload {
  dispatch_semaphore_t sem1 = dispatch_semaphore_create(0);
  
  const int totalNumberOfFrames = 20;
  
  NSMutableArray *frameTypes = [NSMutableArray arrayWithCapacity:totalNumberOfFrames];
  NSMutableArray *tags = [NSMutableArray arrayWithCapacity:totalNumberOfFrames];
  NSMutableArray *payloadData = [NSMutableArray arrayWithCapacity:totalNumberOfFrames];
  
  // Send all frames on channel 0
  for (int i = 0; i < totalNumberOfFrames; ++i ) {
    uint32_t frameType = PTFrameTypeTestPing - i;
    [frameTypes addObject:[NSNumber numberWithUnsignedInt:frameType]]; // note: PTFrameTypeTest* are adjusted to UINT32_MAX, thus we subtract to avoid overflow
    uint32_t tag = [protocol_[0] newTag];
    [tags addObject:[NSNumber numberWithUnsignedInt:tag]];
    
    dispatch_data_t payload = NULL;
    
    // Only include a payload for 2/3 of the frames
    if (i % 3 != 0) {
      [payloadData addObject:[[NSString stringWithFormat:@"Frame #%d", i] dataUsingEncoding:NSUTF8StringEncoding]];
      payload = [[payloadData objectAtIndex:i] createReferencingDispatchData];
    } else {
      [payloadData addObject:[NSNull null]];
    }
    
    [protocol_[0] sendFrameOfType:frameType tag:tag withPayload:payload overChannel:channel_[0] callback:^(NSError *error) {
      if (error) XCTFail(@"sendFrameOfType failed: %@", error);
    }];
  }
  
  // Read all frames on channel 1
  __block int read_i = 0;
  [protocol_[1] readFramesOverChannel:channel_[1] onFrame:^(NSError *error, uint32_t type, uint32_t tag, uint32_t payloadSize, dispatch_block_t resumeReadingFrames) {
    if (error) XCTFail(@"readFramesOverChannel failed: %@", error);
    
    uint32_t expectedType = [[frameTypes objectAtIndex:read_i] unsignedIntValue];
    uint32_t expectedTag = [[tags objectAtIndex:read_i] unsignedIntValue];
    NSData *expectedPayloadData = [payloadData objectAtIndex:read_i];
    if (expectedPayloadData == (id)[NSNull null])
      expectedPayloadData = nil;

    XCTAssertEqual(type, expectedType);
    XCTAssertEqual(tag, expectedTag);
    XCTAssertEqual(payloadSize, (uint32_t)(expectedPayloadData ? expectedPayloadData.length : 0));
    
    dispatch_block_t cont = ^{
      ++read_i;
      if (read_i < totalNumberOfFrames) {
        resumeReadingFrames();
      } else {
        dispatch_semaphore_signal(sem1);
      }
    };
    
    if (payloadSize) {
      [protocol_[1] readPayloadOfSize:payloadSize overChannel:channel_[1] callback:^(NSError *error, dispatch_data_t contiguousData, const uint8_t *buffer, size_t bufferSize) {
        PTAssertNotNULL(contiguousData);
        PTAssertNotNULL(buffer);
        XCTAssertEqual((uint32_t)bufferSize, payloadSize);
        
        if (memcmp((const void *)(expectedPayloadData.bytes), (const void *)buffer, bufferSize) != 0) {
          XCTFail(@"Received payload differs from sent payload");
        }
        
        //NSLog(@"Received payload as UTF-8 string: \"%@\"", [[NSString alloc] initWithBytes:buffer length:bufferSize encoding:NSUTF8StringEncoding]);
        cont();
      }];
    } else {
      cont();
    }
  }];

  // Give each read 100ms to complete, or fail with timeout
  [self waitForSemaphore:sem1 milliseconds:totalNumberOfFrames * 100];
}


@end
