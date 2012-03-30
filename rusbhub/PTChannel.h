//
// Represents a communication channel between two endpoints talking the same
// PTProtocol.
//
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <netinet/in.h>
#import <sys/socket.h>

#import "PTProtocol.h"
#import "PTUSBHub.h"

@class PTData;
@protocol PTChannelDelegate;

@interface PTChannel : NSObject

@property PTProtocol *protocol;
@property (strong) id<PTChannelDelegate> delegate;
@property (readonly) BOOL isListening; // YES if this channel is a listening server
@property (readonly) BOOL isConnected; // YES if this channel is a connected peer

// These block callbacks can be used as an alternative to providing a delegate.
// You can not use a delegate AND provide block callbacks. E.g. setting a
// delegate and then setting a onFrame callback block will re-route any "frame"
// events to the block and never call the delegate.
@property (copy) BOOL(^shouldAcceptFrame)(PTChannel *channel, uint32_t type, uint32_t tag, uint32_t payloadSize);
@property (copy) void(^onFrame)(PTChannel *channel, uint32_t type, uint32_t tag, PTData *payload);
@property (copy) void(^onAccept)(PTChannel *serverChannel, PTChannel *channel);
@property (copy) void(^onEnd)(PTChannel *channel, NSError *error);

// Create a new channel initialized with delegate=*delegate*.
+ (PTChannel*)channelWithDelegate:(id<PTChannelDelegate>)delegate;

// Initialize a new frame channel, configuring it to use the calling queue's
// protocol instance (as returned by [PTProtocol sharedProtocolForQueue:
//   dispatch_get_current_queue()])
- (id)init;

// Initialize a new frame channel with a specific protocol.
- (id)initWithProtocol:(PTProtocol*)protocol;

- (BOOL)startReadingFromConnectedChannel:(dispatch_io_t)channel error:(__autoreleasing NSError**)error;

// Connect to a TCP port on a device connected over USB
- (void)connectToPort:(int)port overUSBHub:(PTUSBHub*)usbHub deviceID:(NSNumber*)deviceID callback:(void(^)(NSError *error))callback;

// Connect to a TCP port at IPv4 address. INADDR_LOOPBACK can be used as address
// to connect to the local host.
- (void)connectToPort:(in_port_t)port IPv4Address:(in_addr_t)address callback:(void(^)(NSError *error))callback;

// Listen for connections on port and address, effectively starting a socket
// server. For this to make sense, you should provide a onAccept block handler
// or a delegate implementing ioFrameChannel:didAcceptConnection:.
- (void)listenOnPort:(in_port_t)port IPv4Address:(in_addr_t)address callback:(void(^)(NSError *error))callback;

// Send a frame with an optional payload and optional callback.
// If *callback* is not NULL, the block is invoked when either an error occured
// or when the frame (and payload, if any) has been completely sent.
- (void)sendFrameOfType:(uint32_t)frameType tag:(uint32_t)tag withPayload:(dispatch_data_t)payload callback:(void(^)(NSError *error))callback;

// Close the channel, preventing further reading and writing. Any ongoing and
// queued reads and writes will be aborted.
- (void)close;

// "graceful" close -- any ongoing and queued reads and writes will complete
// before the channel ends.
- (void)cancel;

@end


// A simple subclass used for device-specific channels that contains a device
// identifier
@interface PTDeviceChannel : PTChannel
@property (strong) NSNumber *deviceID;
@end


// Wraps a mapped dispatch_data_t object. The memory pointed to by *data* is
// valid until *dispatchData* is deallocated (normally when the receiver is
// deallocated).
@interface PTData : NSObject
@property (readonly) dispatch_data_t dispatchData;
@property (readonly) void *data;
@property (readonly) size_t length;
@end


// Protocol for PTChannel delegates
@protocol PTChannelDelegate <NSObject>

@required
// Invoked when a new frame has arrived on a channel.
- (void)ioFrameChannel:(PTChannel*)channel didReceiveFrameOfType:(uint32_t)type tag:(uint32_t)tag payload:(PTData*)payload;

@optional
// Invoked to accept an incoming frame on a channel. Reply NO ignore the
// incoming frame. If not implemented by the delegate, all frames are accepted.
- (BOOL)ioFrameChannel:(PTChannel*)channel shouldAcceptFrameOfType:(uint32_t)type tag:(uint32_t)tag payloadSize:(uint32_t)payloadSize;

// Invoked when the channel closed. If it closed because of an error, *error* is
// a non-nil NSError object.
- (void)ioFrameChannel:(PTChannel*)channel didEndWithError:(NSError*)error;

// For listening channels, this method is invoked when a new connection has been
// accepted.
- (void)ioFrameChannel:(PTChannel*)channel didAcceptConnection:(PTChannel*)otherChannel;

@end
