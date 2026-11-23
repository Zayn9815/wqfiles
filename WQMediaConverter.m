//
//  WQMediaConverter.m
//  WQ Glass
//
//  Native offline Video & Audio Format + Encoding Converter built on
//  AVAssetReader + AVAssetWriter + CoreMedia + AudioToolbox.
//

#import "WQMediaConverter.h"
#import "WQLocalization.h"
#import "WQTheme.h"
#import "WQUI.h"
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <stdatomic.h>
#import <sys/stat.h>

static NSString *wq_conv_unique_path(NSString *dir, NSString *filename)
{
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *base = [dir stringByAppendingPathComponent:filename];
    if (![NSFileManager.defaultManager fileExistsAtPath:base]) return base;
    NSString *ext = filename.pathExtension;
    NSString *stem = ext.length ? filename.stringByDeletingPathExtension : filename;
    for (NSUInteger i = 2; i < 1000; i++) {
        NSString *cand = ext.length
            ? [NSString stringWithFormat:@"%@_%lu.%@", stem, (unsigned long)i, ext]
            : [NSString stringWithFormat:@"%@_%lu", stem, (unsigned long)i];
        NSString *full = [dir stringByAppendingPathComponent:cand];
        if (![NSFileManager.defaultManager fileExistsAtPath:full]) return full;
    }
    return [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_%@", NSUUID.UUID.UUIDString, filename]];
}

static unsigned long long wq_conv_file_size(NSString *path)
{
    struct stat st;
    if (path.length && lstat(path.fileSystemRepresentation, &st) == 0) {
        return (unsigned long long)st.st_size;
    }
    return 0;
}

static NSString *wq_conv_fourcc_string(FourCharCode code)
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
    if ([s isEqualToString:@"avc1"]) return @"H.264";
    if ([s isEqualToString:@"hvc1"] || [s isEqualToString:@"hev1"]) return @"HEVC (H.265)";
    if ([s isEqualToString:@"mp4a"]) return @"AAC";
    if ([s isEqualToString:@"alac"]) return @"ALAC";
    if ([s isEqualToString:@"lpcm"]) return @"PCM";
    return s.length ? s : @"Media";
}

static NSString *wq_conv_duration_text(double secs)
{
    if (!isfinite(secs) || secs <= 0) return @"--";
    long total = (long)llround(secs);
    long h = total / 3600;
    long m = (total % 3600) / 60;
    long s = total % 60;
    if (h > 0) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", h, m, s];
    return [NSString stringWithFormat:@"%ld:%02ld", m, s];
}

BOOL wq_is_convertible_media_path(NSString *path)
{
    if (!path.length) return NO;
    NSString *ext = path.pathExtension.lowercaseString;
    static NSSet<NSString *> *sMediaExts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sMediaExts = [NSSet setWithArray:@[
            @"mp4", @"mov", @"m4v", @"ts", @"3gp",
            @"mp3", @"m4a", @"aac", @"wav", @"aiff", @"aif", @"caf", @"flac"
        ]];
    });
    return [sMediaExts containsObject:ext];
}

typedef NS_ENUM(NSInteger, WQConvMode) {
    WQConvModeVideo = 0,
    WQConvModeAudio = 1,
};

typedef NS_ENUM(NSInteger, WQConvVideoContainer) {
    WQConvVideoContainerMP4 = 0,
    WQConvVideoContainerMOV = 1,
    WQConvVideoContainerM4V = 2,
};

typedef NS_ENUM(NSInteger, WQConvVideoCodec) {
    WQConvVideoCodecH264 = 0,
    WQConvVideoCodecHEVC = 1,
};

typedef NS_ENUM(NSInteger, WQConvVideoRes) {
    WQConvVideoResOriginal = 0,
    WQConvVideoRes1080p = 1,
    WQConvVideoRes720p = 2,
    WQConvVideoRes480p = 3,
    WQConvVideoRes360p = 4,
};

typedef NS_ENUM(NSInteger, WQConvQuality) {
    WQConvQualityHigh = 0,
    WQConvQualityBalanced = 1,
    WQConvQualityCompact = 2,
};

typedef NS_ENUM(NSInteger, WQConvAudioFormat) {
    WQConvAudioFormatM4A_AAC = 0,
    WQConvAudioFormatM4A_ALAC = 1,
    WQConvAudioFormatWAV_PCM = 2,
    WQConvAudioFormatAIFF_PCM = 3,
    WQConvAudioFormatCAF_PCM = 4,
};

@implementation WQMediaConverterViewController {
    NSString *_filePath;
    BOOL _sourceHasVideo;
    BOOL _sourceHasAudio;
    CGSize _sourceVideoSize;
    double _sourceDuration;
    NSString *_sourceSummary;

    WQConvMode _mode;
    WQConvVideoContainer _videoContainer;
    WQConvVideoCodec _videoCodec;
    WQConvVideoRes _videoRes;
    WQConvQuality _videoQuality;
    WQConvAudioFormat _audioFormat;
    NSInteger _audioBitrateKbps; // 96, 128, 192, 256, 320
    BOOL _deleteOriginal;

    BOOL _converting;
    float _progress;
    NSString *_statusText;
    NSString *_lastOutputPath;
    atomic_bool _cancelFlag;
    AVAssetReader *_activeReader;
    AVAssetWriter *_activeWriter;

    UIProgressView *_progressView;
    UILabel *_progressLabel;
    UIButton *_actionButton;
}

