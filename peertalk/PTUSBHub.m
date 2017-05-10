//  Peertalk
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

#import "PTUSBHub.h"

#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <sys/un.h>
#include <err.h>

#import "PTHostnameProvider.h"

#ifdef OS_OBJECT_USE_OBJC
#define PT_PRECISE_LIFETIME_UNUSED __attribute__((objc_precise_lifetime, unused))
#else
#define PT_PRECISE_LIFETIME_UNUSED
#endif

#ifdef DEBUG
#define NSLogDebug(...) NSLog(__VA_ARGS__)
#else
#define NSLogDebug(...) 
#endif

NSString * const PTUSBHubErrorDomain = @"PTUSBHubError";

typedef uint32_t USBMuxPacketType;
enum {
    USBMuxPacketTypeResult = 1,
    USBMuxPacketTypeConnect = 2,
    USBMuxPacketTypeListen = 3,
    USBMuxPacketTypeDeviceAdd = 4,
    USBMuxPacketTypeDeviceRemove = 5,
    // ? = 6,
    // ? = 7,
    USBMuxPacketTypePlistPayload = 8,
};

typedef uint32_t USBMuxPacketProtocol;
enum {
    USBMuxPacketProtocolBinary = 0,
    USBMuxPacketProtocolPlist = 1,
};

typedef uint32_t USBMuxReplyCode;
enum {
    USBMuxReplyCodeOK = 0,
    USBMuxReplyCodeBadCommand = 1,
    USBMuxReplyCodeBadDevice = 2,
    USBMuxReplyCodeConnectionRefused = 3,
    // ? = 4,
    // ? = 5,
    USBMuxReplyCodeBadVersion = 6,
};


typedef struct usbmux_packet {
    uint32_t size;
    USBMuxPacketProtocol protocol;
    USBMuxPacketType type;
    uint32_t tag;
    char data[0];
} __attribute__((__packed__)) usbmux_packet_t;

static const uint32_t kUsbmuxPacketMaxPayloadSize = UINT32_MAX - (uint32_t)sizeof(usbmux_packet_t);


static uint32_t usbmux_packet_payload_size(usbmux_packet_t *upacket) {
    return upacket->size - sizeof(usbmux_packet_t);
}


static void *usbmux_packet_payload(usbmux_packet_t *upacket) {
    return (void*)upacket->data;
}


static void usbmux_packet_set_payload(usbmux_packet_t *upacket,
                                      const void *payload,
                                      uint32_t payloadLength)
{
    memcpy(usbmux_packet_payload(upacket), payload, payloadLength);
}


static usbmux_packet_t *usbmux_packet_alloc(uint32_t payloadSize) {
    assert(payloadSize <= kUsbmuxPacketMaxPayloadSize);
    uint32_t upacketSize = sizeof(usbmux_packet_t) + payloadSize;
    usbmux_packet_t *upacket = CFAllocatorAllocate(kCFAllocatorDefault, upacketSize, 0);
    memset(upacket, 0, sizeof(usbmux_packet_t));
    upacket->size = upacketSize;
    return upacket;
}


static usbmux_packet_t *usbmux_packet_create(USBMuxPacketProtocol protocol,
                                             USBMuxPacketType type,
                                             uint32_t tag,
                                             const void *payload,
                                             uint32_t payloadSize)
{
    usbmux_packet_t *upacket = usbmux_packet_alloc(payloadSize);
    if (!upacket) {
        return NULL;
    }
    
    upacket->protocol = protocol;
    upacket->type = type;
    upacket->tag = tag;
    
    if (payload && payloadSize) {
        usbmux_packet_set_payload(upacket, payload, (uint32_t)payloadSize);
    }
    
    return upacket;
}


static void usbmux_packet_free(usbmux_packet_t *upacket) {
    CFAllocatorDeallocate(kCFAllocatorDefault, upacket);
}


NSString * const PTUSBDeviceDidAttachNotification = @"PTUSBDeviceDidAttachNotification";
NSString * const PTUSBDeviceDidDetachNotification = @"PTUSBDeviceDidDetachNotification";

static NSString *kPlistPacketTypeListen = @"Listen";
static NSString *kPlistPacketTypeConnect = @"Connect";


// Represents a channel of communication between the host process and a remote
// (device) system. In practice, a PTUSBChannel is connected to a usbmuxd
// endpoint which is configured to either listen for device changes (the
// PTUSBHub's channel is usually configured as a device notification listener) or
// configured as a TCP bridge (e.g. channels returned from PTUSBHub's
// connectToDevice:port:callback:). You should not create channels yourself, but
// let PTUSBHub provide you with already configured channels.
@interface PTUSBChannel : NSObject 

