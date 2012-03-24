//
// Represents a communication channel between two endpoints talking the same
// RIOFrameProtocol.
//
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import "RIOFrameProtocol.h"
#import "RUSBHub.h"
#import <netinet/in.h>

@class RIOData;
@protocol RIOFrameChannelDelegate;

@interface RIOFrameChannel : NSObject

@property RIOFrameProtocol *protocol;
@property (readonly) dispatch_io_t readingFromDispatchChannel;
@property (strong) id<RIOFrameChannelDelegate> delegate;

// These block callbacks can be used as an alternative to providing a delegate.
// You can not use a delegate AND provide block callbacks. E.g. setting a
// delegate and then setting a onFrame callback block will re-route any "frame"
// events to the block and never call the delegate.
@property (copy) BOOL(^shouldAcceptFrame)(RIOFrameChannel *channel, uint32_t type, uint32_t tag, uint32_t payloadSize);
@property (copy) void(^onFrame)(RIOFrameChannel *channel, uint32_t type, uint32_t tag, RIOData *payload);
@property (copy) void(^onEnd)(RIOFrameChannel *channel, NSError *error);

// Create a new channel initialized with delegate=*delegate*.
+ (RIOFrameChannel*)channelWithDelegate:(id<RIOFrameChannelDelegate>)delegate;

// Initialize a new frame channel, configuring it to use the calling queue's
// protocol instance (as returned by [RIOFrameProtocol sharedProtocolForQueue:
//   dispatch_get_current_queue()])
- (id)init;

// Initialize a new frame channel with a specific protocol.
- (id)initWithProtocol:(RIOFrameProtocol*)protocol;

- (void)startReadingFromChannel:(dispatch_io_t)channel;

- (void)close;

// "graceful" close -- any queued reads and writes will complete before the
// channel ends.
- (void)cancel;

// Connect to a TCP port on a device connected over USB
- (void)connectToPort:(int)port overUSBHub:(RUSBHub*)usbHub deviceID:(NSNumber*)deviceID callback:(void(^)(NSError *error))callback;

// Connect to a TCP port at IPv4 address. INADDR_LOOPBACK can be used as address
// to connect to the local host.
- (void)connectToPort:(in_port_t)port atIPv4Address:(in_addr_t)address callback:(void(^)(NSError *error))callback;

// Send a frame with an optional payload and optional callback.
// If *callback* is not NULL, the block is invoked when either an error occured
// or when the frame (and payload, if any) has been completely sent.
- (void)sendFrameOfType:(uint32_t)frameType tag:(uint32_t)tag withPayload:(dispatch_data_t)payload callback:(void(^)(NSError *error))callback;

@end


// A simple subclass used for device-specific channels that contains a device
// identifier
@interface RIODeviceFrameChannel : RIOFrameChannel
@property (strong) NSNumber *deviceID;
@end


// Wraps a mapped dispatch_data_t object. The memory pointed to by *data* is
// valid until *dispatchData* is deallocated (normally when the receiver is
// deallocated).
@interface RIOData : NSObject
@property (readonly) dispatch_data_t dispatchData;
@property (readonly) void *data;
@property (readonly) size_t length;
@end


// Protocol for RIOFrameChannel delegates
@protocol RIOFrameChannelDelegate <NSObject>

@optional
// Invoked to accept an incoming frame on a channel. Reply NO ignore the
// incoming frame. If not implemented by the delegate, all frames are accepted.
- (BOOL)ioFrameChannel:(RIOFrameChannel*)channel shouldAcceptFrameOfType:(uint32_t)type tag:(uint32_t)tag payloadSize:(uint32_t)payloadSize;

@required
// Invoked when a new frame has arrived on a channel.
- (void)ioFrameChannel:(RIOFrameChannel*)channel didReceiveFrameOfType:(uint32_t)type tag:(uint32_t)tag payload:(RIOData*)payload;

@optional
// Invoked when the channel closed. If it closed because of an error, *error* is
// a non-nil NSError object.
- (void)ioFrameChannel:(RIOFrameChannel*)channel didEndWithError:(NSError*)error;

@end
