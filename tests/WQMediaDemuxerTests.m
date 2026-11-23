//
//  WQMediaDemuxerTests.m
//  Host-side unit tests for WQMediaDemuxer (.ts / .m2ts / .flv / .mkv probing & lossless MP4 remuxing).
//

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import "../WQMediaDemuxer.h"
#include <string.h>

static int gFailures = 0;
#define CHECK(cond) do { if (!(cond)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #cond); gFailures++; } } while (0)

static void appendTSPacket(NSMutableData *dst, uint16_t pid, BOOL pusi, NSData *payload)
{
    uint8_t pkt[188];
    memset(pkt, 0xFF, sizeof(pkt));
    pkt[0] = 0x47;
    pkt[1] = (uint8_t)((pusi ? 0x40 : 0x00) | ((pid >> 8) & 0x1F));
    pkt[2] = (uint8_t)(pid & 0xFF);
    pkt[3] = 0x10;
    size_t copyLen = MIN((size_t)184, payload.length);
    if (copyLen > 0) memcpy(pkt + 4, payload.bytes, copyLen);
    [dst appendBytes:pkt length:188];
}

static void encodePESTimestamp(uint8_t *out, int64_t pts)
{
    out[0] = (uint8_t)(0x21 | (((pts >> 30) & 0x07) << 1));
    out[1] = (uint8_t)((pts >> 22) & 0xFF);
    out[2] = (uint8_t)(0x01 | (((pts >> 15) & 0x7F) << 1));
    out[3] = (uint8_t)((pts >> 7) & 0xFF);
    out[4] = (uint8_t)(0x01 | ((pts & 0x7F) << 1));
}

static NSData *buildPES(uint8_t streamID, int64_t pts, NSData *esPayload)
{
    NSMutableData *pes = [NSMutableData new];
    uint8_t hdr[14] = {0};
    hdr[0] = 0x00; hdr[1] = 0x00; hdr[2] = 0x01; hdr[3] = streamID;
    uint16_t pesLen = (uint16_t)MIN((NSUInteger)65000, 8 + esPayload.length);
    hdr[4] = (uint8_t)((pesLen >> 8) & 0xFF);
    hdr[5] = (uint8_t)(pesLen & 0xFF);
    hdr[6] = 0x80;
    hdr[7] = 0x80; // PTS present
    hdr[8] = 5;
    encodePESTimestamp(hdr + 9, pts);
    [pes appendBytes:hdr length:14];
    [pes appendData:esPayload];
    return pes;
}

static NSData *buildSyntheticTS(void)
{
    NSMutableData *ts = [NSMutableData new];

    // PAT (PID 0x0000 -> PMT PID 0x1000)
    const uint8_t pat[] = {
        0x00, // pointer
        0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00,
        0x00, 0x01, 0xF0, 0x00,
        0x00, 0x00, 0x00, 0x00
    };
    appendTSPacket(ts, 0x0000, YES, [NSData dataWithBytes:pat length:sizeof(pat)]);

    // PMT (PID 0x1000: H.264 0x1B on PID 0x0100, AAC 0x0F on PID 0x0101)
    const uint8_t pmt[] = {
        0x00, // pointer
        0x02, 0xB0, 0x17, 0x00, 0x01, 0xC1, 0x00, 0x00,
        0xE1, 0x00, 0xF0, 0x00,
        0x1B, 0xE1, 0x00, 0xF0, 0x00,
        0x0F, 0xE1, 0x01, 0xF0, 0x00,
        0x00, 0x00, 0x00, 0x00
    };
    appendTSPacket(ts, 0x1000, YES, [NSData dataWithBytes:pmt length:sizeof(pmt)]);

    // Minimal valid H.264 Baseline SPS (320x240) + PPS + IDR slice
    const uint8_t h264ES[] = {
        0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0xE0, 0x1E, 0xDA, 0x05, 0x07, 0xE8, 0x40, 0x00, 0x00, 0x03, 0x00, 0x40, 0x00, 0x00, 0x0C, 0x03, 0xC5, 0x8B, 0x92,
        0x00, 0x00, 0x00, 0x01, 0x68, 0xCE, 0x3C, 0x80,
        0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84, 0x21, 0xA0,
    };
    // Minimal ADTS AAC frame (11 bytes, 44.1kHz stereo, AAC-LC)
    const uint8_t adtsES[] = {
        0xFF, 0xF1, 0x50, 0x80, 0x01, 0x7F, 0xFC,
        0xDE, 0x04, 0x00, 0x26
    };

    appendTSPacket(ts, 0x0100, YES, buildPES(0xE0, 90000, [NSData dataWithBytes:h264ES length:sizeof(h264ES)]));
    appendTSPacket(ts, 0x0101, YES, buildPES(0xC0, 90000, [NSData dataWithBytes:adtsES length:sizeof(adtsES)]));
    appendTSPacket(ts, 0x0100, YES, buildPES(0xE0, 180000, [NSData dataWithBytes:h264ES length:sizeof(h264ES)]));
    appendTSPacket(ts, 0x0101, YES, buildPES(0xC0, 180000, [NSData dataWithBytes:adtsES length:sizeof(adtsES)]));
    return ts;
}