// The underlying dispatch I/O channel. This is handy if you want to handle your
// own I/O logic without PTUSBChannel. Remember to dispatch_retain() the channel
// if you plan on using it as it might be released from the PTUSBChannel at any
// point in time.
@property (readonly) dispatch_io_t dispatchChannel;

// The underlying file descriptor.
@property (readonly) dispatch_fd_t fileDescriptor;

// Send data
- (void)sendDispatchData:(dispatch_data_t)data callback:(void(^)(NSError*))callback;
- (void)sendData:(NSData*)data callback:(void(^)(NSError*))callback;

// Read data
- (void)readFromOffset:(off_t)offset length:(size_t)length callback:(void(^)(NSError *error, dispatch_data_t data))callback;

// Close the channel, preventing further reads and writes, but letting currently
// queued reads and writes finish.
- (void)cancel;

// Close the channel, preventing further reads and writes, immediately
// terminating any ongoing reads and writes.
- (void)stop;

@end


@interface PTUSBChannel ()
{
    dispatch_io_t dispatchChannel_;
    dispatch_fd_t _channelFileDescriptor; // -1 if the channel is not open or if the fd ownership has been transfered to a client 
    dispatch_queue_t queue_;
    uint32_t nextPacketTag_;
    NSMutableDictionary *responseHandlers_;
    BOOL autoReadPackets_;
    BOOL isReadingPackets_;
}

+ (NSDictionary*)packetDictionaryWithPacketType:(NSString*)messageType payload:(NSDictionary*)payload;

- (BOOL)openOnQueue:(dispatch_queue_t)queue error:(NSError**)error onEnd:(void(^)(NSError *error))onEnd;

- (void)listenWithBroadcastHandler:(void(^)(NSDictionary *packet))broadcastHandler callback:(void(^)(NSError*))callback;
- (void)sendRequest:(NSDictionary*)packet callback:(void(^)(NSError *error, NSDictionary *responsePacket))callback;

- (BOOL) transferChannelToClientUsingBlock:(void(^)(dispatch_io_t dispatchChannel)) block;
- (BOOL) transferChannelToClientAsNSStreamsUsingBlock:(void(^)(NSInputStream* inputStream, NSOutputStream* outputStream)) block ;

@end


@interface PTAttachedDevice : NSObject

@property NSNumber* deviceId;
@property NSString* hostName;
@property NSDictionary <NSString*, id> * deviceInfo;
@property dispatch_data_t hostnameMessageData;

- (instancetype) initWithDeviceInfo:(NSDictionary<NSString*, id>*)attachedDeviceInfo;

@end



@interface PTUSBHub () {
    PTUSBChannel *broadcastPacketsChannel_;
    NSMutableSet<PTAttachedDevice*>* attachedDevices_;
}
@end


@implementation PTUSBHub


+ (PTUSBHub*)sharedHub {
    static PTUSBHub *gSharedHub;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gSharedHub = [PTUSBHub new];
    });
    return gSharedHub;
}

+ (void) startMonitoringAttachedDevices
{
    // Create the shared hub
    [self sharedHub];
}

- (id)init {
    self = [super init];
    if (self != nil) {
        attachedDevices_ = [NSMutableSet new];
        [self startListeningForBroadcastPackets];
    }
    return self;
}


- (void) startListeningForBroadcastPackets
{
    broadcastPacketsChannel_ = [PTUSBChannel new];
    NSError *error = nil;
    if ([broadcastPacketsChannel_ openOnQueue:dispatch_get_main_queue() error:&error onEnd:nil]) {
        
        [broadcastPacketsChannel_ listenWithBroadcastHandler:^(NSDictionary *packet) { [self handleBroadcastPacket:packet]; } 
                                                    callback:^(NSError *error) { NSLog(@"PTUSBHub failed to initialize: %@", error); }];
    } else {
        NSLog(@"PTUSBHub failed to initialize: %@", error);
    }
}

- (void)connectToDevice:(NSNumber*)deviceID port:(int)port onConnected:(void(^)(NSError*, PTUSBChannel*))onConnected onEnd:(void(^)(NSError*))onEnd 
{
    PTUSBChannel *usbChannel = [PTUSBChannel new];
    NSError *error = nil;
    
    if ([usbChannel openOnQueue:dispatch_get_main_queue() error:&error onEnd:onEnd]) {
        
        NSDictionary *connectToDevicePacket = [PTUSBChannel packetDictionaryWithPacketType:kPlistPacketTypeConnect
                                                                                   payload:@{ @"DeviceID": deviceID,
                                                                                              @"PortNumber": @(htons(port & 0xffff)) }];
        
        [usbChannel sendRequest:connectToDevicePacket callback:^(NSError *error, NSDictionary *responsePacket) {
            
            onConnected (error, usbChannel);
        }];
    }
    else {
        onConnected (error, nil);
    }
}

