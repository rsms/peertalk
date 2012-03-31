# peertalk

An iOS and OS X Cocoa library communicating over USB and TCP/IP.

Highlights:

1. Provides you with USB device attach/detach events and attached device's info

2. Can connect to TCP services on supported attached devices (e.g. an iPhone),
   bridging the communication over USB transport

3. Offers a higher-level API (PTChannel and PTProtocol) for convenient
   implementations.

4. Tested and designed for libdispatch (aka Grand Central Dispatch).


## Getting started

Suck down the code and open *peertalk.xcodeproj* in Xcode 4.3 or later on OS X 10.7 or later.

1. Select the "peertalk" target and hit Cmd+U (Product → Test) and verify that the unit tests passed.

2. Select the "Peertalk Example" target and hit Cmd+R (Product → Run). You should se a less than-pretty, standard window with some text saying it's ready. That's the OS X example app you're looking at.

3. In Xcode, select the "Peertalk iOS Example" target for the iPhone Simulator, and hit Cmd+R (Product → Run). There should be some action going on now. Try sending some messages between the OS X app and the app running in the iPhone simulator.

3. Connect your iOS device (iPhone, iPod or iPad) and kill the iPhone simulator and go back to Xcode. Select the "Peertalk iOS Example" target for your connected iOS device. Hit Cmd+R (Product → Run) to build and run the sample app on your device.

It _should_ work.


## License (MIT)

Copyright (c) 2012 Rasmus Andersson <http://rsms.me/>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
