//
//  XLDFFTakDecoder.m
//  XLDFFTakDecoder
//
//  Created by tmkk on 12/10/11.
//  Copyright 2012 tmkk. All rights reserved.
//

#import "XLDFFTakDecoder.h"

int samplesPerFrameFromHeader(const char *path, int samplerate)
{
    int ret = 0;
    FILE *fp = fopen(path, "rb");
    if(!fp) return 0;
    char buf[4];
    unsigned char tmp8;
    if(fread(buf,1,4,fp) < 4) {
        goto last;
    }
    if(memcmp(buf,"tBaK",4)) goto last;
    while(1) {
        if(fread(&tmp8,1,1,fp) < 1) {
            goto last;
        }
        if(tmp8 == 0 || tmp8 > 7) {
            goto last;
        }
        else if(tmp8 != 1) {
            unsigned int size = 0;
            int i;
            for(i=0;i<3;i++) {
                if(fread(&tmp8,1,1,fp) < 1) {
                    goto last;
                }
                size = (size << 8) | tmp8;
            }
            if(fseeko(fp, size, SEEK_CUR) != 0) goto last;
        }
        if(fseeko(fp, 3, SEEK_CUR) != 0) goto last;
        if(fread(&tmp8,1,1,fp) < 1) {
            goto last;
        }
        tmp8 = tmp8 & 0x3f;
        if(tmp8 != 2 && tmp8 != 4) goto last; /* only codec type 2 and 4 are supported by ffmpeg */
        if(fread(&tmp8,1,1,fp) < 1) {
            goto last;
        }
        tmp8 = (tmp8 & 0x3c) >> 2;
        switch (tmp8) {
            case 0:
                //ret = 0.094 * samplerate;
                ret = (samplerate * 3) >> 5;
                break;
            case 1:
                //ret = 0.125 * samplerate;
                ret = (samplerate * 4) >> 5;
                break;
            case 2:
                //ret = 0.188 * samplerate;
                ret = (samplerate * 6) >> 5;
                break;
            case 3:
                //ret = 0.25 * samplerate;
                ret = (samplerate * 8) >> 5;
                break;
            case 4:
                ret = 4096;
                break;
            case 5:
                ret = 8192;
                break;
            case 6:
                ret = 16384;
                break;
            case 7:
                ret = 512;
                break;
            case 8:
                ret = 1024;
                break;
            case 9:
                ret = 2048;
                break;
            default:
                break;
        }
        break;
    }
last:
    fclose(fp);
    return ret;
}

@implementation XLDFFTakDecoder

+ (BOOL)canHandleFile:(char *)path
{
    FILE *fp = fopen(path,"rb");
    if(!fp) return NO;
    char buf[4];
    if(fread(buf,1,4,fp) < 4) {
        fclose(fp);
        return NO;
    }
    fclose(fp);
    if(memcmp(buf,"tBaK",4)) return NO;
    return YES;
}

+ (BOOL)canLoadThisBundle
{
    return YES;
}

- (id)init
{
    [super init];
    metadataDic = [[NSMutableDictionary alloc] init];
    
    av_register_all();
    av_log_set_level(AV_LOG_QUIET);
    
    return self;
}

- (void)dealloc
{
    [metadataDic release];
    if(srcPath) [srcPath release];
    [super dealloc];
}

