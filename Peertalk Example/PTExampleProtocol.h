#ifndef peertalk_PTExampleProtocol_h
#define peertalk_PTExampleProtocol_h

#import <Foundation/Foundation.h>
#include <stdint.h>

static const int PTExampleProtocolIPv4PortNumber = 2345;

enum {
  PTExampleFrameTypeDeviceInfo = 100,
  PTExampleFrameTypeTextMessage = 101,
};

typedef struct _PTExampleTextFrame {
  const uint8_t *utf8text;
} PTExampleTextFrame;


#endif
