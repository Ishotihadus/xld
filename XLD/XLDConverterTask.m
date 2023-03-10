//
//  XLDConverterTask.m
//  XLD
//
//  Created by tmkk on 07/11/14.
//  Copyright 2007 tmkk. All rights reserved.
//

#import <unistd.h>
#import "XLDConverterTask.h"
#import "XLDQueue.h"
#import "XLDOutput.h"
#import "XLDRawDecoder.h"
#import "XLDDefaultOutputTask.h"
#import "XLDCDDARipper.h"
#import "XLDAccurateRipDB.h"
#import "XLDCustomClasses.h"
#import "XLDTrackValidator.h"
#import "XLDMultipleFileWrappedDecoder.h"
#import <sys/time.h>
#import <math.h>

#define NSAppKitVersionNumber10_5 949
extern int XLDDarkModeSupportEnabled;

typedef struct {
	struct timeval tv1,tv2,tv_start;
	int lasttrack;
	xldoffset_t framesToCopy;
	xldoffset_t baseline;
	int *buffer;
	int samplesperloop;
	BOOL error;
	double speedIdx[20];
	int speedPos;
} converter_info;

static const int fontSizeForName = 13;
static const int fontSizeForStatus = 11;
static const int fontSizeForSpeed = 9;

@implementation XLDConverterTask

- (id)init
{
	[super init];
	
	encoderArray = [[NSMutableArray alloc] init];
	encoderTaskArray = [[NSMutableArray alloc] init];
	tagWritable = YES;
	compressionQuality = 0.7f;
	scaleSize = 300;
	embedImages = YES;
	
	return self;
}

- (id)initWithQueue:(id)q
{
	[self init];
	queue = [q retain];
	
	[queue setMenuForItem:progress];
	[queue setMenuForItem:statusField];
	[queue setMenuForItem:nameField];
	[queue setMenuForItem:speedField];
	[queue setMenuForItem:superview];
	
	return self;
}

- (void)dealloc
{
	//NSLog(@"task dealloc");
	//[self hideProgress];
	[nameField release];
	[statusField release];
	[speedField release];
	[progress release];
	[stopButton release];
	if(queue) [queue release];
	if(encoder) [encoder release];
	if(encoderTask) [encoderTask release];
	if(decoder) [decoder release];
	if(track) [track release];
	if(inFile) [inFile release];
	if(outDir) [outDir release];
	if(iTunesLib) [iTunesLib release];
	[rippingSession release];
	[encoderArray release];
	[encoderTaskArray release];
	if(outputPathStrArray) [outputPathStrArray release];
	if(tmpPathStr) [tmpPathStr release];
	if(tmpPathStrArray) [tmpPathStrArray release];
	if(dstPathStr) [dstPathStr release];
	if(cuePathStr) [cuePathStr release];
	if(cuePathStrArray) [cuePathStrArray release];
	if(trackListForCuesheet) [trackListForCuesheet release];
	if(config) [config release];
	if(configArray) [configArray release];
	if(discLayout) [discLayout release];
	[superview release];
	[super dealloc];
}

- (void)resizeImage:(NSData *)dat
{
	if(scaleType == XLDNoScale) return;
	
    NSBitmapImageRep *rep = nil;
    NSImage *srcImg = [[[NSImage alloc] initWithData:dat] autorelease];
    if(!srcImg || [NSImage hasOrientationTag:dat]) {
        srcImg = [NSImage imageWithDataConsideringOrientation:dat];
        if(!srcImg) return;
        rep = [NSBitmapImageRep imageRepWithData:[srcImg TIFFRepresentation]];
    }
    else {
        rep = [NSBitmapImageRep imageRepWithData:dat];
    }
    if(!rep) return;
	
	int beforeX = [rep pixelsWide];
	int beforeY = [rep pixelsHigh];
	int afterX;
	int afterY;
	
	if((scaleType&0xf) == XLDWidthScale) {
		if(!(scaleType&0x10) && (beforeX <= scaleSize)) return;
		afterY = round((double)beforeY * scaleSize/beforeX);
		afterX = scaleSize;
	}
	else if((scaleType&0xf) == XLDHeightScale) {
		if(!(scaleType&0x10) && (beforeY <= scaleSize)) return;
		afterX = round((double)beforeX * scaleSize/beforeY);
		afterY = scaleSize;
	}
	else if((scaleType&0xf) == XLDShortSideScale) {
		if(beforeX > beforeY) {
			if(!(scaleType&0x10) && (beforeY <= scaleSize)) return;
			afterX = round((double)beforeX * scaleSize/beforeY);
			afterY = scaleSize;
		}
		else {
			if(!(scaleType&0x10) && (beforeX <= scaleSize)) return;
			afterY = round((double)beforeY * scaleSize/beforeX);
			afterX = scaleSize;
		}
	}
	else if((scaleType&0xf) == XLDLongSideScale) {
		if(beforeX > beforeY) {
			if(!(scaleType&0x10) && (beforeX <= scaleSize)) return;
			afterY = round((double)beforeY * scaleSize/beforeX);
			afterX = scaleSize;
		}
		else {
			if(!(scaleType&0x10) && (beforeY <= scaleSize)) return;
			afterX = round((double)beforeX * scaleSize/beforeY);
			afterY = scaleSize;
		}
	}
	else {
		if(beforeX > beforeY) {
			if(!(scaleType&0x10) && (beforeY <= scaleSize)) return;
			afterX = scaleSize;
			afterY = scaleSize;
		}
		else {
			if(!(scaleType&0x10) && (beforeX <= scaleSize)) return;
			afterX = scaleSize;
			afterY = scaleSize;
		}
	}
	
	NSRect targetImageFrame = NSMakeRect(0,0,afterX,afterY);
    NSRect srcImageFrame;
    if((scaleType&0xf) == XLDCropToSquareScale) {
        if(beforeX > beforeY) {
            srcImageFrame = NSMakeRect(([srcImg size].width-[srcImg size].height)*0.5,0,[srcImg size].height,[srcImg size].height);
        }
        else {
            srcImageFrame = NSMakeRect(0,([srcImg size].height-[srcImg size].width)*0.5,[srcImg size].width,[srcImg size].width);
        }
    }
    else {
        srcImageFrame = NSMakeRect(0,0,[srcImg size].width,[srcImg size].height);
    }
    NSBitmapImageRep *newRep = [[NSBitmapImageRep alloc]
                                initWithBitmapDataPlanes:NULL
                                pixelsWide:afterX
                                pixelsHigh:afterY
                                bitsPerSample:8
                                samplesPerPixel:4
                                hasAlpha:YES
                                isPlanar:NO
                                colorSpaceName:NSCalibratedRGBColorSpace
                                bytesPerRow:0
                                bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:newRep]];
    [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
    [srcImg drawInRect:targetImageFrame
              fromRect:srcImageFrame
             operation:NSCompositeCopy
              fraction:1.0];
    [NSGraphicsContext restoreGraphicsState];
    NSDictionary *dic = [NSDictionary dictionaryWithObject:[NSNumber numberWithFloat:compressionQuality] forKey:NSImageCompressionFactor];
    NSData *data = [newRep representationUsingType: NSJPEGFileType properties: dic];
    [[track metadata] setObject:data forKey:XLD_METADATA_COVER];
}

- (void)hideProgress
{
	[superview removeFromSuperview];
}