- (instancetype)initWithFilePath:(NSString *)filePath
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _filePath = [filePath copy];
        _mode = WQConvModeVideo;
        _videoContainer = WQConvVideoContainerMP4;
        _videoCodec = WQConvVideoCodecH264;
        _videoRes = WQConvVideoResOriginal;
        _videoQuality = WQConvQualityBalanced;
        _audioFormat = WQConvAudioFormatM4A_AAC;
        _audioBitrateKbps = 192;
        _deleteOriginal = NO;
        atomic_init(&_cancelFlag, false);
        self.title = WQLocalized(@"Format & Codec Converter");
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    if (wq_prism_enabled()) {
        wq_prism_install_background(self);
        self.tableView.backgroundColor = UIColor.clearColor;
    }
    wq_theme_apply_scroll_insets(self.tableView, 40.0);

    __weak typeof(self) weakSelf = self;
    if (self.navigationController.viewControllers.firstObject == self) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithPrimaryAction:
            [UIAction actionWithTitle:WQLocalized(@"Close") image:nil identifier:nil handler:^(UIAction *__unused a) {
            __strong typeof(weakSelf) me = weakSelf;
            if (!me) return;
            atomic_store(&me->_cancelFlag, true);
            [me dismissViewControllerAnimated:YES completion:nil];
        }]];
    }

    [self installFooterControls];
    [self inspectSourceFile];
}

- (void)dealloc
{
    atomic_store(&_cancelFlag, true);
}

- (void)installFooterControls
{
    CGFloat w = self.tableView.bounds.size.width ?: self.view.bounds.size.width ?: 360.0;
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 126)];
    footer.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UIVisualEffectView *card = wq_theme_make_glass_card(20.0, YES);
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [footer addSubview:card];

    _progressLabel = [UILabel new];
    _progressLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold];
    _progressLabel.textColor = wq_theme_secondary_text();
    _progressLabel.text = WQLocalized(@"Ready to convert offline on device");
    _progressLabel.textAlignment = NSTextAlignmentCenter;

    _progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _progressView.progress = 0.0f;
    _progressView.tintColor = wq_theme_accent();
    _progressView.trackTintColor = [wq_theme_primary_text() colorWithAlphaComponent:0.12];
    _progressView.layer.cornerRadius = 3;
    _progressView.clipsToBounds = YES;

    _actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _actionButton.layer.cornerRadius = 14;
    _actionButton.clipsToBounds = YES;
    _actionButton.backgroundColor = wq_theme_accent();
    [_actionButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    _actionButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    [_actionButton setTitle:WQLocalized(@"Start Conversion") forState:UIControlStateNormal];
    [_actionButton addTarget:self action:@selector(toggleConvert) forControlEvents:UIControlEventTouchUpInside];
    [_actionButton.heightAnchor constraintEqualToConstant:46].active = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_progressLabel, _progressView, _actionButton]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    [card.contentView addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:footer.topAnchor constant:8],
        [card.bottomAnchor constraintEqualToAnchor:footer.bottomAnchor constant:-8],
        [card.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:14],
        [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-14],
        [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:14],
        [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-14],
    ]];
    self.tableView.tableFooterView = footer;
}

- (void)inspectSourceFile
{
    NSString *path = _filePath;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        NSArray<AVAssetTrack *> *vTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
        NSArray<AVAssetTrack *> *aTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
        CMTime dur = asset.duration;
#pragma clang diagnostic pop
        double durSec = CMTIME_IS_NUMERIC(dur) ? CMTimeGetSeconds(dur) : 0.0;
        CGSize vSize = CGSizeZero;
        NSString *vCodec = nil;
        if (vTracks.count > 0) {
            AVAssetTrack *vt = vTracks.firstObject;
            CGSize nat = vt.naturalSize;
            CGAffineTransform tx = vt.preferredTransform;
            CGSize transformed = CGSizeApplyAffineTransform(nat, tx);
            vSize = CGSizeMake(fabs(transformed.width), fabs(transformed.height));
            if (vt.formatDescriptions.count > 0) {
                CMFormatDescriptionRef fd = (__bridge CMFormatDescriptionRef)vt.formatDescriptions.firstObject;
                vCodec = wq_conv_fourcc_string(CMFormatDescriptionGetMediaSubType(fd));
            }
        }
        NSString *aCodec = nil;
        if (aTracks.count > 0) {
            AVAssetTrack *at = aTracks.firstObject;
            if (at.formatDescriptions.count > 0) {
                CMFormatDescriptionRef fd = (__bridge CMFormatDescriptionRef)at.formatDescriptions.firstObject;
                aCodec = wq_conv_fourcc_string(CMFormatDescriptionGetMediaSubType(fd));
            }
        }
        unsigned long long sz = wq_conv_file_size(path);
        NSMutableArray<NSString *> *parts = [NSMutableArray new];
        [parts addObject:wq_size_text(sz)];
        if (durSec > 0) [parts addObject:wq_conv_duration_text(durSec)];
        if (vSize.width > 0 && vSize.height > 0) {
            [parts addObject:[NSString stringWithFormat:@"%dx%d", (int)llround(vSize.width), (int)llround(vSize.height)]];
        }
        if (vCodec.length) [parts addObject:vCodec];
        if (aCodec.length) [parts addObject:aCodec];
        NSString *summary = [parts componentsJoinedByString:@" · "];

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) me = weakSelf;
            if (!me) return;
            me->_sourceHasVideo = (vTracks.count > 0);
            me->_sourceHasAudio = (aTracks.count > 0);
            me->_sourceVideoSize = vSize;
            me->_sourceDuration = durSec;
            me->_sourceSummary = summary;
            if (!me->_sourceHasVideo) {
                me->_mode = WQConvModeAudio;
            }
            [me.tableView reloadData];
        });
    });
}

