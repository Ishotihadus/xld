
# define FloatToUnsigned(f)	((unsigned int)(((int)((f) - 2147483648.0)) + 2147483647 + 1))

#import <Foundation/Foundation.h>
#import <objc/objc-runtime.h>
#import <sndfile.h>
#import <unistd.h>
#import <sys/stat.h>
#import <getopt.h>
#import "XLDDecoder.h"
#import "XLDOutput.h"
#import "XLDOutputTask.h"
#import "XLDTrack.h"
#import "XLDRawDecoder.h"
#import "XLDCueParser.h"
#import "XLDDDPParser.h"
#import "XLDecoderCenter.h"
#import "XLDPluginManager.h"
#import "XLDDefaultOutputTask.h"
#import "XLDProfileManager.h"
#import "XLDLogChecker.h"
#import "XLDAccurateRipChecker.h"
#import "XLDMultipleFileWrappedDecoder.h"
#import "XLDCustomClasses.h"

/*
static OSStatus (*_LSSetApplicationInformationItem)(int, CFTypeRef asn, CFStringRef key, CFStringRef value, CFDictionaryRef *info) = NULL;
static CFTypeRef (*_LSGetCurrentApplicationASN)(void) = NULL;
static CFStringRef _kLSApplicationTypeKey = NULL;
static CFStringRef _kLSApplicationUIElementTypeKey = NULL;

static CFStringRef launchServicesKey(const char *symbol)
{
	CFStringRef *keyPtr = dlsym(RTLD_DEFAULT, symbol);
	return keyPtr ? *keyPtr : NULL;
}
*/

static void ConvertToIeeeExtended(double num, char* bytes)
{
	int    sign;
	int expon;
	double fMant, fsMant;
	unsigned int hiMant, loMant;
	
	if (num < 0) {
		sign = 0x8000;
		num *= -1;
	} else {
		sign = 0;
	}
	
	if (num == 0) {
		expon = 0; hiMant = 0; loMant = 0;
	}
	else {
		fMant = frexp(num, &expon);
		if ((expon > 16384) || !(fMant < 1)) {    /* Infinity or NaN */
			expon = sign|0x7FFF; hiMant = 0; loMant = 0; /* infinity */
		}
		else {    /* Finite */
			expon += 16382;
			if (expon < 0) {    /* denormalized */
				fMant = ldexp(fMant, expon);
				expon = 0;
			}
			expon |= sign;
			fMant = ldexp(fMant, 32);          
			fsMant = floor(fMant); 
			hiMant = FloatToUnsigned(fsMant);
			fMant = ldexp(fMant - fsMant, 32); 
			fsMant = floor(fMant); 
			loMant = FloatToUnsigned(fsMant);
		}
	}
	
	bytes[0] = expon >> 8;
	bytes[1] = expon;
	bytes[2] = hiMant >> 24;
	bytes[3] = hiMant >> 16;
	bytes[4] = hiMant >> 8;
	bytes[5] = hiMant;
	bytes[6] = loMant >> 24;
	bytes[7] = loMant >> 16;
	bytes[8] = loMant >> 8;
	bytes[9] = loMant;
}

static void writeWavHeader(int bps, int channels, int samplerate, int isFloat, unsigned int frames, FILE *fp)
{
	unsigned int tmp1;
	unsigned short tmp2;
	fwrite("RIFF", 1, 4, fp);
	tmp1 = NSSwapHostIntToLittle(frames*bps*channels+36);
	fwrite(&tmp1, 4, 1, fp);
	fwrite("WAVE", 1, 4, fp);
	fwrite("fmt ", 1, 4, fp);
	tmp1 = NSSwapHostIntToLittle(16);
	fwrite(&tmp1, 4, 1, fp);
	tmp2 = isFloat ? 3 : 1;
	tmp2 = NSSwapHostShortToLittle(tmp2);
	fwrite(&tmp2, 2, 1, fp);
	tmp2 = NSSwapHostShortToLittle(channels);
	fwrite(&tmp2, 2, 1, fp);
	tmp1 = NSSwapHostIntToLittle(samplerate);
	fwrite(&tmp1, 4, 1, fp);
	tmp1 = NSSwapHostIntToLittle(bps*channels*samplerate);
	fwrite(&tmp1, 4, 1, fp);
	tmp2 = NSSwapHostShortToLittle(bps*channels);
	fwrite(&tmp2, 2, 1, fp);
	tmp2 = NSSwapHostShortToLittle(bps*8);
	fwrite(&tmp2, 2, 1, fp);
	fwrite("data", 1, 4, fp);
	tmp1 = NSSwapHostIntToLittle(frames*bps*channels);
	fwrite(&tmp1, 4, 1, fp);
}

static void writeAiffHeader(int bps, int channels, int samplerate, int isFloat, unsigned int frames, FILE *fp)
{
	unsigned int tmp1;
	unsigned short tmp2;
	char ieeeExtended[10];
	if(isFloat) {
		fwrite("FORM", 1, 4, fp);
		tmp1 = NSSwapHostIntToBig(frames*bps*channels+64);
		fwrite(&tmp1, 4, 1, fp);
		fwrite("AIFC", 1, 4, fp);
		fwrite("FVER", 1, 4, fp);
		tmp1 = NSSwapHostIntToBig(4);
		fwrite(&tmp1, 4, 1, fp);
		tmp1 = NSSwapHostIntToBig(0xa2805140);
		fwrite(&tmp1, 4, 1, fp);
		fwrite("COMM", 1, 4, fp);
		tmp1 = NSSwapHostIntToBig(24);
		fwrite(&tmp1, 4, 1, fp);
		tmp2 = NSSwapHostShortToBig(channels);
		fwrite(&tmp2, 2, 1, fp);
		tmp1 = NSSwapHostIntToBig(frames);
		fwrite(&tmp1, 4, 1, fp);
		tmp2 = NSSwapHostShortToBig(bps*8);
		fwrite(&tmp2, 2, 1, fp);
		ConvertToIeeeExtended(samplerate,ieeeExtended);
		fwrite(ieeeExtended, 1, 10, fp);
		fwrite("FL32", 1, 4, fp);
		tmp2 = 0;
		fwrite(&tmp2, 2, 1, fp);
		fwrite("SSND", 1, 4, fp);
		tmp1 = NSSwapHostIntToBig(frames*bps*channels+8);
		fwrite(&tmp1, 4, 1, fp);
		tmp1 = 0;
		fwrite(&tmp1, 4, 1, fp);
		fwrite(&tmp1, 4, 1, fp);
		
	}
	else {
		fwrite("FORM", 1, 4, fp);
		tmp1 = NSSwapHostIntToBig(frames*bps*channels+46);
		fwrite(&tmp1, 4, 1, fp);
		fwrite("AIFF", 1, 4, fp);
		fwrite("COMM", 1, 4, fp);
		tmp1 = NSSwapHostIntToBig(18);
		fwrite(&tmp1, 4, 1, fp);
		tmp2 = NSSwapHostShortToBig(channels);
		fwrite(&tmp2, 2, 1, fp);
		tmp1 = NSSwapHostIntToBig(frames);
		fwrite(&tmp1, 4, 1, fp);
		tmp2 = NSSwapHostShortToBig(bps*8);
		fwrite(&tmp2, 2, 1, fp);
		ConvertToIeeeExtended(samplerate,ieeeExtended);
		fwrite(ieeeExtended, 1, 10, fp);
		fwrite("SSND", 1, 4, fp);
		tmp1 = NSSwapHostIntToBig(frames*bps*channels+8);
		fwrite(&tmp1, 4, 1, fp);
		tmp1 = 0;
		fwrite(&tmp1, 4, 1, fp);
		fwrite(&tmp1, 4, 1, fp);
	}
}

