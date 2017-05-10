// Peertalk
//
// Copyright (c) 2012 Rasmus Andersson <http://rsms.me/>
//
// Connection by hostname Copyright (c) 2017 Jean-Luc Jumpertz 
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

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
FOUNDATION_EXPORT NSString * const PTUSBDeviceDidAttachNotification;

// PTUSBDeviceDidDetachNotification
// Posted when a device has been detached.
//
//  .userInfo = {
//    DeviceID = 3;
//    MessageType = Detached;
//  }
//
FOUNDATION_EXPORT NSString * const PTUSBDeviceDidDetachNotification;

// NSError domain
FOUNDATION_EXPORT NSString * const PTUSBHubErrorDomain;

// Error codes returned with NSError.code for NSError domain PTUSBHubErrorDomain
typedef NS_ENUM(unsigned int, PTUSBHubError) {
  PTUSBHubErrorInvalidCommand = 1,
  PTUSBHubErrorUnknownDevice = 2,
  PTUSBHubErrorConnectionRefused = 3,
  PTUSBHubErrorInvalidResponse = 4,
};

@interface PTUSBHub : NSObject

// Shared, implicitly opened hub.
+ (PTUSBHub*)sharedHub;

/// Create the sharedHub instance and start monitoring USB- attached / detached devices
+ (void) startMonitoringAttachedDevices;

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


/// Connect to a Bonjour service on a device, while the actual transport is over USB.
/// The Bonjour service is supposed to be resolved, so the client only knows the service
/// hostname and port. In order to be compatible with the standard way of connecting to 
/// NetServices, a pair of NSStreams is provided in the callback.
/// And because NSStreams have their onw closing mechanism, no 'onEnd' callback is provided in this case.
- (void) connectToDeviceWithHostName:(NSString*)deviceHostname 
                                port:(int)port 
                             onStart:(void(^)(NSError*, NSInputStream*, NSOutputStream*))onStart;


@end
