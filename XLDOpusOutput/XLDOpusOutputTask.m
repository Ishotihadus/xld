//
//  XLDOpusOutputTask.m
//  XLDOpusOutput
//
//  Created by tmkk on 12/08/09.
//  Copyright 2012 tmkk. All rights reserved.
//

#import "XLDOpusOutputTask.h"

typedef int64_t xldoffset_t;
#import "XLDTrack.h"
#import "lpc.h"

#ifdef __i386__
#import <xmmintrin.h>
#endif

#define IMIN(a,b) ((a) < (b) ? (a) : (b))   /**< Minimum int value.   */
#define IMAX(a,b) ((a) > (b) ? (a) : (b))   /**< Maximum int value.   */

#define OPUS_SURROUND_API_SUPPORT 1

static const int max_ogg_delay=48000;

static const float s32tof32scaler[4]  __attribute__((aligned(16))) = {4.656612873e-10f,4.656612873e-10f,4.656612873e-10f,4.656612873e-10f};

typedef enum
{
	OpusEncoderModeVBR = 0,
	OpusEncoderModeCVBR = 1,
	OpusEncoderModeCBR = 2
} OpusEncoderMode;

static inline int oe_write_page(ogg_page *page, FILE *fp)
{
	int written;
	written=fwrite(page->header,1,page->header_len, fp);
	written+=fwrite(page->body,1,page->body_len, fp);
	return written;
}

#define readint(buf, base) (((buf[base+3]<<24)&0xff000000)| \
((buf[base+2]<<16)&0xff0000)| \
((buf[base+1]<<8)&0xff00)| \
(buf[base]&0xff))
#define writeint(buf, base, val) do{ buf[base+3]=((val)>>24)&0xff; \
buf[base+2]=((val)>>16)&0xff; \
buf[base+1]=((val)>>8)&0xff; \
buf[base]=(val)&0xff; \
}while(0)

static void comment_init(char **comments, int* length, const char *vendor_string)
{
	/*The 'vendor' field should be the actual encoding library used.*/
	int vendor_length=strlen(vendor_string);
	int user_comment_list_length=0;
	int len=8+4+vendor_length+4;
	char *p=(char*)malloc(len);
	if(p==NULL){
		fprintf(stderr, "malloc failed in comment_init()\n");
		exit(1);
	}
	memcpy(p, "OpusTags", 8);
	writeint(p, 8, vendor_length);
	memcpy(p+12, vendor_string, vendor_length);
	writeint(p, 12+vendor_length, user_comment_list_length);
	*length=len;
	*comments=p;
}

static void comment_add(char **comments, int* length, char *tag, char *val)
{
	char* p=*comments;
	int vendor_length=readint(p, 8);
	int user_comment_list_length=readint(p, 8+4+vendor_length);
	int tag_len=(tag?strlen(tag):0);
	int val_len=strlen(val);
	int len=(*length)+4+tag_len+val_len;
	
	p=(char*)realloc(p, len);
	if(p==NULL){
		fprintf(stderr, "realloc failed in comment_add()\n");
		exit(1);
	}
	
	writeint(p, *length, tag_len+val_len);      /* length of comment */
	if(tag) memcpy(p+*length+4, tag, tag_len);  /* comment */
	memcpy(p+*length+4+tag_len, val, val_len);  /* comment */
	writeint(p, 8+4+vendor_length, user_comment_list_length+1);
	*comments=p;
	*length=len;
}

#if 1
static const char basis_64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static char *base64enc(const unsigned char *input, int len)
{
	char *encoded = malloc(((len + 2) / 3 * 4) + 1);
	int i;
	char *p;
	
	p = encoded;
	for (i = 0; i < len - 2; i += 3) {
		*p++ = basis_64[(input[i] >> 2) & 0x3F];
		*p++ = basis_64[((input[i] & 0x3) << 4) | ((int) (input[i + 1] & 0xF0) >> 4)];
		*p++ = basis_64[((input[i + 1] & 0xF) << 2) | ((int) (input[i + 2] & 0xC0) >> 6)];
		*p++ = basis_64[input[i + 2] & 0x3F];
	}
	if (i < len) {
		*p++ = basis_64[(input[i] >> 2) & 0x3F];
		if (i == (len - 1)) {
			*p++ = basis_64[((input[i] & 0x3) << 4)];
			*p++ = '=';
		}
		else {
			*p++ = basis_64[((input[i] & 0x3) << 4) | ((int) (input[i + 1] & 0xF0) >> 4)];
			*p++ = basis_64[((input[i + 1] & 0xF) << 2)];
		}
		*p++ = '=';
	}
	
	*p++ = '\0';
	return encoded;
}
#else
#import <openssl/bio.h>
#import <openssl/evp.h>
#import <openssl/buffer.h>
static char *base64enc(const unsigned  char *input, int length)
{
	BIO *bmem, *b64;
	BUF_MEM *bptr;
	
	b64 = BIO_new(BIO_f_base64());
	BIO_set_flags(b64, BIO_FLAGS_BASE64_NO_NL);
	bmem = BIO_new(BIO_s_mem());
	b64 = BIO_push(b64, bmem);
	BIO_write(b64, input, length);
	BIO_flush(b64);
	BIO_get_mem_ptr(b64, &bptr);
	
	char *buff = (char *)malloc(bptr->length+1);
	memcpy(buff, bptr->data, bptr->length);
	buff[bptr->length] = 0;
	
	BIO_free_all(b64);
	
	return buff;
}
#endif

