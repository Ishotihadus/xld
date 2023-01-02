//
//  XLDConverterTask.h
//  XLD
//
//  Created by tmkk on 07/11/14.
//  Copyright 2007 tmkk. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import "XLDTrack.h"
#import "XLDCustomClasses.h"
#import "XLDDiscLayout.h"
#import "XLDCDDAResult.h"
#import "XLDCDDARippingSession.h"

@interface XLDConverterTask : NSObject {
	id encoder;
	Class decoderClass;
	id encoderTask;
	id decoder;
	NSMutableArray *encoderArray;
	NSMutableArray *encoderTaskArray;
	NSDictionary *config;
	NSArray *configArray;
	XLDTrack *track;
	NSString *inFile;
	NSString *outDir;
	xldoffset_t index;
	xldoffset_t totalFrame;
	BOOL fixOffset;
	BOOL tagWritable;
	XLDFormat rawFmt;
	XLDEndian rawEndian;
	int rawOffset;
	int processOfExistingFiles;
	BOOL embedImages;
	
	BOOL running;
	BOOL stopConvert;
	
	NSProgressIndicator *progress;
	NSButton *stopButton;
	NSTextField *nameField;
	NSTextField *statusField;
	NSTextField *speedField;
	BOOL guiPrepared;
	
	id queue;
	XLDScaleType scaleType;
	float compressionQuality;
	int scaleSize;
	NSString *iTunesLib;
	//BOOL mountOnEnd;
	XLDCDDARippingSession *rippingSession;
	int defeatPower;
	BOOL testMode;
	int offsetFixupValue;
	BOOL detectOffset;
	int currentTrack;
	int totalTrack;
	
	double percent;
	double speed;
	double remainingSec;
	double remainingMin;
	BOOL useOldEngine;
	BOOL useC2Pointer;
	XLDView *superview;
	int position;
	
	BOOL appendBOM;
	BOOL moveAfterFinish;
	NSString *tmpPathStr;
	NSString *dstPathStr;
	NSString *cuePathStr;
	NSMutableArray *outputPathStrArray;
	NSMutableArray *tmpPathStrArray;
	NSMutableArray *cuePathStrArray;
	NSArray *trackListForCuesheet;
	BOOL removeOriginalFile;
	XLDDiscLayout *discLayout;
	cddaRipResult *ripResult;
}

- (id)initWithQueue:(id)q;
- (void)beginConvert;
- (void)stopConvert:(id)sender;
- (void)showProgressInView:(NSTableView *)view row:(int)row;
- (void)hideProgress;
- (void)setFixOffset:(BOOL)flag;
- (void)setIndex:(xldoffset_t)idx;
- (void)setTotalFrame:(xldoffset_t)frame;
- (void)setDecoderClass:(Class)dec;
- (void)setEncoder:(id)enc withConfiguration:(NSDictionary*)cfg;
- (void)setEncoders:(id)enc withConfigurations:(NSArray*)cfg;
- (void)setRawFormat:(XLDFormat)fmt;
- (void)setRawEndian:(XLDEndian)e;
- (void)setRawOffset:(int)offset;
- (void)setInputPath:(NSString *)path;
- (NSString *)outputDir;
- (void)setOutputDir:(NSString *)path;
- (void)setTagWritable:(BOOL)flag;
- (void)setTrack:(XLDTrack *)t;
- (void)setScaleType:(XLDScaleType)type;
- (void)setCompressionQuality:(float)quality;
- (void)setScaleSize:(int)pixel;
- (BOOL)isActive;
- (void)setiTunesLib:(NSString *)lib withAppName:(NSString *)appName;
- (BOOL)isAtomic;
//- (void)setMountOnEnd;
- (void)setTrackListForCuesheet:(NSArray *)tracks appendBOM:(BOOL)flag;
- (void)setCDDARippingSession:(id)obj;
- (XLDCDDARippingSession *)rippingSession;
- (void)setTestMode;
- (void)setOffsetFixupValue:(int)value;
- (NSView *)progressView;
- (int)position;
- (void)setProcessOfExistingFiles:(int)value;
- (void)setEmbedImages:(BOOL)flag;
- (void)setMoveAfterFinish:(BOOL)flag;
- (void)setRemoveOriginalFile:(BOOL)flag;
- (void)setDiscLayout:(XLDDiscLayout *)layout;
- (void)taskSelected;
- (void)taskDeselected;
- (cddaRipResult *)cddaRipResult;
@end
