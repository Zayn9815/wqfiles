//
//  WQMediaDemuxer.m
//  WQ Glass Native MPEG-TS / M2TS / MKV / WebM / FLV / AVI Demuxer & Lossless Remuxer
//  Pure C / Foundation / AVFoundation / CoreMedia / AudioToolbox (Zero UIKit).
//  GPL-3.0-or-later.
//

#import "WQMediaDemuxer.h"
#import <AudioToolbox/AudioToolbox.h>
#import <CommonCrypto/CommonDigest.h>
#import <CoreMedia/CoreMedia.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

@implementation WQMediaProbeInfo
- (instancetype)init
{
    if ((self = [super init])) {
        _containerFormat = @"Unknown";
        _audioTrackNames = @[];
    }
    return self;
}
@end

#pragma mark - Big-Endian / Little-Endian Helpers

static inline uint16_t wq_u16be(const uint8_t *p) { return (uint16_t)(((uint16_t)p[0] << 8) | p[1]); }
static inline uint32_t wq_u24be(const uint8_t *p) { return ((uint32_t)p[0] << 16) | ((uint32_t)p[1] << 8) | p[2]; }
static inline uint32_t wq_u32be(const uint8_t *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }
static inline uint16_t wq_u16le(const uint8_t *p) { return (uint16_t)(p[0] | ((uint16_t)p[1] << 8)); }
static inline uint32_t wq_u32le(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }
static inline uint64_t wq_u64be(const uint8_t *p)
{
    return ((uint64_t)wq_u32be(p) << 32) | (uint64_t)wq_u32be(p + 4);
}

static NSString *wq_demux_fourcc_name(FourCharCode code)
{
    char buf[5];
    buf[0] = (char)((code >> 24) & 0xFF);
    buf[1] = (char)((code >> 16) & 0xFF);
    buf[2] = (char)((code >> 8) & 0xFF);
    buf[3] = (char)(code & 0xFF);
    buf[4] = '\0';
    for (int i = 0; i < 4; i++) {
        if (buf[i] < 32 || buf[i] > 126) return @"Media";
    }
    NSString *s = [[NSString stringWithUTF8String:buf] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if ([s isEqualToString:@"avc1"] || [s isEqualToString:@"H264"] || [s isEqualToString:@"h264"]) return @"H.264";
    if ([s isEqualToString:@"hvc1"] || [s isEqualToString:@"hev1"] || [s isEqualToString:@"HEVC"]) return @"HEVC (H.265)";
    if ([s isEqualToString:@"mp4a"]) return @"AAC";
    if ([s isEqualToString:@"alac"]) return @"ALAC";
    if ([s isEqualToString:@"lpcm"]) return @"PCM";
    if ([s isEqualToString:@".mp3"]) return @"MP3";
    if ([s isEqualToString:@"ac-3"]) return @"AC-3";
    if ([s isEqualToString:@"ec-3"]) return @"E-AC-3";
    if ([s isEqualToString:@"fLaC"]) return @"FLAC";
    return s.length ? s : @"Media";
}

BOOL wq_media_needs_remux_extension(NSString *path)
{
    NSString *ext = path.pathExtension.lowercaseString;
    if (!ext.length) return NO;
    static NSSet<NSString *> *exts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        exts = [NSSet setWithArray:@[@"ts", @"m2ts", @"mts", @"mkv", @"webm", @"flv", @"avi"]];
    });
    return [exts containsObject:ext];
}

#pragma mark - Bounded WQRemuxCache

NSString *wq_media_remux_cache_dir(void)
{
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    NSString *dir = [caches stringByAppendingPathComponent:@"WQRemuxCache"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

NSString *wq_media_remux_cache_path_for(NSString *srcPath, NSString *ext)
{
    struct stat st;
    unsigned long long sz = 0;
    long mtime = 0;
    if (srcPath.length && lstat(srcPath.fileSystemRepresentation, &st) == 0) {
        sz = (unsigned long long)st.st_size;
        mtime = (long)st.st_mtime;
    }
    NSString *key = [NSString stringWithFormat:@"%@|%llu|%ld", srcPath ?: @"", sz, mtime];
    NSData *d = [key dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(d.bytes, (CC_LONG)d.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < 16; i++) [hex appendFormat:@"%02x", digest[i]];
    NSString *cleanExt = ext.length ? ext : @"mp4";
    return [wq_media_remux_cache_dir() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", hex, cleanExt]];
}

void wq_media_remux_cache_prune(unsigned long long maxBytes)
{
    if (maxBytes == 0) maxBytes = 512ULL * 1024ULL * 1024ULL;
    NSString *dir = wq_media_remux_cache_dir();
    NSURL *dirURL = [NSURL fileURLWithPath:dir];
    NSArray<NSURLResourceKey> *keys = @[NSURLIsRegularFileKey, NSURLFileSizeKey, NSURLContentModificationDateKey];
    NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:dirURL
                                                          includingPropertiesForKeys:keys
                                                                             options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                               error:nil];
    if (!files.count) return;
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray new];
    unsigned long long total = 0;
    for (NSURL *u in files) {
        NSNumber *isReg = nil, *sz = nil;
        NSDate *mod = nil;
        [u getResourceValue:&isReg forKey:NSURLIsRegularFileKey error:nil];
        if (!isReg.boolValue) continue;
        [u getResourceValue:&sz forKey:NSURLFileSizeKey error:nil];
        [u getResourceValue:&mod forKey:NSURLContentModificationDateKey error:nil];
        unsigned long long b = sz.unsignedLongLongValue;
        total += b;
        [entries addObject:@{ @"url": u, @"size": @(b), @"date": mod ?: NSDate.distantPast }];
    }
    if (total <= maxBytes && entries.count <= 16) return;
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"date"] compare:b[@"date"]]; // oldest first
    }];
    NSUInteger count = entries.count;
    for (NSDictionary *e in entries) {
        if (total <= maxBytes && count <= 16) break;
        [NSFileManager.defaultManager removeItemAtURL:e[@"url"] error:nil];
        total -= MIN(total, [e[@"size"] unsignedLongLongValue]);
        count--;
    }
}

#pragma mark - Elementary Stream Format Helpers (Annex-B + ADTS + ESDS)

typedef struct {
    const uint8_t *data;
    size_t size;
    size_t pos; // next NALU payload start
    size_t len; // payload len
} WQAnnexBCursor;

static BOOL wq_annexb_next(WQAnnexBCursor *cur, const uint8_t **outNAL, size_t *outLen)
{
    if (!cur || !cur->data || cur->pos >= cur->size) return NO;
    const uint8_t *b = cur->data;
    size_t n = cur->size;
    size_t i = cur->pos;

    // Locate current start code (3 or 4 bytes).
    while (i + 2 < n) {
        if (b[i] == 0x00 && b[i + 1] == 0x00) {
            if (b[i + 2] == 0x01) { i += 3; break; }
            if (i + 3 < n && b[i + 2] == 0x00 && b[i + 3] == 0x01) { i += 4; break; }
        }
        i++;
    }
    if (i >= n) { cur->pos = n; return NO; }

    size_t start = i;
    while (i + 2 < n) {
        if (b[i] == 0x00 && b[i + 1] == 0x00 &&
            (b[i + 2] == 0x01 || (i + 3 < n && b[i + 2] == 0x00 && b[i + 3] == 0x01))) {
            break;
        }
        i++;
    }
    size_t end = (i + 2 < n) ? i : n;
    cur->pos = end;
    *outNAL = b + start;
    *outLen = end - start;
    return (*outLen > 0);
}

static CMVideoFormatDescriptionRef wq_create_h264_format(NSData *sps, NSData *pps)
{
    if (!sps.length || !pps.length) return NULL;
    const uint8_t *sets[2] = { (const uint8_t *)sps.bytes, (const uint8_t *)pps.bytes };
    size_t sizes[2] = { sps.length, pps.length };
    CMVideoFormatDescriptionRef desc = NULL;
    OSStatus st = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, 2, sets, sizes, 4, &desc);
    return (st == noErr) ? desc : NULL;
}

static CMVideoFormatDescriptionRef wq_create_hevc_format(NSData *vps, NSData *sps, NSData *pps)
{
    if (!vps.length || !sps.length || !pps.length) return NULL;
    const uint8_t *sets[3] = {
        (const uint8_t *)vps.bytes,
        (const uint8_t *)sps.bytes,
        (const uint8_t *)pps.bytes,
    };
    size_t sizes[3] = { vps.length, sps.length, pps.length };
    CMVideoFormatDescriptionRef desc = NULL;
    OSStatus st = CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault, 3, sets, sizes, 4, NULL, &desc);
    return (st == noErr) ? desc : NULL;
}

static const uint32_t kWQAACSampleRates[16] = {
    96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
    16000, 12000, 11025, 8000, 7350, 0, 0, 0
};

static NSData *wq_build_esds_box(const uint8_t *asc, size_t ascLen)
{
    // Constructs a valid ISO BMFF esds payload (version/flags + ES_Descriptor + DecoderConfigDescriptor + DecoderSpecificInfo)
    if (!asc || ascLen == 0 || ascLen > 32) return nil;
    NSMutableData *esds = [NSMutableData new];
    uint8_t verFlags[4] = {0, 0, 0, 0};
    [esds appendBytes:verFlags length:4];

    // Tag 0x05 DecoderSpecificInfo
    uint8_t decSpecHdr[2] = { 0x05, (uint8_t)ascLen };
    // Tag 0x04 DecoderConfigDescriptor: 13 bytes fixed + 2 + ascLen
    uint8_t decCfgLen = (uint8_t)(13 + 2 + ascLen);
    // Tag 0x03 ES_Descriptor: 3 bytes fixed + 2 + decCfgLen + 3 SLConfig
    uint8_t esDescLen = (uint8_t)(3 + 2 + decCfgLen + 3);

    uint8_t esHdr[5] = { 0x03, esDescLen, 0x00, 0x01, 0x00 };
    [esds appendBytes:esHdr length:5];

    uint8_t decCfg[15] = {
        0x04, decCfgLen,
        0x40,       // objectTypeIndication: MPEG-4 Audio (0x40)
        0x15,       // streamType: AudioStream (0x05 << 2 | 1)
        0x00, 0x00, 0x00,
        0x00, 0x01, 0xF4, 0x00, // maxBitrate 128000
        0x00, 0x01, 0xF4, 0x00, // avgBitrate 128000
    };
    [esds appendBytes:decCfg length:15];
    [esds appendBytes:decSpecHdr length:2];
    [esds appendBytes:asc length:ascLen];

    uint8_t slCfg[3] = { 0x06, 0x01, 0x02 };
    [esds appendBytes:slCfg length:3];
    return esds;
}