- (void)connectToDevice:(NSNumber*)deviceID port:(int)port onStart:(void(^)(NSError*, dispatch_io_t))onStart onEnd:(void(^)(NSError*))onEnd {
    
    [self connectToDevice:deviceID port:port onConnected:^(NSError *error, PTUSBChannel *usbChannel) {
        
        if (error == nil) {
            // The client takes ownership of the dispatch channel connected to the device
            BOOL isChannelValidForClient = [usbChannel transferChannelToClientUsingBlock:^(dispatch_io_t dispatchChannel) {
                
                onStart(nil, dispatchChannel);
            }];
            
            if (! isChannelValidForClient) {
                NSError* error = [NSError errorWithDomain:PTUSBHubErrorDomain code:PTUSBHubErrorInvalidCommand 
                                                 userInfo:@{ NSLocalizedDescriptionKey: @"Error when connecting to the device" }];
                onStart(error, nil);
            }
        }
        else {
            onStart(error, nil);
        }
        
    } onEnd:onEnd];
}

- (void) connectToDeviceWithHostName:(NSString*)deviceHostname port:(int)port onStart:(void(^)(NSError*, NSInputStream*, NSOutputStream*))onStart 
{
    void (^onDeviceConnectedBlock)(NSError *error, PTUSBChannel *usbChannel) = ^(NSError *error, PTUSBChannel *usbChannel) {
        
        if (error == nil) {
            // The client takes ownership of the dispatch channel connected to the device
            BOOL isChannelValidForClient = [usbChannel transferChannelToClientAsNSStreamsUsingBlock:^(NSInputStream *inputStream, NSOutputStream *outputStream) {
                
                onStart (nil, inputStream, outputStream);
            }];
            
            if (! isChannelValidForClient) {
                NSError* error = [NSError errorWithDomain:PTUSBHubErrorDomain code:PTUSBHubErrorInvalidCommand 
                                                 userInfo:@{ NSLocalizedDescriptionKey: @"Error when connecting to the device" }];
                onStart(error, nil, nil);
            }
        }
        else {
            onStart(error, nil, nil);
        }
    };
    
    __block PTAttachedDevice* targetDevice = nil;
    [attachedDevices_ enumerateObjectsUsingBlock:^(PTAttachedDevice * _Nonnull device, BOOL * _Nonnull stop) {
        if ((device.hostName != nil) && ([device.hostName caseInsensitiveCompare:deviceHostname] == NSOrderedSame)) {
            targetDevice = device;
            *stop = YES;
        }
    }];
    
    if (targetDevice != nil) {
        [self connectToDevice:targetDevice.deviceId port:port onConnected:onDeviceConnectedBlock onEnd:nil];
    }
    else {
        // Try to get the missing hostnames of attached devices 
        NSMutableSet* queriedDevices = [NSMutableSet new];
        [attachedDevices_ enumerateObjectsUsingBlock:^(PTAttachedDevice * _Nonnull device, BOOL * _Nonnull stop) {
            if (device.hostName == nil) {
                [queriedDevices addObject:device.deviceId];
            }
        }];
        
        if (queriedDevices.count > 0) {
            [queriedDevices enumerateObjectsUsingBlock:^(NSNumber*  _Nonnull deviceId, BOOL * _Nonnull stop) {
                
                [self getHostNameOfAttachedDeviceWithId:deviceId completion:^(NSError *error, PTAttachedDevice *queriedDevice) {
                    
                    if (queriedDevices.count > 0) {
                        [queriedDevices removeObject:deviceId];
                        
                        if ((error == nil) && ([queriedDevice.hostName caseInsensitiveCompare:deviceHostname] == NSOrderedSame)) {
                            
                            // This is the target device
                            [self connectToDevice:queriedDevice.deviceId port:port onConnected:onDeviceConnectedBlock  onEnd:nil];
                            
                            // Empy the queriedDevices set to prevent a connection to more than one device
                            [queriedDevices removeAllObjects];
                        }
                        else if (queriedDevices.count == 0) {
                            // No match
                            NSError* error = [NSError errorWithDomain:PTUSBHubErrorDomain code:PTUSBHubErrorUnknownDevice 
                                                             userInfo:@{ NSLocalizedDescriptionKey: @"No attached device with the specified host name" }];
                            onStart(error, nil, nil);
                        }
                    }
                }];
            }];
        }
        else {
            // Unknown hostname
            NSError* error = [NSError errorWithDomain:PTUSBHubErrorDomain code:PTUSBHubErrorUnknownDevice 
                                             userInfo:@{ NSLocalizedDescriptionKey: @"No attached device with the specified host name" }];
            onStart(error, nil, nil);
        }
    }
}