- (void)prepareGUI
{
	if(guiPrepared) return;
	nameField = [[NSTextField alloc] init];
	[nameField setBordered:NO];
	[nameField setEditable:NO];
	[[nameField cell] setWraps:NO];
	[nameField setBackgroundColor:[NSColor controlColor]];
	[nameField setFont:[NSFont boldSystemFontOfSize:fontSizeForName]];
	
	statusField = [[NSTextField alloc] init];
	[statusField setBordered:NO];
	[statusField setEditable:NO];
	[[statusField cell] setWraps:NO];
	[statusField setBackgroundColor:[NSColor controlColor]];
	[statusField setTextColor:[NSColor grayColor]];
	[statusField setFont:[NSFont systemFontOfSize:fontSizeForStatus]];
	[statusField setStringValue:LS(@"Waiting")];
	
	speedField = [[NSTextField alloc] init];
	[speedField setBordered:NO];
	[speedField setEditable:NO];
	[[speedField cell] setWraps:NO];
	[speedField setBackgroundColor:[NSColor controlColor]];
	if(XLDDarkModeSupportEnabled) {
		[speedField setTextColor:[[NSColor controlTextColor] blendedColorWithFraction:0.3 ofColor:[NSColor controlBackgroundColor]]];
	} else {
		[speedField setTextColor:[NSColor darkGrayColor]];
	}
	[speedField setFont:[NSFont systemFontOfSize:fontSizeForSpeed]];
	
	progress = [[NSProgressIndicator alloc] init];
	[progress setControlSize:NSSmallControlSize];
	[progress setIndeterminate:NO];
	[progress setStyle:NSProgressIndicatorBarStyle];
	
	stopButton = [[NSButton alloc] init];
	/*[stopButton setButtonType:NSMomentaryLightButton];
	 [[stopButton cell] setControlSize:NSSmallControlSize];
	 [[stopButton cell] setBezelStyle:NSRoundedBezelStyle];
	 [stopButton setFont:[NSFont systemFontOfSize:11]];
	 [stopButton setAction:@selector(stopConvert:)];
	 [stopButton setTarget:self];
	 [stopButton setTitle:LS(@"Cancel")];*/
	[stopButton setButtonType:NSMomentaryChangeButton];
	[stopButton setImagePosition:NSImageOnly];
	[stopButton setBezelStyle:NSRegularSquareBezelStyle];
	[stopButton setBordered:NO];
	[stopButton setImage:[NSImage imageNamed:@"ExportStop"]];
	[stopButton setAlternateImage:[NSImage imageNamed:@"ExportStopPressed"]];
	[stopButton setAction:@selector(stopConvert:)];
	[stopButton setTarget:self];
	
	superview = [[XLDView alloc] init];
	NSRect frame0;
	frame0.origin.x = 0;
	frame0.origin.y = 0;
	frame0.size.width = 385;
	frame0.size.height = 40;
	NSRect frame1;
	frame1.origin.x = 10;
	frame1.origin.y = 30;
	frame1.size.width = 385;
	frame1.size.height = 19;
	NSRect frame4 = frame1;
	frame4.origin.y = 19;
	frame4.size.height = 11;
	NSRect frame2 = frame1;
	frame2.origin.y = 4;
	frame2.size.height = 13;
	frame2.size.width -= 50;
	NSRect frame3 = frame2;
	frame3.origin.x += frame2.size.width + 10;
	frame3.origin.y = 4;
	frame3.size.width = 15;
	frame3.size.height = 15;
	NSRect frame5 = frame2;
	frame5.origin.y = 11;
	
	[superview setFrame:frame0];
	[progress setFrame:frame2];
	[nameField setFrame:frame1];
	[stopButton setFrame:frame3];
	[statusField setFrame:frame5];
	[speedField setFrame:frame4];
	[progress setAutoresizingMask:NSViewWidthSizable];
	[nameField setAutoresizingMask:NSViewWidthSizable];
	[stopButton setAutoresizingMask:NSViewMinXMargin];
	[statusField setAutoresizingMask:NSViewWidthSizable];
	[speedField setAutoresizingMask:NSViewWidthSizable];
	[superview setAutoresizingMask:NSViewWidthSizable];
	if([NSCell instanceMethodForSelector:@selector(setLineBreakMode:)]) {
		[[nameField cell] setLineBreakMode:NSLineBreakByTruncatingTail];
	}
	
	[superview addSubview:statusField];
	[superview addSubview:progress];
	[superview addSubview:nameField];
	[superview addSubview:speedField];
	[superview addSubview:stopButton];
	guiPrepared = YES;
}

- (void)showProgressInView:(NSTableView *)view row:(int)row
{
	[self prepareGUI];
	NSMutableString *titleStr = [NSMutableString stringWithString:[track desiredFileName]];
	NSRange formatIndicatorRange = [titleStr rangeOfString:@"[[[XLD_FORMAT_INDICATOR]]]"];
	if(formatIndicatorRange.location != NSNotFound) {
		[titleStr replaceOccurrencesOfString:@"[[[XLD_FORMAT_INDICATOR]]]" withString:LS(@"Multiple Formats") options:0 range:NSMakeRange(0, [titleStr length])];
	}
	if(testMode) [nameField setStringValue:[NSString stringWithFormat:@"(Test) %@",titleStr]];
	else [nameField setStringValue:titleStr];
	
	position = row;
	NSRect frame1 = [view frameOfCellAtColumn:0 row:row];
	[superview setFrame:frame1];
	
	if(!running) {
		[progress setHidden:YES];
		[statusField setHidden:NO];
	}
	
	[view addSubview:superview];
}

- (void)updateStatusMessage:(NSString *)message withFont:(NSFont *)font andColor:(NSColor *)color
{
	if(color) [statusField setTextColor:color];
	if(font) [statusField setFont:font];
	[statusField setStringValue:message];
	[statusField setHidden:NO];
}