static CMAudioFormatDescriptionRef wq_create_aac_format_from_asc(const uint8_t *asc, size_t ascLen)
{
    if (!asc || ascLen < 2) return NULL;
    uint8_t srIdx = (uint8_t)(((asc[0] & 0x07) << 1) | ((asc[1] & 0x80) >> 7));
    uint8_t chCfg = (uint8_t)((asc[1] >> 3) & 0x0F);
    uint32_t sampleRate = (srIdx < 16 && kWQAACSampleRates[srIdx] > 0) ? kWQAACSampleRates[srIdx] : 44100;
    uint32_t channels = (chCfg > 0 && chCfg <= 8) ? chCfg : 2;
    if (chCfg == 7) channels = 8;

    AudioStreamBasicDescription asbd;
    memset(&asbd, 0, sizeof(asbd));
    asbd.mSampleRate = (Float64)sampleRate;
    asbd.mFormatID = kAudioFormatMPEG4AAC;
    asbd.mChannelsPerFrame = channels;
    asbd.mFramesPerPacket = 1024;

    NSData *esds = wq_build_esds_box(asc, ascLen);
    NSDictionary *ext = esds ? @{ (__bridge NSString *)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: @{ @"esds": esds } } : nil;

    CMAudioFormatDescriptionRef desc = NULL;
    OSStatus st = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, NULL, 0, NULL,
                                                 (__bridge CFDictionaryRef)ext, &desc);
    return (st == noErr) ? desc : NULL;
}

static CMAudioFormatDescriptionRef wq_create_mp3_format(uint32_t sampleRate, uint32_t channels)
{
    AudioStreamBasicDescription asbd;
    memset(&asbd, 0, sizeof(asbd));
    asbd.mSampleRate = sampleRate ?: 44100.0;
    asbd.mFormatID = kAudioFormatMPEGLayer3;
    asbd.mChannelsPerFrame = channels ?: 2;
    asbd.mFramesPerPacket = 1152;
    CMAudioFormatDescriptionRef desc = NULL;
    OSStatus st = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, NULL, 0, NULL, NULL, &desc);
    return (st == noErr) ? desc : NULL;
}

static CMVideoFormatDescriptionRef wq_create_video_format_with_atom(FourCharCode codec, int32_t width, int32_t height,
                                                                     NSString *atomName, NSData *atomData)
{
    if (!atomData.length || width <= 0 || height <= 0) return NULL;
    NSDictionary *ext = @{
        (__bridge NSString *)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: @{ atomName: atomData }
    };
    CMVideoFormatDescriptionRef desc = NULL;
    OSStatus st = CMVideoFormatDescriptionCreate(kCFAllocatorDefault, codec, width, height,
                                                 (__bridge CFDictionaryRef)ext, &desc);
    return (st == noErr) ? desc : NULL;
}

static CMSampleBufferRef wq_make_sample_buffer(const void *bytes, size_t len, CMFormatDescriptionRef fmt,
                                               CMTime pts, CMTime dts, CMTime duration, BOOL isVideo, BOOL isSync)
{
    if (!bytes || !len || !fmt) return NULL;
    CMBlockBufferRef block = NULL;
    OSStatus st = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, len, kCFAllocatorDefault,
                                                     NULL, 0, len, kCMBlockBufferAssureMemoryNowFlag, &block);
    if (st != noErr || !block) return NULL;
    st = CMBlockBufferReplaceDataBytes(bytes, block, 0, len);
    if (st != noErr) {
        CFRelease(block);
        return NULL;
    }

    CMSampleTimingInfo timing;
    timing.duration = duration;
    timing.presentationTimeStamp = pts;
    timing.decodeTimeStamp = dts;

    CMSampleBufferRef sbuf = NULL;
    st = CMSampleBufferCreateReady(kCFAllocatorDefault, block, fmt, 1, 1, &timing, 1, &len, &sbuf);
    CFRelease(block);
    if (st != noErr || !sbuf) return NULL;

    if (isVideo && !isSync) {
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sbuf, true);
        if (attachments && CFArrayGetCount(attachments) > 0) {
            CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
            CFDictionarySetValue(dict, kCMSampleAttachmentKey_NotSync, kCFBooleanTrue);
        }
    }
    return sbuf;
}

static BOOL wq_append_sample_waiting(AVAssetWriterInput *input, CMSampleBufferRef sbuf, BOOL (^_Nullable cancelled)(void))
{
    if (!input || !sbuf) return NO;
    int spin = 0;
    while (!input.readyForMoreMediaData) {
        if (cancelled && cancelled()) return NO;
        usleep(spin < 20 ? 1500 : 5000);
        spin++;
        if (spin > 4000) return NO;
    }
    return [input appendSampleBuffer:sbuf];
}

#pragma mark - Shared Passthrough Writer Wrapper

@interface WQPassthroughMuxer : NSObject
@property (nonatomic, strong, nullable) AVAssetWriter *writer;
@property (nonatomic, strong, nullable) AVAssetWriterInput *videoInput;
@property (nonatomic, strong, nullable) AVAssetWriterInput *audioInput;
@property (nonatomic) CMVideoFormatDescriptionRef videoDesc;
@property (nonatomic) CMAudioFormatDescriptionRef audioDesc;
@property (nonatomic) BOOL sessionStarted;
@property (nonatomic) int64_t lastVideoDTS;
@property (nonatomic) int64_t lastAudioPTS;
@property (nonatomic, copy, nullable) BOOL (^cancelled)(void);
@end

@implementation WQPassthroughMuxer

- (instancetype)initWithOutputURL:(NSURL *)url fileType:(AVFileType)fileType error:(NSError **)errOut
{
    if ((self = [super init])) {
        _writer = [[AVAssetWriter alloc] initWithURL:url fileType:fileType error:errOut];
        _lastVideoDTS = -1;
        _lastAudioPTS = -1;
    }
    return self;
}

- (void)dealloc
{
    if (_videoDesc) CFRelease(_videoDesc);
    if (_audioDesc) CFRelease(_audioDesc);
}

- (BOOL)ensureSessionStartedAtTime:(CMTime)t
{
    if (!_writer) return NO;
    if (_sessionStarted) return YES;
    if (!_videoInput && !_audioInput) return NO;
    if (![_writer startWriting]) return NO;
    [_writer startSessionAtSourceTime:CMTIME_IS_VALID(t) ? t : kCMTimeZero];
    _sessionStarted = YES;
    return YES;
}

- (BOOL)configureVideoFormat:(CMVideoFormatDescriptionRef)desc
{
    if (!desc || _videoDesc) return (_videoDesc != NULL);
    if (![_writer canApplyOutputSettings:nil forMediaType:AVMediaTypeVideo]) return NO;
    AVAssetWriterInput *in = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo outputSettings:nil sourceFormatHint:desc];
    in.expectsMediaDataInRealTime = NO;
    if (![_writer canAddInput:in]) return NO;
    [_writer addInput:in];
    _videoDesc = (CMVideoFormatDescriptionRef)CFRetain(desc);
    _videoInput = in;
    return YES;
}

- (BOOL)configureAudioFormat:(CMAudioFormatDescriptionRef)desc
{
    if (!desc || _audioDesc) return (_audioDesc != NULL);
    if (![_writer canApplyOutputSettings:nil forMediaType:AVMediaTypeAudio]) return NO;
    AVAssetWriterInput *in = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio outputSettings:nil sourceFormatHint:desc];
    in.expectsMediaDataInRealTime = NO;
    if (![_writer canAddInput:in]) return NO;
    [_writer addInput:in];
    _audioDesc = (CMAudioFormatDescriptionRef)CFRetain(desc);
    _audioInput = in;
    return YES;
}

- (BOOL)appendVideoBytes:(const void *)bytes length:(size_t)len pts:(CMTime)pts dts:(CMTime)dts duration:(CMTime)dur sync:(BOOL)sync
{
    if (!_videoInput || !_videoDesc || !len) return NO;
    if (![self ensureSessionStartedAtTime:kCMTimeZero]) return NO;
    int64_t dtsVal = CMTIME_IS_VALID(dts) ? dts.value : pts.value;
    if (_lastVideoDTS >= 0 && dtsVal <= _lastVideoDTS) {
        dtsVal = _lastVideoDTS + 1;
        if (CMTIME_IS_VALID(dts)) dts.value = dtsVal;
        if (pts.value < dtsVal) pts.value = dtsVal;
    }
    _lastVideoDTS = dtsVal;
    CMSampleBufferRef sb = wq_make_sample_buffer(bytes, len, _videoDesc, pts, dts, dur, YES, sync);
    if (!sb) return NO;
    BOOL ok = wq_append_sample_waiting(_videoInput, sb, _cancelled);
    CFRelease(sb);
    return ok;
}

- (BOOL)appendAudioBytes:(const void *)bytes length:(size_t)len pts:(CMTime)pts duration:(CMTime)dur
{
    if (!_audioInput || !_audioDesc || !len) return NO;
    if (![self ensureSessionStartedAtTime:kCMTimeZero]) return NO;
    if (_lastAudioPTS >= 0 && pts.value <= _lastAudioPTS) {
        pts.value = _lastAudioPTS + 1;
    }
    _lastAudioPTS = pts.value;
    CMSampleBufferRef sb = wq_make_sample_buffer(bytes, len, _audioDesc, pts, pts, dur, NO, YES);
    if (!sb) return NO;
    BOOL ok = wq_append_sample_waiting(_audioInput, sb, _cancelled);
    CFRelease(sb);
    return ok;
}