#pragma mark - Labels & Option Helpers

- (NSString *)videoContainerLabel
{
    switch (_videoContainer) {
        case WQConvVideoContainerMOV: return @"MOV (.mov) — QuickTime";
        case WQConvVideoContainerM4V: return @"M4V (.m4v) — Apple Video";
        default: return @"MP4 (.mp4) — Universal";
    }
}

- (NSString *)videoContainerExtension
{
    switch (_videoContainer) {
        case WQConvVideoContainerMOV: return @"mov";
        case WQConvVideoContainerM4V: return @"m4v";
        default: return @"mp4";
    }
}

- (AVFileType)videoFileType
{
    switch (_videoContainer) {
        case WQConvVideoContainerMOV: return AVFileTypeQuickTimeMovie;
        case WQConvVideoContainerM4V: return AVFileTypeAppleM4V;
        default: return AVFileTypeMPEG4;
    }
}

- (NSString *)videoCodecLabel
{
    return (_videoCodec == WQConvVideoCodecHEVC)
        ? WQLocalized(@"HEVC / H.265 (Smaller Size, 4K)")
        : WQLocalized(@"H.264 / AVC (Maximum Compatibility)");
}

- (NSString *)videoResLabel
{
    switch (_videoRes) {
        case WQConvVideoRes1080p: return @"1080p Full HD";
        case WQConvVideoRes720p:  return @"720p HD";
        case WQConvVideoRes480p:  return @"480p SD";
        case WQConvVideoRes360p:  return @"360p Compact";
        default: return WQLocalized(@"Original Resolution");
    }
}

- (NSString *)videoQualityLabel
{
    switch (_videoQuality) {
        case WQConvQualityHigh:    return WQLocalized(@"High Bitrate");
        case WQConvQualityCompact: return WQLocalized(@"Compact (Small File)");
        default: return WQLocalized(@"Balanced (Recommended)");
    }
}

- (NSString *)audioFormatLabel
{
    switch (_audioFormat) {
        case WQConvAudioFormatM4A_ALAC: return @"M4A — ALAC (Apple Lossless)";
        case WQConvAudioFormatWAV_PCM:  return @"WAV — Uncompressed 16-bit PCM";
        case WQConvAudioFormatAIFF_PCM: return @"AIFF — Lossless PCM";
        case WQConvAudioFormatCAF_PCM:  return @"CAF — Core Audio PCM";
        default: return @"M4A — AAC (Universal High Efficiency)";
    }
}

- (NSString *)audioExtension
{
    switch (_audioFormat) {
        case WQConvAudioFormatWAV_PCM:  return @"wav";
        case WQConvAudioFormatAIFF_PCM: return @"aiff";
        case WQConvAudioFormatCAF_PCM:  return @"caf";
        default: return @"m4a";
    }
}

- (AVFileType)audioFileType
{
    switch (_audioFormat) {
        case WQConvAudioFormatWAV_PCM:  return AVFileTypeWAVE;
        case WQConvAudioFormatAIFF_PCM: return AVFileTypeAIFF;
        case WQConvAudioFormatCAF_PCM:  return AVFileTypeCoreAudioFormat;
        default: return AVFileTypeAppleM4A;
    }
}

- (BOOL)audioFormatUsesBitrate
{
    return (_audioFormat == WQConvAudioFormatM4A_AAC);
}

#pragma mark - Conversion Engine (AVAssetReader + AVAssetWriter)

- (void)updateProgressUI:(float)p text:(NSString *)text
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_progress = p;
        self->_statusText = text;
        self->_progressView.progress = p;
        self->_progressLabel.text = text;
    });
}

- (void)toggleConvert
{
    wq_haptic_selection();
    if (_converting) {
        atomic_store(&_cancelFlag, true);
        [_activeReader cancelReading];
        [_activeWriter cancelWriting];
        _progressLabel.text = WQLocalized(@"Cancelling…");
        return;
    }
    [self startConversion];
}