typedef struct {
	unsigned char *data;
	int maxlen;
	int pos;
} Packet;

static int write_uint32(Packet *p, ogg_uint32_t val)
{
	if (p->pos>p->maxlen-4)
		return 0;
	p->data[p->pos  ] = (val    ) & 0xFF;
	p->data[p->pos+1] = (val>> 8) & 0xFF;
	p->data[p->pos+2] = (val>>16) & 0xFF;
	p->data[p->pos+3] = (val>>24) & 0xFF;
	p->pos += 4;
	return 1;
}

static int write_uint16(Packet *p, ogg_uint16_t val)
{
	if (p->pos>p->maxlen-2)
		return 0;
	p->data[p->pos  ] = (val    ) & 0xFF;
	p->data[p->pos+1] = (val>> 8) & 0xFF;
	p->pos += 2;
	return 1;
}

static int write_chars(Packet *p, const unsigned char *str, int nb_chars)
{
	int i;
	if (p->pos>p->maxlen-nb_chars)
		return 0;
	for (i=0;i<nb_chars;i++)
		p->data[p->pos++] = str[i];
	return 1;
}

int opus_header_to_packet(const OpusHeader *h, unsigned char *packet, int len)
{
	int i;
	Packet p;
	unsigned char ch;
	
	p.data = packet;
	p.maxlen = len;
	p.pos = 0;
	if (len<19)return 0;
	if (!write_chars(&p, (const unsigned char*)"OpusHead", 8))
		return 0;
	/* Version is 1 */
	ch = 1;
	if (!write_chars(&p, &ch, 1))
		return 0;
	
	ch = h->channels;
	if (!write_chars(&p, &ch, 1))
		return 0;
	
	if (!write_uint16(&p, h->preskip))
		return 0;
	
	if (!write_uint32(&p, h->input_sample_rate))
		return 0;
	
	if (!write_uint16(&p, h->gain))
		return 0;
	
	ch = h->channel_mapping;
	if (!write_chars(&p, &ch, 1))
		return 0;
	
	if (h->channel_mapping != 0)
	{
		ch = h->nb_streams;
		if (!write_chars(&p, &ch, 1))
			return 0;
		
		ch = h->nb_coupled;
		if (!write_chars(&p, &ch, 1))
			return 0;
		
		/* Multi-stream support */
		for (i=0;i<h->channels;i++)
		{
			if (!write_chars(&p, &h->stream_map[i], 1))
				return 0;
		}
	}
	
	return p.pos;
}

@implementation XLDOpusOutputTask

- (id)init
{
	[super init];
	return self;
}

- (id)initWithConfigurations:(NSDictionary *)cfg
{
	[self init];
	configurations = [cfg retain];
	return self;
}

- (void)dealloc
{
	if(fp) fclose(fp);
	if(configurations) [configurations release];
	if(packet) free(packet);
	if(input) free(input);
	if(resamplerBuffer) free(resamplerBuffer);
	[super dealloc];
}

- (BOOL)setOutputFormat:(XLDFormat)fmt
{
	format = fmt;
	if(format.bps > 4) return NO;
	if(format.channels > 255) return NO;
	
	return YES;
}