static void writeSamples(int *samples, unsigned int numSamples, int bps, int endian, FILE *fp)
{
	unsigned int i;
	for(i=0;i<numSamples;i++) {
		if(bps==1) {
			char sample = samples[i] >> 24;
			if(endian) sample += 0x80;
			fwrite(&sample, 1, 1, fp);
		}
		else if(bps==2) {
			short sample = samples[i] >> 16;
			if(endian) sample = NSSwapHostShortToLittle(sample);
			else sample = NSSwapHostShortToBig(sample);
			fwrite(&sample, 2, 1, fp);
		}
		else if(bps==3) {
			unsigned char sample[3];
			if(endian) {
				sample[0] = (samples[i] >> 8) & 0xff;
				sample[1] = (samples[i] >> 16) & 0xff;
				sample[2] = (samples[i] >> 24) & 0xff;
			}
			else {
				sample[0] = (samples[i] >> 24) & 0xff;
				sample[1] = (samples[i] >> 16) & 0xff;
				sample[2] = (samples[i] >> 8) & 0xff;
			}
			fwrite(sample, 1, 3, fp);
		}
		else {
			int sample = samples[i];
			if(endian) sample = NSSwapHostIntToLittle(sample);
			else sample = NSSwapHostIntToBig(sample);
			fwrite(&sample, 4, 1, fp);
		}
	}
	fflush(fp);
}

static void usage(void)
{
	fprintf(stderr,"X Lossless Decoder %s by tmkk\n",[[[[NSBundle mainBundle] infoDictionary] valueForKey:@"CFBundleShortVersionString"] UTF8String]);
	fprintf(stderr,"usage: xld [-c cuesheet] [--ddpms DDPMSfile] [-e] [-f format] [-o outpath] [-t track] [--raw] file\n");
	fprintf(stderr,"\t-c: Cue sheet you want to split file with\n");
	fprintf(stderr,"\t-e: Exclude pre-gap from decoded file\n");
	fprintf(stderr,"\t-f: Specify format of decoded file\n");
	fprintf(stderr,"\t      wav        : Microsoft WAV (default)\n");
	fprintf(stderr,"\t      aif        : Apple AIFF\n");
	fprintf(stderr,"\t      raw_big    : Raw PCM (big endian)\n");
	fprintf(stderr,"\t      raw_little : Raw PCM (little endian)\n");
	fprintf(stderr,"\t      mp3        : LAME MP3\n");
	fprintf(stderr,"\t      aac        : MPEG-4 AAC\n");
	fprintf(stderr,"\t      flac       : FLAC\n");
	fprintf(stderr,"\t      alac       : Apple Lossless\n");
	fprintf(stderr,"\t      vorbis     : Ogg Vorbis\n");
	fprintf(stderr,"\t      wavpack    : WavPack\n");
	fprintf(stderr,"\t      opus       : Opus\n");
	fprintf(stderr,"\t-o: Specify path of decoded file\n\t    (directory or filename; directory only for cue sheet mode)\n");
	fprintf(stderr,"\t-t: List of tracks you want to decode; ex. -t 1,3,4\n");
	fprintf(stderr,"\t--raw: Force read input file as Raw PCM\n\t       following 4 options are required\n");
	fprintf(stderr,"\t  --samplerate: Samplerate of Raw PCM file; default=44100\n");
	fprintf(stderr,"\t  --bit       : Bit depth of Raw PCM file; default=16\n");
	fprintf(stderr,"\t  --channels  : Number of channels of Raw PCM file; default=2\n");
	fprintf(stderr,"\t  --endian    : Endian of Raw PCM file (little or big); default=little\n");
	fprintf(stderr,"\t--correct-30samples: Correct \"30 samples moved offset\" problem\n");
	fprintf(stderr,"\t--ddpms: DDPMS file (assumes that the associated file is Raw PCM)\n");
	fprintf(stderr,"\t--stdout: write output to stdout (-o option is ignored)\n");
	fprintf(stderr,"\t--profile <name>: Choose a profile saved as <name> in GUI\n");
	fprintf(stderr,"\t--logchecker <path>: Check sanity of a logfile in <path>\n");
	fprintf(stderr,"\t--no-metadata : Do not append any metadata\n");
	fprintf(stderr,"\t--filename-format <format> : Format output filename as <format>\n");
	fprintf(stderr,"\t--scan-replaygain <path>: Scan replaygain of a file in <path>\n");
	fprintf(stderr,"\t--cue-encoding <name>: Specify cue sheet encoding as IANA charset <name>\n");
}

static int checkLogfile(char *file)
{
	Class logChecker = (Class)objc_lookUpClass("XLDLogChecker");
	if(logChecker) {
		NSData *dat = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:file]];
		if(dat) {
			XLDLogChecker *checker = [[logChecker alloc] init];
			XLDLogCheckerResult result = [checker validateData:dat];
			switch (result) {
				case XLDLogCheckerOK:
					fprintf(stderr,"OK\n");
					break;
				case XLDLogCheckerSignatureNotFound:
					fprintf(stderr,"Not signed\n");
					break;
				case XLDLogCheckerNotLogFile:
					fprintf(stderr,"Not a logfile\n");
					break;
				case XLDLogCheckerUnknownVersion:
					fprintf(stderr,"Malformed\n");
					break;
				case XLDLogCheckerInvalidHash:
					fprintf(stderr,"Malformed\n");
					break;
				case XLDLogCheckerMalformed:
					fprintf(stderr,"Malformed\n");
					break;
				default:
					fprintf(stderr,"Unknown\n");
					break;
			}
			[checker release];
			if(result != XLDLogCheckerOK) return -1;
			else return 0;
		}
		else fprintf(stderr,"error: cannot open file\n");
		return -1;
	}
	fprintf(stderr,"error: logchecker plugin not loaded\n");
	return -1;
}