- (void)beginConvert
{
	running = YES;
	NSString *outputPathStr;
	BOOL hasFormatSeparatedDirectoryStructure = NO;
	if(encoder) {
		if(config) encoderTask = [(id <XLDOutput>)encoder createTaskForOutputWithConfigurations:config];
		else encoderTask = [(id <XLDOutput>)encoder createTaskForOutput];
	}
	else {
		int i;
		for(i=0;i<[encoderArray count];i++) {
			id tmpEncoder;
			if(configArray) tmpEncoder = [(id <XLDOutput>)[encoderArray objectAtIndex:i] createTaskForOutputWithConfigurations:[configArray objectAtIndex:i]];
			else tmpEncoder = [(id <XLDOutput>)[encoderArray objectAtIndex:i] createTaskForOutput];
			[encoderTaskArray addObject:tmpEncoder];
			[tmpEncoder release];
		}
		outputPathStrArray = [[NSMutableArray alloc] init];
	}
	
	if([NSStringFromClass(decoderClass) isEqualToString:@"XLDRawDecoder"]) 
		decoder = [[XLDRawDecoder alloc] initWithFormat:rawFmt endian:rawEndian offset:rawOffset];
	else if([NSStringFromClass(decoderClass) isEqualToString:@"XLDMultipleFileWrappedDecoder"])
		decoder = [[XLDMultipleFileWrappedDecoder alloc] initWithDiscLayout:discLayout];
	else
		decoder = [[decoderClass alloc] init];
	
	if([NSStringFromClass(decoderClass) isEqualToString:@"XLDCDDARipper"]) {
		[(XLDCDDARipper *)decoder setRipperMode:[rippingSession ripperMode]];
		[(XLDCDDARipper *)decoder setRetryCount:[rippingSession retryCount]];
		[(XLDCDDARipper *)decoder setOffsetCorrectionValue:[rippingSession offsetCorrectionValue]];
		[(XLDCDDARipper *)decoder setMaxSpeed:[rippingSession maxRippingSpeed]];
		if(testMode) [(XLDCDDARipper *)decoder setTestMode];
		if(rippingSession) {
			id obj = [[track metadata] objectForKey:XLD_METADATA_TRACK];
			if(obj) currentTrack = [obj intValue];
			else currentTrack = 0;
			totalTrack = [rippingSession result]->trackNumber;
			ripResult = [[rippingSession result] resultForIndex:currentTrack];
			if(currentTrack == 0) ripResult->parent = [rippingSession result];
		}
	}
	
	if([NSStringFromClass(decoderClass) isEqualToString:@"XLDDSDDecoder"]) {
		if([[track metadata] objectForKey:@"XLD_METADATA_DSDDecoder_Configurations"]) {
			[(id)decoder performSelector:@selector(loadConfigurations:) withObject:[[track metadata] objectForKey:@"XLD_METADATA_DSDDecoder_Configurations"]];
		}
	}
	
	if(![(id <XLDDecoder>)decoder openFile:(char *)[inFile UTF8String]]) {
		[stopButton removeFromSuperview];
		[superview setTag:1];
		[self updateStatusMessage:LS(@"Error: cannot open the input file") withFont:[NSFont boldSystemFontOfSize:fontSizeForStatus] andColor:[NSColor redColor]];
		[decoder closeFile];
		if(ripResult) ripResult->pending = YES;
		//[self hideProgress];
		[queue performSelectorOnMainThread:@selector(convertFinished:) withObject:self waitUntilDone:NO];
		return;
	}
	
	if(testMode) {
		outputPathStr = @"/dev/null";
		moveAfterFinish = NO;
	}
	else {
		NSFileManager *fm = [NSFileManager defaultManager];
		if(encoderTask) {
			NSString *desiredFilename = [track desiredFileName];
			if([desiredFilename length] > 240) {
				desiredFilename = [desiredFilename substringToIndex:239];
			}
			outputPathStr = [outDir stringByAppendingPathComponent:[desiredFilename stringByAppendingPathExtension:[encoderTask extensionStr]]];
			[fm createDirectoryWithIntermediateDirectoryInPath:[outputPathStr stringByDeletingLastPathComponent]];
			if(![fm isWritableFileAtPath:[outputPathStr stringByDeletingLastPathComponent]]) {
				[stopButton removeFromSuperview];
				[superview setTag:1];
				[self updateStatusMessage:LS(@"Error: cannot write the output file") withFont:[NSFont boldSystemFontOfSize:fontSizeForStatus] andColor:[NSColor redColor]];
				[decoder closeFile];
				if(ripResult) ripResult->pending = YES;
				//[self hideProgress];
				[queue performSelectorOnMainThread:@selector(convertFinished:) withObject:self waitUntilDone:NO];
				return;
			}
			if(processOfExistingFiles == 1) {
				if([fm fileExistsAtPath:outputPathStr]) {
					[stopButton removeFromSuperview];
					[superview setTag:1];
					[self updateStatusMessage:LS(@"Skipped: file already exists in the output path") withFont:[NSFont boldSystemFontOfSize:fontSizeForStatus] andColor:nil];
					[decoder closeFile];
					if(ripResult) ripResult->pending = YES;
					//[self hideProgress];
					[queue performSelectorOnMainThread:@selector(convertFinished:) withObject:self waitUntilDone:NO];
					return;
				}
			}
			else if(processOfExistingFiles == 0 || ([outputPathStr isEqualToString:inFile] && !removeOriginalFile)) {
				int i=1;
				while([fm fileExistsAtPath:outputPathStr]) {
					outputPathStr = [outDir stringByAppendingPathComponent:[[NSString stringWithFormat:@"%@(%d)",desiredFilename,i] stringByAppendingPathExtension:[encoderTask extensionStr]]];
					i++;
				}
			}
			else if(processOfExistingFiles == 2) {
				BOOL isDir = NO;
				if([fm fileExistsAtPath:outputPathStr isDirectory:&isDir]) {
					if(isDir) {
						[stopButton removeFromSuperview];
						[superview setTag:1];
						[self updateStatusMessage:LS(@"Error: cannot overwrite a folder with the output file") withFont:[NSFont boldSystemFontOfSize:fontSizeForStatus] andColor:[NSColor redColor]];
						[decoder closeFile];
						if(ripResult) ripResult->pending = YES;
						//[self hideProgress];
						[queue performSelectorOnMainThread:@selector(convertFinished:) withObject:self waitUntilDone:NO];
						return;
					}
				}
				if([outputPathStr isEqualToString:inFile] && removeOriginalFile) {
					moveAfterFinish = YES;
				}
			}
            else if([outputPathStr isEqualToString:inFile] && removeOriginalFile) {
                moveAfterFinish = YES;
            }
		}
		else {
			int i,j;
			for(i=0;i<[encoderTaskArray count];i++) {
				BOOL duplicatedExt = NO;
				id tmpEncoderTask = [encoderTaskArray objectAtIndex:i];
				NSString *baseName;
				NSString *outDirForThisOutput = outDir;
				NSString *desiredFilenameForThisOutput = [track desiredFileName];
				NSString *formatStr = configArray ? [[configArray objectAtIndex:i] objectForKey:@"ConfigName"] : [[[encoderArray objectAtIndex:i] class] pluginName];
				for(j=0;j<[encoderTaskArray count];j++) {
					if((i!=j) && [[tmpEncoderTask extensionStr] isEqualToString:[[encoderTaskArray objectAtIndex:j] extensionStr]]) duplicatedExt = YES;
				}
				NSRange formatIndicatorRange = [outDir rangeOfString:@"[[[XLD_FORMAT_INDICATOR]]]"];
				if(formatIndicatorRange.location != NSNotFound) {
					outDirForThisOutput = [NSMutableString stringWithString:outDir];
					[(NSMutableString *)outDirForThisOutput replaceOccurrencesOfString:@"[[[XLD_FORMAT_INDICATOR]]]" withString:formatStr options:0 range:NSMakeRange(0, [outDirForThisOutput length])];
					duplicatedExt = NO;
					hasFormatSeparatedDirectoryStructure = YES;
				}
				formatIndicatorRange = [desiredFilenameForThisOutput rangeOfString:@"[[[XLD_FORMAT_INDICATOR]]]"];
				if(formatIndicatorRange.location != NSNotFound) {
					desiredFilenameForThisOutput = [NSMutableString stringWithString:desiredFilenameForThisOutput];
					[(NSMutableString *)desiredFilenameForThisOutput replaceOccurrencesOfString:@"[[[XLD_FORMAT_INDICATOR]]]" withString:formatStr options:0 range:NSMakeRange(0, [desiredFilenameForThisOutput length])];
					duplicatedExt = NO;
					hasFormatSeparatedDirectoryStructure = YES;
				}
				if(duplicatedExt) desiredFilenameForThisOutput = [NSString stringWithFormat:@"%@(%@)",desiredFilenameForThisOutput,formatStr];
				if([desiredFilenameForThisOutput length] > 240) {
					desiredFilenameForThisOutput = [desiredFilenameForThisOutput substringToIndex:239];
				}
				
				baseName = [outDirForThisOutput stringByAppendingPathComponent:desiredFilenameForThisOutput];
				outputPathStr = [baseName stringByAppendingPathExtension:[tmpEncoderTask extensionStr]];
				[fm createDirectoryWithIntermediateDirectoryInPath:[outputPathStr stringByDeletingLastPathComponent]];
				if(![fm isWritableFileAtPath:[outputPathStr stringByDeletingLastPathComponent]]) {
					[stopButton removeFromSuperview];
					[superview setTag:1];
					[self updateStatusMessage:LS(@"Error: cannot write the output file") withFont:[NSFont boldSystemFontOfSize:fontSizeForStatus] andColor:[NSColor redColor]];
					[decoder closeFile];
					if(ripResult) ripResult->pending = YES;
					//[self hideProgress];
					[queue performSelectorOnMainThread:@selector(convertFinished:) withObject:self waitUntilDone:NO];
					return;
				}
				if(processOfExistingFiles == 1) {
					if([fm fileExistsAtPath:outputPathStr]) {
						[encoderTaskArray removeObjectAtIndex:i];
						[encoderArray removeObjectAtIndex:i];
						i--;
						continue;
					}
				}
				else if(processOfExistingFiles == 0 || ([outputPathStr isEqualToString:inFile] && !removeOriginalFile)) {
					j=1;
					while([fm fileExistsAtPath:outputPathStr]) {
						outputPathStr = [[NSString stringWithFormat:@"%@(%d)",baseName,j] stringByAppendingPathExtension:[tmpEncoderTask extensionStr]];
						j++;
					}
				}
				else if(processOfExistingFiles == 2) {
					BOOL isDir = NO;
					if([fm fileExistsAtPath:outputPathStr isDirectory:&isDir]) {
						if(isDir) {
							[stopButton removeFromSuperview];
							[superview setTag:1];
							[self updateStatusMessage:LS(@"Error: cannot overwrite a folder with the output file") withFont:[NSFont boldSystemFontOfSize:fontSizeForStatus] andColor:[NSColor redColor]];
							[decoder closeFile];
							if(ripResult) ripResult->pending = YES;
							//[self hideProgress];
							[queue performSelectorOnMainThread:@selector(convertFinished:) withObject:self waitUntilDone:NO];
							return;
						}
					}
					if([outputPathStr isEqualToString:inFile] && removeOriginalFile) {
						moveAfterFinish = YES;
					}
				}
                else if([outputPathStr isEqualToString:inFile] && removeOriginalFile) {
                    moveAfterFinish = YES;
                }
				//NSLog(outputPathStr);
				[outputPathStrArray addObject:outputPathStr];
			}
			if([encoderTaskArray count] == 0) {
				[stopButton removeFromSuperview];
				[superview setTag:1];
				[self updateStatusMessage:LS(@"Skipped: file already exists in the output path") withFont:[NSFont boldSystemFontOfSize:fontSizeForStatus] andColor:nil];
				[decoder closeFile];
				if(ripResult) ripResult->pending = YES;
				//[self hideProgress];
				[queue performSelectorOnMainThread:@selector(convertFinished:) withObject:self waitUntilDone:NO];
				return;
			}
			outputPathStr = [outputPathStrArray objectAtIndex:0];
		}
		
		if(trackListForCuesheet) {
			if(encoderTask) {
				NSString *desiredFilename = [track desiredFileName];
				if([desiredFilename length] > 240) {
					desiredFilename = [desiredFilename substringToIndex:239];
				}
				cuePathStr = [outDir stringByAppendingPathComponent:[desiredFilename stringByAppendingPathExtension:@"cue"]];
				if(processOfExistingFiles != 2 || [cuePathStr isEqualToString:inFile]) {
					int i=1;
					while([fm fileExistsAtPath:cuePathStr]) {
						cuePathStr = [outDir stringByAppendingPathComponent:[[NSString stringWithFormat:@"%@(%d)",desiredFilename,i] stringByAppendingPathExtension:@"cue"]];
						i++;
					}
				}
				[cuePathStr retain];
				
				if([NSStringFromClass(decoderClass) isEqualToString:@"XLDCDDARipper"] && rippingSession) {
					[[rippingSession result] setCuePath:cuePathStr];
					[[rippingSession result] setAppendBOM:appendBOM];
				}
			}
			else {
				int i,j;
				cuePathStrArray = [[NSMutableArray alloc] init];
				for(i=0;i<[outputPathStrArray count];i++) {
					NSString *path;
					NSString *basename;
					if(hasFormatSeparatedDirectoryStructure)
						basename = [[outputPathStrArray objectAtIndex:i] stringByDeletingPathExtension];
					else
						basename = [NSString stringWithFormat:@"%@(%@)",[[outputPathStrArray objectAtIndex:i] stringByDeletingPathExtension],[[[encoderArray objectAtIndex:i] class] pluginName]];
					path = [basename stringByAppendingPathExtension:@"cue"];
					if(processOfExistingFiles != 2 || [path isEqualToString:inFile]) {
						j=1;
						while([fm fileExistsAtPath:path]) {
							path = [[NSString stringWithFormat:@"%@(%d)",basename,j] stringByAppendingPathExtension:@"cue"];
							j++;
						}
					}
					[cuePathStrArray addObject:path];
				}
				if([NSStringFromClass(decoderClass) isEqualToString:@"XLDCDDARipper"] && rippingSession) {
					[[rippingSession result] setCuePathArray:cuePathStrArray];
					[[rippingSession result] setAppendBOM:appendBOM];
				}
			}
		}
	}
	
	if([NSStringFromClass(decoderClass) isEqualToString:@"XLDCDDARipper"] && rippingSession) {
		[(XLDCDDARipper *)decoder setResultStructure:ripResult];
		if(testMode) ripResult->testEnabled = YES;
		else {
			ripResult->enabled = YES;
			if(encoder) ripResult->filename = [outputPathStr retain];
			else ripResult->filelist = [outputPathStrArray retain];
		}
		
		XLDCDDAResult *resultObj = [rippingSession result];
		if(!testMode && [resultObj accurateRipDB] && (currentTrack > 0)) detectOffset = YES;
		if([resultObj logFileName] || [resultObj cueFileName]) {
			if(encoder) {
				if([resultObj logFileName]) [resultObj addLogDirectory:outDir];
				if([resultObj cueFileName]) [resultObj addCueDirectory:outDir withIndex:0];
			}
			else {
				int i;
				for(i=0;i<[outputPathStrArray count];i++) {
					if([resultObj logFileName]) [resultObj addLogDirectory:[[outputPathStrArray objectAtIndex:i] stringByDeletingLastPathComponent]];
					if([resultObj cueFileName]) [resultObj addCueDirectory:[[outputPathStrArray objectAtIndex:i] stringByDeletingLastPathComponent] withIndex:i];
				}
			}
		}
	}
	
	[decoder seekToFrame:index];
	if([(id <XLDDecoder>)decoder error]) {
		[stopButton removeFromSuperview];
		[superview setTag:1];
		[self updateStatusMessage:LS(@"Error: seek failure") withFont:[NSFont boldSystemFontOfSize:fontSizeForStatus] andColor:[NSColor redColor]];
		[decoder closeFile];
		//[self hideProgress];
		[queue performSelectorOnMainThread:@selector(convertFinished:) withObject:self waitUntilDone:NO];
		return;
	}
	
	/* remove cover art from track temporally */
	NSData *imgBackup = nil;
	if(!embedImages && [[track metadata] objectForKey:XLD_METADATA_COVER]) {
		imgBackup = [[[track metadata] objectForKey:XLD_METADATA_COVER] retain];
		[[track metadata] removeObjectForKey:XLD_METADATA_COVER];
	}
	
	if(tagWritable && [[track metadata] objectForKey:XLD_METADATA_COVER]) {
		[self resizeImage:[[track metadata] objectForKey:XLD_METADATA_COVER]];
		//[[[track metadata] objectForKey:XLD_METADATA_COVER] writeToFile: @"/Users/tmkk/test3.jpg" atomically: NO];
	}
	
	XLDFormat fmt;
	
	fmt.bps = [decoder bytesPerSample];
	fmt.channels = [decoder channels];
	fmt.samplerate = [decoder samplerate];
	fmt.isFloat = [decoder isFloat];
	
	if(encoderTask) {
		if(![(id <XLDOutputTask> )encoderTask setOutputFormat:fmt]) {
			if(imgBackup) {
				[[track metadata] setObject:imgBackup forKey:XLD_METADATA_COVER];
				[imgBackup release];
			}
			[encoderTask closeFile];
			[decoder closeFile];
			[stopButton removeFromSuperview];
			[superview setTag:1];
			[self updateStatusMessage:LS(@"Error: incompatible output format") withFont:[NSFont boldSystemFontOfSize:fontSizeForStatus] andColor:[NSColor redColor]];
			//[self hideProgress];
			[queue performSelectorOnMainThread:@selector(convertFinished:) withObject:self waitUntilDone:NO];
			return;
		}
		[encoderTask setEnableAddTag:tagWritable];
		dstPathStr = [outputPathStr retain];
		if(moveAfterFinish) {
			NSString *tempDir = NSTemporaryDirectory();
			NSString *filePath = [tempDir stringByAppendingPathComponent:@"xld_XXXXXX.tmp"];
			size_t bufferSize = strlen([filePath fileSystemRepresentation]) + 1;
			char *buf = (char *)malloc(bufferSize);
			[filePath getFileSystemRepresentation:buf maxLength:bufferSize];
			mkstemps(buf, 4);
			tmpPathStr = [[NSString alloc] initWithUTF8String:buf];
			free(buf);
		}
		NSString *outFile = moveAfterFinish ? tmpPathStr : outputPathStr;
		BOOL fixed = NO;
		if([track frames] == -1 && ![NSStringFromClass([decoder class]) isEqualToString:@"XLDMP3Decoder"]) {
			[track setFrames:[decoder totalFrames] - index];
			fixed = YES;
		}
		if(![encoderTask openFileForOutput:outFile withTrackData:track]) {
			if(fixed) [track setFrames:-1];
			if(imgBackup) {
				[[track metadata] setObject:imgBackup forKey:XLD_METADATA_COVER];
				[imgBackup release];
			}
			//fprintf(stderr,"error: cannot write file %s\n",[outFile UTF8String]);
			[encoderTask closeFile];
			[decoder closeFile];
			[stopButton removeFromSuperview];
			[superview setTag:1];
			[self updateStatusMessage:LS(@"Error: cannot write the output file") withFont:[NSFont boldSystemFontOfSize:fontSizeForStatus] andColor:[NSColor redColor]];
			//[self hideProgress];
			[queue performSelectorOnMainThread:@selector(convertFinished:) withObject:self waitUntilDone:NO];
			return;
		}
		if(fixed) [track setFrames:-1];
	}
	else {
		int i,fail=0;
		if(moveAfterFinish) {
			NSString *tempDir = NSTemporaryDirectory();
			tmpPathStrArray = [[NSMutableArray alloc] init];
			for(i=0;i<[encoderTaskArray count];i++) {
				NSString *filePath = [tempDir stringByAppendingPathComponent:@"xld_XXXXXX.tmp"];
				size_t bufferSize = strlen([filePath fileSystemRepresentation]) + 1;
				char *buf = (char *)malloc(bufferSize);
				[filePath getFileSystemRepresentation:buf maxLength:bufferSize];
				mkstemps(buf, 4);
				[tmpPathStrArray addObject:[NSString stringWithUTF8String:buf]];
				free(buf);
			}
		}
		NSArray *outArray = moveAfterFinish ? tmpPathStrArray : outputPathStrArray;
		BOOL fixed = NO;
		if([track frames] == -1 && ![NSStringFromClass([decoder class]) isEqualToString:@"XLDMP3Decoder"]) {
			[track setFrames:[decoder totalFrames] - index];
			fixed = YES;
		}
		for(i=0;i<[encoderTaskArray count];i++) {
			id tmpEncoderTask = [encoderTaskArray objectAtIndex:i];
			[(id <XLDOutputTask> )tmpEncoderTask setOutputFormat:fmt];
			[tmpEncoderTask setEnableAddTag:tagWritable];
			if(![tmpEncoderTask openFileForOutput:[outArray objectAtIndex:i] withTrackData:track]) {
				fprintf(stderr,"error: cannot write file %s\n",[[outArray objectAtIndex:i] UTF8String]);
				fail++;
			}
		}
		if(fixed) [track setFrames:-1];
		if(fail == [encoderTaskArray count]) {
			if(imgBackup) {
				[[track metadata] setObject:imgBackup forKey:XLD_METADATA_COVER];
				[imgBackup release];
			}
			for(i=0;i<[encoderTaskArray count];i++) [[encoderTaskArray objectAtIndex:i] closeFile];
			[decoder closeFile];
			[stopButton removeFromSuperview];
			[superview setTag:1];
			[self updateStatusMessage:LS(@"Error: cannot write the output file") withFont:[NSFont boldSystemFontOfSize:fontSizeForStatus] andColor:[NSColor redColor]];
			//[self hideProgress];
			[queue performSelectorOnMainThread:@selector(convertFinished:) withObject:self waitUntilDone:NO];
			return;
		}
	}

	if(imgBackup) {
		[[track metadata] setObject:imgBackup forKey:XLD_METADATA_COVER];
		[imgBackup release];
	}
	
	[statusField setHidden:YES];
	[progress setHidden:NO];
	[NSThread detachNewThreadSelector:@selector(convert) toTarget:self withObject:nil];
	/*NSThread *th = [[NSThread alloc] initWithTarget:self selector:@selector(convert) object:nil];
	[th setStackSize:4096*512];
	NSLog(@"stack: %d",[th stackSize]);
	[th start];
	[th release];*/
}