int main(void)
{
    @autoreleasepool {
        CHECK(wq_media_needs_remux_extension(@"/tmp/video.ts"));
        CHECK(wq_media_needs_remux_extension(@"/tmp/clip.M2TS"));
        CHECK(wq_media_needs_remux_extension(@"/tmp/movie.mkv"));
        CHECK(wq_media_needs_remux_extension(@"/tmp/stream.webm"));
        CHECK(wq_media_needs_remux_extension(@"/tmp/old.flv"));
        CHECK(wq_media_needs_remux_extension(@"/tmp/cam.avi"));
        CHECK(!wq_media_needs_remux_extension(@"/tmp/standard.mp4"));
        CHECK(!wq_media_needs_remux_extension(@"/tmp/notes.txt"));

        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"WQDemuxTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

        // 1. Probe & remux synthetic 188-byte MPEG-TS
        NSString *tsPath = [dir stringByAppendingPathComponent:@"sample.ts"];
        [buildSyntheticTS() writeToFile:tsPath atomically:YES];
        WQMediaProbeInfo *tsInfo = wq_media_probe_file(tsPath);
        CHECK(tsInfo != nil);
        CHECK([tsInfo.containerFormat isEqualToString:@"MPEG-TS"]);
        CHECK(tsInfo.hasVideo && [tsInfo.videoCodec isEqualToString:@"H.264"]);
        CHECK(tsInfo.hasAudio && [tsInfo.audioCodec isEqualToString:@"AAC"]);
        CHECK(tsInfo.durationSeconds >= 0.9);
        CHECK(tsInfo.needsRemuxForAVFoundation);

        NSString *mp4Out = [dir stringByAppendingPathComponent:@"remuxed.mp4"];
        NSString *remuxErr = nil;
        BOOL remuxOK = wq_media_remux_file(tsPath, mp4Out, AVFileTypeMPEG4, nil, nil, &remuxErr);
        CHECK(remuxOK);
        CHECK([NSFileManager.defaultManager fileExistsAtPath:mp4Out]);
        WQMediaProbeInfo *mp4Info = wq_media_probe_file(mp4Out);
        CHECK(mp4Info != nil && mp4Info.hasVideo && mp4Info.hasAudio);

        // 2. Probe 192-byte BDAV M2TS
        NSMutableData *m2ts = [NSMutableData new];
        NSData *rawTS = buildSyntheticTS();
        for (NSUInteger off = 0; off + 188 <= rawTS.length; off += 188) {
            uint8_t ts4[4] = {0, 0, 0, 1};
            [m2ts appendBytes:ts4 length:4];
            [m2ts appendData:[rawTS subdataWithRange:NSMakeRange(off, 188)]];
        }
        NSString *m2tsPath = [dir stringByAppendingPathComponent:@"bdav.m2ts"];
        [m2ts writeToFile:m2tsPath atomically:YES];
        WQMediaProbeInfo *m2tsInfo = wq_media_probe_file(m2tsPath);
        CHECK(m2tsInfo != nil && [m2tsInfo.containerFormat isEqualToString:@"BDAV / M2TS"]);

        // 3. Probe minimal FLV container
        const uint8_t flvHdr[] = { 'F','L','V',0x01, 0x05, 0x00,0x00,0x00,0x09, 0x00,0x00,0x00,0x00 };
        NSString *flvPath = [dir stringByAppendingPathComponent:@"clip.flv"];
        [[NSData dataWithBytes:flvHdr length:sizeof(flvHdr)] writeToFile:flvPath atomically:YES];
        WQMediaProbeInfo *flvInfo = wq_media_probe_file(flvPath);
        CHECK(flvInfo != nil && [flvInfo.containerFormat isEqualToString:@"FLV"]);

        // 4. Probe minimal EBML/MKV container
        const uint8_t ebmlHdr[] = { 0x1A,0x45,0xDF,0xA3, 0x9F, 0x42,0x86,0x81,0x01 };
        NSString *mkvPath = [dir stringByAppendingPathComponent:@"clip.mkv"];
        [[NSData dataWithBytes:ebmlHdr length:sizeof(ebmlHdr)] writeToFile:mkvPath atomically:YES];
        WQMediaProbeInfo *mkvInfo = wq_media_probe_file(mkvPath);
        CHECK(mkvInfo != nil && [mkvInfo.containerFormat isEqualToString:@"Matroska (MKV)"]);

        // 5. Remux cache path & prune sanity check
        NSString *cached = wq_media_remux_cache_path_for(tsPath, @"mp4");
        CHECK([cached hasSuffix:@".mp4"]);
        wq_media_remux_cache_prune(64ULL * 1024ULL * 1024ULL);

        [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
        if (gFailures) {
            fprintf(stderr, "%d WQMediaDemuxer test(s) failed\n", gFailures);
            return 1;
        }
        puts("All WQMediaDemuxer tests passed.");
    }
    return 0;
}