- (BOOL)openFile:(char *)path
{
    //NSLog(@"open with fftak decoder");
    fCtx = NULL;
    codecCtx = NULL;
    AVCodec *codec = NULL;
    int i;
    
    if(avformat_open_input(&fCtx, path, NULL, NULL) != 0) {
        fprintf(stderr,"avformat_open_input failure\n");
        return NO;
    }
    
    if(avformat_find_stream_info(fCtx, NULL) < 0) {
        fprintf(stderr,"av_find_stream_info failure\n");
        goto end;
    }
    
    for(i=0;i<fCtx->nb_streams;i++) {
        if(AVMEDIA_TYPE_AUDIO != fCtx->streams[i]->codecpar->codec_type) continue;
        
        enum AVCodecID codec_id = fCtx->streams[i]->codecpar->codec_id;
        if(codec_id == AV_CODEC_ID_TAK) {
            codec = avcodec_find_decoder(codec_id);
            if(codec) {
                codecCtx = avcodec_alloc_context3(codec);
                targetStream = fCtx->streams[i];
                stream_idx = i;
                break;
            }
        }
    }
    
    if(!codec) goto end;
    
    if(avcodec_parameters_to_context(codecCtx, targetStream->codecpar) < 0) {
        fprintf(stderr,"avcodec_parameters_to_context failed\n");
        goto end;
    }
    if(avcodec_open2(codecCtx, codec, NULL) < 0) {
        fprintf(stderr, "avcodec_open failure\n");
        goto end;
    }
    
    samplerate = codecCtx->sample_rate;
    channels = codecCtx->channels;
    totalFrames = targetStream->duration;
    //NSLog(@"%d,%d,%lld,%f",samplerate,channels,totalFrames,av_q2d(targetStream->time_base));
    bps = codecCtx->bits_per_coded_sample / 8;
    samplesPerFrame = samplesPerFrameFromHeader(path,samplerate);
    if(!samplesPerFrame) goto end;
    //NSLog(@"samples per frame:%d",samplesPerFrame);
    switch (codecCtx->sample_fmt) {
        case AV_SAMPLE_FMT_U8: planer = 0; break;
        case AV_SAMPLE_FMT_S16: planer = 0; break;
        case AV_SAMPLE_FMT_S32: planer = 0; break;
        case AV_SAMPLE_FMT_U8P: planer = 1; break;
        case AV_SAMPLE_FMT_S16P: planer = 1; break;
        case AV_SAMPLE_FMT_S32P: planer = 1; break;
        default:
            fprintf (stderr, "Unsupported audio format %d\n", (int)codecCtx->sample_fmt);
            goto end;
    }
    
    AVDictionaryEntry *t = NULL;
    while ((t = av_dict_get(fCtx->metadata, "", t, AV_DICT_IGNORE_SUFFIX))) {
        if(!strcasecmp(t->key,"cuesheet")) {
            NSString *str = [[NSString alloc] initWithUTF8String:t->value];
            if(str) {
                [metadataDic setObject:str forKey:XLD_METADATA_CUESHEET];
                [str release];
            }
        }
        else if(!strcasecmp(t->key,"title")) {
            NSString *str = [[NSString alloc] initWithUTF8String:t->value];
            if(str) {
                [metadataDic setObject:str forKey:XLD_METADATA_TITLE];
                [str release];
            }
        }
        else if(!strcasecmp(t->key,"artist")) {
            NSString *str = [[NSString alloc] initWithUTF8String:t->value];
            if(str) {
                [metadataDic setObject:str forKey:XLD_METADATA_ARTIST];
                [str release];
            }
        }
        else if(!strcasecmp(t->key,"album")) {
            NSString *str = [[NSString alloc] initWithUTF8String:t->value];
            if(str) {
                [metadataDic setObject:str forKey:XLD_METADATA_ALBUM];
                [str release];
            }
        }
        else if(!strcasecmp(t->key,"album artist")) {
            NSString *str = [[NSString alloc] initWithUTF8String:t->value];
            if(str) {
                [metadataDic setObject:str forKey:XLD_METADATA_ALBUMARTIST];
                [str release];
            }
        }
        else if(!strcasecmp(t->key,"albumartist")) {
            NSString *str = [[NSString alloc] initWithUTF8String:t->value];
            if(str) {
                if(![metadataDic objectForKey:XLD_METADATA_ALBUMARTIST])
                    [metadataDic setObject:str forKey:XLD_METADATA_ALBUMARTIST];
                [str release];
            }
        }
        else if(!strcasecmp(t->key,"genre")) {
            NSString *str = [[NSString alloc] initWithUTF8String:t->value];
            if(str) {
                [metadataDic setObject:str forKey:XLD_METADATA_GENRE];
                [str release];
            }
        }
        else if(!strcasecmp(t->key,"year")) {
            NSString *str = [[NSString alloc] initWithUTF8String:t->value];
            if(str) {
                int year = [str intValue];
                if(year >= 1000 && year < 3000) [metadataDic setObject:[NSNumber numberWithInt:year] forKey:XLD_METADATA_YEAR];
                [str release];
            }
        }
        else if(!strcasecmp(t->key,"composer")) {
            NSString *str = [[NSString alloc] initWithUTF8String:t->value];
            if(str) {
                [metadataDic setObject:str forKey:XLD_METADATA_COMPOSER];
                [str release];
            }
        }
        else if(!strcasecmp(t->key,"track")) {
            NSString *str = [[NSString alloc] initWithUTF8String:t->value];
            if(str) {
                int track = [str intValue];
                if(track > 0) [metadataDic setObject:[NSNumber numberWithInt:track] forKey:XLD_METADATA_TRACK];
                if([str rangeOfString:@"/"].location != NSNotFound) {
                    track = [[str substringFromIndex:[str rangeOfString:@"/"].location+1] intValue];
                    if(track > 0) [metadataDic setObject:[NSNumber numberWithInt:track] forKey:XLD_METADATA_TOTALTRACKS];
                }
                [str release];
            }
        }
        else if(!strcasecmp(t->key,"disc")) {
            NSString *str = [[NSString alloc] initWithUTF8String:t->value];
            if(str) {
                int disc = [str intValue];
                if(disc > 0) [metadataDic setObject:[NSNumber numberWithInt:disc] forKey:XLD_METADATA_DISC];
                if([str rangeOfString:@"/"].location != NSNotFound) {
                    disc = [[str substringFromIndex:[str rangeOfString:@"/"].location+1] intValue];
                    if(disc > 0) [metadataDic setObject:[NSNumber numberWithInt:disc] forKey:XLD_METADATA_TOTALDISCS];
                }
                [str release];
            }
        }
        else if(!strcasecmp(t->key,"comment")) {
            NSString *str = [[NSString alloc] initWithUTF8String:t->value];
            if(str) {
                [metadataDic setObject:str forKey:XLD_METADATA_COMMENT];
                [str release];
            }
        }
        else if(!strcasecmp(t->key,"lyrics")) {
            NSString *str = [[NSString alloc] initWithUTF8String:t->value];
            if(str) {
                [metadataDic setObject:str forKey:XLD_METADATA_LYRICS];
                [str release];
            }
        }
        else if(!strcasecmp(t->key,"ISRC")) {
            NSString *str = [[NSString alloc] initWithUTF8String:t->value];
            if(str) {
                [metadataDic setObject:str forKey:XLD_METADATA_ISRC];
                [str release];
            }
        }
        else if(!strcasecmp(t->key,"iTunes_CDDB_1")) {
            NSString *str = [[NSString alloc] initWithUTF8String:t->value];
            if(str) {
                [metadataDic setObject:str forKey:XLD_METADATA_GRACENOTE2];
                [str release];
            }
        }
        else if(!strcasecmp(t->key,"MUSICBRAINZ_TRACKID")) {
            NSString *str = [[NSString alloc] initWithUTF8String:t->value];
            if(str) {
                [metadataDic setObject:str forKey:XLD_METADATA_MB_TRACKID];
                [str release];
            }
        }
        else if(!strcasecmp(t->key,"MUSICBRAINZ_ALBUMID")) {
            NSString *str = [[NSString alloc] initWithUTF8String:t->value];
            if(str) {
                [metadataDic setObject:str forKey:XLD_METADATA_MB_ALBUMID];
                [str release];
            }
        }
        else if(!strcasecmp(t->key,"MUSICBRAINZ_ARTISTID")) {
            NSString *str = [[NSString alloc] initWithUTF8String:t->value];
            if(str) {
                [metadataDic setObject:str forKey:XLD_METADATA_MB_ARTISTID];
                [str release];
            }
        }
        else if(!strcasecmp(t->key,"MUSICBRAINZ_ALBUMARTISTID")) {
            NSString *str = [[NSString alloc] initWithUTF8String:t->value];
            if(str) {
                [metadataDic setObject:str forKey:XLD_METADATA_MB_ALBUMARTISTID];
                [str release];
            }
        }
        else if(!strcasecmp(t->key,"MUSICBRAINZ_DISCID")) {
            NSString *str = [[NSString alloc] initWithUTF8String:t->value];
            if(str) {
                [metadataDic setObject:str forKey:XLD_METADATA_MB_DISCID];
                [str release];
            }
        }
        else if(!strcasecmp(t->key,"MUSICIP_PUID")) {
            NSString *str = [[NSString alloc] initWithUTF8String:t->value];
            if(str) {
                [metadataDic setObject:str forKey:XLD_METADATA_PUID];
                [str release];
            }
        }
        else if(!strcasecmp(t->key,"MUSICBRAINZ_ALBUMSTATUS")) {
            NSString *str = [[NSString alloc] initWithUTF8String:t->value];
            if(str) {
                [metadataDic setObject:str forKey:XLD_METADATA_MB_ALBUMSTATUS];
                [str release];
            }
        }
        else if(!strcasecmp(t->key,"MUSICBRAINZ_ALBUMTYPE")) {
            NSString *str = [[NSString alloc] initWithUTF8String:t->value];
            if(str) {
                [metadataDic setObject:str forKey:XLD_METADATA_MB_ALBUMTYPE];
                [str release];
            }
        }
        else if(!strcasecmp(t->key,"RELEASECOUNTRY")) {
            NSString *str = [[NSString alloc] initWithUTF8String:t->value];
            if(str) {
                [metadataDic setObject:str forKey:XLD_METADATA_MB_RELEASECOUNTRY];
                [str release];
            }
        }
        else if(!strcasecmp(t->key,"MUSICBRAINZ_RELEASEGROUPID")) {
            NSString *str = [[NSString alloc] initWithUTF8String:t->value];
            if(str) {
                [metadataDic setObject:str forKey:XLD_METADATA_MB_RELEASEGROUPID];
                [str release];
            }
        }
        else if(!strcasecmp(t->key,"MUSICBRAINZ_WORKID")) {
            NSString *str = [[NSString alloc] initWithUTF8String:t->value];
            if(str) {
                [metadataDic setObject:str forKey:XLD_METADATA_MB_WORKID];
                [str release];
            }
        }
        else if(!strcasecmp(t->key,"REPLAYGAIN_TRACK_GAIN")) {
            NSString *str = [[NSString alloc] initWithUTF8String:t->value];
            if(str) {
                [metadataDic setObject:[NSNumber numberWithFloat:[str floatValue]] forKey:XLD_METADATA_REPLAYGAIN_TRACK_GAIN];
                [str release];
            }
        }
        else if(!strcasecmp(t->key,"REPLAYGAIN_TRACK_PEAK")) {
            NSString *str = [[NSString alloc] initWithUTF8String:t->value];
            if(str) {
                [metadataDic setObject:[NSNumber numberWithFloat:[str floatValue]] forKey:XLD_METADATA_REPLAYGAIN_TRACK_PEAK];
                [str release];
            }
        }
        else if(!strcasecmp(t->key,"REPLAYGAIN_ALBUM_GAIN")) {
            NSString *str = [[NSString alloc] initWithUTF8String:t->value];
            if(str) {
                [metadataDic setObject:[NSNumber numberWithFloat:[str floatValue]] forKey:XLD_METADATA_REPLAYGAIN_ALBUM_GAIN];
                [str release];
            }
        }
        else if(!strcasecmp(t->key,"REPLAYGAIN_ALBUM_PEAK")) {
            NSString *str = [[NSString alloc] initWithUTF8String:t->value];
            if(str) {
                [metadataDic setObject:[NSNumber numberWithFloat:[str floatValue]] forKey:XLD_METADATA_REPLAYGAIN_ALBUM_PEAK];
                [str release];
            }
        }
        else { //unknown text metadata
            NSString *str = [[NSString alloc] initWithUTF8String:t->value];
            NSString *idx = [[NSString alloc] initWithUTF8String:t->key];
            if(str && idx) {
                [metadataDic setObject:str forKey:[NSString stringWithFormat:@"XLD_UNKNOWN_TEXT_METADATA_%@",idx]];
            }
            if(str) [str release];
            if(idx) [idx release];
        }
    }
    for(i=0;i<fCtx->nb_streams;i++) {
        if(fCtx->streams[i]->disposition & AV_DISPOSITION_ATTACHED_PIC && fCtx->streams[i]->metadata) {
            AVDictionaryEntry *t = av_dict_get(fCtx->streams[i]->metadata, "Cover Art (front)", NULL, 0);
            if(t) {
                if(fCtx->streams[i]->attached_pic.size > 0) {
                    NSData *imgData = [NSData dataWithBytes:fCtx->streams[i]->attached_pic.data length:fCtx->streams[i]->attached_pic.size];
                    if(imgData) [metadataDic setObject:imgData forKey:XLD_METADATA_COVER];
                }
            }
        }
        else if(fCtx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_ATTACHMENT && fCtx->streams[i]->metadata) {
            AVDictionaryEntry *t = av_dict_get(fCtx->streams[i]->metadata, "Cover Art (front)", NULL, 0);
            if(t) {
                if(fCtx->streams[i]->codecpar->extradata_size > 0) {
                    NSData *imgData = [NSData dataWithBytes:fCtx->streams[i]->codecpar->extradata length:fCtx->streams[i]->codecpar->extradata_size];
                    if(imgData) [metadataDic setObject:imgData forKey:XLD_METADATA_COVER];
                }
            }
        }
    }
    
    if(srcPath) [srcPath release];
    srcPath = [[NSString alloc] initWithUTF8String:path];
    bufferedSamples = 0;
    hasValidPacket = NO;
    tmpBuffer = (int *)malloc(samplerate*channels*sizeof(int));
    lastPos = 0;
    return YES;
    
end:
    if(codecCtx) avcodec_free_context(&codecCtx);
    if(fCtx) avformat_close_input(&fCtx);
    fCtx = NULL;
    codecCtx = NULL;
    return NO;
}