static char *fgets_private(char *buf, int size, FILE *fp)
{
	int i;
	char c;
	static int ignore_LF;
	for(i=0;i<size-1;) {
		if(fread(&c,1,1,fp) != 1) break;
		buf[i++] = c;
		if(c == '\n') {
			if(ignore_LF) {
				i--;
				ignore_LF = 0;
				continue;
			}
			break;
		}
		else if(c == '\r') {
			buf[i-1] = '\n';
			ignore_LF = 1;
			break;
		}
		ignore_LF = 0;
	}
	if(i==0) return NULL;
	buf[i] = 0;
	return buf;
}

static int scanReplayGain(const char *infile, const char *outfile, XLDCueParser *cueParser, XLDecoderCenter *center)
{
	NSString *inPath = [NSString stringWithUTF8String:infile];
	id <XLDDecoder> decoder = [center preferredDecoderForFile:inPath];
	if(decoder) {
		[decoder openFile:(char *)infile];
		XLDTrack *track = [[XLDTrack alloc] init];
		[track setSeconds:[decoder totalFrames]/[decoder samplerate]];
		[track setFrames:[decoder totalFrames]];
		[track setMetadata:[decoder metadata]];
		NSArray *trackList = [NSArray arrayWithObject:track];
		[track release];
		XLDAccurateRipChecker *checker = [[XLDAccurateRipChecker alloc] initWithTracks:trackList totalFrames:[decoder totalFrames]];
		[decoder closeFile];
		[checker startReplayGainScanningForFile:inPath withDecoder:decoder];
		fprintf(stdout,"%s",[[checker logStrForSingleReplayGainScanner] UTF8String]);
		[checker release];
	} else {
		NSArray *trackList = [cueParser trackListForExternalCueSheet:inPath decoder:&decoder];
		if(!trackList || !decoder) {
			if([cueParser errorMsg]) fprintf(stderr,"error: %s\n",[[cueParser errorMsg] UTF8String]);
			else fprintf(stderr,"error: %s isn't an audio file or cue sheet\n",infile);
			return -1;
		}
		if(![trackList count]) {
			fprintf(stderr,"error: given cue sheet doesn't contain tracks\n");
			return -1;
		}
		NSString *targetFile = [decoder srcPath];
		xldoffset_t totalFrames = [decoder totalFrames];
		[decoder closeFile];
		if(![decoder isKindOfClass:[XLDMultipleFileWrappedDecoder class]]) {
			decoder = [center preferredDecoderForFile:targetFile];
		}
		XLDAccurateRipChecker *checker = [[XLDAccurateRipChecker alloc] initWithTracks:trackList totalFrames:totalFrames];
		[checker startReplayGainScanningForFile:targetFile withDecoder:decoder];
		fprintf(stdout,"%s",[[checker logStrForReplayGainScanner] UTF8String]);
		[checker release];
		
		if(outfile) {
			FILE *fp = fopen(infile, "rb");
			FILE *fpw = fopen(outfile, "w");
			if(!fpw) {
				fprintf(stderr,"error: cannot write cue sheet to %s\n",outfile);
				return -1;
			}
			char buf[1024];
			int track = 0;
			int written = 0;
			while(fgets_private(buf,1024,fp)) {
				char *ptr = buf;
				while(*ptr == ' ' || *ptr == '\t') ptr++;
				char *indent_end = ptr;
				if(track == 0 && written == 0) {
					if(!strncasecmp(ptr, "FILE ", 5)) {
						fwrite(buf, 1, indent_end-buf, fpw);
						fprintf(fpw, "REM REPLAYGAIN_ALBUM_GAIN %.2f dB\n", [[[[trackList objectAtIndex:0] metadata] objectForKey:XLD_METADATA_REPLAYGAIN_ALBUM_GAIN] floatValue]);
						fwrite(buf, 1, indent_end-buf, fpw);
						fprintf(fpw, "REM REPLAYGAIN_ALBUM_PEAK %f\n", [[[[trackList objectAtIndex:0] metadata] objectForKey:XLD_METADATA_REPLAYGAIN_ALBUM_PEAK] floatValue]);
						fputs(buf, fpw);
						written++;
						continue;
					}
				} else if(track <= [trackList count] && track == written) {
					if(!strncasecmp(ptr, "INDEX ", 6)) {
						fwrite(buf, 1, indent_end-buf, fpw);
						fprintf(fpw, "REM REPLAYGAIN_TRACK_GAIN %.2f dB\n", [[[[trackList objectAtIndex:track-1] metadata] objectForKey:XLD_METADATA_REPLAYGAIN_TRACK_GAIN] floatValue]);
						fwrite(buf, 1, indent_end-buf, fpw);
						fprintf(fpw, "REM REPLAYGAIN_TRACK_PEAK %f\n", [[[[trackList objectAtIndex:track-1] metadata] objectForKey:XLD_METADATA_REPLAYGAIN_TRACK_PEAK] floatValue]);
						fputs(buf, fpw);
						written++;
						continue;
					}
				}
				if(!strncasecmp(ptr, "TRACK ", 6)) track++;
				else if(!strncasecmp(ptr, "REM REPLAYGAIN_ALBUM_GAIN ", 26) ||
						!strncasecmp(ptr, "REM REPLAYGAIN_ALBUM_PEAK ", 26) ||
						!strncasecmp(ptr, "REM REPLAYGAIN_TRACK_GAIN ", 26) ||
						!strncasecmp(ptr, "REM REPLAYGAIN_TRACK_PEAK ", 26)) {
					continue;
				}
				fputs(buf, fpw);
			}
			fclose(fp);
			fclose(fpw);
		}
	}
	return 0;
}

