#ifndef peertalk_PTExampleProtocol_h
#define peertalk_PTExampleProtocol_h

#import <Foundation/Foundation.h>
#include <stdint.h>

static const int PTExampleProtocolIPv4PortNumber = 2345;

enum {
  PTExampleFrameTypeDeviceInfo = 100,
  PTExampleFrameTypeTextMessage = 101,
  PTExampleFrameTypePing = 102,
  PTExampleFrameTypePong = 103,
};

#endif