- (int)samplerate
{
    return samplerate;
}

- (int)bytesPerSample
{
    return bps;
}

- (int)channels
{
    return channels;
}

- (xldoffset_t)totalFrames
{
    return totalFrames;
}

- (int)isFloat
{
    return 0;
}

- (int)decodeToBuffer:(int *)buffer frames:(int)count
{
    //fprintf(stderr,"%d samples required\n",count);
    int written = 0;
    if(bufferedSamples) {
        if(bufferedSamples >= count) {
            memcpy(buffer, tmpBuffer, count*channels*sizeof(int));
            bufferedSamples -= count;
            return count;
        }
        memcpy(buffer, tmpBuffer, bufferedSamples*channels*sizeof(int));
        written += bufferedSamples;
        bufferedSamples = 0;
    }
    AVFrame* frame = av_frame_alloc();
    AVPacket packet;
    while(1) {
        int ret = av_read_frame(fCtx, &packet);
        if(ret == AVERROR_EOF) {
            //fprintf(stderr, "EOF; %d samples written (start from %f)\n",written,(fCtx->streams[0]->duration-written)/(float)codecCtx->sample_rate);
            break;
        }
        else if(ret != 0) {
            error = YES;
            break;
        }
        if(packet.stream_index != targetStream->index) {
            av_packet_unref(&packet);
            continue;
        }
        lastPos++;
        if(avcodec_send_packet(codecCtx, &packet) != 0) {
            fprintf(stderr,"avcodec_send_packet failed\n");
            error = YES;
            av_packet_unref(&packet);
            break;
        }
        while(avcodec_receive_frame(codecCtx, frame) == 0) {
            int *ptr = buffer+written*channels;
            int i=0,j;
            int total = frame->nb_samples;
            if(written + total > count) total = count - written;
            int rest = frame->nb_samples - total;
            if(planer) {
                if(bps == 1) {
                    for(i=0;i<total;i++) {
                        for(j=0;j<channels;j++) {
                            unsigned char *inptr = (unsigned char *)frame->data[j];
                            ptr[i*channels+j] = ((int)(*(inptr+i)^0x80)) << 24;
                        }
                    }
                    for(;i<frame->nb_samples;i++) {
                        for(j=0;j<channels;j++) {
                            unsigned char *inptr = (unsigned char *)frame->data[j];
                            tmpBuffer[(i+bufferedSamples-total)*channels+j] = ((int)(*(inptr+i)^0x80)) << 24;
                        }
                    }
                }
                else if(bps == 2) {
                    for(i=0;i<total;i++) {
                        for(j=0;j<channels;j++) {
                            short *inptr = (short *)frame->data[j];
                            ptr[i*channels+j] = ((int)*(inptr+i)) << 16;
                        }
                    }
                    for(;i<frame->nb_samples;i++) {
                        for(j=0;j<channels;j++) {
                            short *inptr = (short *)frame->data[j];
                            tmpBuffer[(i+bufferedSamples-total)*channels+j] = ((int)*(inptr+i)) << 16;
                        }
                    }
                }
                else if(bps == 3) {
                    for(i=0;i<total;i++) {
                        for(j=0;j<channels;j++) {
                            int *inptr = (int *)frame->data[j];
                            ptr[i*channels+j] = *(inptr+i) << 8;
                        }
                    }
                    for(;i<frame->nb_samples;i++) {
                        for(j=0;j<channels;j++) {
                            int *inptr = (int *)frame->data[j];
                            tmpBuffer[(i+bufferedSamples-total)*channels+j] = *(inptr+i) << 8;
                        }
                    }
                }
                else if(bps == 4) {
                    for(i=0;i<total;i++) {
                        for(j=0;j<channels;j++) {
                            int *inptr = (int *)frame->data[j];
                            ptr[i*channels+j] = *(inptr+i);
                        }
                    }
                    for(;i<frame->nb_samples;i++) {
                        for(j=0;j<channels;j++) {
                            int *inptr = (int *)frame->data[j];
                            tmpBuffer[(i+bufferedSamples-total)*channels+j] = *(inptr+i);
                        }
                    }
                }
            }
            else {
                if(bps == 1) {
                    unsigned char *inptr = (unsigned char *)frame->data[0];
                    for(i=0;i<total;i++) {
                        for(j=0;j<channels;j++) {
                            ptr[i*channels+j] = ((int)(*(inptr+i*channels+j)^0x80)) << 24;
                        }
                    }
                    for(;i<frame->nb_samples;i++) {
                        for(j=0;j<channels;j++) {
                            tmpBuffer[(i+bufferedSamples-total)*channels+j] = ((int)(*(inptr+i*channels+j)^0x80)) << 24;
                        }
                    }
                }
                else if(bps == 2) {
                    short *inptr = (short *)frame->data[0];
                    for(i=0;i<total;i++) {
                        for(j=0;j<channels;j++) {
                            ptr[i*channels+j] = ((int)*(inptr+i*channels+j)) << 16;
                        }
                    }
                    for(;i<frame->nb_samples;i++) {
                        for(j=0;j<channels;j++) {
                            tmpBuffer[(i+bufferedSamples-total)*channels+j] = ((int)*(inptr+i*channels+j)) << 16;
                        }
                    }
                }
                else if(bps == 3) {
                    int *inptr = (int *)frame->data[0];
                    for(i=0;i<total;i++) {
                        for(j=0;j<channels;j++) {
                            ptr[i*channels+j] = *(inptr+i*channels+j) << 8;
                        }
                    }
                    for(;i<frame->nb_samples;i++) {
                        for(j=0;j<channels;j++) {
                            tmpBuffer[(i+bufferedSamples-total)*channels+j] = *(inptr+i*channels+j) << 8;
                        }
                    }
                }
                else if(bps == 4) {
                    int *inptr = (int *)frame->data[0];
                    for(i=0;i<total;i++) {
                        for(j=0;j<channels;j++) {
                            ptr[i*channels+j] = *(inptr+i*channels+j);
                        }
                    }
                    for(;i<frame->nb_samples;i++) {
                        for(j=0;j<channels;j++) {
                            tmpBuffer[(i+bufferedSamples-total)*channels+j] = *(inptr+i*channels+j);
                        }
                    }
                }
            }
            written += total;
            bufferedSamples += rest;
            //fprintf(stderr,"%d samples written\n",frame->nb_samples);
            //fprintf(stderr,"%d samples in outbuf, %d in tmpbuf\n",written,bufferedSamples);
        }
        av_packet_unref(&packet);
        if(written >= count) break;
    }
    av_frame_free(&frame);
    return written;
}