- (CGSize)targetVideoSizeForSource:(CGSize)nat
{
    CGFloat maxShort = 0;
    switch (_videoRes) {
        case WQConvVideoRes1080p: maxShort = 1080; break;
        case WQConvVideoRes720p:  maxShort = 720; break;
        case WQConvVideoRes480p:  maxShort = 480; break;
        case WQConvVideoRes360p:  maxShort = 360; break;
        default: maxShort = 0; break;
    }
    CGFloat w = MAX(2.0, nat.width);
    CGFloat h = MAX(2.0, nat.height);
    if (maxShort > 0) {
        CGFloat shortSide = MIN(w, h);
        if (shortSide > maxShort) {
            CGFloat scale = maxShort / shortSide;
            w = floor(w * scale);
            h = floor(h * scale);
        }
    }
    // Video encoders require even pixel dimensions.
    int iw = MAX(16, ((int)llround(w)) & ~1);
    int ih = MAX(16, ((int)llround(h)) & ~1);
    return CGSizeMake(iw, ih);
}

- (NSInteger)targetVideoBitrateForSize:(CGSize)sz
{
    double pixels = (double)sz.width * (double)sz.height;
    double bpp = 0.16; // Balanced H.264 baseline
    if (_videoQuality == WQConvQualityHigh) bpp = 0.28;
    else if (_videoQuality == WQConvQualityCompact) bpp = 0.09;
    if (_videoCodec == WQConvVideoCodecHEVC) bpp *= 0.68; // HEVC needs ~32% less bitrate
    double bps = pixels * 30.0 * bpp;
    if (bps < 400000.0) bps = 400000.0;
    if (bps > 22000000.0) bps = 22000000.0;
    return (NSInteger)llround(bps);
}

- (NSDictionary<NSString *, id> *)audioOutputSettings
{
    if (_audioFormat == WQConvAudioFormatM4A_ALAC) {
        return @{
            AVFormatIDKey: @(kAudioFormatAppleLossless),
            AVEncoderBitDepthHintKey: @16,
            AVNumberOfChannelsKey: @2,
            AVSampleRateKey: @44100.0,
        };
    }
    if (_audioFormat == WQConvAudioFormatWAV_PCM || _audioFormat == WQConvAudioFormatCAF_PCM) {
        return @{
            AVFormatIDKey: @(kAudioFormatLinearPCM),
            AVSampleRateKey: @44100.0,
            AVNumberOfChannelsKey: @2,
            AVLinearPCMBitDepthKey: @16,
            AVLinearPCMIsBigEndianKey: @NO,
            AVLinearPCMIsFloatKey: @NO,
            AVLinearPCMIsNonInterleaved: @NO,
        };
    }
    if (_audioFormat == WQConvAudioFormatAIFF_PCM) {
        return @{
            AVFormatIDKey: @(kAudioFormatLinearPCM),
            AVSampleRateKey: @44100.0,
            AVNumberOfChannelsKey: @2,
            AVLinearPCMBitDepthKey: @16,
            AVLinearPCMIsBigEndianKey: @YES,
            AVLinearPCMIsFloatKey: @NO,
            AVLinearPCMIsNonInterleaved: @NO,
        };
    }
    return @{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVNumberOfChannelsKey: @2,
        AVSampleRateKey: @44100.0,
        AVEncoderBitRateKey: @(_audioBitrateKbps * 1000),
    };
}

- (void)startConversion
{
    if (_mode == WQConvModeVideo && !_sourceHasVideo) {
        wq_alert(self, WQLocalized(@"No Video Track"), WQLocalized(@"This file is audio-only. Switch to Audio mode to convert it."));
        return;
    }
    if (_mode == WQConvModeAudio && !_sourceHasAudio) {
        wq_alert(self, WQLocalized(@"No Audio Track"), WQLocalized(@"This file has no audio track to extract or convert."));
        return;
    }

    _converting = YES;
    atomic_store(&_cancelFlag, false);
    _progressView.progress = 0.0f;
    _progressLabel.text = WQLocalized(@"Preparing encoder…");
    _actionButton.backgroundColor = UIColor.systemRedColor;
    [_actionButton setTitle:WQLocalized(@"Cancel Conversion") forState:UIControlStateNormal];

    NSString *srcPath = _filePath;
    NSString *srcDir = srcPath.stringByDeletingLastPathComponent;
    if (![NSFileManager.defaultManager isWritableFileAtPath:srcDir]) {
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
        srcDir = [[docs stringByAppendingPathComponent:@"Downloads"] stringByAppendingPathComponent:@"Converted"];
    }
    NSString *stem = srcPath.lastPathComponent.stringByDeletingPathExtension;
    NSString *suffix = (_mode == WQConvModeVideo)
        ? [NSString stringWithFormat:@"_%@", (_videoCodec == WQConvVideoCodecHEVC ? @"hevc" : @"h264")]
        : [NSString stringWithFormat:@"_%ldk", (long)_audioBitrateKbps];
    NSString *ext = (_mode == WQConvModeVideo) ? [self videoContainerExtension] : [self audioExtension];
    NSString *outPath = wq_conv_unique_path(srcDir, [NSString stringWithFormat:@"%@%@.%@", stem, suffix, ext]);

    WQConvMode mode = _mode;
    AVFileType fileType = (mode == WQConvModeVideo) ? [self videoFileType] : [self audioFileType];
    AVVideoCodecType vCodecType = (_videoCodec == WQConvVideoCodecHEVC) ? AVVideoCodecTypeHEVC : AVVideoCodecTypeH264;
    NSDictionary<NSString *, id> *audioSettings = (mode == WQConvModeVideo)
        ? @{
            AVFormatIDKey: @(kAudioFormatMPEG4AAC),
            AVNumberOfChannelsKey: @2,
            AVSampleRateKey: @44100.0,
            AVEncoderBitRateKey: @(_audioBitrateKbps * 1000),
        }
        : [self audioOutputSettings];
    BOOL deleteOrig = _deleteOriginal;

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        __strong typeof(weakSelf) me = weakSelf;
        if (!me) return;

        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:srcPath] options:nil];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        NSArray<AVAssetTrack *> *vTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
        NSArray<AVAssetTrack *> *aTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
        double totalSec = CMTIME_IS_NUMERIC(asset.duration) ? CMTimeGetSeconds(asset.duration) : 0.0;