- (void)handleBroadcastPacket:(NSDictionary*)packet 
{
    NSString *messageType = packet[@"MessageType"];
    
    if ([@"Attached" isEqualToString:messageType]) {
        PTAttachedDevice* attachedDevice = [[PTAttachedDevice alloc] initWithDeviceInfo:packet[@"Properties"]];
        [attachedDevices_ addObject:attachedDevice];
        [[NSNotificationCenter defaultCenter] postNotificationName:PTUSBDeviceDidAttachNotification object:self userInfo:packet];
        
    } else if ([@"Detached" isEqualToString:messageType]) {
        NSNumber* detachedDeviceId = packet[@"DeviceID"];
        if (detachedDeviceId != nil) {
            PTAttachedDevice* detachedDevice = [self attachedDeviceWithId:detachedDeviceId];
            if (detachedDevice != nil) {
                [attachedDevices_ removeObject:detachedDevice];
                [[NSNotificationCenter defaultCenter] postNotificationName:PTUSBDeviceDidDetachNotification object:self userInfo:packet];
            }
        }
        
    } else {
        NSLogDebug(@"Warning: Unhandled broadcast message: %@", packet);
    }
}

- (PTAttachedDevice*) attachedDeviceWithId:(NSNumber*)deviceID
{
    __block PTAttachedDevice* deviceWithId = nil;
    [attachedDevices_ enumerateObjectsUsingBlock:^(PTAttachedDevice * _Nonnull device, BOOL * _Nonnull stop) {
        if ([device.deviceId isEqual:deviceID]) {
            deviceWithId = device;
            *stop = YES;
        }
    }];
    return deviceWithId;
}

- (void) getHostNameOfAttachedDeviceWithId:(NSNumber*)deviceID completion:(void(^)(NSError* error, PTAttachedDevice* attachedDeviceWithId))completion
{
    PTAttachedDevice* attachedDevice = [self attachedDeviceWithId:deviceID];
    
    [self connectToDevice:deviceID port:kPTHostnameProviderPort onStart:^(NSError *connectError, dispatch_io_t channel) {
        
        if (connectError == nil) {
            // Read the hostname message
            
            attachedDevice.hostnameMessageData = nil;

            dispatch_io_read(channel, 0, SIZE_MAX, dispatch_get_main_queue(), ^(bool done, dispatch_data_t  _Nullable data, int error) {
                
                if (data != nil) {
                    dispatch_data_t hostnameMessageData = attachedDevice.hostnameMessageData;
                    
                    if (hostnameMessageData == nil) {
                        hostnameMessageData = data;
                    }
                    else {
                        hostnameMessageData = dispatch_data_create_concat(hostnameMessageData, data);
                    }
                    
                    attachedDevice.hostnameMessageData = hostnameMessageData;
                    
                    if (dispatch_data_get_size(hostnameMessageData) > kPTHostnameProviderResponseOffsetHostname) {
                        
                        const char *messageBuffer = NULL;
                        size_t bufferSize = 0;
                        PT_PRECISE_LIFETIME_UNUSED dispatch_data_t map_data = dispatch_data_create_map(hostnameMessageData, (const void **)&messageBuffer, &bufferSize);
                        
                        size_t messageSize = (messageBuffer[0] << 8) + messageBuffer[1];
                        if ((bufferSize == messageSize) 
                            && (strncmp(&messageBuffer[kPTHostnameProviderResponseOffsetMagicString], kPTHostnameProviderResponseMagicString, 
                                        strlen(kPTHostnameProviderResponseMagicString)) == 0)) {
                            
                            // The message is fully received and the magic string matches: get the hostname
                            attachedDevice.hostName = [[NSString alloc] initWithBytes:&messageBuffer[kPTHostnameProviderResponseOffsetHostname]
                                                                               length:messageSize - kPTHostnameProviderResponseOffsetHostname - 1
                                                                             encoding:NSUTF8StringEncoding];
                            
                            if (completion != nil) {
                                completion (nil, attachedDevice);
                            }
                             
                        }
                    }
                }
                
                NSError* readError = nil;
                if (error != 0) {
                    readError = [NSError errorWithDomain:NSPOSIXErrorDomain code:error userInfo:nil];
                }
                
                if (done) {
                    attachedDevice.hostnameMessageData = nil;
                    dispatch_io_close(channel, 0); // This retains the channel until the read is complete
                    
                    if ((readError != nil) || (attachedDevice.hostName.length == 0)) {
                        completion (readError, attachedDevice);
                    }
                }
            });
        }
        else {
            // Could not connect to device with the provided id and port
            completion (connectError, attachedDevice);
        }
        
    } onEnd:nil];
}

