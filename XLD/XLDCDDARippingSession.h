//
//  XLDCDDARippingSession.h
//  XLD-64
//
//  Created by tmkk on 2021/01/07.
//
//

#import <Foundation/Foundation.h>
#import "XLDCDDABackend.h"
#import "XLDCDDAResult.h"

@interface XLDCDDARippingSession : NSObject {
    NSString *devicePath;
    XLDCDDAResult *result;
    xld_cdread_t cdread;
    int offsetCorrectionValue;
    int retryCount;
    xldoffset_t firstAudioFrame;
    xldoffset_t lastAudioFrame;
    XLDRipperMode ripperMode;
    int maxRippingSpeed;
}

+ (XLDCDDARippingSession *)createSessionForDevice:(NSString *)device;
+ (XLDCDDARippingSession *)sessionForDevice:(const char *)device;
- (id)initWithDevicePath:(NSString *)device;
- (int)open;
- (void)close;
- (void)destroy;
- (XLDCDDAResult *)result;
- (void)setResult:(XLDCDDAResult *)obj;
- (BOOL)allTasksFinished;
- (xld_cdread_t *)descriptor;
- (int)offsetCorrectionValue;
- (void)setOffsetCorrectionValue:(int)value;
- (int)retryCount;
- (void)setRetryCount:(int)value;
- (xldoffset_t)firstAudioFrame;
- (void)setFirstAudioFrame:(xldoffset_t)frame;
- (xldoffset_t)lastAudioFrame;
- (void)setLastAudioFrame:(xldoffset_t)frame;
- (XLDRipperMode)ripperMode;
- (void)setRipperMode:(XLDRipperMode)mode;
- (int)maxRippingSpeed;
- (void)setMaxRippingSpeed:(int)maxSpeed;

@end