- (BOOL)openFileForOutput:(NSString *)str withTrackData:(id)track
{
	int ret;
	int i;
	
	fp = fopen([str UTF8String], "wb");
	if(!fp) {
		return NO;
	}
	
	if(ogg_stream_init(&os, rand())==-1){
		fprintf(stderr,"Error: stream init failed\n");
		goto fail;
	}
	
	if(format.samplerate>24000)coding_rate=48000;
	else if(format.samplerate>16000)coding_rate=24000;
	else if(format.samplerate>12000)coding_rate=16000;
	else if(format.samplerate>8000)coding_rate=12000;
	else coding_rate=8000;
	
	frame_size = [[configurations objectForKey:@"FrameSize"] intValue];
#ifdef OPUS_SET_EXPERT_FRAME_DURATION
	if(!frame_size) {
		/* variable frame size */
		useVariableFramesize = YES;
		frame_size = 2*48000; /* set lookahead size to maximum */
	}
#else
	if(!frame_size) frame_size = 960;
#endif
	frame_size = frame_size/(48000/coding_rate);
	
	/* setup header */
	header.channels=format.channels;
	header.gain=0;
	header.input_sample_rate=format.samplerate;
#if OPUS_SURROUND_API_SUPPORT
	header.channel_mapping=header.channels>8?255:header.channels>2;
#else
	unsigned char      mapping[256];
	for(i=0;i<256;i++)mapping[i]=i;
	int force_narrow=0;
	header.nb_coupled=0;
	header.nb_streams=header.channels;
	if(header.channels <= 8){
		static const unsigned char opusenc_streams[8][10]={
			/*Coupled, NB_bitmap, mapping...*/
			/*1*/ {0,   0, 0},
			/*2*/ {1,   0, 0,1},
			/*3*/ {1,   0, 0,2,1},
			/*4*/ {2,   0, 0,1,2,3},
			/*5*/ {2,   0, 0,4,1,2,3},
			/*6*/ {2,1<<3, 0,4,1,2,3,5},
			/*7*/ {2,1<<4, 0,4,1,2,3,5,6},
			/*6*/ {3,1<<4, 0,6,1,2,3,4,5,7}
		};
		for(i=0;i<header.channels;i++)mapping[i]=opusenc_streams[header.channels-1][i+2];
		force_narrow=opusenc_streams[header.channels-1][1];
		header.nb_coupled=opusenc_streams[header.channels-1][0];
		header.nb_streams=header.channels-header.nb_coupled;
	}
	header.channel_mapping=header.channels>8?255:header.nb_streams>1;
	if(header.channel_mapping>0)for(i=0;i<header.channels;i++)header.stream_map[i]=mapping[i];
#endif
	
	/*Initialize OPUS encoder*/
#if OPUS_SURROUND_API_SUPPORT
	st = opus_multistream_surround_encoder_create(coding_rate,format.channels,header.channel_mapping,&header.nb_streams,&header.nb_coupled,header.stream_map,frame_size<480/(48000/coding_rate)?OPUS_APPLICATION_RESTRICTED_LOWDELAY:OPUS_APPLICATION_AUDIO,&ret);
#else
	st = opus_multistream_encoder_create(coding_rate,format.channels,header.nb_streams,header.nb_coupled,mapping,frame_size<480/(48000/coding_rate)?OPUS_APPLICATION_RESTRICTED_LOWDELAY:OPUS_APPLICATION_AUDIO,&ret);
#endif
	if(ret != OPUS_OK) {
		fprintf(stderr, "opus_multistream_encoder_create failure\n");
		if(st) opus_multistream_encoder_destroy(st);
		st = NULL;
		return NO;
	}
	
	int bitrate = [[configurations objectForKey:@"Bitrate"] intValue];
	if(bitrate<=0){
		bitrate=((64000*header.nb_streams+32000*header.nb_coupled)*
				(IMIN(48,IMAX(8,((format.samplerate<44100?format.samplerate:48000)+1000)/1000))+16)+32)>>6;
	}
	if(bitrate > 256000 * format.channels) bitrate = 256000 * format.channels;
	ret = opus_multistream_encoder_ctl(st, OPUS_SET_BITRATE(bitrate));
	if(ret != OPUS_OK) {
		goto fail;
	}
	
	int encoderMode = [[configurations objectForKey:@"EncoderMode"] intValue];
	ret = opus_multistream_encoder_ctl(st, OPUS_SET_VBR(encoderMode != OpusEncoderModeCBR));
	if(ret != OPUS_OK) {
		goto fail;
	}
	
	if(encoderMode != OpusEncoderModeCBR) {
		ret = opus_multistream_encoder_ctl(st, OPUS_SET_VBR_CONSTRAINT(encoderMode != OpusEncoderModeVBR));
		if(ret != OPUS_OK) {
			goto fail;
		}
	}
	
	ret = opus_multistream_encoder_ctl(st, OPUS_SET_COMPLEXITY(10));
	if(ret != OPUS_OK) {
		goto fail;
	}
	
#if !OPUS_SURROUND_API_SUPPORT
	if(force_narrow!=0){
		for(i=0;i<header.nb_streams;i++){
			if(force_narrow&(1<<i)){
				OpusEncoder *oe;
				opus_multistream_encoder_ctl(st,OPUS_MULTISTREAM_GET_ENCODER_STATE(i,&oe));
				ret = opus_encoder_ctl(oe, OPUS_SET_MAX_BANDWIDTH(OPUS_BANDWIDTH_NARROWBAND));
				if(ret != OPUS_OK){
					goto fail;
				}
			}
		}
	}
#endif
	
	opus_int32 lookahead;
	ret = opus_multistream_encoder_ctl(st, OPUS_GET_LOOKAHEAD(&lookahead));
	if(ret != OPUS_OK) {
		goto fail;
	}
	
#if defined(OPUS_SET_EXPERT_FRAME_DURATION) && defined(OPUS_FRAMESIZE_VARIABLE)
	if(useVariableFramesize) {
		i=OPUS_FRAMESIZE_VARIABLE;
		ret = opus_multistream_encoder_ctl(st, OPUS_SET_EXPERT_FRAME_DURATION(i));
		if(ret != OPUS_OK){
			fprintf(stderr,"Warning OPUS_SET_EXPERT_FRAME_DURATION returned: %s\n",opus_strerror(ret));
		}
	}
#endif
	
	/* setup resampler */
	if(coding_rate != format.samplerate) {
		resampler = speex_resampler_init(format.channels, format.samplerate, coding_rate, 5, &ret);
		if(ret!=0) fprintf(stderr, "resampler error: %s\n", speex_resampler_strerror(ret));
		lookahead += speex_resampler_get_output_latency(resampler);
	}
	
	header.preskip=lookahead*(48000./coding_rate);
	
	max_frame_bytes=(1275*3+7)*header.nb_streams;
	packet=malloc(sizeof(unsigned char)*max_frame_bytes);
	if(!packet) goto fail;
	
	/* setup tags */
	char *comments;
	int comments_length;
	const char *opus_version=opus_get_version_string();
	comment_init(&comments, &comments_length, opus_version);
	comment_add(&comments, &comments_length, "ENCODER=", (char *)[[NSString stringWithFormat:@"X Lossless Decoder %@",[[NSBundle mainBundle] objectForInfoDictionaryKey: @"CFBundleShortVersionString"]] UTF8String]);
	if(addTag) {
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_TITLE]) {
			comment_add(&comments,&comments_length,"TITLE=",(char *)[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_TITLE] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_ARTIST]) {
			comment_add(&comments,&comments_length,"ARTIST=",(char *)[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_ARTIST] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_ALBUM]) {
			comment_add(&comments,&comments_length,"ALBUM=",(char *)[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_ALBUM] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_ALBUMARTIST]) {
			comment_add(&comments,&comments_length,"ALBUMARTIST=",(char *)[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_ALBUMARTIST] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_GENRE]) {
			comment_add(&comments,&comments_length,"GENRE=",(char *)[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_GENRE] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_COMPOSER]) {
			comment_add(&comments,&comments_length,"COMPOSER=",(char *)[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_COMPOSER] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_TRACK]) {
			comment_add(&comments,&comments_length,"TRACKNUMBER=",(char *)[[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_TRACK] stringValue] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_TOTALTRACKS]) {
			comment_add(&comments,&comments_length,"TRACKTOTAL=",(char *)[[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_TOTALTRACKS] stringValue] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_DISC]) {
			comment_add(&comments,&comments_length,"DISCNUMBER=",(char *)[[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_DISC] stringValue] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_TOTALDISCS]) {
			comment_add(&comments,&comments_length,"DISCTOTAL=",(char *)[[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_TOTALDISCS] stringValue] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_DATE]) {
			comment_add(&comments,&comments_length,"DATE=",(char *)[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_DATE] UTF8String]);
		}
		else if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_YEAR]) {
			comment_add(&comments,&comments_length,"DATE=",(char *)[[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_YEAR] stringValue] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_GROUP]) {
			comment_add(&comments,&comments_length,"CONTENTGROUP=",(char *)[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_GROUP] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_COMMENT]) {
			comment_add(&comments,&comments_length,"COMMENT=",(char *)[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_COMMENT] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_ISRC]) {
			comment_add(&comments,&comments_length,"ISRC=",(char *)[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_ISRC] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_CATALOG]) {
			comment_add(&comments,&comments_length,"MCN=",(char *)[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_CATALOG] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_COMPILATION]) {
			comment_add(&comments,&comments_length,"COMPILATION=",(char *)[[NSString stringWithFormat:@"%d",[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_COMPILATION] intValue]] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_TITLESORT]) {
			comment_add(&comments,&comments_length,"TITLESORT=",(char *)[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_TITLESORT] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_ARTISTSORT]) {
			comment_add(&comments,&comments_length,"ARTISTSORT=",(char *)[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_ARTISTSORT] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_ALBUMSORT]) {
			comment_add(&comments,&comments_length,"ALBUMSORT=",(char *)[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_ALBUMSORT] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_ALBUMARTISTSORT]) {
			comment_add(&comments,&comments_length,"ALBUMARTISTSORT=",(char *)[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_ALBUMARTISTSORT] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_COMPOSERSORT]) {
			comment_add(&comments,&comments_length,"COMPOSERSORT=",(char *)[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_COMPOSERSORT] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_GRACENOTE2]) {
			comment_add(&comments,&comments_length,"iTunes_CDDB_1=",(char *)[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_GRACENOTE2] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_MB_TRACKID]) {
			comment_add(&comments,&comments_length,"MUSICBRAINZ_TRACKID=",(char *)[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_MB_TRACKID] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_MB_ALBUMID]) {
			comment_add(&comments,&comments_length,"MUSICBRAINZ_ALBUMID=",(char *)[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_MB_ALBUMID] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_MB_ARTISTID]) {
			comment_add(&comments,&comments_length,"MUSICBRAINZ_ARTISTID=",(char *)[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_MB_ARTISTID] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_MB_ALBUMARTISTID]) {
			comment_add(&comments,&comments_length,"MUSICBRAINZ_ALBUMARTISTID=",(char *)[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_MB_ALBUMARTISTID] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_MB_DISCID]) {
			comment_add(&comments,&comments_length,"MUSICBRAINZ_DISCID=",(char *)[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_MB_DISCID] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_PUID]) {
			comment_add(&comments,&comments_length,"MUSICIP_PUID=",(char *)[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_PUID] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_MB_ALBUMSTATUS]) {
			comment_add(&comments,&comments_length,"MUSICBRAINZ_ALBUMSTATUS=",(char *)[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_MB_ALBUMSTATUS] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_MB_ALBUMTYPE]) {
			comment_add(&comments,&comments_length,"MUSICBRAINZ_ALBUMTYPE=",(char *)[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_MB_ALBUMTYPE] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_MB_RELEASECOUNTRY]) {
			comment_add(&comments,&comments_length,"RELEASECOUNTRY=",(char *)[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_MB_RELEASECOUNTRY] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_MB_RELEASEGROUPID]) {
			comment_add(&comments,&comments_length,"MUSICBRAINZ_RELEASEGROUPID=",(char *)[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_MB_RELEASEGROUPID] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_MB_WORKID]) {
			comment_add(&comments,&comments_length,"MUSICBRAINZ_WORKID=",(char *)[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_MB_WORKID] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_SMPTE_TIMECODE_START]) {
			comment_add(&comments,&comments_length,"SMPTE_TIMECODE_START=",(char *)[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_SMPTE_TIMECODE_START] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_SMPTE_TIMECODE_DURATION]) {
			comment_add(&comments,&comments_length,"SMPTE_TIMECODE_DURATION=",(char *)[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_SMPTE_TIMECODE_DURATION] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_MEDIA_FPS]) {
			comment_add(&comments,&comments_length,"MEDIA_FPS=",(char *)[[[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_MEDIA_FPS] UTF8String]);
		}
		if([[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_COVER]) {
			NSData *imgData = [[(XLDTrack *)track metadata] objectForKey:XLD_METADATA_COVER];
			NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:imgData];
			if(rep) {
				NSMutableData *pictureBlockData = [NSMutableData data];
				int type = OSSwapHostToBigInt32(3);
				int width = OSSwapHostToBigInt32([rep pixelsWide]);
				int height = OSSwapHostToBigInt32([rep pixelsHigh]);
				int depth = OSSwapHostToBigInt32([rep bitsPerPixel]);
				int indexedColor = 0;
				int descLength = 0;
				char *mime = 0;
				if([imgData length] >= 8 && 0 == memcmp([imgData bytes], "\x89PNG\x0d\x0a\x1a\x0a", 8))
					mime = "image/png";
				else if([imgData length] >= 6 && (0 == memcmp([imgData bytes], "GIF87a", 6) || 0 == memcmp([imgData bytes], "GIF89a", 6))) {
					mime = "image/gif";
					indexedColor = OSSwapHostToBigInt32(256);
				}
				else if([imgData length] >= 2 && 0 == memcmp([imgData bytes], "\xff\xd8", 2))
					mime = "image/jpeg";
				int mimeLength = mime ? OSSwapHostToBigInt32(strlen(mime)) : 0;
				int pictureLength = OSSwapHostToBigInt32([imgData length]);
				if(mime) {
					[pictureBlockData appendBytes:&type length:4];
					[pictureBlockData appendBytes:&mimeLength length:4];
					[pictureBlockData appendBytes:mime length:strlen(mime)];
					[pictureBlockData appendBytes:&descLength length:4];
					[pictureBlockData appendBytes:&width length:4];
					[pictureBlockData appendBytes:&height length:4];
					[pictureBlockData appendBytes:&depth length:4];
					[pictureBlockData appendBytes:&indexedColor length:4];
					[pictureBlockData appendBytes:&pictureLength length:4];
					[pictureBlockData appendData:imgData];
					char *encodedData = base64enc([pictureBlockData bytes], [pictureBlockData length]);
					comment_add(&comments,&comments_length,"METADATA_BLOCK_PICTURE=",encodedData);
					free(encodedData);
				}
			}
		}
		NSArray *keyArr = [[(XLDTrack *)track metadata] allKeys];
		for(i=[keyArr count]-1;i>=0;i--) {
			NSString *key = [keyArr objectAtIndex:i];
			NSRange range = [key rangeOfString:@"XLD_UNKNOWN_TEXT_METADATA_"];
			if(range.location != 0) continue;
			const char *idx = [[NSString stringWithFormat:@"%@=",[key substringFromIndex:range.length]] UTF8String];
			const char *dat = [[[(XLDTrack *)track metadata] objectForKey:key] UTF8String];
			comment_add(&comments,&comments_length,(char *)idx,(char *)dat);
		}
	}
	
	/*Write header*/
	{
		unsigned char header_data[100];
		int packet_size=opus_header_to_packet(&header, header_data, 100);
		op.packet=header_data;
		op.bytes=packet_size;
		op.b_o_s=1;
		op.e_o_s=0;
		op.granulepos=0;
		op.packetno=0;
		ogg_stream_packetin(&os, &op);
		
		while((ret=ogg_stream_flush(&os, &og))){
			if(!ret)break;
			ret=oe_write_page(&og, fp);
			if(ret!=og.header_len+og.body_len){
				fprintf(stderr,"Error: failed writing header to output stream\n");
				goto fail;
			}
		}
		op.packet=(unsigned char *)comments;
		op.bytes=comments_length;
		op.b_o_s=0;
		op.e_o_s=0;
		op.granulepos=0;
		op.packetno=1;
		ogg_stream_packetin(&os, &op);
	}
	
	/* writing the rest of the opus header packets */
	while((ret=ogg_stream_flush(&os, &og))){
		if(!ret)break;
		ret=oe_write_page(&og, fp);
		if(ret!=og.header_len + og.body_len){
			fprintf(stderr,"Error: failed writing header to output stream\n");
			goto fail;
		}
	}
	
	free(comments);
	
	pid = -1;
	original_samples = 0;
	enc_granulepos = 0;
	last_segments = 0;
	last_granulepos = 0;
	bufferedSamples = 0;
	bufferSize = 0;
	bufferedResamplerSamples = 0;
	return YES;