@end

#pragma mark -

@implementation PTUSBChannel

+ (NSDictionary*)packetDictionaryWithPacketType:(NSString*)messageType payload:(NSDictionary*)payload {
    NSDictionary *packet = nil;
    
    static NSString *bundleName = nil;
    static NSString *bundleVersion = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary *infoDict = [NSBundle mainBundle].infoDictionary;
        if (infoDict) {
            bundleName = infoDict[@"CFBundleName"];
            bundleVersion = [infoDict[@"CFBundleVersion"] description];
        }
    });
    
    if (bundleName) {
        packet = @{@"MessageType": messageType,
                   @"ProgName": bundleName,
                   @"ClientVersionString": bundleVersion};
    } else {
        packet = @{@"MessageType": messageType};
    }
    
    if (payload) {
        NSMutableDictionary *mpacket = [NSMutableDictionary dictionaryWithDictionary:payload];
        [mpacket addEntriesFromDictionary:packet];
        packet = mpacket;
    }
    
    return packet;
}


- (id)init {
    self = [super init];
    if (self !=nil) {
        autoReadPackets_ = NO;
        _channelFileDescriptor = -1;
    }
    return self;
}


- (void)dealloc {
    //NSLogDebug(@"dealloc %@", self);
    
#ifndef OS_OBJECT_USE_OBJC
    if (dispatchChannel_) {
        dispatch_release(channel_);
        dispatchChannel_ = nil;
    }
#endif
    
    if (_channelFileDescriptor != -1) {
        close (_channelFileDescriptor);
        _channelFileDescriptor = -1;
    }
}


- (dispatch_io_t)dispatchChannel {
    return dispatchChannel_;
}


- (dispatch_fd_t)fileDescriptor {
    return dispatch_io_get_descriptor(dispatchChannel_);
}