- (xldoffset_t)seekToFrame:(xldoffset_t)count
{
    //NSLog(@"seeking to %lld",count);
    xldoffset_t target = count/samplesPerFrame;
    if(target < lastPos) {
        if(av_seek_frame(fCtx, targetStream->index, 0, AVSEEK_FLAG_BACKWARD) < 0) {
            fprintf(stderr,"av_seek_frame failed\n");
            error = YES;
            return 0;
        }
        lastPos = 0;
    }/* else {
      //if(avformat_seek_file(fCtx,targetStream->index,INT64_MIN,count,INT64_MAX,0) < 0) {
      if(av_seek_frame(fCtx, targetStream->index, count, AVSEEK_FLAG_BACKWARD) < 0) {
      fprintf(stderr,"av_seek_frame failed\n");
      error = YES;
      return 0;
      }
      lastPos = target;
    }*/
    xldoffset_t currentPos;
    bufferedSamples = 0;
    AVFrame* frame = av_frame_alloc();
    AVPacket packet;
    while(1) {
        int ret = av_read_frame(fCtx, &packet);
        if(ret == AVERROR_EOF) {
            //fprintf(stderr, "EOF; %d samples written (start from %f)\n",written,(fCtx->streams[0]->duration-written)/(float)codecCtx->sample_rate);
            break;
        }
        else if(ret != 0) {
            error = YES;
            break;
        }
        //else if(packet.pts < 0) continue;
        if(packet.stream_index != targetStream->index) {
            av_packet_unref(&packet);
            continue;
        }
        currentPos = lastPos*samplesPerFrame;
        if(lastPos++ < target) {
            /* explicitly decode the 1st frame; otherwise decode fails */
            if(lastPos != 1) {
                av_packet_unref(&packet);
                continue;
            }
        }
        //fprintf(stderr, "target: %lld, current pos: %lld\n",count,currentPos);
        avcodec_flush_buffers(codecCtx);
        if(avcodec_send_packet(codecCtx, &packet) != 0) {
            fprintf(stderr,"avcodec_send_packet failed\n");
            error = YES;
            av_packet_unref(&packet);
            break;
        }
        while(avcodec_receive_frame(codecCtx, frame) == 0) {
            //fprintf(stderr, "current pos from frame: %lld\n",av_frame_get_best_effort_timestamp(frame));
            if(currentPos + frame->nb_samples < count) {
                currentPos += frame->nb_samples;
                continue;
            }
            int *ptr = tmpBuffer+bufferedSamples*channels;
            int i,j;
            int total = frame->nb_samples;
            xldoffset_t ignore = 0;
            if(currentPos < count) {
                ignore = count - currentPos;
                currentPos += total;
                total -= ignore;
            }
            else currentPos += total;
            if(planer) {
                if(bps == 1) {
                    for(i=0;i<total;i++) {
                        for(j=0;j<channels;j++) {
                            unsigned char *inptr = (unsigned char *)frame->data[j] + ignore;
                            ptr[i*channels+j] = ((int)(*(inptr+i)^0x80)) << 24;
                        }
                    }
                }
                else if(bps == 2) {
                    for(i=0;i<total;i++) {
                        for(j=0;j<channels;j++) {
                            short *inptr = (short *)frame->data[j] + ignore;
                            ptr[i*channels+j] = ((int)*(inptr+i)) << 16;
                        }
                    }
                }
                else if(bps == 3) {
                    for(i=0;i<total;i++) {
                        for(j=0;j<channels;j++) {
                            int *inptr = (int *)frame->data[j] + ignore;
                            ptr[i*channels+j] = *(inptr+i) << 8;
                        }
                    }
                }
                else if(bps == 4) {
                    for(i=0;i<total;i++) {
                        for(j=0;j<channels;j++) {
                            int *inptr = (int *)frame->data[j] + ignore;
                            ptr[i*channels+j] = *(inptr+i);
                        }
                    }
                }
            }
            else {
                if(bps == 1) {
                    unsigned char *inptr = (unsigned char *)frame->data[0] + ignore*channels;
                    for(i=0;i<total;i++) {
                        for(j=0;j<channels;j++) {
                            ptr[i*channels+j] = ((int)(*(inptr+i*channels+j)^0x80)) << 24;
                        }
                    }
                }
                else if(bps == 2) {
                    short *inptr = (short *)frame->data[0] + ignore*channels;
                    for(i=0;i<total;i++) {
                        for(j=0;j<channels;j++) {
                            ptr[i*channels+j] = ((int)*(inptr+i*channels+j)) << 16;
                        }
                    }
                }
                else if(bps == 3) {
                    int *inptr = (int *)frame->data[0] + ignore*channels;
                    for(i=0;i<total;i++) {
                        for(j=0;j<channels;j++) {
                            ptr[i*channels+j] = *(inptr+i*channels+j) << 8;
                        }
                    }
                }
                else if(bps == 4) {
                    int *inptr = (int *)frame->data[0] + ignore*channels;
                    for(i=0;i<total;i++) {
                        for(j=0;j<channels;j++) {
                            ptr[i*channels+j] = *(inptr+i*channels+j);
                        }
                    }
                }
            }
            bufferedSamples += total;
        }
        av_packet_unref(&packet);
        if(currentPos >= count) break;
    }
    av_frame_free(&frame);
    //NSLog(@"seek complete, %d samples in buffer",bufferedSamples);
    return count;
}

- (void)closeFile;
{
    [metadataDic removeAllObjects];
    if(codecCtx) avcodec_free_context(&codecCtx);
    if(fCtx) avformat_close_input(&fCtx);
    codecCtx = NULL;
    fCtx = NULL;
    error = NO;
}

- (BOOL)error
{
    return error;
}

- (XLDEmbeddedCueSheetType)hasCueSheet
{
    if([metadataDic objectForKey:XLD_METADATA_CUESHEET]) return XLDTextTypeCueSheet;
    else return XLDNoCueSheet;
}

- (id)cueSheet
{
    return [metadataDic objectForKey:XLD_METADATA_CUESHEET];
}

- (id)metadata
{
    return metadataDic;
}

- (NSString *)srcPath
{
    return srcPath;
}

@end
