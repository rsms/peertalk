# peertalk

PeerTalk is an iOS and Mac Cocoa library for communicating over USB.

    
                             ┌──────────────────────────────┐
                             │ ┌──────────────────────────┐ │
                             │ │                          │ │
      ┌─────────┐            │ │                          │ │
      │┌───────┐│            │ │          Hello           │ │
      ││       ││            │ │                          │ │
      ││ Hello ││            │ │                          │ │
      ││       ││            │ │                          │ │
      │└───────┘│            │ └──────────────────────────┘ │
      │    ⃝    │            \  ─────────────────────────── \
      └────╦────┘             \  \ \ \ \ \ \ \ \ \ \ \ \ \ \ \
           ║         ╔══════════■ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \
           ╚═════════╝          \  ─────────────────────────── \
          - meep -               └─────────────────────────────┘
             - beep -
    

#### Highlights

1. Provides you with USB device attach/detach events and attached device's info

2. Can connect to TCP services on supported attached devices (e.g. an iPhone),
   bridging the communication over USB transport

3. Offers a higher-level API (PTChannel and PTProtocol) for convenient
   implementations.

4. Tested and designed for libdispatch (aka Grand Central Dispatch).

5. Now compatible with Bonjour® services and NSStream-based programs

Grab the goods from [https://github.com/rsms/peertalk](https://github.com/rsms/peertalk)


### Usage in Apple App Store

PeerTalk has successfully been released on both the iOS and OS X app store.

A great example is [Duet Display](http://www.duetdisplay.com/) which is a fantastic piece of software allowing you to use your iDevice as an extra display for your Mac using the Lightning or 30-pin cable.

Facebook's [Origami](http://facebook.github.io/origami/) uses PeerTalk for it's Origami Live iOS app (in fact, this is where PeerTalk was first used, back in 2012)

This *probably* means that you can use PeerTalk for apps aiming at the App Store.

## Getting started

Suck down the code and open *peertalk.xcodeproj* in Xcode 4.3 or later on OS X 10.7 or later.

1. Select the "peertalk" target and hit Cmd+U (Product → Test) and verify that the unit tests passed.

2. Select the "Peertalk Example" target and hit Cmd+R (Product → Run). You should se a less than-pretty, standard window with some text saying it's ready. That's the OS X example app you're looking at.

3. In Xcode, select the "Peertalk iOS Example" target for the iPhone Simulator, and hit Cmd+R (Product → Run). There should be some action going on now. Try sending some messages between the OS X app and the app running in the iPhone simulator.

3. Connect your iOS device (iPhone, iPod or iPad) and kill the iPhone simulator and go back to Xcode. Select the "Peertalk iOS Example" target for your connected iOS device. Hit Cmd+R (Product → Run) to build and run the sample app on your device.

It _should_ work.

Demo video: [http://www.youtube.com/watch?v=kQPWy8N0mBg](http://www.youtube.com/watch?v=kQPWy8N0mBg)

<iframe width="880" height="530" src="http://www.youtube.com/embed/kQPWy8N0mBg?hd=1&amp;rel=0" frameborder="0" allowfullscreen></iframe>

## Using peertalk with Bonjour

Peertalk can now be used to connect from a macOS application to a Bonjour service running on a USB-attached iOS device. It only involves a small modification of your existing Bonjour code.

When you want to connect to a Bonjour service, you generally use a `NSNetService` object associated with a class implementing the `NSNetServiceDelegate`protocol. Then you *resolve* the Bonjour service:

````
// self implements the NSNetServiceDelegate protocol
NSString *serviceName = ...;
NSString *serviceType = @"_music._tcp"; // or any custom service type prided by your iOS app
NSNetService *service;
 
service = [[NSNetService alloc] initWithDomain:@"local." type: serviceType name:serviceName];
service.delegate = self;
[service resolveWithTimeout:5.0];
````

Then you implement the delegate method `netServiceDidResolveAddress`:

````
- (void)netServiceDidResolveAddress:(NSNetService *)netService
{
    // netService has been succesfuly resolved, its hostname and port are now set
    
    // First try to connect to the service using a USB link
    [PTUSBHub.sharedHub connectToDeviceWithHostName: netService.hostName port:(int)netService.port 
                                            onStart:^(NSError *error, NSInputStream *inStream, NSOutputStream *outStream) {
        
        if ((inStream == nil) || (outStream == nil)) {
            // USB connection did not succeed or was not supported: connect to the resolved service via standard Bonjour mechanism
            [netService getInputStream:&inStream outputStream:&outStream];
        }
        
        if ((inStream != nil) && (outStream != nil)) {
            // ... Use the NSStreams for communicating with the service
        }
    }];
    
}
````

### In the iOS app providing the Bonjour service

For this mechanism to work, **peertalk** needs a way to know the Bonjour hostname of the USB-connected iOS device providing the Bonjour service.

This is achieved by running a `PTHostNameProvider` in your iOS application, typically in the AppDelegate:

````
#import "AppDelegate.h"
#import "PTHostnameProvider.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

  [PTHostNameProvider start];
  
  // Other inits ...
  return YES;
}

// ...

@end

````