- (void)stopConvert:(id)sender
{
	if(running) {
		if([NSStringFromClass(decoderClass) isEqualToString:@"XLDCDDARipper"]) [decoder cancel];
		stopConvert = YES;
		[stopButton setEnabled:NO];
		return;
	}
	[self hideProgress];
	[queue convertFinished:self];
}


- (void)updateStatus
{
	if([progress isIndeterminate]) {
		[speedField setStringValue:[NSString stringWithFormat:LS(@"%.1fx realtime"),speed]];
	}
	else {
		[progress setDoubleValue:percent];
		[speedField setStringValue:[NSString stringWithFormat:LS(@"%.1f %%, %.1fx realtime, %d:%02d remaining"),percent,speed,(int)remainingMin,(int)remainingSec]];
	}
}

- (void)updateStatusMessageOnMainThread:(NSString *)message withFont:(NSFont *)font andColor:(NSColor *)color
{
	SEL selector = @selector(updateStatusMessage:withFont:andColor:);
	NSMethodSignature* signature = [self methodSignatureForSelector:selector];
	NSInvocation* invocation = [NSInvocation invocationWithMethodSignature:signature];
	[invocation setTarget:self];
	[invocation setSelector:selector];
	[invocation setArgument:(void *)&message atIndex:2];
	[invocation setArgument:(void *)&font atIndex:3];
	[invocation setArgument:(void *)&color atIndex:4];
	[invocation retainArguments];
	[invocation performSelectorOnMainThread:@selector(invoke) withObject:nil waitUntilDone:YES];
}

