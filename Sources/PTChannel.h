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
#import "PTDefines.h"

@class PTAddress;
@protocol PTChannelDelegate;

NS_ASSUME_NONNULL_BEGIN

PT_FINAL @interface PTChannel : NSObject

// Delegate
@property (strong, nullable) id<PTChannelDelegate> delegate;

// Communication protocol.
@property PTProtocol *protocol;

// YES if this channel is a listening server
@property (readonly) BOOL isListening;

// YES if this channel is a connected peer
@property (readonly) BOOL isConnected;

// Arbitrary attachment. Note that if you set this, the object will grow by
// 8 bytes (64 bits).
@property (strong) id userInfo;

// Create a new channel using the shared PTProtocol for the current dispatch
// queue, with *delegate*.
+ (PTChannel *)channelWithDelegate:(nullable id<PTChannelDelegate>)delegate NS_SWIFT_UNAVAILABLE("");

// Initialize a new frame channel, configuring it to use the calling queue's
// protocol instance (as returned by [PTProtocol sharedProtocolForQueue:
//   dispatch_get_current_queue()])
- (id)init NS_SWIFT_UNAVAILABLE("");

//// Initialize a new frame channel with a specific protocol.
- (id)initWithProtocol:(PTProtocol *)protocol NS_SWIFT_UNAVAILABLE("");

// Initialize a new frame channel with a specific protocol and delegate.
- (id)initWithProtocol:(nullable PTProtocol *)protocol delegate:(nullable id<PTChannelDelegate>)delegate NS_SWIFT_NAME(init(protocol:delegate:));

// Connect to a TCP port on a device connected over USB
- (void)connectToPort:(int)port overUSBHub:(PTUSBHub *)usbHub deviceID:(NSNumber *)deviceID callback:(void(^)(NSError * _Nullable error))callback NS_SWIFT_NAME(connect(to:over:deviceID:callback:));

// Connect to a TCP port at IPv4 address. Provided port must NOT be in network
// byte order. Provided in_addr_t must NOT be in network byte order. A value returned
// from inet_aton() will be in network byte order. You can use a value of inet_aton()
// as the address parameter here, but you must flip the byte order before passing the
// in_addr_t to this function.
- (void)connectToPort:(in_port_t)port IPv4Address:(in_addr_t)address callback:(void(^)(NSError * _Nullable error, PTAddress *_Nullable address))callback NS_SWIFT_NAME(connect(to:IPv4Address:callback:));

// Listen for connections on port and address, effectively starting a socket
// server. Provided port must NOT be in network byte order. Provided in_addr_t
// must NOT be in network byte order.
// For this to make sense, you should provide a onAccept block handler
// or a delegate implementing ioFrameChannel:didAcceptConnection:.
- (void)listenOnPort:(in_port_t)port IPv4Address:(in_addr_t)address callback:(void(^)(NSError * _Nullable error))callback NS_SWIFT_NAME(listen(on:IPv4Address:callback:));

// Send a frame with an optional payload and optional callback.
// If *callback* is not NULL, the block is invoked when either an error occured
// or when the frame (and payload, if any) has been completely sent.
- (void)sendFrameOfType:(uint32_t)frameType tag:(uint32_t)tag withPayload:(nullable NSData *)payload callback:(nullable void(^)(NSError * _Nullable error))callback NS_SWIFT_NAME(sendFrame(type:tag:payload:callback:));

// Lower-level method to assign a connected dispatch IO channel to this channel
- (BOOL)startReadingFromConnectedChannel:(dispatch_io_t)channel error:(__autoreleasing NSError **)error NS_SWIFT_NAME(startReading(from:));

// Close the channel, preventing further reading and writing. Any ongoing and
// queued reads and writes will be aborted.
- (void)close;

// "graceful" close -- any ongoing and queued reads and writes will complete
// before the channel ends.
- (void)cancel;

@end

// Represents a peer's address
PT_FINAL @interface PTAddress : NSObject
// For network addresses, this is the IP address in textual format
@property (readonly) NSString *name;
// For network addresses, this is the port number. Otherwise 0 (zero).
@property (readonly) NSInteger port;
@end


// Protocol for PTChannel delegates
@protocol PTChannelDelegate <NSObject>

@required
// Invoked when a new frame has arrived on a channel.
- (void)ioFrameChannel:(PTChannel *)channel didReceiveFrameOfType:(uint32_t)type tag:(uint32_t)tag payload:(nullable NSData *)payload NS_SWIFT_NAME(channel(_:didRecieveFrame:tag:payload:));

@optional
// Invoked to accept an incoming frame on a channel. Reply NO ignore the
// incoming frame. If not implemented by the delegate, all frames are accepted.
- (BOOL)ioFrameChannel:(PTChannel *)channel shouldAcceptFrameOfType:(uint32_t)type tag:(uint32_t)tag payloadSize:(uint32_t)payloadSize NS_SWIFT_NAME(channel(_:shouldAcceptFrame:tag:payloadSize:));;

// Invoked when the channel closed. If it closed because of an error, *error* is
// a non-nil NSError object.
- (void)ioFrameChannel:(PTChannel *)channel didEndWithError:(nullable NSError *)error NS_SWIFT_NAME(channelDidEnd(_:error:));

// For listening channels, this method is invoked when a new connection has been
// accepted.
- (void)ioFrameChannel:(PTChannel *)channel didAcceptConnection:(PTChannel *)otherChannel fromAddress:(PTAddress *)address NS_SWIFT_NAME(channel(_:didAcceptConnection:from:));

@end

NS_ASSUME_NONNULL_END
