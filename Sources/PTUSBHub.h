#include <dispatch/dispatch.h>
#import <Foundation/Foundation.h>

// PTUSBDeviceDidAttachNotification
// Posted when a device has been attached. Also posted for each device that is
// already attached when the PTUSBHub starts listening.
//
//  .userInfo = {
//    DeviceID = 3;
//    MessageType = Attached;
//    Properties = {
//      ConnectionSpeed = 480000000;
//      ConnectionType = USB;
//      DeviceID = 3;
//      LocationID = 1234567890;
//      ProductID = 1234;
//      SerialNumber = 0123456789abcdef0123456789abcdef01234567;
//    };
//  }
//
FOUNDATION_EXPORT NSNotificationName const PTUSBDeviceDidAttachNotification NS_SWIFT_NAME(deviceDidAttach);

// PTUSBDeviceDidDetachNotification
// Posted when a device has been detached.
//
//  .userInfo = {
//    DeviceID = 3;
//    MessageType = Detached;
//  }
//
FOUNDATION_EXPORT NSNotificationName const PTUSBDeviceDidDetachNotification NS_SWIFT_NAME(deviceDidDetach);

typedef NSString * PTUSBHubNotificationKey NS_TYPED_ENUM;
FOUNDATION_EXPORT PTUSBHubNotificationKey const PTUSBHubNotificationKeyDeviceID NS_SWIFT_NAME(deviceID);
FOUNDATION_EXPORT PTUSBHubNotificationKey const PTUSBHubNotificationKeyMessageType NS_SWIFT_NAME(messageType);
FOUNDATION_EXPORT PTUSBHubNotificationKey const PTUSBHubNotificationKeyProperties NS_SWIFT_NAME(properties);

// NSError domain
FOUNDATION_EXPORT NSString * const PTUSBHubErrorDomain;

// Error codes returned with NSError.code for NSError domain PTUSBHubErrorDomain
typedef enum {
  PTUSBHubErrorBadDevice = 2,
  PTUSBHubErrorConnectionRefused = 3,
} PTUSBHubError;

@interface PTUSBHub : NSObject

// Shared, implicitly opened hub.
+ (instancetype)sharedHub;

- (instancetype)init NS_UNAVAILABLE;

// Connect to a TCP *port* on a device, while the actual transport is over USB.
// Upon success, *error* is nil and *channel* is a duplex I/O channel.
// You can retrieve the underlying file descriptor using
// dispatch_io_get_descriptor(channel). The dispatch_io_t channel behaves just
// like any stream type dispatch_io_t, making it possible to use the same logic
// for both USB bridged connections and e.g. ethernet-based connections.
//
// *onStart* is called either when a connection failed, in which case the error
// argument is non-nil, or when the connection was successfully established (the
// error argument is nil). Must not be NULL.
//
// *onEnd* is called when a connection was open and just did close. If the error
// argument is non-nil, the channel closed because of an error. Pass NULL for no
// callback.
//
- (void)connectToDevice:(NSNumber*)deviceID
                   port:(int)port
                onStart:(void(^)(NSError *error, dispatch_io_t channel))onStart
                  onEnd:(void(^)(NSError *error))onEnd;

// Start listening for devices. You only need to invoke this method on custom
// instances to start receiving notifications. The shared instance returned from
// +sharedHub is always in listening mode.
//
// *onStart* is called either when the system failed to start listening, in
// which case the error argument is non-nil, or when the receiver is listening.
// Pass NULL for no callback.
//
// *onEnd* is called when listening stopped. If the error argument is non-nil,
// listening stopped because of an error. Pass NULL for no callback.
//
- (void)listenOnQueue:(dispatch_queue_t)queue
              onStart:(void(^)(NSError*))onStart
                onEnd:(void(^)(NSError*))onEnd;

@end