fail:
	if(st) opus_multistream_encoder_destroy(st);
	st = NULL;
	ogg_stream_clear(&os);
	return NO;
}

- (NSString *)extensionStr
{
	return @"opus";
}

- (BOOL)writeBuffer:(int *)buffer frames:(int)counts
{
	int pos=0,i;
	original_samples += counts;
	if(resampler) {
		int ratio = coding_rate/format.samplerate + 1;
		spx_uint32_t usedSamples=counts+bufferedResamplerSamples;
		if(!resamplerBuffer || bufferSize < counts) {
			resamplerBuffer = realloc(resamplerBuffer,sizeof(float)*(counts+2048)*format.channels);
			input = realloc(input,sizeof(float)*((counts+2048)*ratio+frame_size*2)*format.channels);
			bufferSize = counts;
		}
		if(format.isFloat) {
			memcpy(resamplerBuffer+bufferedResamplerSamples*format.channels, buffer, counts*format.channels*sizeof(float));
		}
		else {
#if defined(__i386__) && 0
			int total = counts*format.channels;
			int *src = buffer;
			float *dest = resamplerBuffer + bufferedResamplerSamples*format.channels;
			__m128 v0, v1, v2, v3, v4;
			__asm__ __volatile__ (
				"movaps		(%8), %4		\n\t"
				"jmp		2f				\n\t"
				"1:							\n\t"
				"subl		$16, %5			\n\t"
				"cvtdq2ps	(%6), %0		\n\t"
				"cvtdq2ps	16(%6), %1		\n\t"
				"cvtdq2ps	32(%6), %2		\n\t"
				"cvtdq2ps	48(%6), %3		\n\t"
				"addl		$64, %6			\n\t"
				"mulps		%4, %0			\n\t"
				"mulps		%4, %1			\n\t"
				"mulps		%4, %2			\n\t"
				"mulps		%4, %3			\n\t"
				"movups		%0, (%7)		\n\t"
				"movups		%1, 16(%7)		\n\t"
				"movups		%2, 32(%7)		\n\t"
				"movups		%3, 48(%7)		\n\t"
				"addl		$64, %7			\n\t"
				"2:							\n\t"
				"cmpl		$15, %5			\n\t"
				"ja			1b				\n\t"
				"jmp		4f				\n\t"
				"3:							\n\t"
				"subl		$8, %5			\n\t"
				"cvtdq2ps	(%6), %0		\n\t"
				"cvtdq2ps	16(%6), %1		\n\t"
				"addl		$32, %6			\n\t"
				"mulps		%4, %0			\n\t"
				"mulps		%4, %1			\n\t"
				"movups		%0, (%7)		\n\t"
				"movups		%1, 16(%7)		\n\t"
				"addl		$32, %7			\n\t"
				"4:							\n\t"
				"cmpl		$7, %5			\n\t"
				"ja			3b				\n\t"
				"jmp		6f				\n\t"
				"5:							\n\t"
				"subl		$4, %5			\n\t"
				"cvtdq2ps	(%6), %0		\n\t"
				"addl		$16, %6			\n\t"
				"mulps		%4, %0			\n\t"
				"movups		%0, (%7)		\n\t"
				"addl		$16, %7			\n\t"
				"6:							\n\t"
				"cmpl		$3, %5			\n\t"
				"ja			5b				\n\t"
				"jmp		8f				\n\t"
				"7:							\n\t"
				"subl		$1, %5			\n\t"
				"cvtsi2ss	(%6), %0		\n\t"
				"addl		$4, %6			\n\t"
				"mulss		%4, %0			\n\t"
				"movss		%0, (%7)		\n\t"
				"addl		$4, %7			\n\t"
				"8:							\n\t"
				"cmpl		$0, %5			\n\t"
				"jne		3b				\n\t"
				: "=x"(v0), "=x"(v1), "=x"(v2), "=x"(v3), "=x"(v4), "+r"(total), "+r"(src), "+r"(dest)
				: "r"(s32tof32scaler)
			);
#else
			int total = counts*format.channels;
			int offset = bufferedResamplerSamples*format.channels;
			for(i=0;i<total;i++) {
				resamplerBuffer[offset+i] = buffer[i] * 4.656612873e-10f;
			}
#endif
		}
		if(usedSamples >= 2048) {
			usedSamples -= 1024; /* always preserve 1024 samples, which may be required for LPC in the finalization process */
			spx_uint32_t outSamples=usedSamples*ratio;
			speex_resampler_process_interleaved_float(resampler,resamplerBuffer,&usedSamples,input+bufferedSamples*format.channels,&outSamples);
			bufferedResamplerSamples = counts+bufferedResamplerSamples-usedSamples;
			if(bufferedResamplerSamples) {
				memmove(resamplerBuffer, resamplerBuffer+usedSamples*format.channels, bufferedResamplerSamples*sizeof(float)*format.channels);
			}
			bufferedSamples += outSamples;
		}
		else {
			/* wait until at least 2048 samples are filled */
			bufferedResamplerSamples += counts;
			return YES;
		}
	}
	else {
		if(!input || bufferSize < counts) {
			input = realloc(input,sizeof(float)*(counts+frame_size*2)*format.channels);
			bufferSize = counts;
		}
		if(format.isFloat) {
			memcpy(input+bufferedSamples*format.channels, buffer, counts*format.channels*sizeof(float));
		}
		else {
			int total = counts*format.channels;
			int offset = bufferedSamples*format.channels;
			for(i=0;i<total;i++) {
				input[offset+i] = buffer[i] * 4.656612873e-10f;
			}
		}
		bufferedSamples += counts;
	}
	while(bufferedSamples >= frame_size*2) {
		int size_segments,cur_frame_size,nb_samples;
		pid++;
		
		nb_samples = frame_size;
		op.e_o_s=0;
		cur_frame_size=frame_size;
		
		int nbBytes = opus_multistream_encode_float(st, input+pos, cur_frame_size, packet, max_frame_bytes);
		if(nbBytes < 0) return NO;
		
#ifdef OPUS_SET_EXPERT_FRAME_DURATION
		if(useVariableFramesize) cur_frame_size = opus_packet_get_nb_samples(packet,nbBytes,coding_rate);
#endif
		pos += cur_frame_size*format.channels;
		bufferedSamples -= cur_frame_size;
		
		enc_granulepos+=cur_frame_size*48000/coding_rate;
		size_segments=(nbBytes+255)/255;
		while((((size_segments<=255)&&(last_segments+size_segments>255))
			   ||(enc_granulepos-last_granulepos>max_ogg_delay))
			  &&ogg_stream_flush_fill(&os, &og,255*255)) {
			if(ogg_page_packets(&og)!=0)last_granulepos=ogg_page_granulepos(&og);
			last_segments-=og.header[26];
			int ret=oe_write_page(&og, fp);
			if(ret!=og.header_len+og.body_len){
				fprintf(stderr,"Error: failed writing data to output stream\n");
				return NO;
			}
		}
		
		op.packet=(unsigned char *)packet;
		op.bytes=nbBytes;
		op.b_o_s=0;
		op.granulepos=enc_granulepos;
		op.packetno=2+pid;
		ogg_stream_packetin(&os, &op);
		last_segments+=size_segments;
		
		while((op.e_o_s||(enc_granulepos+(cur_frame_size*48000/coding_rate)-last_granulepos>max_ogg_delay)||
			   (last_segments>=255))?
			  ogg_stream_flush_fill(&os, &og,255*255):
			  ogg_stream_pageout_fill(&os, &og,255*255)){
			if(ogg_page_packets(&og)!=0)last_granulepos=ogg_page_granulepos(&og);
			last_segments-=og.header[26];
			int ret=oe_write_page(&og, fp);
			if(ret!=og.header_len+og.body_len){
				fprintf(stderr,"Error: failed writing data to output stream\n");
				return NO;
			}
		}
	}
	
	if(pos && bufferedSamples) memmove(input, input+pos, bufferedSamples*format.channels*sizeof(float));
	return YES;
}