int cmdline_main(int argc, char *argv[])
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	unsigned int sf_format = SF_FORMAT_WAV;
	int i,useCueSheet=0,ignoreGap=0,debug=0,useDdpms=0,writeToStdout=0;;
	int offset = 0;
	char *cuesheet = NULL;
	char *trks = NULL;
	const char *outdir = NULL;
	char *ddpms = NULL;
	const char *outfile = NULL;
	NSString *extStr = nil;
	XLDFormat outputFormat;
	int rawMode = 0;
	outputFormat.samplerate = 44100;
	outputFormat.channels = 2;
	int rawEndian = XLDLittleEndian;
	outputFormat.bps = 2;
	outputFormat.isFloat = 0;
	Class customOutputClass = nil;
	id encoder = nil;
	BOOL acceptStdoutWriting = YES;
	NSDictionary *profileDic = nil;
	char *infile;
	int error = 0;
	BOOL logcheckerMode = NO;
	BOOL addMetadata = YES;
	NSString *filenameFormat = nil;
	BOOL replaygainScannerMode = NO;
	NSStringEncoding cueEncoding = -1;
	
	int		ch;
	extern char	*optarg;
	extern int	optind, opterr;
	int option_index;
	struct option options[] = {
		{"raw", 0, NULL, 0},
		{"samplerate", 1, NULL,0},
		{"endian", 1, NULL, 0},
		{"bit", 1, NULL, 0},
		{"channels", 1, NULL, 0},
		{"read-embedded-cuesheet", 0, NULL, 0},
		{"ignore-embedded-cuesheet", 0, NULL, 0},
		{"correct-30samples", 0, NULL, 0},
		{"ddpms", 1, NULL, 0},
		{"stdout", 0, NULL, 0},
		{"profile", 1, NULL, 0},
		{"cmdline", 0, NULL, 0},
		{"logchecker", 0, NULL, 0},
		{"no-metadata", 0, NULL, 0},
		{"filename-format", 1, NULL, 0},
		{"scan-replaygain", 0, NULL, 0},
		{"cue-encoding", 1, NULL, 0},
		{0, 0, 0, 0}
	};
	
	XLDPluginManager *pluginManager = [[XLDPluginManager alloc] init];
	XLDecoderCenter *decoderCenter = [[XLDecoderCenter alloc] initWithPlugins:[pluginManager plugins]];
	XLDCueParser *cueParser = [[XLDCueParser alloc] initWithDelegate:nil];
	[cueParser setDecoderCenter:decoderCenter];
	NSUserDefaults *pref = [NSUserDefaults standardUserDefaults];
	
	while ((ch = getopt_long(argc, argv, "c:et:do:f:", options, &option_index)) != -1){
		switch (ch){
			case 0:
				if(!strcmp(options[option_index].name, "raw")) {
					rawMode = 1;
				}
				else if(!strcmp(options[option_index].name, "samplerate")) {
					outputFormat.samplerate = atoi(optarg);
				}
				else if(!strcmp(options[option_index].name, "endian")) {
					if(!strncasecmp(optarg,"little",6)) rawEndian = XLDLittleEndian;
					else if(!strncasecmp(optarg,"big",3)) rawEndian = XLDBigEndian;
				}
				else if(!strcmp(options[option_index].name, "bit")) {
					outputFormat.bps = atoi(optarg) >> 3;
				}
				else if(!strcmp(options[option_index].name, "channels")) {
					outputFormat.channels = atoi(optarg);
				}
				else if(!strcmp(options[option_index].name, "correct-30samples")) {
					offset = 30;
				}
				else if(!strcmp(options[option_index].name, "ddpms")) {
					ddpms = optarg;
					useDdpms = 1;
					rawMode = 1;
				}
				else if(!strcmp(options[option_index].name, "stdout")) {
					writeToStdout = 1;
				}
				else if(!strcmp(options[option_index].name, "profile")) {
					profileDic = [XLDProfileManager profileForName:[NSString stringWithUTF8String:optarg]];
				}
				else if(!strcmp(options[option_index].name, "logchecker")) {
					logcheckerMode = YES;
				}
				else if(!strcmp(options[option_index].name, "no-metadata")) {
					addMetadata = NO;
				}
				else if(!strcmp(options[option_index].name, "filename-format")) {
					filenameFormat = [NSString stringWithUTF8String:optarg];
				}
				else if(!strcmp(options[option_index].name, "scan-replaygain")) {
					replaygainScannerMode = YES;
				}
				else if(!strcmp(options[option_index].name, "cue-encoding")) {
					CFStringRef arg = CFStringCreateWithCString(NULL, optarg, kCFStringEncodingUTF8);
					CFStringEncoding tmpEncoding = CFStringConvertIANACharSetNameToEncoding(arg);
					if(tmpEncoding != kCFStringEncodingInvalidId) {
						cueEncoding = CFStringConvertEncodingToNSStringEncoding(tmpEncoding);
						//fprintf(stderr, "%lu, %s\n",cueEncoding,[[NSString localizedNameOfStringEncoding:cueEncoding] UTF8String]);
					} else {
						fprintf(stderr, "error: encoding name \"%s\" is unknown\n", optarg);
					}
					CFRelease(arg);
				}
				else if(!strcmp(options[option_index].name, "cmdline")) {
					//skip
				}
				break;
			case 'c':
				cuesheet = optarg;
				useCueSheet = 1;
				break;
			case 'e':
				ignoreGap = 1;
				break;
			case 't':
				trks = optarg;
				break;
			case 'd':
				debug = 1;
				break;
			case 'o':
				outfile = optarg;
				break;
			case 'f':
				if(!strcasecmp(optarg,"wav")) {
					sf_format = SF_FORMAT_WAV;
					customOutputClass = (Class)objc_lookUpClass("XLDWavOutput");
					if(!customOutputClass) {
						fprintf(stderr,"error: Wav output plugin not loaded\n");
						return -1;
					}
					acceptStdoutWriting = YES;
				}
				else if(!strcasecmp(optarg,"aif")) {
					sf_format = SF_FORMAT_AIFF;
					customOutputClass = (Class)objc_lookUpClass("XLDAiffOutput");
					if(!customOutputClass) {
						fprintf(stderr,"error: AIFF output plugin not loaded\n");
						return -1;
					}
					acceptStdoutWriting = YES;
				}
				else if(!strcasecmp(optarg,"raw_big")) {
					sf_format = SF_FORMAT_RAW|SF_ENDIAN_BIG;
					customOutputClass = (Class)objc_lookUpClass("XLDPCMBEOutput");
					if(!customOutputClass) {
						fprintf(stderr,"error: PCM (big endian) output plugin not loaded\n");
						return -1;
					}
					acceptStdoutWriting = YES;
				}
				else if(!strcasecmp(optarg,"raw_little")) {
					sf_format = SF_FORMAT_RAW|SF_ENDIAN_LITTLE;
					customOutputClass = (Class)objc_lookUpClass("XLDPCMLEOutput");
					if(!customOutputClass) {
						fprintf(stderr,"error: PCM (little endian) output plugin not loaded\n");
						return -1;
					}
					acceptStdoutWriting = YES;
				}
				else if(!strcasecmp(optarg,"mp3")) {
					customOutputClass = (Class)objc_lookUpClass("XLDLameOutput");
					if(!customOutputClass) {
						fprintf(stderr,"error: MP3 output plugin not loaded\n");
						return -1;
					}
					acceptStdoutWriting = NO;
				}
				else if(!strcasecmp(optarg,"aac")) {
					customOutputClass = (Class)objc_lookUpClass("XLDAacOutput2");
					if(!customOutputClass) {
						customOutputClass = (Class)objc_lookUpClass("XLDAacOutput");
						if(!customOutputClass) {
							fprintf(stderr,"error: AAC output plugin not loaded\n");
							return -1;
						}
					}
					acceptStdoutWriting = NO;
				}
				else if(!strcasecmp(optarg,"flac")) {
					customOutputClass = (Class)objc_lookUpClass("XLDFlacOutput");
					if(!customOutputClass) {
						fprintf(stderr,"error: FLAC output plugin not loaded\n");
						return -1;
					}
					acceptStdoutWriting = NO;
				}
				else if(!strcasecmp(optarg,"alac")) {
					customOutputClass = (Class)objc_lookUpClass("XLDAlacOutput");
					if(!customOutputClass) {
						fprintf(stderr,"error: FLAC output plugin not loaded\n");
						return -1;
					}
					acceptStdoutWriting = NO;
				}
				else if(!strcasecmp(optarg,"vorbis")) {
					customOutputClass = (Class)objc_lookUpClass("XLDVorbisOutput");
					if(!customOutputClass) {
						fprintf(stderr,"error: Ogg Vorbis output plugin not loaded\n");
						return -1;
					}
					acceptStdoutWriting = NO;
				}
				else if(!strcasecmp(optarg,"wavpack")) {
					customOutputClass = (Class)objc_lookUpClass("XLDWavpackOutput");
					if(!customOutputClass) {
						fprintf(stderr,"error: WavPack output plugin not loaded\n");
						return -1;
					}
					acceptStdoutWriting = NO;
				}
				else if(!strcasecmp(optarg,"opus")) {
					customOutputClass = (Class)objc_lookUpClass("XLDOpusOutput");
					if(!customOutputClass) {
						fprintf(stderr,"error: Opus output plugin not loaded\n");
						return -1;
					}
					acceptStdoutWriting = NO;
				}
				else sf_format = SF_FORMAT_WAV;
				break;
			default:
				usage();
				return 0;
		}
	}
	
	//argc -= optind;
	//argv += optind;
	if(!argv[optind]) {
		usage();
		return -1; 
	}
	
	if(cueEncoding != -1) {
		[cueParser setPreferredEncoding:cueEncoding];
	}
	else if([pref objectForKey:@"CuesheetEncodings2"]) {
		[cueParser setPreferredEncoding:[[pref objectForKey:@"CuesheetEncodings2"] unsignedIntValue]];
	}
	
	if(logcheckerMode) return checkLogfile(argv[optind]);
	if(replaygainScannerMode) return scanReplayGain(argv[optind],optind+1<argc?argv[optind+1]:NULL,cueParser,decoderCenter);
	
	if(profileDic) {
		NSString *outFormatStr = [profileDic objectForKey:@"OutputFormatName"];
		if([outFormatStr isEqualToString:@"WAV"]) {
			sf_format = SF_FORMAT_WAV;
			customOutputClass = (Class)objc_lookUpClass("XLDWavOutput");
			if(!customOutputClass) {
				fprintf(stderr,"error: Wav output plugin not loaded\n");
				return -1;
			}
			acceptStdoutWriting = YES;
		}
		else if([outFormatStr isEqualToString:@"AIFF"]) {
			sf_format = SF_FORMAT_AIFF;
			customOutputClass = (Class)objc_lookUpClass("XLDAiffOutput");
			if(!customOutputClass) {
				fprintf(stderr,"error: AIFF output plugin not loaded\n");
				return -1;
			}
			acceptStdoutWriting = YES;
		}
		else if([profileDic objectForKey:@"XLDPcmBEOutput_BitDepth"]) {
			sf_format = SF_FORMAT_RAW|SF_ENDIAN_BIG;
			customOutputClass = (Class)objc_lookUpClass("XLDPcmBEOutput");
			if(!customOutputClass) {
				fprintf(stderr,"error: PCM (big endian) output plugin not loaded\n");
				return -1;
			}
			acceptStdoutWriting = YES;
		}
		else if([profileDic objectForKey:@"XLDPcmLEOutput_BitDepth"]) {
			sf_format = SF_FORMAT_RAW|SF_ENDIAN_LITTLE;
			customOutputClass = (Class)objc_lookUpClass("XLDPcmLEOutput");
			if(!customOutputClass) {
				fprintf(stderr,"error: PCM (little endian) output plugin not loaded\n");
				return -1;
			}
			acceptStdoutWriting = YES;
		}
		else if([outFormatStr isEqualToString:@"Wave64"]) {
			customOutputClass = (Class)objc_lookUpClass("XLDWave64Output");
			if(!customOutputClass) {
				fprintf(stderr,"error: Wave64 output plugin not loaded\n");
				return -1;
			}
			acceptStdoutWriting = NO;
		}
		else if([outFormatStr isEqualToString:@"LAME MP3"]) {
			customOutputClass = (Class)objc_lookUpClass("XLDLameOutput");
			if(!customOutputClass) {
				fprintf(stderr,"error: MP3 output plugin not loaded\n");
				return -1;
			}
			acceptStdoutWriting = NO;
		}
		else if([outFormatStr isEqualToString:@"MPEG-4 AAC"]) {
			customOutputClass = (Class)objc_lookUpClass("XLDAacOutput2");
			if(!customOutputClass) {
				customOutputClass = (Class)objc_lookUpClass("XLDAacOutput");
				if(!customOutputClass) {
					fprintf(stderr,"error: AAC output plugin not loaded\n");
					return -1;
				}
			}
			acceptStdoutWriting = NO;
		}
		else if([outFormatStr isEqualToString:@"FLAC"]) {
			customOutputClass = (Class)objc_lookUpClass("XLDFlacOutput");
			if(!customOutputClass) {
				fprintf(stderr,"error: FLAC output plugin not loaded\n");
				return -1;
			}
			acceptStdoutWriting = NO;
		}
		else if([outFormatStr isEqualToString:@"Apple Lossless"]) {
			customOutputClass = (Class)objc_lookUpClass("XLDAlacOutput");
			if(!customOutputClass) {
				fprintf(stderr,"error: FLAC output plugin not loaded\n");
				return -1;
			}
			acceptStdoutWriting = NO;
		}
		else if([outFormatStr isEqualToString:@"Ogg Vorbis"]) {
			customOutputClass = (Class)objc_lookUpClass("XLDVorbisOutput");
			if(!customOutputClass) {
				fprintf(stderr,"error: Ogg Vorbis output plugin not loaded\n");
				return -1;
			}
			acceptStdoutWriting = NO;
		}
		else if([outFormatStr isEqualToString:@"WavPack"]) {
			customOutputClass = (Class)objc_lookUpClass("XLDWavpackOutput");
			if(!customOutputClass) {
				fprintf(stderr,"error: WavPack output plugin not loaded\n");
				return -1;
			}
			acceptStdoutWriting = NO;
		}
		if([[profileDic objectForKey:@"SelectOutput"] intValue])
			outdir = (char *)[[[profileDic objectForKey:@"OutputDir"] stringByExpandingTildeInPath] UTF8String];
	}
	
	if(writeToStdout && !acceptStdoutWriting) {
		fprintf(stderr,"error: writing to stdout does not work with this encoder.\n");
		return -1;
	}
	
	if(outfile) {
		struct stat sb;
		i = stat(outfile,&sb);
		if(!i && S_ISDIR(sb.st_mode)) {
			outdir = realpath(outfile, NULL);
			outfile = NULL;
		}
		else {
			NSString *standardizedPath = [[NSString stringWithUTF8String:outfile] stringByStandardizingPath];
			NSString *lastPathComponent = [standardizedPath lastPathComponent];
			NSString *directoryComponent = [standardizedPath stringByDeletingLastPathComponent];
			if ([directoryComponent length] == 0) directoryComponent = @"./";
			[[NSFileManager defaultManager] createDirectoryWithIntermediateDirectoryInPath:directoryComponent];
			char *tmp = realpath([directoryComponent UTF8String], NULL);
			outfile = [[[NSString stringWithUTF8String:tmp] stringByAppendingPathComponent:lastPathComponent] UTF8String];
			free(tmp);
		}
	}
	if(!outdir) {
		outdir = realpath("./", NULL);
	}
	infile = realpath(argv[optind], NULL);
	
	id decoder;
	
	NSMutableArray* trackList;
	XLDDDPParser *ddpParser = [[XLDDDPParser alloc] init];
	if(useDdpms) {
		if([ddpParser openDDPMS:[NSString stringWithUTF8String:ddpms]]) {
			trackList = [[ddpParser trackListArray] retain];
		}
		else {
			fprintf(stderr,"Error while parsing DDPMS\n");
			return -1;
		}
	}
	else trackList = [[NSMutableArray alloc] init];
	
	if(rawMode) {
		if(useDdpms) decoder = [[XLDRawDecoder alloc] initWithFormat:outputFormat endian:rawEndian offset:[ddpParser offsetBytes]];
		else decoder = [[XLDRawDecoder alloc] initWithFormat:outputFormat endian: rawEndian];
	}
	else {
		decoder = [decoderCenter preferredDecoderForFile:[NSString stringWithUTF8String:infile]];
		if(!decoder) {
			fprintf(stderr,"error: cannot handle file\n");
			return -1;
		}
	}
	
	if(![decoder conformsToProtocol:@protocol(XLDDecoder)]) {
		fprintf(stderr,"invalid decoder class\n");
		return -1;
	}
	
	if(![(id <XLDDecoder>)decoder openFile:infile]) {
		fprintf(stderr,"error: cannot open file\n");
		[decoder closeFile];
		return -1;
	}
	
	outputFormat.bps = [decoder bytesPerSample];
	outputFormat.channels = [decoder channels];
	outputFormat.samplerate = [decoder samplerate];
	outputFormat.isFloat = [decoder isFloat];
	
	NSMutableDictionary *configDic = [NSMutableDictionary dictionary];
	[configDic setObject:[NSNumber numberWithInt:0] forKey:@"BitDepth"];
	[configDic setObject:[NSNumber numberWithBool:NO] forKey:@"IsFloat"];
	[configDic setObject:[NSNumber numberWithUnsignedInt:sf_format] forKey:@"SFFormat"];
	
	if(!customOutputClass) {
		customOutputClass = (Class)objc_lookUpClass("XLDWavOutput");
		if(!customOutputClass) {
			fprintf(stderr,"error: Wav output plugin not loaded\n");
			return -1;
		}
	}