- (void)cleanupSubviews
{
	[progress removeFromSuperview];
	[speedField removeFromSuperview];
	[stopButton removeFromSuperview];
}

- (BOOL)writeBuffer:(int *)buffer ForMultipleTasks:(int)ret
{
	int i;
	BOOL result = YES;
	for(i=0;i<[encoderTaskArray count];i++) {
		if(![[encoderTaskArray objectAtIndex:i] writeBuffer:buffer frames:ret]) {
			fprintf(stderr,"error: cannot output sample\n");
			result = NO;
		}
	}
	return result;
}

- (void)convert
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSFileManager *fm = [NSFileManager defaultManager];
	converter_info *info = (converter_info *)malloc(sizeof(converter_info));
	info->lasttrack = 0;
	info->framesToCopy = totalFrame;
	info->buffer = (int *)malloc(8192 * [decoder channels] * 4);
	info->error = NO;
	info->speedPos = -1;
	/*
	struct timeval tv1,tv2,tv_start;
	int lasttrack = 0;
	xldoffset_t framesToCopy = totalFrame;
	xldoffset_t baseline;
	int *buffer = (int *)malloc(8192 * [decoder channels] * 4);
	int samplesperloop;
	BOOL error = NO;
	double speedIdx[20];
	int speedPos = -1;
	*/
	int i;
	//replayGainSampleCount = 0;
	speed = 0;
	
	if(encoderTask && [NSStringFromClass([encoderTask class]) isEqualToString:@"XLDAlacOutputTask"]) {
		info->samplesperloop = 2560;
	}
	else info->samplesperloop = 8192;
	if(totalFrame == -1) {
		info->lasttrack = 1;
		info->framesToCopy = [decoder totalFrames] - index;
		totalFrame = info->framesToCopy;
		//NSLog(@"%lld,%lld",totalFrame,info->framesToCopy);
	}
	else if(totalFrame == 0) {
		info->lasttrack = 1;
		[progress setIndeterminate:YES];
		[progress performSelectorOnMainThread:@selector(startAnimation:) withObject:nil waitUntilDone:NO];
	}
	
	if(detectOffset) {
		if((currentTrack != 1) && (index != [rippingSession firstAudioFrame]) && ![ripResult->validator preTrackSamplesCommitted]) {
			int *tmp = malloc(2352*4*2);
			[decoder seekToFrame:index-2352];
			[decoder decodeToBufferWithoutReport:tmp frames:2352];
			[ripResult->validator commitPreTrackSamples:tmp];
			free(tmp);
		}
	}
	
	if(fixOffset && ![NSStringFromClass(decoderClass) isEqualToString:@"XLDCDDARipper"]) {
		int *tmpbuf = (int *)calloc(30*[decoder channels],4);
		if(encoderTask) [encoderTask writeBuffer:tmpbuf frames:30 - index];
		else {
			for(i=0;i<[encoderTaskArray count];i++) [[encoderTaskArray objectAtIndex:i] writeBuffer:tmpbuf frames:30 - index];
		}
		free(tmpbuf);
	}
	
	if(offsetFixupValue > 0) {
		[decoder seekToFrame:index+offsetFixupValue];
		info->framesToCopy -= offsetFixupValue;
	}
	else if(offsetFixupValue < 0) {
		int size = 0-offsetFixupValue;
		int *tmpbuf = (int *)calloc(size*[decoder channels],4);
		if(encoderTask) [encoderTask writeBuffer:tmpbuf frames:size];
		else {
			for(i=0;i<[encoderTaskArray count];i++) [[encoderTaskArray objectAtIndex:i] writeBuffer:tmpbuf frames:size];
		}
		free(tmpbuf);
		info->framesToCopy += offsetFixupValue;
	}
	
	info->baseline = info->framesToCopy;
	gettimeofday(&info->tv1,NULL);
	gettimeofday(&info->tv_start,NULL);
	do {
		NSAutoreleasePool *pool2 = [[NSAutoreleasePool alloc] init];
		if(stopConvert) {
			if(encoderTask) {
				//[encoderTask finalize];
				[encoderTask closeFile];
				if(!testMode) {
#if MAC_OS_X_VERSION_MIN_REQUIRED < 1050
					if(moveAfterFinish) [fm removeFileAtPath:tmpPathStr handler:nil];
					else [fm removeFileAtPath:dstPathStr handler:nil];
#else
					if(moveAfterFinish) [fm removeItemAtPath:tmpPathStr error:nil];
					else [fm removeItemAtPath:dstPathStr error:nil];
#endif
				}
			}
			else {
				for(i=0;i<[encoderTaskArray count];i++) {
					//[[encoderTaskArray objectAtIndex:i] finalize];
					[[encoderTaskArray objectAtIndex:i] closeFile];
					if(!testMode) {
#if MAC_OS_X_VERSION_MIN_REQUIRED < 1050
						if(moveAfterFinish) [fm removeFileAtPath:[tmpPathStrArray objectAtIndex:i] handler:nil];
						else [fm removeFileAtPath:[outputPathStrArray objectAtIndex:i] handler:nil];
#else
						if(moveAfterFinish) [fm removeItemAtPath:[tmpPathStrArray objectAtIndex:i] error:nil];
						else [fm removeItemAtPath:[outputPathStrArray objectAtIndex:i] error:nil];
#endif
					}
				}
			}
			[pool2 release];
			goto finish;
		}
		//NSLog(@"begin decode");
		if(!info->lasttrack && info->framesToCopy < info->samplesperloop) info->samplesperloop = (int)(info->framesToCopy);
		int ret = [decoder decodeToBuffer:(int *)(info->buffer) frames:info->samplesperloop];
		if([(id <XLDDecoder>)decoder error]) {
			//fprintf(stderr,"error: cannot decode\n");
			info->error = YES;
			[self updateStatusMessageOnMainThread:LS(@"Error has occurred in the decoder") withFont:[NSFont boldSystemFontOfSize:fontSizeForStatus] andColor:[NSColor redColor]];
			[pool2 release];
			break;
		}
		//NSLog(@"%d,%d",ret,samplesperloop);
		//NSLog(@"begin output");
		if(ret > 0) {
			if(encoderTask) {
				if(![encoderTask writeBuffer:info->buffer frames:ret]) {
					//fprintf(stderr,"error: cannot output sample\n");
					info->error = YES;
					[self updateStatusMessageOnMainThread:LS(@"Error has occurred in the encoder") withFont:[NSFont boldSystemFontOfSize:fontSizeForStatus] andColor:[NSColor redColor]];
					[pool2 release];
					break;
				}
			}
			else {
				if(![self writeBuffer:info->buffer ForMultipleTasks:ret]) {
					//fprintf(stderr,"error: cannot output sample\n");
					info->error = YES;
					[self updateStatusMessageOnMainThread:LS(@"Error has occurred in the encoder") withFont:[NSFont boldSystemFontOfSize:fontSizeForStatus] andColor:[NSColor redColor]];
					[pool2 release];
					break;
				}
			}
		}
		info->framesToCopy -= ret;
		//NSLog(@"end output");
		gettimeofday(&info->tv2,NULL);
		double elapsed1 = info->tv2.tv_sec-info->tv1.tv_sec + (info->tv2.tv_usec-info->tv1.tv_usec)*0.000001;
		double elapsed2 = info->tv2.tv_sec-info->tv_start.tv_sec + (info->tv2.tv_usec-info->tv_start.tv_usec)*0.000001;
		if(elapsed1 > 0.25) {
			percent = 100.0*((double)totalFrame-(double)(info->framesToCopy))/(double)totalFrame;
			if(speed == 0.0) {
				speed = (((double)totalFrame-(double)(info->framesToCopy))/(double)[decoder samplerate]) / elapsed2;
			}
			remainingSec = round((((double)(info->framesToCopy))/(double)[decoder samplerate]) / speed);
			remainingMin = floor(remainingSec / 60.0);
			remainingSec = remainingSec - remainingMin*60;
			[self performSelectorOnMainThread:@selector(updateStatus) withObject:nil waitUntilDone:YES];
			info->tv1 = info->tv2;
		}
		if(elapsed2 > 1.0) {
			if((info->speedPos == -1) || (elapsed2 > 20)) {
				speed = (((double)(info->baseline)-(double)(info->framesToCopy))/(double)[decoder samplerate]) / elapsed2;
				for(i=0;i<20;i++) info->speedIdx[i] = speed;
				info->speedPos = 0;
			}
			else {
				info->speedIdx[info->speedPos++] = (((double)(info->baseline)-(double)(info->framesToCopy))/[decoder samplerate]) / elapsed2;
				speed = 0;
				for(i=0;i<20;i++) speed += info->speedIdx[i];
				speed /= 20.0;
				if(info->speedPos == 20) info->speedPos = 0;
			}
			info->baseline = info->framesToCopy;
			info->tv_start = info->tv2;
		}
		
		//NSLog(@"after wrote:%d,%d",ret,samplesperloop);
		if((!info->lasttrack && !info->framesToCopy) || (info->lasttrack && (ret < info->samplesperloop)) || !ret) {
			if(offsetFixupValue > 0) {
				int *tmpbuf = (int *)calloc(offsetFixupValue*[decoder channels],4);
				if(encoderTask) [encoderTask writeBuffer:tmpbuf frames:offsetFixupValue];
				else {
					for(i=0;i<[encoderTaskArray count];i++) [[encoderTaskArray objectAtIndex:i] writeBuffer:tmpbuf frames:offsetFixupValue];
				}
				free(tmpbuf);
			}
			percent = 100.0*((double)totalFrame-(double)(info->framesToCopy))/(double)totalFrame;
			[self performSelectorOnMainThread:@selector(updateStatus) withObject:nil waitUntilDone:YES];
			[pool2 release];
			break;
		}
		[pool2 release];
	} while(1);
	if(!info->error && [decoder respondsToSelector:@selector(analyzeTrackGain)]) {
		[decoder analyzeTrackGain];
		if(rippingSession && currentTrack) {
			[[rippingSession result] commitReplayGainTagForTrack:currentTrack];
		}
	}
	if(!info->error && detectOffset) {
		if((currentTrack != totalTrack) && (index+totalFrame != [rippingSession lastAudioFrame]) && ripResult->next && ripResult->next->willSkip) {
			int *tmp = malloc(2352*4*2);
			[decoder seekToFrame:index+totalFrame];
			[decoder decodeToBufferWithoutReport:tmp frames:2352];
			[ripResult->validator commitPostTrackSamples:tmp];
			free(tmp);
		}
	}
	if(encoderTask) {
		if(!info->error) [encoderTask finalize];
		[encoderTask closeFile];
		if(info->error && !testMode) {
#if MAC_OS_X_VERSION_MIN_REQUIRED < 1050
			if(moveAfterFinish) [fm removeFileAtPath:tmpPathStr handler:nil];
			else [fm removeFileAtPath:dstPathStr handler:nil];
#else
			if(moveAfterFinish) [fm removeItemAtPath:tmpPathStr error:nil];
			else [fm removeItemAtPath:dstPathStr error:nil];
#endif
		}
	}
	else {
		for(i=0;i<[encoderTaskArray count];i++) {
			if(!info->error) [[encoderTaskArray objectAtIndex:i] finalize];
			[[encoderTaskArray objectAtIndex:i] closeFile];
			if(info->error && !testMode) {
#if MAC_OS_X_VERSION_MIN_REQUIRED < 1050
				if(moveAfterFinish) [fm removeFileAtPath:[tmpPathStrArray objectAtIndex:i] handler:nil];
				else [fm removeFileAtPath:[outputPathStrArray objectAtIndex:i] handler:nil];
#else
				if(moveAfterFinish) [fm removeItemAtPath:[tmpPathStrArray objectAtIndex:i] error:nil];
				else [fm removeItemAtPath:[outputPathStrArray objectAtIndex:i] error:nil];
#endif
			}
		}
	}
	