#pragma clang diagnostic pop

        NSError *err = nil;
        AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&err];
        if (!reader || err) {
            [me finishConversionWithPath:nil errorText:err.localizedDescription ?: WQLocalized(@"Could not open source media.")];
            return;
        }
        AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:outPath] fileType:fileType error:&err];
        if (!writer || err) {
            [me finishConversionWithPath:nil errorText:err.localizedDescription ?: WQLocalized(@"Could not initialize output writer.")];
            return;
        }
        me->_activeReader = reader;
        me->_activeWriter = writer;

        AVAssetReaderTrackOutput *videoOut = nil;
        AVAssetWriterInput *videoIn = nil;
        if (mode == WQConvModeVideo && vTracks.count > 0) {
            AVAssetTrack *vt = vTracks.firstObject;
            CGSize outSize = [me targetVideoSizeForSource:vt.naturalSize];
            NSInteger vBitrate = [me targetVideoBitrateForSize:outSize];

            NSDictionary *readV = @{
                (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            };
            videoOut = [[AVAssetReaderTrackOutput alloc] initWithTrack:vt outputSettings:readV];
            videoOut.alwaysCopiesSampleData = NO;
            if ([reader canAddOutput:videoOut]) [reader addOutput:videoOut];

            NSDictionary *writeV = @{
                AVVideoCodecKey: vCodecType,
                AVVideoWidthKey: @((NSInteger)outSize.width),
                AVVideoHeightKey: @((NSInteger)outSize.height),
                AVVideoCompressionPropertiesKey: @{
                    AVVideoAverageBitRateKey: @(vBitrate),
                },
            };
            videoIn = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo outputSettings:writeV];
            videoIn.transform = vt.preferredTransform;
            videoIn.expectsMediaDataInRealTime = NO;
            if ([writer canAddInput:videoIn]) [writer addInput:videoIn];
        }

        AVAssetReaderAudioMixOutput *audioOut = nil;
        AVAssetWriterInput *audioIn = nil;
        if (aTracks.count > 0) {
            NSDictionary *readA = @{
                AVFormatIDKey: @(kAudioFormatLinearPCM),
                AVSampleRateKey: @44100.0,
                AVNumberOfChannelsKey: @2,
                AVLinearPCMBitDepthKey: @16,
                AVLinearPCMIsBigEndianKey: @NO,
                AVLinearPCMIsFloatKey: @NO,
                AVLinearPCMIsNonInterleaved: @NO,
            };
            audioOut = [[AVAssetReaderAudioMixOutput alloc] initWithAudioTracks:aTracks audioSettings:readA];
            audioOut.alwaysCopiesSampleData = NO;
            if ([reader canAddOutput:audioOut]) [reader addOutput:audioOut];

            audioIn = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio outputSettings:audioSettings];
            audioIn.expectsMediaDataInRealTime = NO;
            if ([writer canAddInput:audioIn]) [writer addInput:audioIn];
        }

        if (![reader startReading]) {
            [me finishConversionWithPath:nil errorText:reader.error.localizedDescription ?: WQLocalized(@"Failed to start media reader.")];
            return;
        }
        if (![writer startWriting]) {
            [me finishConversionWithPath:nil errorText:writer.error.localizedDescription ?: WQLocalized(@"Failed to start media writer.")];
            return;
        }
        [writer startSessionAtSourceTime:kCMTimeZero];

        dispatch_group_t grp = dispatch_group_create();
        __block double lastReport = 0;

        if (videoOut && videoIn) {
            dispatch_group_enter(grp);
            dispatch_queue_t vq = dispatch_queue_create("com.wqglass.conv.video", DISPATCH_QUEUE_SERIAL);
            [videoIn requestMediaDataWhenReadyOnQueue:vq usingBlock:^{
                while (videoIn.isReadyForMoreMediaData) {
                    if (atomic_load(&me->_cancelFlag)) {
                        [videoIn markAsFinished];
                        dispatch_group_leave(grp);
                        return;
                    }
                    CMSampleBufferRef sb = [videoOut copyNextSampleBuffer];
                    if (sb) {
                        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
                        if (totalSec > 0 && CMTIME_IS_NUMERIC(pts)) {
                            double now = CFAbsoluteTimeGetCurrent();
                            if (now - lastReport >= 0.12) {
                                lastReport = now;
                                float pct = (float)MIN(0.99, MAX(0.0, CMTimeGetSeconds(pts) / totalSec));
                                [me updateProgressUI:pct text:WQLocalizedFormat(@"Converting Video… %d%%", (int)lroundf(pct * 100.0f))];
                            }
                        }
                        if (![videoIn appendSampleBuffer:sb]) {
                            CFRelease(sb);
                            [videoIn markAsFinished];
                            dispatch_group_leave(grp);
                            return;
                        }
                        CFRelease(sb);
                    } else {
                        [videoIn markAsFinished];
                        dispatch_group_leave(grp);
                        return;
                    }
                }
            }];
        }

        if (audioOut && audioIn) {
            dispatch_group_enter(grp);
            dispatch_queue_t aq = dispatch_queue_create("com.wqglass.conv.audio", DISPATCH_QUEUE_SERIAL);
            [audioIn requestMediaDataWhenReadyOnQueue:aq usingBlock:^{
                while (audioIn.isReadyForMoreMediaData) {
                    if (atomic_load(&me->_cancelFlag)) {
                        [audioIn markAsFinished];
                        dispatch_group_leave(grp);
                        return;
                    }
                    CMSampleBufferRef sb = [audioOut copyNextSampleBuffer];
                    if (sb) {
                        if (!videoIn && totalSec > 0) {
                            CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
                            if (CMTIME_IS_NUMERIC(pts)) {
                                double now = CFAbsoluteTimeGetCurrent();
                                if (now - lastReport >= 0.12) {
                                    lastReport = now;
                                    float pct = (float)MIN(0.99, MAX(0.0, CMTimeGetSeconds(pts) / totalSec));
                                    [me updateProgressUI:pct text:WQLocalizedFormat(@"Converting Audio… %d%%", (int)lroundf(pct * 100.0f))];
                                }
                            }
                        }
                        if (![audioIn appendSampleBuffer:sb]) {
                            CFRelease(sb);
                            [audioIn markAsFinished];
                            dispatch_group_leave(grp);
                            return;
                        }
                        CFRelease(sb);
                    } else {
                        [audioIn markAsFinished];
                        dispatch_group_leave(grp);
                        return;
                    }
                }
            }];
        }

        dispatch_group_wait(grp, DISPATCH_TIME_FOREVER);

        if (atomic_load(&me->_cancelFlag)) {
            [reader cancelReading];
            [writer cancelWriting];
            [NSFileManager.defaultManager removeItemAtPath:outPath error:nil];
            [me finishConversionWithPath:nil errorText:WQLocalized(@"Conversion cancelled.")];
            return;
        }

        dispatch_semaphore_t doneSem = dispatch_semaphore_create(0);
        [writer finishWritingWithCompletionHandler:^{
            dispatch_semaphore_signal(doneSem);
        }];
        dispatch_semaphore_wait(doneSem, DISPATCH_TIME_FOREVER);

        if (writer.status == AVAssetWriterStatusCompleted && reader.status != AVAssetReaderStatusFailed) {
            if (deleteOrig && ![outPath isEqualToString:srcPath]) {
                [NSFileManager.defaultManager removeItemAtPath:srcPath error:nil];
            }
            [me finishConversionWithPath:outPath errorText:nil];
        } else {
            [NSFileManager.defaultManager removeItemAtPath:outPath error:nil];
            NSString *msg = writer.error.localizedDescription ?: reader.error.localizedDescription ?: WQLocalized(@"Conversion failed.");
            [me finishConversionWithPath:nil errorText:msg];
        }
    });
}