- (BOOL)openOnQueue:(dispatch_queue_t)queue error:(NSError**)error onEnd:(void(^)(NSError*))onEnd {
    assert(queue != nil);
    assert(dispatchChannel_ == nil);
    queue_ = queue;
    
    // Create socket
    dispatch_fd_t fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd == -1) {
        if (error) *error = [[NSError alloc] initWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return NO;
    }
    
    // prevent SIGPIPE
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
    
    // Connect socket
    struct sockaddr_un addr;
    addr.sun_family = AF_UNIX;
    strcpy(addr.sun_path, "/var/run/usbmuxd");
    socklen_t socklen = sizeof(addr);
    if (connect(fd, (struct sockaddr*)&addr, socklen) == -1) {
        if (error) *error = [[NSError alloc] initWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return NO;
    }
    
    _channelFileDescriptor = fd;
    
    dispatchChannel_ = dispatch_io_create(DISPATCH_IO_STREAM, fd, queue_, ^(int errorNumber) {
        
        if (onEnd) {
            NSError* error = nil;
            if (errorNumber != 0) {
                error =  [[NSError alloc] initWithDomain:NSPOSIXErrorDomain code:errorNumber userInfo:nil];
            }
            
            onEnd(error);
        }
    });
    
    return YES;
}

- (BOOL) transferChannelToClientUsingBlock:(void(^)(dispatch_io_t dispatchChannel)) block 
{
    dispatch_fd_t fd = _channelFileDescriptor;
    
    BOOL isTransferValid = (fd != -1);
    
    if (isTransferValid) {
        dispatch_io_t clientChannel = dispatch_io_create(DISPATCH_IO_STREAM, fd, queue_, ^(int error) {
            close(fd);
        });
        
        block(clientChannel);
        
        _channelFileDescriptor = -1; // Release ownership of the file descriptor
    }
    
    return isTransferValid;
}

- (BOOL) transferChannelToClientAsNSStreamsUsingBlock:(void(^)(NSInputStream* inputStream, NSOutputStream* outputStream)) block 
{
    dispatch_fd_t fd = _channelFileDescriptor;
    
    BOOL isTransferDone = NO;
    
    if (fd != -1) {
        CFReadStreamRef  readStream = NULL;
        CFWriteStreamRef writeStream = NULL;
        
        CFStreamCreatePairWithSocket(NULL, fd, &readStream, &writeStream);
        
        if ((readStream != nil) && (writeStream != nil)) {
            
            NSInputStream* inputStream   = (__bridge_transfer NSInputStream*) readStream;
            NSOutputStream* outputStream = (__bridge_transfer NSOutputStream*) writeStream;
            
            block(inputStream, outputStream);
            
            isTransferDone = YES;
            _channelFileDescriptor = -1;
        }
    }
    
    return isTransferDone;
}


- (void)listenWithBroadcastHandler:(void(^)(NSDictionary *packet))broadcastHandler callback:(void(^)(NSError*))callback {
    autoReadPackets_ = YES;
    [self scheduleReadPacketWithBroadcastHandler:broadcastHandler];
    
    NSDictionary *packet = [PTUSBChannel packetDictionaryWithPacketType:kPlistPacketTypeListen payload:nil];
    
    [self sendRequest:packet callback:^(NSError *error, NSDictionary *responsePacket) {
        
        if (callback != 0) {
            callback(error);
        }
    }];
}


- (NSError*) errorFromPlistResponse:(NSDictionary*)packet {

    NSError* error = nil;
    
    NSNumber *replyCodeObject = packet[@"Number"];
        
    if ([replyCodeObject isKindOfClass:[NSNumber class]]) {
        
        USBMuxReplyCode replyCode = (USBMuxReplyCode)replyCodeObject.integerValue;
        if (replyCode != 0) {
            NSString *errmessage;
            switch (replyCode) {
                case USBMuxReplyCodeBadCommand: errmessage = @"illegal command"; break;
                case USBMuxReplyCodeBadDevice: errmessage = @"unknown device"; break;
                case USBMuxReplyCodeConnectionRefused: errmessage = @"connection refused"; break;
                case USBMuxReplyCodeBadVersion: errmessage = @"invalid version"; break;
                default: errmessage = @"Unspecified error";
            }
            error = [NSError errorWithDomain:PTUSBHubErrorDomain code:replyCode userInfo:@{NSLocalizedDescriptionKey: errmessage}];
        } 
    }
    else {
        error = [NSError errorWithDomain:PTUSBHubErrorDomain code:PTUSBHubErrorInvalidResponse userInfo:nil];
    }
    
    return error;
}


- (uint32_t)nextPacketTag {
    return ++nextPacketTag_;
}


- (void)sendRequest:(NSDictionary*)packet callback:(void(^)(NSError*, NSDictionary*))callback {
    uint32_t tag = [self nextPacketTag];
    
    [self sendPacket:packet tag:tag callback:^(NSError *error) {
        if (error) {
            callback(error, nil);
            return;
        }
        if (callback != nil) {
            // TODO: timeout un-triggered callbacks in responseQueue_
            if (!responseHandlers_) responseHandlers_ = [NSMutableDictionary new];
            
            responseHandlers_[@(tag)] = ^(NSError* error, NSDictionary* responseData) {
                
                if (error == nil) {
                    error = [self errorFromPlistResponse:responseData];
                }
                callback(error, responseData);
            };
        }
    }];
    
    // We are awaiting a response
    [self setNeedsReadingPacket];
}


- (void)setNeedsReadingPacket {
    if (!isReadingPackets_) {
        [self scheduleReadPacketWithBroadcastHandler:nil];
    }
}


- (void)scheduleReadPacketWithBroadcastHandler:(void(^)(NSDictionary *packet))broadcastHandler {
    assert(isReadingPackets_ == NO);
    
    [self scheduleReadPacketWithCallback:^(NSError *error, NSDictionary *packet, uint32_t packetTag) {
        // Interpret the package we just received
        if (packetTag == 0) {
            // Broadcast message
            //NSLogDebug(@"Received broadcast: %@", packet);
            if (broadcastHandler) broadcastHandler(packet);
        } else if (responseHandlers_) {
            // Reply
            NSNumber *key = @(packetTag);
            void(^requestCallback)(NSError*,NSDictionary*) = responseHandlers_[key];
            if (requestCallback) {
                [responseHandlers_ removeObjectForKey:key];
                requestCallback(error, packet);
            } else {
                NSLogDebug(@"Warning: Ignoring reply packet for which there is no registered callback. Packet => %@", packet);
            }
        }
        
        // Schedule reading another incoming package
        if (autoReadPackets_) {
            [self scheduleReadPacketWithBroadcastHandler:broadcastHandler];
        }
    }];
}


- (void)scheduleReadPacketWithCallback:(void(^)(NSError*, NSDictionary*, uint32_t))callback {
    static usbmux_packet_t ref_upacket;
    isReadingPackets_ = YES;
    
    dispatch_io_read(dispatchChannel_, 0, sizeof(ref_upacket.size), queue_, ^(bool done, dispatch_data_t data, int error) {
        //NSLogDebug(@"dispatch_io_read 0,4: done=%d data=%p error=%d", done, data, error);
        
        if (!done)
            return;
        
        if (error) {
            isReadingPackets_ = NO;
            callback([[NSError alloc] initWithDomain:NSPOSIXErrorDomain code:error userInfo:nil], nil, 0);
            return;
        }
        
        // Read size of incoming usbmux_packet_t
        uint32_t upacket_len = 0;
        char *buffer = NULL;
        size_t buffer_size = 0;
        PT_PRECISE_LIFETIME_UNUSED dispatch_data_t map_data = dispatch_data_create_map(data, (const void **)&buffer, &buffer_size); // objc_precise_lifetime guarantees 'map_data' isn't released before memcpy has a chance to do its thing
        assert(buffer_size == sizeof(ref_upacket.size));
        memcpy((void *)&(upacket_len), (const void *)buffer, buffer_size);
#ifndef OS_OBJECT_USE_OBJC
        dispatch_release(map_data);
#endif
        
        // Allocate a new usbmux_packet_t for the expected size
        uint32_t payloadLength = upacket_len - (uint32_t)sizeof(usbmux_packet_t);
        usbmux_packet_t *upacket = usbmux_packet_alloc(payloadLength);
        
        // Read rest of the incoming usbmux_packet_t
        off_t offset = sizeof(ref_upacket.size);
        dispatch_io_read(dispatchChannel_, offset, upacket->size - sizeof(ref_upacket.size), queue_, ^(bool done, dispatch_data_t data, int error) {
            //NSLogDebug(@"dispatch_io_read X,Y: done=%d data=%p error=%d", done, data, error);
            
            if (!done) {
                return;
            }
            
            isReadingPackets_ = NO;
            
            if (error) {
                callback([[NSError alloc] initWithDomain:NSPOSIXErrorDomain code:error userInfo:nil], nil, 0);
                usbmux_packet_free(upacket);
                return;
            }
            
            if (upacket_len > kUsbmuxPacketMaxPayloadSize) {
                callback(
                         [[NSError alloc] initWithDomain:PTUSBHubErrorDomain code:PTUSBHubErrorInvalidResponse userInfo:@{ NSLocalizedDescriptionKey:@"Received a packet that is too large"}],
                         nil,
                         0
                         );
                usbmux_packet_free(upacket);
                return;
            }
            
            // Copy read bytes onto our usbmux_packet_t
            char *buffer = NULL;
            size_t buffer_size = 0;
            PT_PRECISE_LIFETIME_UNUSED dispatch_data_t map_data = dispatch_data_create_map(data, (const void **)&buffer, &buffer_size);
            assert(buffer_size == upacket->size - offset);
            memcpy(((void *)(upacket))+offset, (const void *)buffer, buffer_size);
#ifndef OS_OBJECT_USE_OBJC
            dispatch_release(map_data);
#endif
            
            //NSLogDebug(@"[PT] Received usbmux_packet: size= %u, protocol= %d, type= %d, tag= %d", upacket->size, upacket->protocol, upacket->type, upacket->tag);
            
            // We only support plist protocol
            if (upacket->protocol != USBMuxPacketProtocolPlist) {
                NSError* error = [[NSError alloc] initWithDomain:PTUSBHubErrorDomain code:PTUSBHubErrorInvalidResponse 
                                                        userInfo:@{NSLocalizedDescriptionKey: @"Unexpected package protocol"}];
                callback(error, nil, upacket->tag);
                NSLogDebug(@"[PT] Received usbmux_packet: packet protocol is not plist - protocol= %d, type= %d, tag= %d payload: %@", upacket->protocol, upacket->type, upacket->tag,  [NSData dataWithBytes:upacket length: upacket->size]);
                usbmux_packet_free(upacket);
                return;
            }
            
            // Only one type of packet in the plist protocol
            if (upacket->type != USBMuxPacketTypePlistPayload) {
                NSError* error = [[NSError alloc] initWithDomain:PTUSBHubErrorDomain code:PTUSBHubErrorInvalidResponse 
                                                        userInfo:@{NSLocalizedDescriptionKey: @"Unexpected package type"}];
                callback(error, nil, upacket->tag);
                NSLogDebug(@"[PT] Received usbmux_packet: plist packet is not of type USBMuxPacketTypePlistPayload - type= %d, tag= %d payload: %@", upacket->type, upacket->tag, [[NSString alloc] initWithData:[NSData dataWithBytes:usbmux_packet_payload(upacket) length:usbmux_packet_payload_size(upacket)]  encoding:NSUTF8StringEncoding]);
                usbmux_packet_free(upacket);
                return;
            }
            
            // Try to decode any payload as plist
            NSError *err = nil;
            NSDictionary *messagePayload = nil;
            if (usbmux_packet_payload_size(upacket) > 0) {
                messagePayload = [NSPropertyListSerialization propertyListWithData:[NSData dataWithBytesNoCopy:usbmux_packet_payload(upacket) length:usbmux_packet_payload_size(upacket) freeWhenDone:NO] options:NSPropertyListImmutable format:NULL error:&err];
            }
            
            // NSLogDebug(@"[PT] Received usbmux_packet: plist packet %@", messagePayload);
            
            // Invoke callback
            callback(err, messagePayload, upacket->tag);
            usbmux_packet_free(upacket);
        });
    });
}


- (void)sendPacketOfType:(USBMuxPacketType)type
            overProtocol:(USBMuxPacketProtocol)protocol
                     tag:(uint32_t)tag
                 payload:(NSData*)payload
                callback:(void(^)(NSError*))callback
{
    assert(payload.length <= kUsbmuxPacketMaxPayloadSize);
    usbmux_packet_t *upacket = usbmux_packet_create(
                                                    protocol,
                                                    type,
                                                    tag,
                                                    payload ? payload.bytes : nil,
                                                    (uint32_t)(payload ? payload.length : 0)
                                                    );
    dispatch_data_t data = dispatch_data_create((const void*)upacket, upacket->size, queue_, ^{
        // Free packet when data is freed
        usbmux_packet_free(upacket);
    });
    //NSData *data1 = [NSData dataWithBytesNoCopy:(void*)upacket length:upacket->size freeWhenDone:NO];
    //[data1 writeToFile:[NSString stringWithFormat:@"/Users/rsms/c-packet-%u.data", tag] atomically:NO];
    [self sendDispatchData:data callback:callback];
}


- (void)sendPacket:(NSDictionary*)packet tag:(uint32_t)tag callback:(void(^)(NSError*))callback {
    NSError *error = nil;
    // NSPropertyListBinaryFormat_v1_0
    NSData *plistData = [NSPropertyListSerialization dataWithPropertyList:packet format:NSPropertyListXMLFormat_v1_0 options:0 error:&error];
    if (!plistData) {
        callback(error);
    } else {
        [self sendPacketOfType:USBMuxPacketTypePlistPayload overProtocol:USBMuxPacketProtocolPlist tag:tag payload:plistData callback:callback];
    }
}


- (void)sendDispatchData:(dispatch_data_t)data callback:(void(^)(NSError*))callback {
    off_t offset = 0;
    dispatch_io_write(dispatchChannel_, offset, data, queue_, ^(bool done, dispatch_data_t data, int _errno) {
        //NSLogDebug(@"dispatch_io_write: done=%d data=%p error=%d", done, data, error);
        if (!done)
            return;
        if (callback) {
            NSError *err = nil;
            if (_errno) err = [[NSError alloc] initWithDomain:NSPOSIXErrorDomain code:_errno userInfo:nil];
            callback(err);
        }
    });
#ifndef OS_OBJECT_USE_OBJC
    dispatch_release(data); // Release our ref. A ref is still held by dispatch_io_write
#endif
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-getter-return-value"

- (void)sendData:(NSData*)data callback:(void(^)(NSError*))callback {
    dispatch_data_t ddata = dispatch_data_create((const void*)data.bytes, data.length, queue_, ^{
        // trick to have the block capture and retain the data
        data.length;
    });
    [self sendDispatchData:ddata callback:callback];
}

#pragma clang diagnostic pop

- (void)readFromOffset:(off_t)offset length:(size_t)length callback:(void(^)(NSError *error, dispatch_data_t data))callback {
    dispatch_io_read(dispatchChannel_, offset, length, queue_, ^(bool done, dispatch_data_t data, int _errno) {
        if (!done)
            return;
        
        NSError *error = nil;
        if (_errno != 0) {
            error = [[NSError alloc] initWithDomain:NSPOSIXErrorDomain code:_errno userInfo:nil];
        }
        
        callback(error, data);
    });
}


- (void)cancel {
    if (dispatchChannel_) {
        dispatch_io_close(dispatchChannel_, 0);
    }
}


- (void)stop {
    if (dispatchChannel_) {
        dispatch_io_close(dispatchChannel_, DISPATCH_IO_STOP);
    }
}

@end

#pragma mark -

@implementation PTAttachedDevice

- (instancetype) initWithDeviceInfo:(NSDictionary<NSString*, id>*)attachedDeviceInfo
{
    self = [super init];
    if (self != nil) {
        _deviceId = attachedDeviceInfo [@"DeviceID"];
        _deviceInfo = attachedDeviceInfo;
    }
    return self;
}

- (BOOL) isEqual:(id)object
{
    return ((self == object)
            || ([object isKindOfClass:[PTAttachedDevice class]] && [self.deviceId isEqual:((PTAttachedDevice*)object).deviceId]));
}

- (NSUInteger) hash
{
    return self.deviceId.hash;
}

@end