#if 1
	{
		/*_LSSetApplicationInformationItem = dlsym(RTLD_DEFAULT, "_LSSetApplicationInformationItem");
		_LSGetCurrentApplicationASN = dlsym(RTLD_DEFAULT, "_LSGetCurrentApplicationASN");
		_kLSApplicationTypeKey = launchServicesKey("_kLSApplicationTypeKey");
		_kLSApplicationUIElementTypeKey = launchServicesKey("_kLSApplicationUIElementTypeKey");
		
		if(!_LSSetApplicationInformationItem) NSLog(@"_LSSetApplicationInformationItem is null");
		if(!_LSGetCurrentApplicationASN) NSLog(@"_LSGetCurrentApplicationASN is null");
		if(!_kLSApplicationTypeKey) NSLog(@"_kLSApplicationTypeKey is null");
		if(!_kLSApplicationUIElementTypeKey) NSLog(@"_kLSApplicationUIElementTypeKey is null");*/
		
		encoder = [[customOutputClass alloc] init];
		[encoder loadPrefs];
		if(profileDic) [encoder loadConfigurations:profileDic];
		id tmpTask = [encoder createTaskForOutput];
		extStr = [tmpTask extensionStr];
		[tmpTask release];
		NSString *desc = [[(id <XLDOutput>)encoder configurations] objectForKey:@"ShortDesc"];
		if(desc) fprintf(stderr,"Encoder option: %s\n",[desc UTF8String]);
		//[encoder release];
		
		/*if(_LSSetApplicationInformationItem && _LSGetCurrentApplicationASN && _kLSApplicationTypeKey && _kLSApplicationUIElementTypeKey)
			_LSSetApplicationInformationItem(-2, _LSGetCurrentApplicationASN(), _kLSApplicationTypeKey, _kLSApplicationUIElementTypeKey, NULL);*/
	}