finish:
	free(info->buffer);
	[decoder closeFile];
	if(rippingSession && [NSStringFromClass(decoderClass) isEqualToString:@"XLDCDDARipper"]) {
		if(testMode) {
			ripResult->testFinished = YES;
		}
		else {
			ripResult->finished = YES;
			if(stopConvert) ripResult->cancelled = YES;
			if(currentTrack) {
				cddaRipResult *topResult = [[rippingSession result] resultForIndex:0];
				topResult->errorCount += ripResult->errorCount;
				topResult->skipCount += ripResult->skipCount;
				topResult->edgeJitterCount += ripResult->edgeJitterCount;
				topResult->atomJitterCount += ripResult->atomJitterCount;
				topResult->droppedCount += ripResult->droppedCount;
				topResult->duplicatedCount += ripResult->duplicatedCount;
				topResult->driftCount += ripResult->driftCount;
				topResult->retrySectorCount += ripResult->retrySectorCount;
				topResult->damagedSectorCount += ripResult->damagedSectorCount;
				if(stopConvert) topResult->cancelled = YES;
			}
		}
	}
	[self performSelectorOnMainThread:@selector(cleanupSubviews) withObject:nil waitUntilDone:YES];
	if(info->error) {
		[superview setTag:1];
	}
	else if(stopConvert) {
		[superview setTag:0];
		[self updateStatusMessageOnMainThread:LS(@"Cancelled") withFont:[NSFont boldSystemFontOfSize:fontSizeForStatus] andColor:nil];
	}
	else {
#if MAC_OS_X_VERSION_MIN_REQUIRED < 1050
		if(removeOriginalFile) [fm removeFileAtPath:inFile handler:nil];
#else
		if(removeOriginalFile) [fm removeItemAtPath:inFile error:nil];
#endif
        NSMutableDictionary *attrDic = nil;
        id label = [[track metadata] objectForKey:XLD_METADATA_FINDERLABEL];
        if([[track metadata] objectForKey:XLD_METADATA_CREATIONDATE] || [[track metadata] objectForKey:XLD_METADATA_MODIFICATIONDATE]) {
            attrDic = [NSMutableDictionary dictionary];
            if([[track metadata] objectForKey:XLD_METADATA_CREATIONDATE]) {
                [attrDic setObject:[[track metadata] objectForKey:XLD_METADATA_CREATIONDATE] forKey:NSFileCreationDate];
            }
            if([[track metadata] objectForKey:XLD_METADATA_MODIFICATIONDATE]) {
                [attrDic setObject:[[track metadata] objectForKey:XLD_METADATA_MODIFICATIONDATE] forKey:NSFileModificationDate];
            }
        }
        if(encoder) {
            if(attrDic) {
#if MAC_OS_X_VERSION_MIN_REQUIRED < 1050
                if(moveAfterFinish) [fm changeFileAttributes:attrDic atPath:tmpPathStr];
                else [fm changeFileAttributes:attrDic atPath:dstPathStr];
#else
				if(moveAfterFinish) [fm setAttributes:attrDic ofItemAtPath:tmpPathStr error:nil];
				else [fm setAttributes:attrDic ofItemAtPath:dstPathStr error:nil];
#endif
            }
            if(label) {
                if(floor(NSAppKitVersionNumber) > NSAppKitVersionNumber10_5) {
                    NSURL *fileURL = moveAfterFinish ? [NSURL fileURLWithPath:tmpPathStr] : [NSURL fileURLWithPath:dstPathStr];
                    NSError *err = nil;
                    [fileURL setResourceValue:label forKey:@"NSURLLabelNumberKey" error:&err];
                }
            }
            if(moveAfterFinish) {
                [fm createDirectoryWithIntermediateDirectoryInPath:[dstPathStr stringByDeletingLastPathComponent]];
                [fm moveFileAtPath:tmpPathStr toPath:dstPathStr];
            }
            if(cuePathStr) {
                [[XLDTrackListUtil cueDataForTracks:trackListForCuesheet withFileName:[dstPathStr lastPathComponent] appendBOM:appendBOM samplerate:[decoder samplerate]] writeToFile:cuePathStr atomically:YES];
            }
            if(iTunesLib) {
                NSMutableString *filename = [NSMutableString stringWithString:dstPathStr];
                [filename replaceOccurrencesOfString:@"\\" withString:@"\\\\" options:0 range:NSMakeRange(0, [filename length])];
                [filename replaceOccurrencesOfString:@"\"" withString:@"\\\"" options:0 range:NSMakeRange(0, [filename length])];
                NSAppleScript *as = [[NSAppleScript alloc] initWithSource:[NSString stringWithFormat:iTunesLib,filename]];
                [as performSelectorOnMainThread:@selector(executeAndReturnError:) withObject:nil waitUntilDone:YES];
                [as release];
            }
        }
        else {
            for(i=0;i<[outputPathStrArray count];i++) {
                if(attrDic) {
#if MAC_OS_X_VERSION_MIN_REQUIRED < 1050
                    if(moveAfterFinish) [fm changeFileAttributes:attrDic atPath:[tmpPathStrArray objectAtIndex:i]];
                    else [fm changeFileAttributes:attrDic atPath:[outputPathStrArray objectAtIndex:i]];
#else
					if(moveAfterFinish) [fm setAttributes:attrDic ofItemAtPath:[tmpPathStrArray objectAtIndex:i] error:nil];
					else [fm setAttributes:attrDic ofItemAtPath:[outputPathStrArray objectAtIndex:i] error:nil];
#endif
                }
                if(moveAfterFinish) {
                    [fm createDirectoryWithIntermediateDirectoryInPath:[[outputPathStrArray objectAtIndex:i] stringByDeletingLastPathComponent]];
                    [fm moveFileAtPath:[tmpPathStrArray objectAtIndex:i] toPath:[outputPathStrArray objectAtIndex:i]];
                }
                if(cuePathStrArray) {
                    [[XLDTrackListUtil cueDataForTracks:trackListForCuesheet withFileName:[[outputPathStrArray objectAtIndex:i] lastPathComponent] appendBOM:appendBOM samplerate:[decoder samplerate]] writeToFile:[cuePathStrArray objectAtIndex:i] atomically:YES];
                }
                if(iTunesLib) {
                    NSRange formatIndicatorRange = [iTunesLib rangeOfString:@"[[[XLD_FORMAT_INDICATOR]]]"];
                    id scpt = iTunesLib;
                    if(formatIndicatorRange.location != NSNotFound) {
                        scpt = [NSMutableString stringWithString:iTunesLib];
                        NSMutableString *formatStr = [NSMutableString stringWithString:configArray ? [[configArray objectAtIndex:i] objectForKey:@"ConfigName"] : [[[encoderArray objectAtIndex:i] class] pluginName]];
                        [formatStr replaceOccurrencesOfString:@"\\" withString:@"\\\\" options:0 range:NSMakeRange(0, [formatStr length])];
                        [formatStr replaceOccurrencesOfString:@"\"" withString:@"\\\"" options:0 range:NSMakeRange(0, [formatStr length])];
                        [formatStr replaceOccurrencesOfString:@"%" withString:@"%%" options:0 range:NSMakeRange(0, [formatStr length])];
                        [scpt replaceOccurrencesOfString:@"[[[XLD_FORMAT_INDICATOR]]]" withString:formatStr options:0 range:NSMakeRange(0, [scpt length])];
                    }
                    NSMutableString *filename = [NSMutableString stringWithString:[outputPathStrArray objectAtIndex:i]];
                    [filename replaceOccurrencesOfString:@"\\" withString:@"\\\\" options:0 range:NSMakeRange(0, [filename length])];
                    [filename replaceOccurrencesOfString:@"\"" withString:@"\\\"" options:0 range:NSMakeRange(0, [filename length])];
                    NSAppleScript *as = [[NSAppleScript alloc] initWithSource:[NSString stringWithFormat:scpt,filename]];
                    [as performSelectorOnMainThread:@selector(executeAndReturnError:) withObject:nil waitUntilDone:YES];
                    [as release];
                }
            }
        }
		[superview setTag:0];
		[self updateStatusMessageOnMainThread:LS(@"Completed") withFont:[NSFont boldSystemFontOfSize:fontSizeForStatus] andColor:[NSColor colorWithCalibratedRed:0.25 green:0.35 blue:0.7 alpha:1]];
	}
	//[self hideProgress];
	[queue performSelectorOnMainThread:@selector(convertFinished:) withObject:self waitUntilDone:NO];
	free(info);
	[pool release];
}