- (BOOL)finish:(NSString **)errorOut
{
    if (!_writer) return NO;
    if (!_sessionStarted) {
        if (errorOut) *errorOut = @"No valid audio or video streams found in source file.";
        return NO;
    }
    [_videoInput markAsFinished];
    [_audioInput markAsFinished];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [_writer finishWritingWithCompletionHandler:^{
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    if (_writer.status == AVAssetWriterStatusCompleted) return YES;
    if (errorOut) *errorOut = _writer.error.localizedDescription ?: @"Writer failed to finalize output.";
    return NO;
}

@end

#pragma mark - MPEG-TS / M2TS Detector & Parser

static BOOL wq_ts_detect_stride(int fd, size_t *outStride, size_t *outOffset)
{
    uint8_t buf[4096];
    ssize_t n = pread(fd, buf, sizeof(buf), 0);
    if (n < 188 * 2) return NO;
    for (size_t off = 0; off < 256 && off + 192 * 2 < (size_t)n; off++) {
        // Check 188-byte TS first
        if (off + 188 * 3 < (size_t)n &&
            buf[off] == 0x47 && buf[off + 188] == 0x47 && buf[off + 376] == 0x47) {
            *outStride = 188;
            *outOffset = off;
            return YES;
        }
        // Check 192-byte BDAV M2TS (4-byte arrival timestamp + 0x47 sync)
        if (off + 4 + 192 * 2 < (size_t)n &&
            buf[off + 4] == 0x47 && buf[off + 192 + 4] == 0x47 && buf[off + 384 + 4] == 0x47) {
            *outStride = 192;
            *outOffset = off;
            return YES;
        }
    }
    return NO;
}

static int64_t wq_parse_pes_timestamp(const uint8_t *p)
{
    int64_t hi = (int64_t)((p[0] >> 1) & 0x07);
    int64_t mid = (int64_t)(((uint32_t)p[1] << 7) | ((p[2] >> 1) & 0x7F));
    int64_t lo = (int64_t)(((uint32_t)p[3] << 7) | ((p[4] >> 1) & 0x7F));
    return (hi << 30) | (mid << 15) | lo;
}

static NSString *wq_ts_stream_type_name(uint8_t st, BOOL *isVideo, BOOL *isAudio)
{
    *isVideo = NO;
    *isAudio = NO;
    switch (st) {
        case 0x1B: *isVideo = YES; return @"H.264";
        case 0x24: *isVideo = YES; return @"HEVC (H.265)";
        case 0x01:
        case 0x02: *isVideo = YES; return @"MPEG-2";
        case 0x10: *isVideo = YES; return @"MPEG-4";
        case 0x0F: *isAudio = YES; return @"AAC";
        case 0x11: *isAudio = YES; return @"AAC-LATM";
        case 0x03:
        case 0x04: *isAudio = YES; return @"MP3";
        case 0x81: *isAudio = YES; return @"AC-3";
        case 0x87: *isAudio = YES; return @"E-AC-3";
        default: return nil;
    }
}

typedef struct {
    uint16_t pmtPID;
    uint16_t videoPID;
    uint8_t videoStreamType;
    NSMutableArray<NSDictionary *> *audioStreams; // @{@"pid": @(pid), @"type": @(st), @"name": name}
} WQTSProgramMap;

static BOOL wq_ts_parse_section_tables(const uint8_t *pkt188, WQTSProgramMap *pmap)
{
    if (!pkt188 || pkt188[0] != 0x47) return NO;
    BOOL pusi = (pkt188[1] & 0x40) != 0;
    uint16_t pid = (uint16_t)(((pkt188[1] & 0x1F) << 8) | pkt188[2]);
    uint8_t afc = (pkt188[3] >> 4) & 0x03;
    if (!(afc & 0x01)) return NO;
    size_t pos = 4;
    if (afc & 0x02) {
        size_t al = pkt188[4];
        pos += 1 + al;
    }
    if (!pusi || pos >= 188) return NO;
    uint8_t pointer = pkt188[pos++];
    pos += pointer;
    if (pos + 3 >= 188) return NO;

    uint8_t tableID = pkt188[pos];
    size_t secLen = (size_t)(((pkt188[pos + 1] & 0x0F) << 8) | pkt188[pos + 2]);
    if (pos + 3 + secLen > 188) secLen = 188 - pos - 3;

    if (pid == 0x0000 && tableID == 0x00 && secLen >= 9) {
        size_t p = pos + 8;
        size_t end = pos + 3 + secLen - 4;
        while (p + 4 <= end) {
            uint16_t prog = wq_u16be(pkt188 + p);
            uint16_t pmt = (uint16_t)(((pkt188[p + 2] & 0x1F) << 8) | pkt188[p + 3]);
            if (prog != 0 && pmt != 0) {
                pmap->pmtPID = pmt;
                return YES;
            }
            p += 4;
        }
    } else if (pmap->pmtPID != 0 && pid == pmap->pmtPID && tableID == 0x02 && secLen >= 13) {
        uint16_t progInfoLen = (uint16_t)(((pkt188[pos + 10] & 0x0F) << 8) | pkt188[pos + 11]);
        size_t p = pos + 12 + progInfoLen;
        size_t end = pos + 3 + secLen - 4;
        if (end > 188) end = 188;
        while (p + 5 <= end) {
            uint8_t st = pkt188[p];
            uint16_t esPID = (uint16_t)(((pkt188[p + 1] & 0x1F) << 8) | pkt188[p + 2]);
            uint16_t esInfoLen = (uint16_t)(((pkt188[p + 3] & 0x0F) << 8) | pkt188[p + 4]);
            BOOL isV = NO, isA = NO;
            NSString *name = wq_ts_stream_type_name(st, &isV, &isA);
            if (isV && pmap->videoPID == 0) {
                pmap->videoPID = esPID;
                pmap->videoStreamType = st;
            } else if (isA && name) {
                BOOL exists = NO;
                for (NSDictionary *d in pmap->audioStreams) {
                    if ([d[@"pid"] unsignedShortValue] == esPID) { exists = YES; break; }
                }
                if (!exists) {
                    [pmap->audioStreams addObject:@{ @"pid": @(esPID), @"type": @(st), @"name": name }];
                }
            }
            p += 5 + esInfoLen;
        }
        return YES;
    }
    return NO;
}

static void wq_parse_h264_sps_size(const uint8_t *nal, size_t len, NSInteger *outW, NSInteger *outH)
{
    // Minimal Exp-Golomb RBSP parser for H.264 SPS baseline/main/high dimensions.
    if (!nal || len < 4 || (nal[0] & 0x1F) != 7) return;
    // Unescape emulation prevention 0x00 0x00 0x03
    uint8_t rbsp[256];
    size_t rlen = 0;
    for (size_t i = 1; i < len && rlen < sizeof(rbsp); i++) {
        if (i + 2 < len && nal[i] == 0x00 && nal[i + 1] == 0x00 && nal[i + 2] == 0x03) {
            rbsp[rlen++] = 0x00;
            rbsp[rlen++] = 0x00;
            i += 2;
        } else {
            rbsp[rlen++] = nal[i];
        }
    }
    if (rlen < 4) return;
    __block size_t bitPos = 0;
    uint32_t (^readBits)(int count) = ^uint32_t(int count) {
        uint32_t v = 0;
        for (int k = 0; k < count; k++) {
            size_t bIdx = bitPos / 8;
            int bOff = 7 - (int)(bitPos % 8);
            if (bIdx >= rlen) return 0;
            v = (v << 1) | ((rbsp[bIdx] >> bOff) & 1U);
            bitPos++;
        }
        return v;
    };
    uint32_t (^readUE)(void) = ^uint32_t(void) {
        int zeros = 0;
        while (bitPos / 8 < rlen && readBits(1) == 0 && zeros < 31) zeros++;
        if (zeros == 0) return 0;
        return ((1U << zeros) - 1U) + readBits(zeros);
    };
    int32_t (^readSE)(void) = ^int32_t(void) {
        uint32_t ue = readUE();
        int32_t mag = (int32_t)((ue + 1) >> 1);
        return (ue & 1U) ? mag : -mag;
    };

    uint8_t profile = rbsp[0];
    bitPos = 24; // skip profile_idc, constraint_set, level_idc
    (void)readUE(); // seq_parameter_set_id
    uint32_t chroma = 1;
    if (profile == 100 || profile == 110 || profile == 122 || profile == 244 ||
        profile == 44 || profile == 83 || profile == 86 || profile == 118 || profile == 128) {
        chroma = readUE();
        if (chroma == 3) (void)readBits(1);
        (void)readUE(); (void)readUE(); (void)readBits(1);
        if (readBits(1)) {
            int scCount = (chroma != 3) ? 8 : 12;
            for (int i = 0; i < scCount; i++) {
                if (readBits(1)) {
                    int sz = (i < 6) ? 16 : 64;
                    int last = 8, next = 8;
                    for (int j = 0; j < sz; j++) {
                        if (next != 0) next = (last + readSE() + 256) % 256;
                        last = (next == 0) ? last : next;
                    }
                }
            }
        }
    }
    (void)readUE(); // log2_max_frame_num_minus4
    uint32_t picOrder = readUE();
    if (picOrder == 0) (void)readUE();
    else if (picOrder == 1) {
        (void)readBits(1); (void)readSE(); (void)readSE();
        uint32_t nref = readUE();
        for (uint32_t i = 0; i < nref && i < 64; i++) (void)readSE();
    }
    (void)readUE(); // max_num_ref_frames
    (void)readBits(1);
    uint32_t picW_m1 = readUE();
    uint32_t picH_m1 = readUE();
    uint32_t frameMbsOnly = readBits(1);
    if (!frameMbsOnly) (void)readBits(1);
    (void)readBits(1);
    uint32_t cropL = 0, cropR = 0, cropT = 0, cropB = 0;
    if (readBits(1)) {
        cropL = readUE(); cropR = readUE(); cropT = readUE(); cropB = readUE();
    }
    NSInteger w = (NSInteger)(picW_m1 + 1) * 16 - (NSInteger)(cropL + cropR) * 2;
    NSInteger h = (NSInteger)(2 - frameMbsOnly) * (NSInteger)(picH_m1 + 1) * 16 - (NSInteger)(cropT + cropB) * 2;
    if (w > 0 && h > 0 && w <= 8192 && h <= 8192) {
        *outW = w;
        *outH = h;
    }
}

static WQMediaProbeInfo *wq_probe_ts(int fd, size_t stride, size_t offset, unsigned long long fileSize)
{
    WQMediaProbeInfo *info = [WQMediaProbeInfo new];
    info.containerFormat = (stride == 192) ? @"BDAV / M2TS" : @"MPEG-TS";
    info.fileSizeBytes = fileSize;
    info.needsRemuxForAVFoundation = YES;

    WQTSProgramMap pmap = { .pmtPID = 0, .videoPID = 0, .videoStreamType = 0, .audioStreams = [NSMutableArray new] };
    uint8_t *headBuf = malloc(1024 * 1024);
    if (!headBuf) return info;
    ssize_t nHead = pread(fd, headBuf, 1024 * 1024, (off_t)offset);
    int64_t minPTS = -1, maxPTS = -1;
    BOOL scannedSize = NO;

    NSMutableData *vidSample = [NSMutableData new];
    for (size_t pos = 0; pos + stride <= (size_t)MAX(0, nHead); pos += stride) {
        const uint8_t *pkt = headBuf + pos + (stride == 192 ? 4 : 0);
        if (pkt[0] != 0x47) continue;
        wq_ts_parse_section_tables(pkt, &pmap);
        uint16_t pid = (uint16_t)(((pkt[1] & 0x1F) << 8) | pkt[2]);
        BOOL pusi = (pkt[1] & 0x40) != 0;
        uint8_t afc = (pkt[3] >> 4) & 0x03;
        if (!(afc & 0x01)) continue;
        size_t pay = 4;
        if (afc & 0x02) pay += 1 + pkt[4];
        if (pay >= 188) continue;

        if (pusi && (pid == pmap.videoPID || pmap.videoPID == 0) && pay + 14 <= 188 &&
            pkt[pay] == 0x00 && pkt[pay + 1] == 0x00 && pkt[pay + 2] == 0x01) {
            uint8_t sid = pkt[pay + 3];
            if ((sid & 0xF0) == 0xE0 || (sid & 0xE0) == 0xC0) {
                uint8_t flags = pkt[pay + 7];
                if ((flags & 0x80) && pay + 14 <= 188) {
                    int64_t pts = wq_parse_pes_timestamp(pkt + pay + 9);
                    if (minPTS < 0 || pts < minPTS) minPTS = pts;
                    if (maxPTS < 0 || pts > maxPTS) maxPTS = pts;
                }
            }
        }
        if (!scannedSize && pmap.videoPID && pid == pmap.videoPID) {
            size_t skip = 0;
            if (pusi && pay + 9 <= 188 && pkt[pay] == 0x00 && pkt[pay + 1] == 0x00 && pkt[pay + 2] == 0x01) {
                skip = 9 + pkt[pay + 8];
            }
            if (pay + skip < 188 && vidSample.length < 131072) {
                [vidSample appendBytes:pkt + pay + skip length:188 - (pay + skip)];
            }
            if (vidSample.length >= 2048 && pmap.videoStreamType == 0x1B) {
                WQAnnexBCursor cur = { vidSample.bytes, vidSample.length, 0, 0 };
                const uint8_t *nal = NULL;
                size_t nalLen = 0;
                while (wq_annexb_next(&cur, &nal, &nalLen)) {
                    if ((nal[0] & 0x1F) == 7) {
                        NSInteger w = 0, h = 0;
                        wq_parse_h264_sps_size(nal, nalLen, &w, &h);
                        if (w > 0 && h > 0) { info.width = w; info.height = h; scannedSize = YES; break; }
                    }
                }
            }
        }
    }
    free(headBuf);

    // Scan tail window for final PTS to compute true duration.
    if (fileSize > stride * 50) {
        size_t tailRead = (size_t)MIN((unsigned long long)(512 * 1024), fileSize - offset);
        off_t startOff = (off_t)(fileSize - tailRead);
        startOff = (off_t)offset + (((startOff - (off_t)offset) / (off_t)stride) * (off_t)stride);
        uint8_t *tailBuf = malloc(tailRead);
        if (tailBuf) {
            ssize_t nTail = pread(fd, tailBuf, tailRead, startOff);
            for (size_t pos = 0; pos + stride <= (size_t)MAX(0, nTail); pos += stride) {
                const uint8_t *pkt = tailBuf + pos + (stride == 192 ? 4 : 0);
                if (pkt[0] != 0x47) continue;
                BOOL pusi = (pkt[1] & 0x40) != 0;
                uint8_t afc = (pkt[3] >> 4) & 0x03;
                if (!pusi || !(afc & 0x01)) continue;
                size_t pay = 4 + ((afc & 0x02) ? (1 + pkt[4]) : 0);
                if (pay + 14 <= 188 && pkt[pay] == 0x00 && pkt[pay + 1] == 0x00 && pkt[pay + 2] == 0x01) {
                    uint8_t sid = pkt[pay + 3];
                    if ((sid & 0xF0) == 0xE0 || (sid & 0xE0) == 0xC0) {
                        uint8_t flags = pkt[pay + 7];
                        if ((flags & 0x80) && pay + 14 <= 188) {
                            int64_t pts = wq_parse_pes_timestamp(pkt + pay + 9);
                            if (maxPTS < 0 || pts > maxPTS) maxPTS = pts;
                        }
                    }
                }
            }
            free(tailBuf);
        }
    }

    if (minPTS >= 0 && maxPTS > minPTS) {
        int64_t delta = maxPTS - minPTS;
        info.durationSeconds = (double)delta / 90000.0;
        if (info.durationSeconds > 0.1) {
            info.bitrateBps = (unsigned long long)((double)fileSize * 8.0 / info.durationSeconds);
        }
    }
    if (pmap.videoPID != 0) {
        BOOL dummyV = NO, dummyA = NO;
        info.hasVideo = YES;
        info.videoTrackCount = 1;
        info.videoCodec = wq_ts_stream_type_name(pmap.videoStreamType, &dummyV, &dummyA) ?: @"H.264";
    }
    if (pmap.audioStreams.count) {
        info.hasAudio = YES;
        info.audioTrackCount = (NSInteger)pmap.audioStreams.count;
        NSMutableArray<NSString *> *names = [NSMutableArray new];
        for (NSDictionary *d in pmap.audioStreams) [names addObject:d[@"name"]];
        info.audioTrackNames = names;
        info.audioCodec = names.firstObject;
    }
    return info;
}

#pragma mark - MPEG-TS / M2TS Lossless Remuxer

@interface WQTSAudioFrameSink : NSObject
@property (nonatomic) uint16_t pid;
@property (nonatomic) uint8_t streamType;
@property (nonatomic, strong) NSMutableData *pesBuffer;
@property (nonatomic) int64_t currentPTS;
@property (nonatomic) BOOL hasPTS;
@property (nonatomic) BOOL configured;
@property (nonatomic) uint32_t sampleRate;
@property (nonatomic) uint64_t totalSamplesEmitted;
@end

@implementation WQTSAudioFrameSink
- (instancetype)init
{
    if ((self = [super init])) {
        _pesBuffer = [NSMutableData new];
    }
    return self;
}
@end

static BOOL wq_remux_ts(int fd, size_t stride, size_t startOffset, unsigned long long fileSize,
                        NSURL *outURL, AVFileType outType,
                        BOOL (^cancelled)(void), void (^progress)(float), NSString **errorOut)
{
    WQTSProgramMap pmap = { .pmtPID = 0, .videoPID = 0, .videoStreamType = 0, .audioStreams = [NSMutableArray new] };
    // Pre-scan first 1MB for PAT/PMT and initial SPS/PPS/VPS/ADTS config so AVAssetWriter knows every track BEFORE startWriting!
    size_t preLen = (size_t)MIN((unsigned long long)(2 * 1024 * 1024), fileSize - startOffset);
    uint8_t *preBuf = malloc(preLen);
    if (!preBuf) { if (errorOut) *errorOut = @"Out of memory"; return NO; }
    ssize_t nPre = pread(fd, preBuf, preLen, (off_t)startOffset);

    NSMutableData *vSample = [NSMutableData new];
    NSMutableData *aSample = [NSMutableData new];
    int64_t basePTS = -1;

    for (size_t pos = 0; pos + stride <= (size_t)MAX(0, nPre); pos += stride) {
        const uint8_t *pkt = preBuf + pos + (stride == 192 ? 4 : 0);
        if (pkt[0] != 0x47) continue;
        wq_ts_parse_section_tables(pkt, &pmap);
        uint16_t pid = (uint16_t)(((pkt[1] & 0x1F) << 8) | pkt[2]);
        BOOL pusi = (pkt[1] & 0x40) != 0;
        uint8_t afc = (pkt[3] >> 4) & 0x03;
        if (!(afc & 0x01)) continue;
        size_t pay = 4 + ((afc & 0x02) ? (1 + pkt[4]) : 0);
        if (pay >= 188) continue;

        uint16_t firstAudPID = pmap.audioStreams.count ? [pmap.audioStreams.firstObject[@"pid"] unsignedShortValue] : 0;
        if (pid == pmap.videoPID || (firstAudPID && pid == firstAudPID)) {
            size_t skip = 0;
            if (pusi && pay + 9 <= 188 && pkt[pay] == 0x00 && pkt[pay + 1] == 0x00 && pkt[pay + 2] == 0x01) {
                if ((pkt[pay + 7] & 0x80) && pay + 14 <= 188) {
                    int64_t pts = wq_parse_pes_timestamp(pkt + pay + 9);
                    if (basePTS < 0 || pts < basePTS) basePTS = pts;
                }
                skip = 9 + pkt[pay + 8];
            }
            if (pay + skip < 188) {
                if (pid == pmap.videoPID && vSample.length < 512 * 1024) {
                    [vSample appendBytes:pkt + pay + skip length:188 - (pay + skip)];
                } else if (firstAudPID && pid == firstAudPID && aSample.length < 65536) {
                    [aSample appendBytes:pkt + pay + skip length:188 - (pay + skip)];
                }
            }
        }
    }
    free(preBuf);

    if (basePTS < 0) basePTS = 0;
    NSError *wErr = nil;
    WQPassthroughMuxer *muxer = [[WQPassthroughMuxer alloc] initWithOutputURL:outURL fileType:outType error:&wErr];
    muxer.cancelled = cancelled;
    if (!muxer.writer || wErr) {
        if (errorOut) *errorOut = wErr.localizedDescription ?: @"Could not create MP4 writer.";
        return NO;
    }

    // Extract H.264/HEVC parameter sets
    BOOL isHEVC = (pmap.videoStreamType == 0x24);
    NSData *vps = nil, *sps = nil, *pps = nil;
    if (vSample.length) {
        WQAnnexBCursor cur = { vSample.bytes, vSample.length, 0, 0 };
        const uint8_t *nal = NULL;
        size_t nalLen = 0;
        while (wq_annexb_next(&cur, &nal, &nalLen)) {
            if (isHEVC) {
                uint8_t ntype = (uint8_t)((nal[0] >> 1) & 0x3F);
                if (ntype == 32 && !vps) vps = [NSData dataWithBytes:nal length:nalLen];
                else if (ntype == 33 && !sps) sps = [NSData dataWithBytes:nal length:nalLen];
                else if (ntype == 34 && !pps) pps = [NSData dataWithBytes:nal length:nalLen];
            } else {
                uint8_t ntype = nal[0] & 0x1F;
                if (ntype == 7 && !sps) sps = [NSData dataWithBytes:nal length:nalLen];
                else if (ntype == 8 && !pps) pps = [NSData dataWithBytes:nal length:nalLen];
            }
        }
        CMVideoFormatDescriptionRef vfmt = isHEVC ? wq_create_hevc_format(vps, sps, pps) : wq_create_h264_format(sps, pps);
        if (vfmt) {
            [muxer configureVideoFormat:vfmt];
            CFRelease(vfmt);
        }
    }

    uint16_t audioPID = pmap.audioStreams.count ? [pmap.audioStreams.firstObject[@"pid"] unsignedShortValue] : 0;
    uint8_t audioType = pmap.audioStreams.count ? (uint8_t)[pmap.audioStreams.firstObject[@"type"] unsignedCharValue] : 0;
    uint32_t audioSR = 44100;
    if (audioPID && aSample.length >= 7) {
        const uint8_t *ab = aSample.bytes;
        size_t al = aSample.length;
        if (audioType == 0x0F || audioType == 0x11) {
            for (size_t i = 0; i + 7 <= al; i++) {
                if (ab[i] == 0xFF && (ab[i + 1] & 0xF0) == 0xF0) {
                    uint8_t profile = (uint8_t)((ab[i + 2] >> 6) & 0x03) + 1;
                    uint8_t srIdx = (uint8_t)((ab[i + 2] >> 2) & 0x0F);
                    uint8_t chCfg = (uint8_t)(((ab[i + 2] & 0x01) << 2) | ((ab[i + 3] >> 6) & 0x03));
                    audioSR = (srIdx < 16 && kWQAACSampleRates[srIdx]) ? kWQAACSampleRates[srIdx] : 44100;
                    uint8_t asc[2] = {
                        (uint8_t)((profile << 3) | (srIdx >> 1)),
                        (uint8_t)(((srIdx & 1) << 7) | ((chCfg ?: 2) << 3))
                    };
                    CMAudioFormatDescriptionRef afmt = wq_create_aac_format_from_asc(asc, 2);
                    if (afmt) {
                        [muxer configureAudioFormat:afmt];
                        CFRelease(afmt);
                    }
                    break;
                }
            }
        } else if (audioType == 0x03 || audioType == 0x04) {
            CMAudioFormatDescriptionRef afmt = wq_create_mp3_format(44100, 2);
            if (afmt) {
                [muxer configureAudioFormat:afmt];
                CFRelease(afmt);
            }
        }
    }

    if (!muxer.videoInput && !muxer.audioInput) {
        if (errorOut) *errorOut = @"No supported H.264/HEVC video or AAC/MP3 audio stream found in this .ts file.";
        return NO;
    }

    NSMutableData *vPES = [NSMutableData new];
    int64_t vPTS = 0, vDTS = 0;
    BOOL vHasPTS = NO, vHasDTS = NO;

    WQTSAudioFrameSink *aSink = [WQTSAudioFrameSink new];
    aSink.pid = audioPID;
    aSink.streamType = audioType;
    aSink.sampleRate = audioSR;

    void (^flushVideoPES)(void) = ^{
        if (!muxer.videoInput || vPES.length < 9) { [vPES setLength:0]; return; }
        const uint8_t *pb = vPES.bytes;
        if (pb[0] != 0x00 || pb[1] != 0x00 || pb[2] != 0x01) { [vPES setLength:0]; return; }
        size_t hdrLen = 9 + pb[8];
        if (hdrLen >= vPES.length) { [vPES setLength:0]; return; }

        WQAnnexBCursor cur = { pb + hdrLen, vPES.length - hdrLen, 0, 0 };
        NSMutableData *avccFrame = [NSMutableData new];
        BOOL keyframe = NO;
        const uint8_t *nal = NULL;
        size_t nalLen = 0;
        while (wq_annexb_next(&cur, &nal, &nalLen)) {
            if (isHEVC) {
                uint8_t ntype = (uint8_t)((nal[0] >> 1) & 0x3F);
                if (ntype == 32 || ntype == 33 || ntype == 34 || ntype == 35) continue;
                if (ntype >= 16 && ntype <= 21) keyframe = YES;
            } else {
                uint8_t ntype = nal[0] & 0x1F;
                if (ntype == 7 || ntype == 8 || ntype == 9) continue;
                if (ntype == 5) keyframe = YES;
            }
            uint32_t beLen = CFSwapInt32HostToBig((uint32_t)nalLen);
            [avccFrame appendBytes:&beLen length:4];
            [avccFrame appendBytes:nal length:nalLen];
        }
        if (avccFrame.length) {
            int64_t relPTS = vHasPTS ? (vPTS - basePTS) : 0;
            if (relPTS < 0) relPTS = 0;
            int64_t relDTS = vHasDTS ? (vDTS - basePTS) : relPTS;
            if (relDTS < 0) relDTS = 0;
            CMTime ptsTime = CMTimeMake(relPTS, 90000);
            CMTime dtsTime = CMTimeMake(relDTS, 90000);
            [muxer appendVideoBytes:avccFrame.bytes length:avccFrame.length pts:ptsTime dts:dtsTime duration:CMTimeMake(3003, 90000) sync:keyframe];
        }
        [vPES setLength:0];
    };

    void (^flushAudioPES)(void) = ^{
        if (!muxer.audioInput || aSink.pesBuffer.length < 9) { [aSink.pesBuffer setLength:0]; return; }
        const uint8_t *pb = aSink.pesBuffer.bytes;
        if (pb[0] != 0x00 || pb[1] != 0x00 || pb[2] != 0x01) { [aSink.pesBuffer setLength:0]; return; }
        size_t hdrLen = 9 + pb[8];
        if (hdrLen >= aSink.pesBuffer.length) { [aSink.pesBuffer setLength:0]; return; }
        const uint8_t *es = pb + hdrLen;
        size_t esLen = aSink.pesBuffer.length - hdrLen;

        int64_t baseAudio90 = aSink.hasPTS ? MAX(0LL, aSink.currentPTS - basePTS) : 0;
        CMTime pesStart = CMTimeMake(baseAudio90, 90000);
        uint64_t frameCountInPES = 0;

        if (aSink.streamType == 0x0F || aSink.streamType == 0x11) {
            size_t i = 0;
            while (i + 7 <= esLen) {
                if (es[i] == 0xFF && (es[i + 1] & 0xF0) == 0xF0) {
                    size_t adtsHdr = (es[i + 1] & 0x01) ? 7 : 9;
                    size_t flen = (size_t)(((es[i + 3] & 0x03) << 11) | ((size_t)es[i + 4] << 3) | (es[i + 5] >> 5));
                    if (flen > adtsHdr && i + flen <= esLen) {
                        CMTime fDur = CMTimeMake(1024, (int32_t)aSink.sampleRate);
                        CMTime fOff = CMTimeMake((int64_t)(frameCountInPES * 1024ULL), (int32_t)aSink.sampleRate);
                        CMTime pts = aSink.hasPTS ? CMTimeAdd(CMTimeConvertScale(pesStart, (int32_t)aSink.sampleRate, kCMTimeRoundingMethod_Default), fOff)
                                                  : CMTimeMake((int64_t)(aSink.totalSamplesEmitted * 1024ULL), (int32_t)aSink.sampleRate);
                        [muxer appendAudioBytes:es + i + adtsHdr length:flen - adtsHdr pts:pts duration:fDur];
                        frameCountInPES++;
                        aSink.totalSamplesEmitted++;
                        i += flen;
                        continue;
                    }
                }
                i++;
            }
        } else if (esLen > 0) {
            CMTime pts = aSink.hasPTS ? CMTimeConvertScale(pesStart, (int32_t)aSink.sampleRate, kCMTimeRoundingMethod_Default)
                                      : CMTimeMake((int64_t)(aSink.totalSamplesEmitted * 1152ULL), (int32_t)aSink.sampleRate);
            [muxer appendAudioBytes:es length:esLen pts:pts duration:CMTimeMake(1152, (int32_t)aSink.sampleRate)];
            aSink.totalSamplesEmitted++;
        }
        [aSink.pesBuffer setLength:0];
    };

    const size_t chunkBytes = stride * 256;
    uint8_t *chunk = malloc(chunkBytes);
    if (!chunk) { if (errorOut) *errorOut = @"Out of memory"; return NO; }
    off_t offset = (off_t)startOffset;
    off_t lastReport = 0;

    while ((unsigned long long)offset < fileSize) {
        if (cancelled && cancelled()) {
            free(chunk);
            if (errorOut) *errorOut = @"Cancelled.";
            return NO;
        }
        ssize_t got = pread(fd, chunk, chunkBytes, offset);
        if (got <= 0) break;
        for (size_t p = 0; p + stride <= (size_t)got; p += stride) {
            const uint8_t *pkt = chunk + p + (stride == 192 ? 4 : 0);
            if (pkt[0] != 0x47) continue;
            uint16_t pid = (uint16_t)(((pkt[1] & 0x1F) << 8) | pkt[2]);
            BOOL pusi = (pkt[1] & 0x40) != 0;
            uint8_t afc = (pkt[3] >> 4) & 0x03;
            if (!(afc & 0x01)) continue;
            size_t pay = 4 + ((afc & 0x02) ? (1 + pkt[4]) : 0);
            if (pay >= 188) continue;

            if (pid == pmap.videoPID) {
                if (pusi) {
                    flushVideoPES();
                    vHasPTS = NO; vHasDTS = NO;
                    if (pay + 9 <= 188 && pkt[pay] == 0x00 && pkt[pay + 1] == 0x00 && pkt[pay + 2] == 0x01) {
                        uint8_t flags = pkt[pay + 7];
                        if ((flags & 0xC0) == 0x80 && pay + 14 <= 188) {
                            vPTS = wq_parse_pes_timestamp(pkt + pay + 9);
                            vHasPTS = YES;
                        } else if ((flags & 0xC0) == 0xC0 && pay + 19 <= 188) {
                            vPTS = wq_parse_pes_timestamp(pkt + pay + 9);
                            vDTS = wq_parse_pes_timestamp(pkt + pay + 14);
                            vHasPTS = YES;
                            vHasDTS = YES;
                        }
                    }
                }
                [vPES appendBytes:pkt + pay length:188 - pay];
            } else if (audioPID && pid == audioPID) {
                if (pusi) {
                    flushAudioPES();
                    aSink.hasPTS = NO;
                    if (pay + 9 <= 188 && pkt[pay] == 0x00 && pkt[pay + 1] == 0x00 && pkt[pay + 2] == 0x01) {
                        if ((pkt[pay + 7] & 0x80) && pay + 14 <= 188) {
                            aSink.currentPTS = wq_parse_pes_timestamp(pkt + pay + 9);
                            aSink.hasPTS = YES;
                        }
                    }
                }
                [aSink.pesBuffer appendBytes:pkt + pay length:188 - pay];
            }
        }
        offset += got;
        if (progress && (offset - lastReport >= (off_t)(fileSize / 40 + 16384))) {
            lastReport = offset;
            progress((float)MIN(0.96, (double)offset / (double)MAX(1ULL, fileSize)));
        }
    }
    free(chunk);

    flushVideoPES();
    flushAudioPES();
    BOOL ok = [muxer finish:errorOut];
    if (ok && progress) progress(1.0f);
    return ok;
}

#pragma mark - FLV Detector, Probe & Lossless Remuxer

static BOOL wq_is_flv(int fd)
{
    uint8_t h[4] = {0};
    return pread(fd, h, 4, 0) == 4 && h[0] == 'F' && h[1] == 'L' && h[2] == 'V';
}

static WQMediaProbeInfo *wq_probe_flv(int fd, unsigned long long fileSize)
{
    WQMediaProbeInfo *info = [WQMediaProbeInfo new];
    info.containerFormat = @"FLV";
    info.fileSizeBytes = fileSize;
    info.needsRemuxForAVFoundation = YES;

    uint8_t *buf = malloc((size_t)MIN((unsigned long long)(512 * 1024), fileSize));
    if (!buf) return info;
    ssize_t n = pread(fd, buf, (size_t)MIN((unsigned long long)(512 * 1024), fileSize), 0);
    if (n < 13) { free(buf); return info; }
    size_t pos = wq_u32be(buf + 5) + 4; // header + PreviousTagSize0
    uint32_t maxTS = 0;

    while (pos + 11 < (size_t)n) {
        uint8_t tagType = buf[pos];
        uint32_t dataSize = wq_u24be(buf + pos + 1);
        uint32_t ts = wq_u24be(buf + pos + 4) | ((uint32_t)buf[pos + 7] << 24);
        if (ts > maxTS) maxTS = ts;
        size_t payload = pos + 11;
        if (payload + dataSize + 4 > (size_t)n) break;
        if (tagType == 9 && dataSize >= 1) {
            uint8_t codecID = buf[payload] & 0x0F;
            info.hasVideo = YES;
            info.videoTrackCount = 1;
            info.videoCodec = (codecID == 7) ? @"H.264" : (codecID == 12 ? @"HEVC (H.265)" : @"Flash Video");
        } else if (tagType == 8 && dataSize >= 1) {
            uint8_t sf = (buf[payload] >> 4) & 0x0F;
            info.hasAudio = YES;
            info.audioTrackCount = 1;
            info.audioCodec = (sf == 10) ? @"AAC" : (sf == 2 || sf == 14 ? @"MP3" : @"Audio");
            info.audioTrackNames = @[info.audioCodec];
        }
        pos = payload + dataSize + 4;
    }
    free(buf);
    if (maxTS > 0) info.durationSeconds = (double)maxTS / 1000.0;
    return info;
}

static BOOL wq_remux_flv(int fd, unsigned long long fileSize, NSURL *outURL, AVFileType outType,
                         BOOL (^cancelled)(void), void (^progress)(float), NSString **errorOut)
{
    uint8_t *buf = malloc((size_t)fileSize);
    if (!buf) { if (errorOut) *errorOut = @"FLV file too large for buffer"; return NO; }
    ssize_t n = pread(fd, buf, (size_t)fileSize, 0);
    if (n < 13) { free(buf); if (errorOut) *errorOut = @"Invalid FLV header"; return NO; }

    NSError *err = nil;
    WQPassthroughMuxer *muxer = [[WQPassthroughMuxer alloc] initWithOutputURL:outURL fileType:outType error:&err];
    muxer.cancelled = cancelled;
    if (!muxer.writer || err) { free(buf); if (errorOut) *errorOut = err.localizedDescription; return NO; }

    size_t pos = wq_u32be(buf + 5) + 4;
    // Pass 1: find sequence headers to configure tracks
    while (pos + 11 < (size_t)n) {
        uint8_t tagType = buf[pos];
        uint32_t dataSize = wq_u24be(buf + pos + 1);
        size_t pay = pos + 11;
        if (pay + dataSize + 4 > (size_t)n) break;
        if (tagType == 9 && dataSize > 5 && (buf[pay] & 0x0F) == 7 && buf[pay + 1] == 0) {
            NSData *avcC = [NSData dataWithBytes:buf + pay + 5 length:dataSize - 5];
            CMVideoFormatDescriptionRef vf = wq_create_video_format_with_atom(kCMVideoCodecType_H264, 1280, 720, @"avcC", avcC);
            if (vf) { [muxer configureVideoFormat:vf]; CFRelease(vf); }
        } else if (tagType == 8 && dataSize > 2 && ((buf[pay] >> 4) & 0x0F) == 10 && buf[pay + 1] == 0) {
            CMAudioFormatDescriptionRef af = wq_create_aac_format_from_asc(buf + pay + 2, dataSize - 2);
            if (af) { [muxer configureAudioFormat:af]; CFRelease(af); }
        } else if (tagType == 8 && dataSize > 1 && ((buf[pay] >> 4) & 0x0F) == 2 && !muxer.audioDesc) {
            CMAudioFormatDescriptionRef af = wq_create_mp3_format(44100, 2);
            if (af) { [muxer configureAudioFormat:af]; CFRelease(af); }
        }
        pos = pay + dataSize + 4;
    }

    if (!muxer.videoInput && !muxer.audioInput) {
        free(buf);
        if (errorOut) *errorOut = @"No H.264/AAC tracks found in FLV file.";
        return NO;
    }

    // Pass 2: stream packets
    pos = wq_u32be(buf + 5) + 4;
    while (pos + 11 < (size_t)n) {
        if (cancelled && cancelled()) { free(buf); if (errorOut) *errorOut = @"Cancelled."; return NO; }
        uint8_t tagType = buf[pos];
        uint32_t dataSize = wq_u24be(buf + pos + 1);
        int64_t ts = (int64_t)(wq_u24be(buf + pos + 4) | ((uint32_t)buf[pos + 7] << 24));
        size_t pay = pos + 11;
        if (pay + dataSize + 4 > (size_t)n) break;
        if (tagType == 9 && dataSize > 5 && (buf[pay] & 0x0F) == 7 && buf[pay + 1] == 1 && muxer.videoInput) {
            BOOL isSync = ((buf[pay] >> 4) & 0x0F) == 1;
            int32_t cts = ((int32_t)((buf[pay + 2] << 24) | (buf[pay + 3] << 16) | (buf[pay + 4] << 8))) >> 8;
            CMTime dts = CMTimeMake(ts, 1000);
            CMTime pts = CMTimeMake(ts + cts, 1000);
            [muxer appendVideoBytes:buf + pay + 5 length:dataSize - 5 pts:pts dts:dts duration:CMTimeMake(33, 1000) sync:isSync];
        } else if (tagType == 8 && dataSize > 2 && ((buf[pay] >> 4) & 0x0F) == 10 && buf[pay + 1] == 1 && muxer.audioInput) {
            [muxer appendAudioBytes:buf + pay + 2 length:dataSize - 2 pts:CMTimeMake(ts, 1000) duration:CMTimeMake(23, 1000)];
        } else if (tagType == 8 && dataSize > 1 && ((buf[pay] >> 4) & 0x0F) == 2 && muxer.audioInput) {
            [muxer appendAudioBytes:buf + pay + 1 length:dataSize - 1 pts:CMTimeMake(ts, 1000) duration:CMTimeMake(26, 1000)];
        }
        pos = pay + dataSize + 4;
        if (progress) progress((float)MIN(0.98, (double)pos / (double)MAX(1, n)));
    }
    free(buf);
    BOOL ok = [muxer finish:errorOut];
    if (ok && progress) progress(1.0f);
    return ok;
}

#pragma mark - EBML / Matroska (MKV / WebM) Detector, Probe & Lightweight Remuxer

static BOOL wq_is_ebml(int fd)
{
    uint8_t h[4] = {0};
    return pread(fd, h, 4, 0) == 4 && h[0] == 0x1A && h[1] == 0x45 && h[2] == 0xDF && h[3] == 0xA3;
}

static size_t wq_ebml_vint_id(const uint8_t *b, size_t maxLen, uint32_t *outID)
{
    if (!maxLen || b[0] == 0) return 0;
    uint8_t m = b[0];
    size_t len = 1;
    while (len <= 4 && (m & (0x80 >> (len - 1))) == 0) len++;
    if (len > 4 || len > maxLen) return 0;
    uint32_t id = 0;
    for (size_t i = 0; i < len; i++) id = (id << 8) | b[i];
    *outID = id;
    return len;
}

static size_t wq_ebml_vint_size(const uint8_t *b, size_t maxLen, uint64_t *outVal, BOOL stripMarker)
{
    if (!maxLen || b[0] == 0) return 0;
    uint8_t m = b[0];
    size_t len = 1;
    while (len <= 8 && (m & (0x80 >> (len - 1))) == 0) len++;
    if (len > 8 || len > maxLen) return 0;
    uint64_t v = stripMarker ? (uint64_t)(m & (0xFF >> len)) : (uint64_t)m;
    for (size_t i = 1; i < len; i++) v = (v << 8) | b[i];
    *outVal = v;
    return len;
}

static double wq_ebml_read_float(const uint8_t *b, size_t len)
{
    if (len == 4) {
        uint32_t u = wq_u32be(b);
        float f = 0;
        memcpy(&f, &u, 4);
        return (double)f;
    }
    if (len == 8) {
        uint64_t u = wq_u64be(b);
        double d = 0;
        memcpy(&d, &u, 8);
        return d;
    }
    return 0.0;
}

static uint64_t wq_ebml_read_uint(const uint8_t *b, size_t len)
{
    uint64_t v = 0;
    for (size_t i = 0; i < len && i < 8; i++) v = (v << 8) | b[i];
    return v;
}

typedef struct {
    uint64_t trackNum;
    uint8_t trackType; // 1=video, 2=audio
    char codecID[64];
    NSInteger width;
    NSInteger height;
    double sampleRate;
    NSInteger channels;
    NSData *codecPrivate;
} WQMkvTrackInfo;

static NSString *wq_mkv_friendly_codec(const char *cid)
{
    if (!cid || !cid[0]) return nil;
    if (strstr(cid, "V_MPEG4/ISO/AVC")) return @"H.264";
    if (strstr(cid, "V_MPEGH/ISO/HEVC")) return @"HEVC (H.265)";
    if (strstr(cid, "V_VP9")) return @"VP9";
    if (strstr(cid, "V_VP8")) return @"VP8";
    if (strstr(cid, "V_AV1")) return @"AV1";
    if (strstr(cid, "A_AAC")) return @"AAC";
    if (strstr(cid, "A_MPEG/L3")) return @"MP3";
    if (strstr(cid, "A_AC3")) return @"AC-3";
    if (strstr(cid, "A_EAC3")) return @"E-AC-3";
    if (strstr(cid, "A_OPUS")) return @"Opus";
    if (strstr(cid, "A_VORBIS")) return @"Vorbis";
    if (strstr(cid, "A_FLAC")) return @"FLAC";
    return [NSString stringWithUTF8String:cid];
}

static void wq_mkv_parse_header_from_buffer(const uint8_t *buf, size_t len,
                                            BOOL *isWebM, uint64_t *timecodeScale, double *durationRaw,
                                            NSMutableArray<NSValue *> *tracksOut)
{
    size_t pos = 0;
    uint64_t tcScale = 1000000; // default 1ms in ns
    while (pos < len) {
        uint32_t eid = 0;
        size_t idLen = wq_ebml_vint_id(buf + pos, len - pos, &eid);
        if (!idLen) break;
        uint64_t esize = 0;
        size_t szLen = wq_ebml_vint_size(buf + pos + idLen, len - pos - idLen, &esize, YES);
        if (!szLen) break;
        size_t body = pos + idLen + szLen;
        // Container elements whose children we descend into:
        if (eid == 0x18538067 || eid == 0x1549A966 || eid == 0x1654AE6B) { // Segment, Info, Tracks
            pos = body;
            continue;
        }
        if (eid == 0x1F43B675) break; // First Cluster reached
        if (body + esize > len) break;

        if (eid == 0x1A45DFA3) { // EBML Header
            NSData *sub = [NSData dataWithBytesNoCopy:(void *)(buf + body) length:(NSUInteger)esize freeWhenDone:NO];
            NSData *webmTag = [@"webm" dataUsingEncoding:NSASCIIStringEncoding];
            if ([sub rangeOfData:webmTag options:0 range:NSMakeRange(0, sub.length)].location != NSNotFound) {
                *isWebM = YES;
            }
        } else if (eid == 0x2AD7B1) { // TimecodeScale
            tcScale = wq_ebml_read_uint(buf + body, (size_t)esize) ?: 1000000;
        } else if (eid == 0x4489) { // Duration
            *durationRaw = wq_ebml_read_float(buf + body, (size_t)esize);
        } else if (eid == 0xAE) { // TrackEntry
            WQMkvTrackInfo t;
            memset(&t, 0, sizeof(t));
            t.sampleRate = 44100.0;
            t.channels = 2;
            size_t tp = body;
            size_t tEnd = body + (size_t)esize;
            while (tp < tEnd) {
                uint32_t tid = 0;
                size_t tidL = wq_ebml_vint_id(buf + tp, tEnd - tp, &tid);
                if (!tidL) break;
                uint64_t tsz = 0;
                size_t tszL = wq_ebml_vint_size(buf + tp + tidL, tEnd - tp - tidL, &tsz, YES);
                if (!tszL) break;
                size_t tbody = tp + tidL + tszL;
                if (tid == 0xE0 || tid == 0xE1) { tp = tbody; continue; } // Video / Audio sub-master
                if (tbody + tsz > tEnd) break;
                if (tid == 0xD7) t.trackNum = wq_ebml_read_uint(buf + tbody, (size_t)tsz);
                else if (tid == 0x83) t.trackType = (uint8_t)wq_ebml_read_uint(buf + tbody, (size_t)tsz);
                else if (tid == 0x86) {
                    size_t cl = (size_t)MIN(tsz, (uint64_t)(sizeof(t.codecID) - 1));
                    memcpy(t.codecID, buf + tbody, cl);
                    t.codecID[cl] = '\0';
                } else if (tid == 0xB0) t.width = (NSInteger)wq_ebml_read_uint(buf + tbody, (size_t)tsz);
                else if (tid == 0xBA) t.height = (NSInteger)wq_ebml_read_uint(buf + tbody, (size_t)tsz);
                else if (tid == 0xB5) t.sampleRate = wq_ebml_read_float(buf + tbody, (size_t)tsz);
                else if (tid == 0x9F) t.channels = (NSInteger)wq_ebml_read_uint(buf + tbody, (size_t)tsz);
                else if (tid == 0x63A2 && tsz > 0 && tsz <= 65536) {
                    t.codecPrivate = [NSData dataWithBytes:buf + tbody length:(NSUInteger)tsz];
                }
                tp = tbody + (size_t)tsz;
            }
            [tracksOut addObject:[NSValue valueWithBytes:&t objCType:@encode(WQMkvTrackInfo)]];
        }
        pos = body + (size_t)esize;
    }
    *timecodeScale = tcScale;
}

static WQMediaProbeInfo *wq_probe_ebml(int fd, unsigned long long fileSize)
{
    WQMediaProbeInfo *info = [WQMediaProbeInfo new];
    info.fileSizeBytes = fileSize;
    info.needsRemuxForAVFoundation = YES;

    size_t scan = (size_t)MIN((unsigned long long)(512 * 1024), fileSize);
    uint8_t *buf = malloc(scan);
    if (!buf) { info.containerFormat = @"Matroska (MKV)"; return info; }
    ssize_t n = pread(fd, buf, scan, 0);
    BOOL isWebM = NO;
    uint64_t tcScale = 1000000;
    double durRaw = 0;
    NSMutableArray<NSValue *> *tracks = [NSMutableArray new];
    if (n > 16) {
        wq_mkv_parse_header_from_buffer(buf, (size_t)n, &isWebM, &tcScale, &durRaw, tracks);
    }
    free(buf);
    info.containerFormat = isWebM ? @"WebM" : @"Matroska (MKV)";
    if (durRaw > 0) {
        info.durationSeconds = (durRaw * (double)tcScale) / 1000000000.0;
        if (info.durationSeconds > 0.1) {
            info.bitrateBps = (unsigned long long)((double)fileSize * 8.0 / info.durationSeconds);
        }
    }
    NSMutableArray<NSString *> *audioNames = [NSMutableArray new];
    for (NSValue *v in tracks) {
        WQMkvTrackInfo t;
        [v getValue:&t];
        NSString *cname = wq_mkv_friendly_codec(t.codecID);
        if (t.trackType == 1) {
            info.hasVideo = YES;
            info.videoTrackCount++;
            if (!info.videoCodec) info.videoCodec = cname;
            if (!info.width) info.width = t.width;
            if (!info.height) info.height = t.height;
        } else if (t.trackType == 2) {
            info.hasAudio = YES;
            info.audioTrackCount++;
            if (cname) [audioNames addObject:cname];
            if (!info.audioCodec) info.audioCodec = cname;
        }
    }
    info.audioTrackNames = audioNames;
    return info;
}

static BOOL wq_remux_ebml(int fd, unsigned long long fileSize, NSURL *outURL, AVFileType outType,
                          BOOL (^cancelled)(void), void (^progress)(float), NSString **errorOut)
{
    if (fileSize > 768ULL * 1024ULL * 1024ULL) {
        if (errorOut) *errorOut = @"MKV/WebM passthrough buffer limit exceeded (>768 MB).";
        return NO;
    }
    uint8_t *buf = malloc((size_t)fileSize);
    if (!buf) { if (errorOut) *errorOut = @"Out of memory reading MKV."; return NO; }
    ssize_t n = pread(fd, buf, (size_t)fileSize, 0);
    if (n < 32) { free(buf); if (errorOut) *errorOut = @"Invalid MKV/WebM file."; return NO; }

    BOOL isWebM = NO;
    uint64_t tcScale = 1000000;
    double durRaw = 0;
    NSMutableArray<NSValue *> *tracks = [NSMutableArray new];
    wq_mkv_parse_header_from_buffer(buf, (size_t)n, &isWebM, &tcScale, &durRaw, tracks);

    NSError *err = nil;
    WQPassthroughMuxer *muxer = [[WQPassthroughMuxer alloc] initWithOutputURL:outURL fileType:outType error:&err];
    muxer.cancelled = cancelled;
    if (!muxer.writer || err) { free(buf); if (errorOut) *errorOut = err.localizedDescription; return NO; }

    uint64_t vTrackNum = 0, aTrackNum = 0;
    for (NSValue *v in tracks) {
        WQMkvTrackInfo t;
        [v getValue:&t];
        if (t.trackType == 1 && !vTrackNum && t.codecPrivate.length) {
            if (strstr(t.codecID, "V_MPEG4/ISO/AVC")) {
                CMVideoFormatDescriptionRef vf = wq_create_video_format_with_atom(kCMVideoCodecType_H264,
                                                                                   (int32_t)(t.width ?: 1280),
                                                                                   (int32_t)(t.height ?: 720),
                                                                                   @"avcC", t.codecPrivate);
                if (vf) { [muxer configureVideoFormat:vf]; CFRelease(vf); vTrackNum = t.trackNum; }
            } else if (strstr(t.codecID, "V_MPEGH/ISO/HEVC")) {
                CMVideoFormatDescriptionRef vf = wq_create_video_format_with_atom(kCMVideoCodecType_HEVC,
                                                                                   (int32_t)(t.width ?: 1280),
                                                                                   (int32_t)(t.height ?: 720),
                                                                                   @"hvcC", t.codecPrivate);
                if (vf) { [muxer configureVideoFormat:vf]; CFRelease(vf); vTrackNum = t.trackNum; }
            }
        } else if (t.trackType == 2 && !aTrackNum) {
            if (strstr(t.codecID, "A_AAC") && t.codecPrivate.length >= 2) {
                CMAudioFormatDescriptionRef af = wq_create_aac_format_from_asc(t.codecPrivate.bytes, t.codecPrivate.length);
                if (af) { [muxer configureAudioFormat:af]; CFRelease(af); aTrackNum = t.trackNum; }
            } else if (strstr(t.codecID, "A_MPEG/L3")) {
                CMAudioFormatDescriptionRef af = wq_create_mp3_format((uint32_t)t.sampleRate, (uint32_t)t.channels);
                if (af) { [muxer configureAudioFormat:af]; CFRelease(af); aTrackNum = t.trackNum; }
            }
        }
    }

    if (!muxer.videoInput && !muxer.audioInput) {
        free(buf);
        if (errorOut) *errorOut = @"This MKV/WebM uses a codec without Apple hardware passthrough support (e.g. VP9/AV1/Opus).";
        return NO;
    }

    // Walk Segment Clusters
    size_t pos = 0;
    uint64_t clusterTC = 0;
    while (pos < (size_t)n) {
        if (cancelled && cancelled()) { free(buf); if (errorOut) *errorOut = @"Cancelled."; return NO; }
        uint32_t eid = 0;
        size_t idLen = wq_ebml_vint_id(buf + pos, (size_t)n - pos, &eid);
        if (!idLen) break;
        uint64_t esize = 0;
        size_t szLen = wq_ebml_vint_size(buf + pos + idLen, (size_t)n - pos - idLen, &esize, YES);
        if (!szLen) break;
        size_t body = pos + idLen + szLen;
        if (eid == 0x18538067 || eid == 0x1F43B675 || eid == 0xA0) { // Segment, Cluster, BlockGroup
            pos = body;
            continue;
        }
        if (body + esize > (size_t)n) break;
        if (eid == 0xE7) { // Cluster Timecode
            clusterTC = wq_ebml_read_uint(buf + body, (size_t)esize);
        } else if ((eid == 0xA3 || eid == 0xA1) && esize >= 4) { // SimpleBlock or Block
            uint64_t trk = 0;
            size_t tlen = wq_ebml_vint_size(buf + body, (size_t)esize, &trk, YES);
            if (tlen && tlen + 3 <= esize) {
                int16_t rel = (int16_t)wq_u16be(buf + body + tlen);
                uint8_t bflags = buf[body + tlen + 2];
                BOOL keyframe = (eid == 0xA3) ? ((bflags & 0x80) != 0) : YES;
                size_t hdrOff = tlen + 3;
                uint64_t absMs = (uint64_t)((int64_t)clusterTC + (int64_t)rel);
                CMTime pts = CMTimeMake((int64_t)absMs, 1000);
                // Handle single frame (lacing == 0) directly
                uint8_t lacing = (bflags >> 1) & 0x03;
                if (lacing == 0 && hdrOff < esize) {
                    if (trk == vTrackNum && muxer.videoInput) {
                        [muxer appendVideoBytes:buf + body + hdrOff length:(size_t)esize - hdrOff pts:pts dts:pts duration:CMTimeMake(33, 1000) sync:keyframe];
                    } else if (trk == aTrackNum && muxer.audioInput) {
                        [muxer appendAudioBytes:buf + body + hdrOff length:(size_t)esize - hdrOff pts:pts duration:CMTimeMake(23, 1000)];
                    }
                }
            }
        }
        pos = body + (size_t)esize;
        if (progress) progress((float)MIN(0.98, (double)pos / (double)MAX(1, n)));
    }
    free(buf);
    BOOL ok = [muxer finish:errorOut];
    if (ok && progress) progress(1.0f);
    return ok;
}

#pragma mark - RIFF / AVI Detector & Probe

static BOOL wq_is_avi(int fd)
{
    uint8_t h[12] = {0};
    return pread(fd, h, 12, 0) == 12 &&
           memcmp(h, "RIFF", 4) == 0 && memcmp(h + 8, "AVI ", 4) == 0;
}

static WQMediaProbeInfo *wq_probe_avi(int fd, unsigned long long fileSize)
{
    WQMediaProbeInfo *info = [WQMediaProbeInfo new];
    info.containerFormat = @"AVI";
    info.fileSizeBytes = fileSize;
    info.needsRemuxForAVFoundation = YES;

    size_t scan = (size_t)MIN((unsigned long long)(128 * 1024), fileSize);
    uint8_t *buf = malloc(scan);
    if (!buf) return info;
    ssize_t n = pread(fd, buf, scan, 0);
    for (size_t i = 12; i + 8 < (size_t)MAX(0, n); i += 2) {
        if (memcmp(buf + i, "avih", 4) == 0 && i + 8 + 40 <= (size_t)n) {
            uint32_t usPerFrame = wq_u32le(buf + i + 8);
            uint32_t totalFrames = wq_u32le(buf + i + 24);
            uint32_t width = wq_u32le(buf + i + 40);
            uint32_t height = wq_u32le(buf + i + 44);
            if (width > 0 && height > 0) { info.width = (NSInteger)width; info.height = (NSInteger)height; }
            if (usPerFrame > 0 && totalFrames > 0) {
                info.fps = 1000000.0 / (double)usPerFrame;
                info.durationSeconds = ((double)usPerFrame * (double)totalFrames) / 1000000.0;
            }
        } else if (memcmp(buf + i, "strh", 4) == 0 && i + 8 + 16 <= (size_t)n) {
            const uint8_t *sh = buf + i + 8;
            if (memcmp(sh, "vids", 4) == 0) {
                info.hasVideo = YES;
                info.videoTrackCount++;
                FourCharCode fc = wq_u32be(sh + 4);
                info.videoCodec = wq_demux_fourcc_name(fc);
            } else if (memcmp(sh, "auds", 4) == 0) {
                info.hasAudio = YES;
                info.audioTrackCount++;
                info.audioCodec = @"Audio";
                info.audioTrackNames = @[@"Audio"];
            }
        }
    }
    free(buf);
    return info;
}

#pragma mark - Public Probe & Remux Entry Points

WQMediaProbeInfo *wq_media_probe_file(NSString *path)
{
    if (!path.length) return nil;
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0) return nil;
    unsigned long long fileSize = (unsigned long long)st.st_size;

    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (fd >= 0) {
        size_t stride = 0, off = 0;
        if (wq_ts_detect_stride(fd, &stride, &off)) {
            WQMediaProbeInfo *ts = wq_probe_ts(fd, stride, off, fileSize);
            close(fd);
            return ts;
        }
        if (wq_is_flv(fd)) {
            WQMediaProbeInfo *flv = wq_probe_flv(fd, fileSize);
            close(fd);
            return flv;
        }
        if (wq_is_ebml(fd)) {
            WQMediaProbeInfo *ebml = wq_probe_ebml(fd, fileSize);
            close(fd);
            return ebml;
        }
        if (wq_is_avi(fd)) {
            WQMediaProbeInfo *avi = wq_probe_avi(fd, fileSize);
            close(fd);
            return avi;
        }
        close(fd);
    }

    // Fallback: Apple-native AVURLAsset probe
    WQMediaProbeInfo *info = [WQMediaProbeInfo new];
    info.containerFormat = path.pathExtension.uppercaseString.length ? path.pathExtension.uppercaseString : @"Media";
    info.fileSizeBytes = fileSize;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSArray<AVAssetTrack *> *vTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    NSArray<AVAssetTrack *> *aTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    CMTime dur = asset.duration;
#pragma clang diagnostic pop
    info.durationSeconds = CMTIME_IS_NUMERIC(dur) ? CMTimeGetSeconds(dur) : 0.0;
    if (info.durationSeconds > 0.1) {
        info.bitrateBps = (unsigned long long)((double)fileSize * 8.0 / info.durationSeconds);
    }
    if (vTracks.count > 0) {
        AVAssetTrack *vt = vTracks.firstObject;
        CGSize nat = vt.naturalSize;
        CGSize tr = CGSizeApplyAffineTransform(nat, vt.preferredTransform);
        info.width = (NSInteger)llround(fabs(tr.width));
        info.height = (NSInteger)llround(fabs(tr.height));
        info.fps = vt.nominalFrameRate;
        info.hasVideo = YES;
        info.videoTrackCount = (NSInteger)vTracks.count;
        if (vt.formatDescriptions.count > 0) {
            CMFormatDescriptionRef fdRef = (__bridge CMFormatDescriptionRef)vt.formatDescriptions.firstObject;
            info.videoCodec = wq_demux_fourcc_name(CMFormatDescriptionGetMediaSubType(fdRef));
        }
    }
    if (aTracks.count > 0) {
        info.hasAudio = YES;
        info.audioTrackCount = (NSInteger)aTracks.count;
        NSMutableArray<NSString *> *anames = [NSMutableArray new];
        for (AVAssetTrack *at in aTracks) {
            NSString *cname = @"Audio";
            if (at.formatDescriptions.count > 0) {
                CMFormatDescriptionRef fdRef = (__bridge CMFormatDescriptionRef)at.formatDescriptions.firstObject;
                cname = wq_demux_fourcc_name(CMFormatDescriptionGetMediaSubType(fdRef));
            }
            if (at.languageCode.length) cname = [NSString stringWithFormat:@"%@ (%@)", cname, at.languageCode.uppercaseString];
            [anames addObject:cname];
        }
        info.audioTrackNames = anames;
        info.audioCodec = anames.firstObject;
    }
    return info;
}

BOOL wq_media_remux_file(NSString *srcPath,
                         NSString *dstPath,
                         AVFileType outputFileType,
                         BOOL (^cancelled)(void),
                         void (^progress)(float fraction),
                         NSString **errorOut)
{
    if (!srcPath.length || !dstPath.length) {
        if (errorOut) *errorOut = @"Invalid source or destination path.";
        return NO;
    }
    struct stat st;
    if (lstat(srcPath.fileSystemRepresentation, &st) != 0) {
        if (errorOut) *errorOut = [NSString stringWithUTF8String:strerror(errno)];
        return NO;
    }
    unsigned long long fileSize = (unsigned long long)st.st_size;
    [NSFileManager.defaultManager removeItemAtPath:dstPath error:nil];
    [NSFileManager.defaultManager createDirectoryAtPath:dstPath.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *outURL = [NSURL fileURLWithPath:dstPath];
    AVFileType ftype = outputFileType ?: AVFileTypeMPEG4;

    int fd = open(srcPath.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) {
        if (errorOut) *errorOut = [NSString stringWithUTF8String:strerror(errno)];
        return NO;
    }

    size_t stride = 0, off = 0;
    BOOL handled = NO;
    BOOL ok = NO;
    if (wq_ts_detect_stride(fd, &stride, &off)) {
        handled = YES;
        ok = wq_remux_ts(fd, stride, off, fileSize, outURL, ftype, cancelled, progress, errorOut);
    } else if (wq_is_flv(fd)) {
        handled = YES;
        ok = wq_remux_flv(fd, fileSize, outURL, ftype, cancelled, progress, errorOut);
    } else if (wq_is_ebml(fd)) {
        handled = YES;
        ok = wq_remux_ebml(fd, fileSize, outURL, ftype, cancelled, progress, errorOut);
    }
    close(fd);

    if (!handled) {
        if (errorOut) *errorOut = @"Lossless remuxer currently supports MPEG-TS (.ts/.m2ts), FLV, and MKV/WebM (H.264/HEVC + AAC/MP3). Use Full Re-Encode for other containers.";
        return NO;
    }
    if (!ok) {
        [NSFileManager.defaultManager removeItemAtPath:dstPath error:nil];
    }
    return ok;
}