#endif
	//SetSystemUIMode(kUIModeAllHidden, 0);
	//[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
	
	if(useCueSheet) {
		[cueParser setTrackData:trackList forCueFile:[NSString stringWithUTF8String:cuesheet] withDecoder:decoder];
		if(![trackList count]) fprintf(stderr,"cannot open cue sheet; ignored.\n");
		if(debug) {
			for(i=0;i<[trackList count];i++) {
				fprintf(stderr,"index:%lld frames:%lld gap:%d\n",[(XLDTrack *)[trackList objectAtIndex:i] index],[[trackList objectAtIndex:i] frames],[[trackList objectAtIndex:i] gap]);
				fprintf(stderr,"title:%s artist:%s\n",[[[[trackList objectAtIndex:i] metadata] objectForKey:XLD_METADATA_TITLE] UTF8String],[[[[trackList objectAtIndex:i] metadata] objectForKey:XLD_METADATA_ARTIST] UTF8String]);
			}
		}
	}
	if(![trackList count]) {
		useCueSheet = 0;
		XLDTrack *trk = [[XLDTrack alloc] init];
		[trackList addObject:trk];
		[trk setMetadata:[decoder metadata]];
		[trk release];
	}
	
	if(trks && useCueSheet) {
		char *tmp;
		for(i=0;i<[trackList count];i++) {
			[[trackList objectAtIndex:i] setEnabled:NO];
		}
		tmp = strtok(trks, "," );
		while (tmp != NULL) {
			int t = atoi(tmp)-1;
			if(t >= 0 && t < [trackList count]) [[trackList objectAtIndex:t] setEnabled:YES];
			tmp = strtok(NULL, "," );
		}
	}
	
	unsigned char *buffer = (unsigned char *)malloc(8192*4*outputFormat.channels);
	
	int track;
	int lastPercent = -1;
	for(track=0;track<[trackList count];track++) {
		id <XLDOutputTask> outputTask = nil;
		int samplesperloop = 8192;
		int lasttrack = 0;
		XLDTrack *trk = [trackList objectAtIndex:track];
		if(![trk enabled]) continue;
		
		if(offset) {
			if([trk index] >= offset) [decoder seekToFrame:[trk index]-offset];
			else [decoder seekToFrame:[trk index]];
		}
		else [decoder seekToFrame:[trk index]];
		if([(id <XLDDecoder>)decoder error]) {
			fprintf(stderr,"error: cannot seek\n");
			error = -1;
			continue;
		}
		NSString *outputPathStr;
		if(useCueSheet || useDdpms || !outfile) {
			if(!filenameFormat) {
				if(!useCueSheet && !useDdpms)
					outputPathStr = [[[[NSString stringWithUTF8String:infile] lastPathComponent] stringByDeletingPathExtension] stringByAppendingPathExtension:extStr];
				else if([[trk metadata] objectForKey:XLD_METADATA_TITLE] && [[trk metadata] objectForKey:XLD_METADATA_ARTIST])
					outputPathStr = [NSString stringWithFormat:@"%02d %@ - %@.%@",track+1,[[trk metadata] objectForKey:XLD_METADATA_ARTIST],[[trk metadata] objectForKey:XLD_METADATA_TITLE],extStr];
				else if([[trk metadata] objectForKey:XLD_METADATA_TITLE])
					outputPathStr = [NSString stringWithFormat:@"%02d %@.%@",track+1,[[trk metadata] objectForKey:XLD_METADATA_TITLE],extStr];
				else if([[trk metadata] objectForKey:XLD_METADATA_ARTIST])
					outputPathStr = [NSString stringWithFormat:@"%02d %@ - Track %02d.%@",track+1,[[trk metadata] objectForKey:XLD_METADATA_ARTIST],track+1,extStr];
				else
					outputPathStr = [NSString stringWithFormat:@"%02d Track %02d.%@",track+1,track+1,extStr];
			}
			else {
				NSString *name,*artist,*album,*albumartist,*composer,*genre;
				int idx = [[trk metadata] objectForKey:XLD_METADATA_TRACK] ? [[[trk metadata] objectForKey:XLD_METADATA_TRACK] intValue] : track+1;
				name = [[trk metadata] objectForKey:XLD_METADATA_TITLE];
				artist = [[trk metadata] objectForKey:XLD_METADATA_ARTIST];
				album = [[trk metadata] objectForKey:XLD_METADATA_ALBUM];
				composer = [[trk metadata] objectForKey:XLD_METADATA_COMPOSER];
				genre = [[trk metadata] objectForKey:XLD_METADATA_GENRE];
				if(!useCueSheet) albumartist = artist;
				else {
					NSString *aartist = [cueParser artist];
					if([[trk metadata] objectForKey:XLD_METADATA_ALBUMARTIST]) aartist = [[trk metadata] objectForKey:XLD_METADATA_ALBUMARTIST];
					albumartist = [aartist isEqualToString:@""] ? artist : aartist;
				}
				if([[trk metadata] objectForKey:XLD_METADATA_COMPILATION] && ![[trk metadata] objectForKey:XLD_METADATA_ALBUMARTIST]) {
					if([[[trk metadata] objectForKey:XLD_METADATA_COMPILATION] boolValue])
						albumartist = (NSMutableString *)@"Compilations";
				}
				NSString *pattern = [filenameFormat stringByStandardizingPath];
				if([pattern characterAtIndex:[pattern length]-1] == '/') pattern = [pattern substringToIndex:[pattern length]-2];
				if([pattern characterAtIndex:0] == '/') pattern = [pattern substringFromIndex:1];
				NSMutableString *str = [[[NSMutableString alloc] init] autorelease];
				int j;
				for(j=0;j<[pattern length]-1;j++) {
					/* track number */
					if([[pattern substringWithRange:NSMakeRange(j,2)] isEqualToString:@"%n"]) {
						[str appendFormat: @"%02d",idx];
						j++;
					}
					/* disc number */
					else if([[pattern substringWithRange:NSMakeRange(j,2)] isEqualToString:@"%D"]) {
						if([[trk metadata] objectForKey:XLD_METADATA_DISC]) {
							[str appendFormat: @"%02d",[[[trk metadata] objectForKey:XLD_METADATA_DISC] intValue]];
						}
						else [str appendString:@"01"];
						j++;
					}
					/* title */
					else if([[pattern substringWithRange:NSMakeRange(j,2)] isEqualToString:@"%t"]) {
						if(name && ![name isEqualToString:@""]) [str appendString: name];
						else [str appendString: @"Unknown Title"];
						j++;
					}
					/* artist */
					else if([[pattern substringWithRange:NSMakeRange(j,2)] isEqualToString:@"%a"]) {
						if(artist && ![artist isEqualToString:@""]) [str appendString: artist];
						else [str appendString: @"Unknown Artist"];
						j++;
					}
					/* album title */
					else if([[pattern substringWithRange:NSMakeRange(j,2)] isEqualToString:@"%T"]) {
						if(album && ![album isEqualToString:@""]) [str appendString: album];
						else [str appendString: @"Unknown Album"];
						j++;
					}
					/* album artist */
					else if([[pattern substringWithRange:NSMakeRange(j,2)] isEqualToString:@"%A"]) {
						if(albumartist && ![albumartist isEqualToString:@""]) [str appendString: albumartist];
						else [str appendString: @"Unknown Artist"];
						j++;
					}
					/* composer */
					else if([[pattern substringWithRange:NSMakeRange(j,2)] isEqualToString:@"%c"]) {
						if(composer && ![composer isEqualToString:@""]) [str appendString: composer];
						else [str appendString: @"Unknown Composer"];
						j++;
					}
					/* year */
					else if([[pattern substringWithRange:NSMakeRange(j,2)] isEqualToString:@"%y"]) {
						NSNumber *year = [[trk metadata] objectForKey:XLD_METADATA_YEAR];
						if(year) [str appendString: [year stringValue]];
						else [str appendString: @"Unknown Year"];
						j++;
					}
					/* genre */
					else if([[pattern substringWithRange:NSMakeRange(j,2)] isEqualToString:@"%g"]) {
						if(genre && ![genre isEqualToString:@""]) [str appendString: genre];
						else [str appendString: @"Unknown Genre"];
						j++;
					}
					/* isrc */
					else if([[pattern substringWithRange:NSMakeRange(j,2)] isEqualToString:@"%i"]) {
						NSString *isrc = [[trk metadata] objectForKey:XLD_METADATA_ISRC];
						if(isrc && ![isrc isEqualToString:@""]) [str appendString: isrc];
						else [str appendString: @"NO_ISRC"];
						j++;
					}
					/* mcn */
					else if([[pattern substringWithRange:NSMakeRange(j,2)] isEqualToString:@"%m"]) {
						NSString *mcn = [[trk metadata] objectForKey:XLD_METADATA_CATALOG];
						if(mcn && ![mcn isEqualToString:@""]) [str appendString: mcn];
						else [str appendString: @"NO_MCN"];
						j++;
					}
					/* discid */
					else if([[pattern substringWithRange:NSMakeRange(j,2)] isEqualToString:@"%I"]) {
						NSNumber *discid = [[trk metadata] objectForKey:XLD_METADATA_FREEDBDISCID];
						if(discid) [str appendString: [NSString stringWithFormat:@"%08X", [discid unsignedIntValue]]];
						else [str appendString: @"NO_DISCID"];
						j++;
					}
					/* format */
					else if([[pattern substringWithRange:NSMakeRange(j,2)] isEqualToString:@"%f"]) {
						[str appendString: [[encoder class] pluginName]];
						j++;
					}
					else if([[pattern substringWithRange:NSMakeRange(j,1)] isEqualToString:@"/"]) {
						[str appendString: @"[[[XLD_DIRECTORY_SEPARATOR]]]"];
					}
					else {
						[str appendString: [pattern substringWithRange:NSMakeRange(j,1)]];
					}
				}
				if(j==[pattern length]-1) [str appendString: [pattern substringWithRange:NSMakeRange(j,1)]];
				[str replaceOccurrencesOfString:@"/" withString:@"???" options:0 range:NSMakeRange(0, [str length])];
				[str replaceOccurrencesOfString:@":" withString:@"???" options:0 range:NSMakeRange(0, [str length])];
				[str replaceOccurrencesOfString:@"[[[XLD_DIRECTORY_SEPARATOR]]]" withString:@"/" options:0 range:NSMakeRange(0, [str length])];
				outputPathStr = [NSString stringWithFormat:@"%@.%@",str,extStr];
			}
			outfile = [[[NSString stringWithUTF8String:outdir] stringByAppendingPathComponent:outputPathStr] UTF8String];
		}
		
		if(!strcmp(infile,outfile)) {
			fprintf(stderr,"error: input and output path are the same\n");
			error = -1;
			continue;
		}
		
		int framesToCopy = [trk frames];
		int totalSize;
		if(framesToCopy != -1) {
			if(!ignoreGap) framesToCopy += [[trackList objectAtIndex:track+1] gap];
		}
		else {
			if(offset) {
				framesToCopy = [decoder totalFrames] - [trk index];
			}
			else {
				lasttrack = 1;
				framesToCopy = [decoder totalFrames] - [trk index];
			}
		}
		totalSize = framesToCopy;
		
		if(!writeToStdout) {
			if(encoder) {
				outputTask = [encoder createTaskForOutput];
			}
			else {
				outputTask = [[XLDDefaultOutputTask alloc] initWithConfigurations:configDic];
			}
			[outputTask setEnableAddTag:addMetadata];
			[[NSFileManager defaultManager] createDirectoryWithIntermediateDirectoryInPath:[[NSString stringWithUTF8String:outfile] stringByDeletingLastPathComponent]];
			if(![outputTask setOutputFormat:outputFormat]) {
				fprintf(stderr,"error: incompatible format (unsupported bitdepth or something)\n");
				error = -1;
				break;
			}
			if(![outputTask openFileForOutput:[NSString stringWithUTF8String:outfile] withTrackData:trk]) {
				fprintf(stderr,"error: cannot write file %s\n",outfile);
				[(id)outputTask release];
				error = -1;
				continue;
			}
		}
		else {
			if((sf_format & SF_FORMAT_WAV) == SF_FORMAT_WAV) {
				writeWavHeader(outputFormat.bps, outputFormat.channels, outputFormat.samplerate, outputFormat.isFloat, framesToCopy, stdout);
			}
			else if((sf_format & SF_FORMAT_AIFF) == SF_FORMAT_AIFF) {
				writeAiffHeader(outputFormat.bps, outputFormat.channels, outputFormat.samplerate, outputFormat.isFloat, framesToCopy, stdout);
			}
		}
		
		if(offset && ([trk index] < offset)) {
			int *tmpbuf = (int *)calloc(offset*outputFormat.channels,4);
			if(!writeToStdout) {
				if(![outputTask writeBuffer:tmpbuf frames:offset - [trk index]]) {
					fprintf(stderr,"error: cannot output sample\n");
					error = -1;
					break;
				}
			}
			else {
				writeSamples(tmpbuf,(offset - [trk index])*outputFormat.channels,outputFormat.bps,0,stdout);
			}
			framesToCopy -= (offset - [trk index]);
			free(tmpbuf);
		}
		
		do {
			if(!lasttrack && framesToCopy < samplesperloop) samplesperloop = framesToCopy;
			xldoffset_t ret = [decoder decodeToBuffer:(int *)buffer frames:samplesperloop];
			if([(id <XLDDecoder>)decoder error]) {
				fprintf(stderr,"error: cannot decode\n");
				error = -1;
				break;
			}
			//NSLog(@"%d,%d",ret,samplesperloop);
			framesToCopy -= ret;
			if(ret > 0) {
				if(!writeToStdout) {
					if(![outputTask writeBuffer:(int *)buffer frames:ret]) {
						fprintf(stderr,"error: cannot output sample\n");
						error = -1;
						break;
					}
				}
				else {
					int endian = 0;
					if((sf_format & SF_FORMAT_WAV) == SF_FORMAT_WAV || (sf_format & (SF_FORMAT_RAW|SF_ENDIAN_LITTLE)) == (SF_FORMAT_RAW|SF_ENDIAN_LITTLE)) endian = 1;
					writeSamples((int *)buffer,ret*outputFormat.channels,outputFormat.bps,endian,stdout);
				}
			}
			int percent = (int)(100.0*(totalSize-framesToCopy)/totalSize);
			if(percent != lastPercent) {
				fprintf(stderr,"\r|");
				for(i=0;i<20;i++) {
					if(percent/5 > i)
						fprintf(stderr,"=");
					else if(percent/5 == i)
						fprintf(stderr,">");
					else fprintf(stderr,"-");
				}
				fprintf(stderr,"| %3d%% (Track %d/%d)",percent,track+1,(int)[trackList count]);
				fflush(stderr);
				lastPercent = percent;
			}
			if((!lasttrack && !framesToCopy) || ret < samplesperloop) {
				break;
			}
		} while(1);
		if(!writeToStdout) {
			[outputTask finalize];
			[outputTask closeFile];
			[(id)outputTask release];
		}
		//if(ignoreGap && [trk gap]) [decoder seekToFrame:[[trackList objectAtIndex:track+1] index]];
	}
	fprintf(stderr,"\ndone.\n");
	[decoder closeFile];
	free(buffer);
	[trackList release];
	[pool release];
	return error;
}