- (void)setFixOffset:(BOOL)flag
{
	fixOffset = flag;
}

- (void)setIndex:(xldoffset_t)idx
{
	index = idx;
}

- (void)setTotalFrame:(xldoffset_t)frame
{
	totalFrame = frame;
}

- (void)setDecoderClass:(Class)dec
{
	decoderClass = dec;
}

- (void)setEncoder:(id)enc withConfiguration:(NSDictionary*)cfg
{
	[encoderArray removeAllObjects];
	if(encoder) [encoder release];
	if(config) [config release];
	if(configArray) [configArray release];
	configArray = nil;
	
	encoder = [enc retain];
	if(cfg) {
		config = [cfg retain];
	}
	else config = nil;
}

- (void)setEncoders:(id)enc withConfigurations:(NSArray*)cfg
{
	if(encoder) [encoder release];
	if(config) [config release];
	if(configArray) [configArray release];
	encoder = nil;
	config = nil;
	
	[encoderArray removeAllObjects];
	[encoderArray addObjectsFromArray:enc];
	if(cfg) {
		configArray = [cfg retain];
	}
	else configArray = nil;
}

- (void)setRawFormat:(XLDFormat)fmt
{
	rawFmt = fmt;
}

- (void)setRawEndian:(XLDEndian)e
{
	rawEndian = e;
}