- (void)finishConversionWithPath:(NSString *)outPath errorText:(NSString *)errorText
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_converting = NO;
        self->_activeReader = nil;
        self->_activeWriter = nil;
        self->_actionButton.backgroundColor = wq_theme_accent();
        [self->_actionButton setTitle:WQLocalized(@"Start Conversion") forState:UIControlStateNormal];

        if (outPath.length) {
            self->_lastOutputPath = outPath;
            self->_progressView.progress = 1.0f;
            unsigned long long origSz = wq_conv_file_size(self->_filePath);
            unsigned long long newSz = wq_conv_file_size(outPath);
            NSString *msg = [NSString stringWithFormat:@"%@ (%@ → %@)",
                             outPath.lastPathComponent,
                             origSz ? wq_size_text(origSz) : @"--",
                             wq_size_text(newSz)];
            self->_progressLabel.text = msg;
            wq_haptic_notify(UINotificationFeedbackTypeSuccess);

            UIAlertController *done = wq_alert_controller(WQLocalized(@"Conversion Complete"), WQVerbatim(msg), UIAlertControllerStyleAlert);
            [done addAction:wq_alert_action(WQLocalized(@"Play Converted File"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
                [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback error:nil];
                AVPlayerViewController *p = [AVPlayerViewController new];
                p.player = [AVPlayer playerWithURL:[NSURL fileURLWithPath:outPath]];
                [self presentViewController:p animated:YES completion:^{ [p.player play]; }];
            })];
            [done addAction:wq_alert_action(WQLocalized(@"Share File"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
                UIActivityViewController *sh = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:outPath]] applicationActivities:nil];
                sh.popoverPresentationController.sourceView = self->_actionButton;
                sh.popoverPresentationController.sourceRect = self->_actionButton.bounds;
                [self presentViewController:sh animated:YES completion:nil];
            })];
            [done addAction:wq_alert_action(WQLocalized(@"OK"), UIAlertActionStyleCancel, nil)];
            [self presentViewController:done animated:YES completion:nil];
        } else {
            self->_progressView.progress = 0.0f;
            self->_progressLabel.text = errorText ?: WQLocalized(@"Conversion failed.");
            wq_haptic_notify(UINotificationFeedbackTypeError);
            if (![errorText isEqualToString:WQLocalized(@"Conversion cancelled.")]) {
                wq_alert(self, WQLocalized(@"Conversion Error"), errorText ?: WQLocalized(@"Could not convert this media file."));
            }
        }
    });
}

