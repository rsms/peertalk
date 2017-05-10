//
//  PTHostnameProvider.m
//
// Copyright (c) 2017 Jean-Luc Jumpertz 
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

#import <Foundation/Foundation.h>

#import "PTHostnameProvider.h"

#include <sys/ioctl.h>
#include <sys/un.h>
#include <err.h>
#include <fcntl.h>
#include <arpa/inet.h>
#import <objc/runtime.h>

#if TARGET_OS_IPHONE
#import <UIKit/UIApplication.h>
#endif

@implementation PTHostNameProvider
{
    dispatch_source_t _dispatchSource;
    dispatch_queue_t _handlerQueue;
}

static PTHostNameProvider* _hostnameProvider = nil;

+ (void) start;
{
    if (_hostnameProvider == nil) {
        _hostnameProvider = [PTHostNameProvider new];
    }
}

- (instancetype) init 
{
    self = [super init];
    if (self != nil) {
        
        _handlerQueue = dispatch_queue_create("com.celedev.CIMP2P.PTHostNameProvider", DISPATCH_QUEUE_SERIAL);
        
#if TARGET_OS_IPHONE
        // In iOS, monitor the applications state notification and suspend / resume the advertising for the P2P connection as appropriate
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleApplicationWillEnterForeground:)
                                                     name:UIApplicationWillEnterForegroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleApplicationDidEnterBackground:)
                                                     name:UIApplicationDidEnterBackgroundNotification object:nil];
        
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateBackground) {
            
            [self startHostnameServer];
        }
#else
        [self startHostnameServer];
#endif
    }
    return self;
}

- (void) handleApplicationWillEnterForeground:(NSNotification*)notification
{
    [self startHostnameServer];
}

- (void) handleApplicationDidEnterBackground:(NSNotification*)notification
{
    [self stopListening];
}

- (void) startHostnameServer
{
    [self listenOnPort:kPTHostnameProviderPort IPv4Address:INADDR_LOOPBACK withConnectionHandler:^(dispatch_io_t acceptedConnectionChannel) {
        
        // Send a single message on the channel and close it
        [self sendHostnameMessageOnChannel:acceptedConnectionChannel withCompletion:^(NSError *error) {
            
            dispatch_io_close(acceptedConnectionChannel, 0);
        }];
        
    } error:NULL];
}

- (void) sendHostnameMessageOnChannel:(dispatch_io_t)dispatchChannel withCompletion:(void(^)(NSError* error))completion
{
    // Get the host name
    const int kMaxHostNameSize = 255;
    char hostName[kMaxHostNameSize + 8]; // Room to append ".local." and trailing null char
    if (gethostname(hostName, kMaxHostNameSize) == 0) {
        hostName[kMaxHostNameSize] = '\0';
        strcat(hostName, ".local.");
    }
    else {
        hostName[0] = '\0';
    }
    
    // Build and send the message
    
    size_t hostNameLength = strlen(hostName);
    if (hostNameLength > 0) {
        size_t messageSize = kPTHostnameProviderResponseOffsetHostname + hostNameLength + 1;
        char* messageBytes = malloc(messageSize);
        messageBytes [0] = (messageSize >> 8) & 0xff;
        messageBytes [1] = messageSize & 0xff;
        memcpy(&messageBytes[kPTHostnameProviderResponseOffsetMagicString], kPTHostnameProviderResponseMagicString, strlen(kPTHostnameProviderResponseMagicString));
        strcpy(&messageBytes[kPTHostnameProviderResponseOffsetHostname], hostName);
        
        dispatch_data_t messageData = dispatch_data_create(messageBytes, messageSize, _handlerQueue, DISPATCH_DATA_DESTRUCTOR_FREE);
        
        dispatch_io_write(dispatchChannel, 0, messageData, _handlerQueue, ^(bool done, dispatch_data_t  _Nullable data, int errorNum) {
            if (done) {
                NSError* writeError = nil;
                if (errorNum != 0) {
                    writeError = [[NSError alloc] initWithDomain:NSPOSIXErrorDomain code:errorNum userInfo:nil];
                }
                completion (writeError);
            }
        });
    }
    else {
        // No host name
        completion(nil);
    }
}

- (BOOL) listenOnPort:(in_port_t)port IPv4Address:(in_addr_t)address withConnectionHandler:(void(^)(dispatch_io_t acceptedConnectionChannel))handler error:(NSError**)error
{
    NSError* listenError = nil;
    
    if (_dispatchSource != nil) {
        [self stopListening];
    }
    
    // Create socket
    dispatch_fd_t fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd == -1) {
        listenError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
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
    
    if ((listenError == nil) && (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on)) == -1)) {
        listenError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    }
    
    if ((listenError == nil) && (fcntl(fd, F_SETFL, O_NONBLOCK) == -1)) {
        listenError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    }
    
    if ((listenError == nil) && (bind(fd, (struct sockaddr*)&addr, socklen) != 0)) {
        listenError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    }
    
    if ((listenError == nil) && (listen(fd, 512) != 0)) {
        listenError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    }
    
    if (listenError == nil) {
        _dispatchSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, _handlerQueue);
        
        dispatch_source_set_event_handler(_dispatchSource, ^{
            unsigned long nconns = dispatch_source_get_data(_dispatchSource);
            while ([self acceptIncomingConnectionOnServerSocket:fd withHandler:handler] && --nconns);
        });
        
        dispatch_source_set_cancel_handler(_dispatchSource, ^{
            // Captures *self*, effectively holding a reference to *self* until cancelled.
            _dispatchSource = nil;
            close(fd);
        });
        
        dispatch_resume(_dispatchSource);
        //NSLog(@"%@ opened on fd #%d", self, fd);
    }
    
    if (listenError != nil) {
        if (fd != -1) {
            close(fd);
        }
        if (error != NULL) {
            *error = listenError;
        }
    }
    return (listenError == nil);
}

- (BOOL) stopListening
{
    BOOL wasStopNeeded = NO;
    
    if (_dispatchSource != nil) {
        dispatch_source_cancel(_dispatchSource);
        _dispatchSource = nil;
        wasStopNeeded = YES;
    }
    return wasStopNeeded;
}

- (BOOL) acceptIncomingConnectionOnServerSocket:(dispatch_fd_t)serverSocketFD withHandler:(void(^)(dispatch_io_t acceptedConnectionChannel))handler
{
    BOOL isConnectionAccepted = YES;
    
    struct sockaddr_in addr;
    socklen_t addrLen = sizeof(addr);
    dispatch_fd_t clientSocketFD = accept(serverSocketFD, (struct sockaddr*)&addr, &addrLen);
    
    isConnectionAccepted = (clientSocketFD != -1);
    
    if (isConnectionAccepted) {
        // prevent SIGPIPE
        int on = 1;
        setsockopt(clientSocketFD, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
        
        if (fcntl(clientSocketFD, F_SETFL, O_NONBLOCK) == -1) {
            close(clientSocketFD);
            isConnectionAccepted = NO;
        }
    }
    
    if (isConnectionAccepted) {
        
        dispatch_io_t acceptedConnectionChannel = dispatch_io_create(DISPATCH_IO_STREAM, clientSocketFD, _handlerQueue, ^(int error) {
            close(clientSocketFD);
        });
        
        if (acceptedConnectionChannel != nil) {
            handler (acceptedConnectionChannel);
        }
    }
 
    return isConnectionAccepted;
}


@end