- (void)setRawOffset:(int)offset
{
	rawOffset = offset;
}

- (void)setInputPath:(NSString *)path
{
	if(inFile) [inFile release];
	inFile = [path retain];
}

- (NSString *)outputDir
{
	return outDir;
}

- (void)setOutputDir:(NSString *)path
{
	if(outDir) [outDir release];
	outDir = [path retain];
}

- (void)setTagWritable:(BOOL)flag
{
	tagWritable = flag;
}

- (void)setTrack:(XLDTrack *)t
{
	if(track) [track release];
	track = [t retain];
}

- (BOOL)isActive
{
	return running;
}

- (void)setScaleType:(XLDScaleType)type
{
	scaleType = type;
}

- (void)setCompressionQuality:(float)quality
{
	compressionQuality = quality;
}

- (void)setScaleSize:(int)pixel
{
	scaleSize = pixel;
}

- (void)setiTunesLib:(NSString *)lib withAppName:(NSString *)appName
{
	if(iTunesLib) {
		[iTunesLib release];
		iTunesLib = nil;
	}
	if(!lib || [lib isEqualToString:@""]) return;
	
	NSMutableString *library = [NSMutableString stringWithString:lib];
	[library replaceOccurrencesOfString:@"\\" withString:@"\\\\" options:0 range:NSMakeRange(0, [library length])];
	[library replaceOccurrencesOfString:@"\"" withString:@"\\\"" options:0 range:NSMakeRange(0, [library length])];
	[library replaceOccurrencesOfString:@"%" withString:@"%%" options:0 range:NSMakeRange(0, [library length])];
	if(!appName) appName = floor(NSAppKitVersionNumber) < 1862 ? @"iTunes" : @"Music";
	
	if([library isEqualToString:@"library playlist 1"]) {
		iTunesLib = [[NSString alloc] initWithFormat:@"\
					 tell application \"%@\" \n \
					 add ((POSIX file(\"%%@\")) as alias) to %@ \n \
					 end tell"
					 ,appName,library];
	}
	else {
		iTunesLib = [[NSString alloc] initWithFormat:@"\
					 tell application \"%@\" \n \
					 if (exists playlist \"%@\") is false then \n \
					 make new user playlist with properties {name:\"%@\"} \n \
					 end if \n \
					 add ((POSIX file(\"%%@\")) as alias) to playlist \"%@\" \n \
					 end tell"
					 ,appName,library,library,library];
	}
	//NSLog(@"%@",iTunesLib);
}

- (BOOL)isAtomic
{
	return [NSStringFromClass(decoderClass) isEqualToString:@"XLDCDDARipper"];
	//return NO;
}
/*
- (void)setMountOnEnd
{
	mountOnEnd = YES;
}
*/

- (void)setTrackListForCuesheet:(NSArray *)tracks appendBOM:(BOOL)flag
{
	if(trackListForCuesheet) [trackListForCuesheet release];
	trackListForCuesheet = [tracks retain];
	appendBOM = flag;
}

- (void)setCDDARippingSession:(id)obj
{
	if(rippingSession) [rippingSession release];
	rippingSession = [obj retain];
}

- (XLDCDDARippingSession *)rippingSession;
{
	return rippingSession;
}

- (void)setTestMode
{
	testMode = YES;
}

- (void)setOffsetFixupValue:(int)value
{
	offsetFixupValue = value;
}

- (NSView *)progressView
{
	[self prepareGUI];
	return superview;
}

- (int)position
{
	return position;
}

- (void)setProcessOfExistingFiles:(int)value
{
	processOfExistingFiles = value;
}

- (void)setEmbedImages:(BOOL)flag
{
	embedImages = flag;
}

- (void)setMoveAfterFinish:(BOOL)flag
{
	moveAfterFinish = flag;
}

- (void)setRemoveOriginalFile:(BOOL)flag
{
	removeOriginalFile = flag;
}

- (void)setDiscLayout:(XLDDiscLayout *)layout
{
	discLayout = [layout retain];
}

- (void)taskSelected
{
	[nameField setTextColor:[NSColor selectedControlTextColor]];
}

- (void)taskDeselected
{
	[nameField setTextColor:[NSColor controlTextColor]];
}

- (cddaRipResult *)cddaRipResult
{
	return ripResult;
}

@end