#pragma mark - TableView DataSource & Delegate

- (NSInteger)numberOfSectionsInTableView:(UITableView *__unused)tableView { return 3; }

- (NSInteger)tableView:(UITableView *__unused)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return 2; // Source info + Mode switch
    if (section == 1) {
        if (_mode == WQConvModeVideo) return 5; // Container, Codec, Res, Quality, Audio Bitrate
        return [self audioFormatUsesBitrate] ? 2 : 1; // Audio Format (+ Bitrate)
    }
    return 1; // Delete original toggle
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) return WQLocalized(@"Source Media");
    if (section == 1) return (_mode == WQConvModeVideo) ? WQLocalized(@"Video Format & Encoding") : WQLocalized(@"Audio Format & Encoding");
    return WQLocalized(@"Output Options");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"conv-row"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"conv-row"];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    UIListContentConfiguration *c = [UIListContentConfiguration valueCellConfiguration];
    c.textProperties.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    c.textProperties.color = wq_theme_primary_text();
    c.secondaryTextProperties.color = wq_theme_secondary_text();

    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            c = [UIListContentConfiguration subtitleCellConfiguration];
            c.text = _filePath.lastPathComponent;
            c.secondaryText = _sourceSummary ?: WQLocalized(@"Inspecting tracks…");
            c.image = [UIImage systemImageNamed:_sourceHasVideo ? @"film.fill" : @"waveform"];
            c.imageProperties.tintColor = wq_theme_accent();
            c.textProperties.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
            c.textProperties.color = wq_theme_primary_text();
            c.secondaryTextProperties.color = wq_theme_secondary_text();
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            c.text = WQLocalized(@"Convert Mode");
            c.secondaryText = (_mode == WQConvModeVideo) ? WQLocalized(@"Video (Format + Codec)") : WQLocalized(@"Audio Only (Extract / Convert)");
            c.image = [UIImage systemImageNamed:@"arrow.triangle.2.circlepath"];
            c.imageProperties.tintColor = wq_theme_accent();
        }
    } else if (indexPath.section == 1) {
        if (_mode == WQConvModeVideo) {
            if (indexPath.row == 0) {
                c.text = WQLocalized(@"Container Format");
                c.secondaryText = [self videoContainerLabel];
            } else if (indexPath.row == 1) {
                c.text = WQLocalized(@"Video Encoding");
                c.secondaryText = [self videoCodecLabel];
            } else if (indexPath.row == 2) {
                c.text = WQLocalized(@"Resolution");
                c.secondaryText = [self videoResLabel];
            } else if (indexPath.row == 3) {
                c.text = WQLocalized(@"Quality Preset");
                c.secondaryText = [self videoQualityLabel];
            } else {
                c.text = WQLocalized(@"Audio Bitrate (AAC)");
                c.secondaryText = [NSString stringWithFormat:@"%ld kbps", (long)_audioBitrateKbps];
            }
        } else {
            if (indexPath.row == 0) {
                c.text = WQLocalized(@"Audio Format & Codec");
                c.secondaryText = [self audioFormatLabel];
            } else {
                c.text = WQLocalized(@"Audio Bitrate");
                c.secondaryText = [NSString stringWithFormat:@"%ld kbps", (long)_audioBitrateKbps];
            }
        }
    } else {
        c.text = WQLocalized(@"Delete Original After Convert");
        c.secondaryText = nil;
        UISwitch *sw = [UISwitch new];
        sw.on = _deleteOriginal;
        sw.onTintColor = wq_theme_accent();
        [sw addTarget:self action:@selector(toggleDeleteOriginal:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }

    cell.contentConfiguration = c;
    return cell;
}

- (void)toggleDeleteOriginal:(UISwitch *)sw
{
    _deleteOriginal = sw.isOn;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_converting) return;
    wq_haptic_selection();

    if (indexPath.section == 0 && indexPath.row == 1) {
        if (_sourceHasVideo) {
            _mode = (_mode == WQConvModeVideo) ? WQConvModeAudio : WQConvModeVideo;
            [tableView reloadData];
        } else {
            wq_alert(self, WQLocalized(@"Audio Source"), WQLocalized(@"This file only contains audio tracks."));
        }
        return;
    }

    if (indexPath.section != 1) return;

    UIAlertController *sheet = wq_alert_controller(WQLocalized(@"Select Option"), nil, UIAlertControllerStyleActionSheet);
    if (_mode == WQConvModeVideo) {
        if (indexPath.row == 0) {
            [sheet addAction:wq_alert_action(@"MP4 (.mp4) — Universal", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) { self->_videoContainer = WQConvVideoContainerMP4; [tableView reloadData]; })];
            [sheet addAction:wq_alert_action(@"MOV (.mov) — QuickTime", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) { self->_videoContainer = WQConvVideoContainerMOV; [tableView reloadData]; })];
            [sheet addAction:wq_alert_action(@"M4V (.m4v) — Apple Video", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) { self->_videoContainer = WQConvVideoContainerM4V; [tableView reloadData]; })];
        } else if (indexPath.row == 1) {
            [sheet addAction:wq_alert_action(WQLocalized(@"H.264 / AVC (Maximum Compatibility)"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) { self->_videoCodec = WQConvVideoCodecH264; [tableView reloadData]; })];
            [sheet addAction:wq_alert_action(WQLocalized(@"HEVC / H.265 (Smaller Size, 4K)"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) { self->_videoCodec = WQConvVideoCodecHEVC; [tableView reloadData]; })];
        } else if (indexPath.row == 2) {
            [sheet addAction:wq_alert_action(WQLocalized(@"Original Resolution"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) { self->_videoRes = WQConvVideoResOriginal; [tableView reloadData]; })];
            [sheet addAction:wq_alert_action(@"1080p Full HD", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) { self->_videoRes = WQConvVideoRes1080p; [tableView reloadData]; })];
            [sheet addAction:wq_alert_action(@"720p HD", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) { self->_videoRes = WQConvVideoRes720p; [tableView reloadData]; })];
            [sheet addAction:wq_alert_action(@"480p SD", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) { self->_videoRes = WQConvVideoRes480p; [tableView reloadData]; })];
            [sheet addAction:wq_alert_action(@"360p Compact", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) { self->_videoRes = WQConvVideoRes360p; [tableView reloadData]; })];
        } else if (indexPath.row == 3) {
            [sheet addAction:wq_alert_action(WQLocalized(@"High Bitrate"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) { self->_videoQuality = WQConvQualityHigh; [tableView reloadData]; })];
            [sheet addAction:wq_alert_action(WQLocalized(@"Balanced (Recommended)"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) { self->_videoQuality = WQConvQualityBalanced; [tableView reloadData]; })];
            [sheet addAction:wq_alert_action(WQLocalized(@"Compact (Small File)"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) { self->_videoQuality = WQConvQualityCompact; [tableView reloadData]; })];
        } else {
            for (NSNumber *kbps in @[@320, @256, @192, @128, @96]) {
                [sheet addAction:wq_alert_action([NSString stringWithFormat:@"%ld kbps", (long)kbps.integerValue], UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
                    self->_audioBitrateKbps = kbps.integerValue;
                    [tableView reloadData];
                })];
            }
        }
    } else {
        if (indexPath.row == 0) {
            [sheet addAction:wq_alert_action(@"M4A — AAC (Universal)", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) { self->_audioFormat = WQConvAudioFormatM4A_AAC; [tableView reloadData]; })];
            [sheet addAction:wq_alert_action(@"M4A — ALAC (Apple Lossless)", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) { self->_audioFormat = WQConvAudioFormatM4A_ALAC; [tableView reloadData]; })];
            [sheet addAction:wq_alert_action(@"WAV — Uncompressed 16-bit PCM", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) { self->_audioFormat = WQConvAudioFormatWAV_PCM; [tableView reloadData]; })];
            [sheet addAction:wq_alert_action(@"AIFF — Lossless PCM", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) { self->_audioFormat = WQConvAudioFormatAIFF_PCM; [tableView reloadData]; })];
            [sheet addAction:wq_alert_action(@"CAF — Core Audio PCM", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) { self->_audioFormat = WQConvAudioFormatCAF_PCM; [tableView reloadData]; })];
        } else {
            for (NSNumber *kbps in @[@320, @256, @192, @128, @96]) {
                [sheet addAction:wq_alert_action([NSString stringWithFormat:@"%ld kbps", (long)kbps.integerValue], UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
                    self->_audioBitrateKbps = kbps.integerValue;
                    [tableView reloadData];
                })];
            }
        }
    }
    [sheet addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    sheet.popoverPresentationController.sourceView = cell ?: self.view;
    sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : CGRectMake(self.view.bounds.size.width * 0.5, self.view.bounds.size.height * 0.5, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

@end

void wq_present_media_converter(UIViewController *host, NSString *filePath)
{
    if (!host || !filePath.length) return;
    WQMediaConverterViewController *vc = [[WQMediaConverterViewController alloc] initWithFilePath:filePath];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [host presentViewController:nav animated:YES completion:nil];
}