- (void)finalize
{
	int pos=0,i,nb_samples=-1,eos=0;
	int extra_samples = (int)header.preskip*(format.samplerate/48000.);
	if(extra_samples) {
		float *lpc_in = resampler?resamplerBuffer:input;
		int lpc_samples = resampler?bufferedResamplerSamples:bufferedSamples;
		int lpc_order = 32;
		if(lpc_samples>lpc_order*2){
			float *paddingBuffer=calloc(format.channels * extra_samples, sizeof(float));
			float *lpc=alloca(lpc_order*sizeof(*lpc));
			for(i=0;i<format.channels;i++){
				vorbis_lpc_from_data(lpc_in+i,lpc,lpc_samples,lpc_order,format.channels);
				vorbis_lpc_predict(lpc,lpc_in+i+(lpc_samples-lpc_order)*format.channels,
								   lpc_order,paddingBuffer+i,extra_samples,format.channels);
			}
			memcpy(lpc_in+lpc_samples*format.channels,paddingBuffer,extra_samples*format.channels*sizeof(float));
			if(resampler) bufferedResamplerSamples += extra_samples;
			else bufferedSamples += extra_samples;
			free(paddingBuffer);
		}
	}
	if(resampler) {
		//fprintf(stderr, "buffered resampler samples: %d\n",bufferedResamplerSamples);
		if(bufferedResamplerSamples) {
			int ratio = coding_rate/format.samplerate + 1;
			float *ptr = resamplerBuffer;
			while(1) {
				spx_uint32_t usedSamples=bufferedResamplerSamples;
				spx_uint32_t outSamples=usedSamples*ratio;
				speex_resampler_process_interleaved_float(resampler,ptr,&usedSamples,input+bufferedSamples*format.channels,&outSamples);
				ptr += usedSamples*format.channels;
				bufferedResamplerSamples -= usedSamples;
				bufferedSamples += outSamples;
				if(!usedSamples || !bufferedResamplerSamples) break;
			}
		}
	}
	//fprintf(stderr, "%d,%d\n",bufferedSamples,frame_size);
	while(!op.e_o_s) {
		int size_segments,cur_frame_size;
		pid++;
		
		if(nb_samples<0){
			if(frame_size > bufferedSamples) nb_samples = bufferedSamples;
			else nb_samples = frame_size;
			if(nb_samples<frame_size) op.e_o_s=1;
			else op.e_o_s=0;
		}
		op.e_o_s|=eos;
		
		cur_frame_size=frame_size;
		
		if(nb_samples<cur_frame_size) {
#ifdef OPUS_SET_EXPERT_FRAME_DURATION
			if(useVariableFramesize) {
				/*if(nb_samples < 120/(48000/coding_rate)) cur_frame_size = 120/(48000/coding_rate);
				else if(nb_samples < 240/(48000/coding_rate)) cur_frame_size = 240/(48000/coding_rate);
				else if(nb_samples < 480/(48000/coding_rate)) cur_frame_size = 480/(48000/coding_rate);*/
				if(nb_samples < 960/(48000/coding_rate)) cur_frame_size = 960/(48000/coding_rate);
				else if(nb_samples < 1920/(48000/coding_rate)) cur_frame_size = 1920/(48000/coding_rate);
				else if(nb_samples < 2880/(48000/coding_rate)) cur_frame_size = 2880/(48000/coding_rate);
				else cur_frame_size = nb_samples;
			}
#endif
			if(bufferSize < cur_frame_size) {
				bufferSize = cur_frame_size;
				input = realloc(input, format.channels*bufferSize);
			}
			for(i=nb_samples*format.channels;i<cur_frame_size*format.channels;i++) input[pos+i]=0;
		}
		
		int nbBytes = opus_multistream_encode_float(st, input+pos, cur_frame_size, packet, max_frame_bytes);
		if(nbBytes < 0) break;
		
#ifdef OPUS_SET_EXPERT_FRAME_DURATION
		if(useVariableFramesize) cur_frame_size = opus_packet_get_nb_samples(packet,nbBytes,coding_rate);
#endif
		pos += cur_frame_size*format.channels;
		bufferedSamples -= cur_frame_size;
		if(op.e_o_s&&bufferedSamples>0){op.e_o_s=0;eos=1;}
		
		enc_granulepos+=cur_frame_size*48000/coding_rate;
		size_segments=(nbBytes+255)/255;
		while((((size_segments<=255)&&(last_segments+size_segments>255))
			   ||(enc_granulepos-last_granulepos>max_ogg_delay))
			  &&ogg_stream_flush_fill(&os, &og,255*255)) {
			if(ogg_page_packets(&og)!=0)last_granulepos=ogg_page_granulepos(&og);
			last_segments-=og.header[26];
			int ret=oe_write_page(&og, fp);
			if(ret!=og.header_len+og.body_len){
				fprintf(stderr,"Error: failed writing data to output stream\n");
				break;
			}
		}
		
		if(!op.e_o_s&&!eos&&max_ogg_delay>5760){
			if(frame_size > bufferedSamples) nb_samples = bufferedSamples;
			else nb_samples = frame_size;
			if(nb_samples<frame_size)eos=1;
			if(nb_samples==0)op.e_o_s=1;
		} else nb_samples=-1;
		
		op.packet=(unsigned char *)packet;
		op.bytes=nbBytes;
		op.b_o_s=0;
		op.granulepos=enc_granulepos;
		if(op.e_o_s){
			op.granulepos=((original_samples*48000+format.samplerate-1)/format.samplerate)+header.preskip;
		}
		op.packetno=2+pid;
		ogg_stream_packetin(&os, &op);
		last_segments+=size_segments;
		
		while((op.e_o_s||(enc_granulepos+(cur_frame_size*48000/coding_rate)-last_granulepos>max_ogg_delay)||
			   (last_segments>=255))?
			  ogg_stream_flush_fill(&os, &og,255*255):
			  ogg_stream_pageout_fill(&os, &og,255*255)){
			if(ogg_page_packets(&og)!=0)last_granulepos=ogg_page_granulepos(&og);
			last_segments-=og.header[26];
			int ret=oe_write_page(&og, fp);
			if(ret!=og.header_len+og.body_len){
				fprintf(stderr,"Error: failed writing data to output stream\n");
				break;
			}
		}
	}
	opus_multistream_encoder_destroy(st);
	st = NULL;
	ogg_stream_clear(&os);
}

- (void)closeFile
{
	if(resampler) speex_resampler_destroy(resampler);
	resampler = NULL;
	if(fp) fclose(fp);
	fp = NULL;
}

- (void)setEnableAddTag:(BOOL)flag
{
	addTag = flag;
}

@end
