//
//  XLDCDDARippingSession.m
//  XLD-64
//
//  Created by Taihei Momma on 2021/01/07.
//
//

#import "XLDCDDARippingSession.h"

static NSMutableDictionary *sessions;

@implementation XLDCDDARippingSession

+ (void)initialize
{
    if (!sessions) sessions = [[NSMutableDictionary alloc] init];
}

+ (XLDCDDARippingSession *)createSessionForDevice:(NSString *)device
{
    XLDCDDARippingSession *session = [[XLDCDDARippingSession alloc] initWithDevicePath:device];
    [sessions setObject:session forKey:device];
    return [session autorelease];
}

+ (XLDCDDARippingSession *)sessionForDevice:(const char *)device
{
    return [sessions objectForKey:[NSString stringWithUTF8String:device]];
}

- (id)initWithDevicePath:(NSString *)device
{
    self = [super init];
    if (self) {
        devicePath = [device retain];
        retryCount = 20;
    }
    return self;
}

- (void)dealloc
{
    [devicePath release];
    [super dealloc];
}

- (int)open
{
    if (cdread.opened) return cdread.fd;
    if (xld_cdda_open(&cdread, [devicePath UTF8String]) != 0) return -1;
    return cdread.fd;
}

- (void)close
{
    xld_cdda_close(&cdread);
}

- (void)destroy
{
    xld_cdda_close(&cdread);
    [sessions removeObjectForKey:devicePath];
}

- (XLDCDDAResult *)result
{
    return result;
}

- (void)setResult:(XLDCDDAResult *)obj
{
    result = [obj retain];
}

- (BOOL)allTasksFinished
{
    return [result allTasksFinished];
}

- (xld_cdread_t *)descriptor
{
    return &cdread;
}

- (int)offsetCorrectionValue
{
    return offsetCorrectionValue;
}

- (void)setOffsetCorrectionValue:(int)value
{
    offsetCorrectionValue = value;
}

- (int)retryCount
{
    return retryCount;
}

- (void)setRetryCount:(int)value
{
    retryCount = value;
}

- (xldoffset_t)firstAudioFrame
{
    return firstAudioFrame;
}

- (void)setFirstAudioFrame:(xldoffset_t)frame
{
    firstAudioFrame = frame;
}

- (xldoffset_t)lastAudioFrame
{
    return lastAudioFrame;
}

- (void)setLastAudioFrame:(xldoffset_t)frame
{
    lastAudioFrame = frame;
}

- (XLDRipperMode)ripperMode
{
    return ripperMode;
}

- (void)setRipperMode:(XLDRipperMode)mode
{
    ripperMode = mode;
}

- (int)maxRippingSpeed
{
    return maxRippingSpeed;
}

- (void)setMaxRippingSpeed:(int)maxSpeed
{
    maxRippingSpeed = maxSpeed;
}

@end
