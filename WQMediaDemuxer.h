//
//  WQMediaDemuxer.h
//  WQ Glass Native MPEG-TS / M2TS / MKV / WebM / FLV / AVI Demuxer & Lossless Remuxer
//  Pure C / Foundation / AVFoundation / CoreMedia / AudioToolbox (Zero UIKit).
//  GPL-3.0-or-later.
//

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WQMediaProbeInfo : NSObject
@property (nonatomic, copy) NSString *containerFormat; // e.g. @"MPEG-TS", @"M2TS", @"Matroska (MKV)", @"WebM", @"FLV", @"AVI", @"MP4"
@property (nonatomic, copy, nullable) NSString *videoCodec;
@property (nonatomic, copy, nullable) NSString *audioCodec;
@property (nonatomic) NSInteger width;
@property (nonatomic) NSInteger height;
@property (nonatomic) double durationSeconds;
@property (nonatomic) double fps;
@property (nonatomic) unsigned long long bitrateBps;
@property (nonatomic) unsigned long long fileSizeBytes;
@property (nonatomic) BOOL hasVideo;
@property (nonatomic) BOOL hasAudio;
@property (nonatomic) NSInteger videoTrackCount;
@property (nonatomic) NSInteger audioTrackCount;
@property (nonatomic, copy) NSArray<NSString *> *audioTrackNames;
@property (nonatomic) BOOL needsRemuxForAVFoundation;
@end

/// Returns YES for container extensions not natively opened as file:// assets by AVURLAsset (.ts, .m2ts, .mts, .mkv, .webm, .flv, .avi).
BOOL wq_media_needs_remux_extension(NSString *path);

/// Fast probe for MPEG-TS, M2TS, MKV, WebM, FLV, AVI, plus AVURLAsset fallback for Apple formats.
WQMediaProbeInfo *_Nullable wq_media_probe_file(NSString *path);

/// Lossless passthrough remuxer into MP4 or MOV (no video/audio re-encoding when source codecs are compatible).
BOOL wq_media_remux_file(NSString *srcPath,
                         NSString *dstPath,
                         AVFileType outputFileType,
                         BOOL (^_Nullable cancelled)(void),
                         void (^_Nullable progress)(float fraction),
                         NSString *_Nullable *_Nullable errorOut);

/// Bounded LRU cache directory and path generator for transparent playback remuxes.
NSString *wq_media_remux_cache_dir(void);
NSString *wq_media_remux_cache_path_for(NSString *srcPath, NSString *ext);
void wq_media_remux_cache_prune(unsigned long long maxBytes);

NS_ASSUME_NONNULL_END
