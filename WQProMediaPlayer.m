//
//  WQProMediaPlayer.m
//  WQ Glass Infuse-Class Universal Media Player & Swipeable Gallery
//  GPL-3.0-or-later.
//

#import "WQProMediaPlayer.h"
#import "WQAccess.h"
#import "WQCore.h"
#import "WQLocalization.h"
#import "WQMediaConverter.h"
#import "WQMediaDemuxer.h"
#import "WQMotion.h"
#import "WQTheme.h"
#import "WQUI.h"
#import <AVKit/AVKit.h>
#import <ImageIO/ImageIO.h>
#import <MediaPlayer/MediaPlayer.h>
#import <MediaToolbox/MediaToolbox.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <netinet/in.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#pragma mark - Watch History Persistence

static NSString *const kWQPlaybackHistoryKey = @"WQPlaybackHistoryMap";
static NSString *const kWQSkipIntervalKey = @"WQPlayerSkipSeconds";
static NSString *const kWQSubSizeKey = @"WQPlayerSubSize";
static NSString *const kWQSubColorKey = @"WQPlayerSubColor";
static NSString *const kWQSubOpacityKey = @"WQPlayerSubBgOpacity";

double wq_playback_progress_for_path(NSString *path)
{
    if (!path.length) return 0.0;
    NSDictionary *map = [NSUserDefaults.standardUserDefaults dictionaryForKey:kWQPlaybackHistoryKey];
    NSDictionary *entry = [map[path] isKindOfClass:NSDictionary.class] ? map[path] : nil;
    if (!entry) return 0.0;
    double pos = [entry[@"pos"] doubleValue];
    double dur = [entry[@"dur"] doubleValue];
    if (dur <= 1.0 || pos <= 0.0) return 0.0;
    return MIN(1.0, MAX(0.0, pos / dur));
}

void wq_playback_save_progress(NSString *path, double positionSeconds, double durationSeconds)
{
    if (!path.length || !isfinite(positionSeconds) || !isfinite(durationSeconds) || durationSeconds <= 1.0) return;
    NSDictionary *existing = [NSUserDefaults.standardUserDefaults dictionaryForKey:kWQPlaybackHistoryKey];
    NSMutableDictionary *map = existing ? [existing mutableCopy] : [NSMutableDictionary new];
    map[path] = @{
        @"pos": @(MAX(0.0, positionSeconds)),
        @"dur": @(durationSeconds),
        @"t": @(CFAbsoluteTimeGetCurrent()),
    };
    if (map.count > 250) {
        NSArray<NSString *> *sorted = [map keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"t"] compare:b[@"t"]];
        }];
        for (NSUInteger i = 0; i < sorted.count && map.count > 220; i++) {
            [map removeObjectForKey:sorted[i]];
        }
    }
    [NSUserDefaults.standardUserDefaults setObject:map forKey:kWQPlaybackHistoryKey];
}

static NSTimeInterval wq_playback_saved_position(NSString *path)
{
    if (!path.length) return 0.0;
    NSDictionary *map = [NSUserDefaults.standardUserDefaults dictionaryForKey:kWQPlaybackHistoryKey];
    NSDictionary *entry = [map[path] isKindOfClass:NSDictionary.class] ? map[path] : nil;
    return entry ? [entry[@"pos"] doubleValue] : 0.0;
}

#pragma mark - Loopback 127.0.0.1 HLS Bridge for Local MPEG-TS (.ts / .m2ts)

@interface WQLocalHLSBridge : NSObject
@property (nonatomic, readonly) uint16_t port;
- (nullable instancetype)initWithFilePath:(NSString *)path duration:(double)duration;
- (nullable NSURL *)playlistURL;
- (void)stop;
@end

@implementation WQLocalHLSBridge {
    NSString *_path;
    double _duration;
    unsigned long long _fileSize;
    int _listenFD;
    atomic_bool _stopped;
    dispatch_queue_t _acceptQueue;
}

- (instancetype)initWithFilePath:(NSString *)path duration:(double)duration
{
    if ((self = [super init])) {
        struct stat st;
        if (!path.length || lstat(path.fileSystemRepresentation, &st) != 0 || st.st_size <= 0) return nil;
        _path = [path copy];
        _duration = (duration > 0.5) ? duration : 3600.0;
        _fileSize = (unsigned long long)st.st_size;
        atomic_init(&_stopped, false);
        _listenFD = socket(AF_INET, SOCK_STREAM, 0);
        if (_listenFD < 0) return nil;
        int yes = 1;
        setsockopt(_listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        addr.sin_port = 0;
        if (bind(_listenFD, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(_listenFD, 8) != 0) {
            close(_listenFD);
            _listenFD = -1;
            return nil;
        }
        socklen_t len = sizeof(addr);
        if (getsockname(_listenFD, (struct sockaddr *)&addr, &len) == 0) {
            _port = ntohs(addr.sin_port);
        }
        _acceptQueue = dispatch_queue_create("com.wqglass.localhls.accept", DISPATCH_QUEUE_SERIAL);
        [self startAcceptLoop];
    }
    return self;
}

- (void)dealloc
{
    [self stop];
}

- (NSURL *)playlistURL
{
    if (_listenFD < 0 || _port == 0) return nil;
    return [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%u/playlist.m3u8", _port]];
}

- (void)stop
{
    atomic_store(&_stopped, true);
    if (_listenFD >= 0) {
        shutdown(_listenFD, SHUT_RDWR);
        close(_listenFD);
        _listenFD = -1;
    }
}

static BOOL wq_bridge_write_all(int fd, const void *buf, size_t len)
{
    const uint8_t *p = (const uint8_t *)buf;
    size_t left = len;
    while (left > 0) {
        ssize_t w = send(fd, p, left, 0);
        if (w <= 0) {
            if (w < 0 && errno == EINTR) continue;
            return NO;
        }
        p += (size_t)w;
        left -= (size_t)w;
    }
    return YES;
}

- (void)startAcceptLoop
{
    __weak typeof(self) weakSelf = self;
    dispatch_async(_acceptQueue, ^{
        while (1) {
            __strong typeof(weakSelf) me = weakSelf;
            if (!me || atomic_load(&me->_stopped) || me->_listenFD < 0) break;
            struct sockaddr_in cli;
            socklen_t clen = sizeof(cli);
            int cfd = accept(me->_listenFD, (struct sockaddr *)&cli, &clen);
            if (cfd < 0) {
                if (errno == EINTR) continue;
                break;
            }
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                [me handleClientSocket:cfd];
                close(cfd);
            });
        }
    });
}

- (void)handleClientSocket:(int)cfd
{
    char reqBuf[4096];
    ssize_t n = recv(cfd, reqBuf, sizeof(reqBuf) - 1, 0);
    if (n <= 0) return;
    reqBuf[n] = '\0';
    NSString *req = [NSString stringWithUTF8String:reqBuf] ?: @"";
    NSArray<NSString *> *lines = [req componentsSeparatedByString:@"\r\n"];
    NSString *first = lines.firstObject ?: @"";

    if ([first containsString:@"/playlist.m3u8"]) {
        NSInteger target = (NSInteger)ceil(_duration) + 2;
        NSString *m3u8 = [NSString stringWithFormat:
            @"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-TARGETDURATION:%ld\n"
            @"#EXTINF:%.3f,\nhttp://127.0.0.1:%u/stream.ts\n#EXT-X-ENDLIST\n",
            (long)target, _duration, _port];
        NSData *body = [m3u8 dataUsingEncoding:NSUTF8StringEncoding];
        NSString *hdr = [NSString stringWithFormat:
            @"HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
            (unsigned long)body.length];
        NSData *hData = [hdr dataUsingEncoding:NSASCIIStringEncoding];
        wq_bridge_write_all(cfd, hData.bytes, hData.length);
        wq_bridge_write_all(cfd, body.bytes, body.length);
        return;
    }

    unsigned long long start = 0;
    unsigned long long end = (_fileSize > 0) ? (_fileSize - 1) : 0;
    BOOL hasRange = NO;
    for (NSString *line in lines) {
        if ([line.lowercaseString hasPrefix:@"range: bytes="]) {
            hasRange = YES;
            NSString *spec = [[line substringFromIndex:13] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            NSArray<NSString *> *parts = [spec componentsSeparatedByString:@"-"];
            if (parts.count >= 1 && parts[0].length) start = (unsigned long long)parts[0].longLongValue;
            if (parts.count >= 2 && parts[1].length) end = (unsigned long long)parts[1].longLongValue;
            if (end >= _fileSize) end = _fileSize - 1;
            break;
        }
    }
    if (start > end || start >= _fileSize) {
        const char *r416 = "HTTP/1.1 416 Range Not Satisfiable\r\nConnection: close\r\n\r\n";
        wq_bridge_write_all(cfd, r416, strlen(r416));
        return;
    }
    unsigned long long length = (end - start) + 1;
    NSString *hdr = hasRange
        ? [NSString stringWithFormat:
           @"HTTP/1.1 206 Partial Content\r\nAccept-Ranges: bytes\r\nContent-Type: video/mp2t\r\n"
           @"Content-Range: bytes %llu-%llu/%llu\r\nContent-Length: %llu\r\nConnection: close\r\n\r\n",
           start, end, _fileSize, length]
        : [NSString stringWithFormat:
           @"HTTP/1.1 200 OK\r\nAccept-Ranges: bytes\r\nContent-Type: video/mp2t\r\n"
           @"Content-Length: %llu\r\nConnection: close\r\n\r\n",
           length];
    NSData *hData = [hdr dataUsingEncoding:NSASCIIStringEncoding];
    if (!wq_bridge_write_all(cfd, hData.bytes, hData.length)) return;

    int fd = open(_path.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return;
    uint8_t buf[131072];
    unsigned long long remaining = length;
    off_t off = (off_t)start;
    while (remaining > 0 && !atomic_load(&_stopped)) {
        size_t want = (size_t)MIN((unsigned long long)sizeof(buf), remaining);
        ssize_t r = pread(fd, buf, want, off);
        if (r <= 0) break;
        if (!wq_bridge_write_all(cfd, buf, (size_t)r)) break;
        off += r;
        remaining -= (unsigned long long)r;
    }
    close(fd);
}

@end

#pragma mark - MTAudioProcessingTap 200% Volume Boost Helper

typedef struct {
    float gain;
} WQTapGainState;

static void wq_audio_tap_init(MTAudioProcessingTapRef __unused tap, void *clientInfo, void **tapStorageOut)
{
    *tapStorageOut = clientInfo;
}

static void wq_audio_tap_finalize(MTAudioProcessingTapRef tap)
{
    WQTapGainState *state = (WQTapGainState *)MTAudioProcessingTapGetStorage(tap);
    if (state) free(state);
}

static void wq_audio_tap_prepare(MTAudioProcessingTapRef __unused tap, CMItemCount __unused maxFrames, const AudioStreamBasicDescription *__unused processingFormat) {}
static void wq_audio_tap_unprepare(MTAudioProcessingTapRef __unused tap) {}

static void wq_audio_tap_process(MTAudioProcessingTapRef tap,
                                 CMItemCount numberFrames,
                                 MTAudioProcessingTapFlags __unused flags,
                                 AudioBufferList *bufferListInOut,
                                 CMItemCount *numberFramesOut,
                                 MTAudioProcessingTapFlags *flagsOut)
{
    OSStatus st = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, NULL, numberFramesOut);
    if (st != noErr) return;
    WQTapGainState *state = (WQTapGainState *)MTAudioProcessingTapGetStorage(tap);
    float gain = state ? state->gain : 1.0f;
    if (fabsf(gain - 1.0f) > 0.01f) {
        for (UInt32 b = 0; b < bufferListInOut->mNumberBuffers; b++) {
            AudioBuffer *ab = &bufferListInOut->mBuffers[b];
            float *samples = (float *)ab->mData;
            if (!samples) continue;
            UInt32 count = ab->mDataByteSize / (UInt32)sizeof(float);
            for (UInt32 i = 0; i < count; i++) {
                float v = samples[i] * gain;
                if (v > 0.96f || v < -0.96f) v = tanhf(v);
                samples[i] = v;
            }
        }
    }
}

#pragma mark - Pro Subtitle Engine (.srt, .vtt, .ass / .ssa)

@interface WQSubtitleCue : NSObject
@property (nonatomic) NSTimeInterval start;
@property (nonatomic) NSTimeInterval end;
@property (nonatomic, copy) NSString *text;
@end

@implementation WQSubtitleCue
@end

static NSTimeInterval wq_parse_subtitle_timestamp(NSString *raw)
{
    NSString *clean = [[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                       stringByReplacingOccurrencesOfString:@"," withString:@"."];
    NSArray<NSString *> *parts = [clean componentsSeparatedByString:@":"];
    if (parts.count == 3) {
        return parts[0].doubleValue * 3600.0 + parts[1].doubleValue * 60.0 + parts[2].doubleValue;
    }
    if (parts.count == 2) {
        return parts[0].doubleValue * 60.0 + parts[1].doubleValue;
    }
    return -1.0;
}

static NSString *wq_strip_ass_tags(NSString *raw)
{
    NSString *s = [raw stringByReplacingOccurrencesOfString:@"\\N" withString:@"\n"];
    s = [s stringByReplacingOccurrencesOfString:@"\\n" withString:@"\n"];
    s = [s stringByReplacingOccurrencesOfString:@"\\h" withString:@" "];
    NSError *err = nil;
    NSRegularExpression *rx = [NSRegularExpression regularExpressionWithPattern:@"\\{[^}]*\\}|<[^>]*>" options:0 error:&err];
    if (rx) s = [rx stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@""];
    return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSArray<WQSubtitleCue *> *wq_parse_subtitles(NSString *content)
{
    if (!content.length) return @[];
    NSString *norm = [[content stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
                      stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];

    // Support .ass / .ssa script files
    if ([norm containsString:@"Dialogue:"] && ([norm containsString:@"[Events]"] || [norm containsString:@"[Script Info]"])) {
        NSMutableArray<WQSubtitleCue *> *assCues = [NSMutableArray new];
        for (NSString *line in [norm componentsSeparatedByString:@"\n"]) {
            if (![line hasPrefix:@"Dialogue:"]) continue;
            NSString *payload = [line substringFromIndex:9];
            // Standard ASS Dialogue has 9 comma-separated fields before the text body.
            NSMutableArray<NSString *> *fields = [NSMutableArray new];
            NSUInteger idx = 0;
            for (int f = 0; f < 9 && idx < payload.length; f++) {
                NSRange comma = [payload rangeOfString:@"," options:0 range:NSMakeRange(idx, payload.length - idx)];
                if (comma.location == NSNotFound) break;
                [fields addObject:[payload substringWithRange:NSMakeRange(idx, comma.location - idx)]];
                idx = NSMaxRange(comma);
            }
            if (fields.count >= 3 && idx < payload.length) {
                NSTimeInterval st = wq_parse_subtitle_timestamp(fields[1]);
                NSTimeInterval en = wq_parse_subtitle_timestamp(fields[2]);
                NSString *txt = wq_strip_ass_tags([payload substringFromIndex:idx]);
                if (st >= 0 && en > st && txt.length) {
                    WQSubtitleCue *c = [WQSubtitleCue new];
                    c.start = st;
                    c.end = en;
                    c.text = txt;
                    [assCues addObject:c];
                }
            }
        }
        if (assCues.count) return assCues;
    }

    NSArray<NSString *> *blocks = [norm componentsSeparatedByString:@"\n\n"];
    NSMutableArray<WQSubtitleCue *> *cues = [NSMutableArray new];
    for (NSString *block in blocks) {
        NSArray<NSString *> *lines = [block componentsSeparatedByString:@"\n"];
        NSInteger timeIdx = -1;
        for (NSInteger i = 0; i < (NSInteger)lines.count; i++) {
            if ([lines[(NSUInteger)i] containsString:@"-->"]) {
                timeIdx = i;
                break;
            }
        }
        if (timeIdx < 0) continue;
        NSArray<NSString *> *range = [lines[(NSUInteger)timeIdx] componentsSeparatedByString:@"-->"];
        if (range.count < 2) continue;
        NSTimeInterval start = wq_parse_subtitle_timestamp(range[0]);
        NSString *endToken = [[range[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
                              componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet].firstObject ?: @"";
        NSTimeInterval end = wq_parse_subtitle_timestamp(endToken);
        if (start < 0 || end <= start) continue;
        NSMutableArray<NSString *> *textLines = [NSMutableArray new];
        for (NSUInteger i = (NSUInteger)timeIdx + 1; i < lines.count; i++) {
            NSString *l = wq_strip_ass_tags(lines[i]);
            if (l.length) [textLines addObject:l];
        }
        if (!textLines.count) continue;
        WQSubtitleCue *cue = [WQSubtitleCue new];
        cue.start = start;
        cue.end = end;
        cue.text = [textLines componentsJoinedByString:@"\n"];
        [cues addObject:cue];
    }
    return cues;
}

static NSString *wq_format_time(NSTimeInterval seconds)
{
    if (!isfinite(seconds) || seconds < 0) seconds = 0;
    NSInteger total = (NSInteger)llround(seconds);
    NSInteger h = total / 3600;
    NSInteger m = (total % 3600) / 60;
    NSInteger s = total % 60;
    if (h > 0) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)h, (long)m, (long)s];
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)m, (long)s];
}

typedef NS_ENUM(NSInteger, WQPlayerAspectMode) {
    WQPlayerAspectFit = 0,
    WQPlayerAspectFill,
    WQPlayerAspectStretch,
    WQPlayerAspect16x9,
    WQPlayerAspect4x3,
    WQPlayerAspect21x9,
};

typedef NS_ENUM(NSInteger, WQPlayerLoopMode) {
    WQPlayerLoopOff = 0,
    WQPlayerLoopOne = 1,
    WQPlayerLoopAll = 2,
};

#pragma mark - Infuse-Class Pro Media Player

@interface WQProMediaPlayerViewController () <AVPictureInPictureControllerDelegate, UIDocumentPickerDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong, readwrite) AVPlayer *player;
@end

@implementation WQProMediaPlayerViewController {
    NSString *_sourcePath;
    NSURL *_activeURL;
    NSDictionary<NSString *, NSString *> *_streamHeaders;
    AVPlayerLayer *_playerLayer;
    AVPictureInPictureController *_pip;
    WQLocalHLSBridge *_hlsBridge;
    atomic_bool _remuxCancelled;
    BOOL _didFallbackFromBridge;
    BOOL _appliedInitialResume;
    NSTimeInterval _lastSavedClock;

    id _timeObserver;
    id _endObserver;
    AVPlayerItem *_observedItem;

    UIView *_videoContainer;
    UIVisualEffectView *_controlsCard;
    UIVisualEffectView *_prepCard;
    UILabel *_prepLabel;
    UIProgressView *_prepProgress;

    UIVisualEffectView *_resumeBanner;
    UILabel *_resumeLabel;
    UIVisualEffectView *_hold2xPill;
    UIVisualEffectView *_upNextBanner;
    UILabel *_upNextLabel;

    UIButton *_playPauseBtn;
    UIButton *_prevBtn;
    UIButton *_nextBtn;
    UIButton *_skipBackBtn;
    UIButton *_skipFwdBtn;
    UIButton *_speedBtn;
    UIButton *_aspectBtn;
    UIButton *_loopBtn;
    UIButton *_pipBtn;
    UIButton *_audioBtn;
    UIButton *_subBtn;
    UIButton *_moreBtn;
    UIButton *_lockBtn;
    UIButton *_unlockBtn;
    UISlider *_scrubber;
    UILabel *_elapsedLabel;
    UILabel *_durationLabel;
    UILabel *_subtitleLabel;
    UIVisualEffectView *_subtitleBox;
    NSLayoutConstraint *_subtitleBottomConstraint;

    UIVisualEffectView *_gestureHudBox;
    UIImageView *_scrubPreviewView;
    UILabel *_gestureHudLabel;
    AVAssetImageGenerator *_thumbGen;
    NSTimeInterval _lastThumbRequestClock;

    float _rate;
    float _preHoldRate;
    float _volumeBoost;     // 1.0, 1.25, 1.5, 2.0
    NSTimeInterval _audioOffset;
    NSTimeInterval _subOffset;
    WQPlayerLoopMode _loopMode;
    WQPlayerAspectMode _aspectMode;
    CGFloat _pinchZoomScale;
    CGFloat _basePinchScale;
    BOOL _controlsHidden;
    BOOL _screenLocked;
    BOOL _scrubbing;
    NSInteger _skipSeconds;

    NSTimeInterval _abPointA;
    NSTimeInterval _abPointB;
    NSTimer *_sleepTimer;
    NSTimeInterval _sleepRemaining;
    BOOL _sleepAtEndOfVideo;

    NSArray<WQSubtitleCue *> *_subtitles;
    NSArray<NSString *> *_playlistPaths;
    NSInteger _playlistIndex;

    NSInteger _panMode; // 0=none, 1=brightness, 2=volume, 3=seek
    CGFloat _panStartValue;
    NSTimeInterval _panStartTime;
    NSTimeInterval _seekTargetTime;
}

+ (void)presentPlayerFrom:(UIViewController *)host title:(NSString *)title localPath:(NSString *)localPath
{
    if (!host || !localPath.length) return;
    WQProMediaPlayerViewController *vc = [[WQProMediaPlayerViewController alloc] initWithTitle:title ?: localPath.lastPathComponent sourcePath:localPath];
    if (wq_is_convertible_media_path(localPath)) {
        __weak WQProMediaPlayerViewController *weakVC = vc;
        vc.onConvert = ^{
            WQProMediaPlayerViewController *me = weakVC;
            if (me) wq_present_media_converter(me, localPath);
        };
    }
    [vc replaceWithLocalURL:[NSURL fileURLWithPath:localPath]];
    if (host.navigationController) {
        [host.navigationController pushViewController:vc animated:YES];
    } else {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationFullScreen;
        vc.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:vc action:@selector(dismissModalSelf)];
        [host presentViewController:nav animated:YES completion:nil];
    }
}

+ (void)presentStreamFrom:(UIViewController *)host
                    title:(NSString *)title
                streamURL:(NSURL *)url
                  headers:(NSDictionary<NSString *, NSString *> *)headers
{
    if (!host || !url) return;
    WQProMediaPlayerViewController *vc = [[WQProMediaPlayerViewController alloc] initWithTitle:title ?: url.lastPathComponent sourcePath:url.absoluteString];
    vc->_streamHeaders = [headers copy];
    AVURLAsset *asset = headers.count
        ? [AVURLAsset URLAssetWithURL:url options:@{@"AVURLAssetHTTPHeaderFieldsKey": headers}]
        : [AVURLAsset URLAssetWithURL:url options:nil];
    [vc loadPlayerItem:[AVPlayerItem playerItemWithAsset:asset]];
    if (host.navigationController) {
        [host.navigationController pushViewController:vc animated:YES];
    } else {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationFullScreen;
        vc.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:vc action:@selector(dismissModalSelf)];
        [host presentViewController:nav animated:YES completion:nil];
    }
}

- (void)dismissModalSelf
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (instancetype)initWithTitle:(NSString *)title sourcePath:(NSString *)sourcePath
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        self.title = title;
        _sourcePath = [sourcePath copy];
        _rate = 1.0f;
        _volumeBoost = 1.0f;
        _pinchZoomScale = 1.0;
        _abPointA = -1.0;
        _abPointB = -1.0;
        NSInteger savedSkip = [NSUserDefaults.standardUserDefaults integerForKey:kWQSkipIntervalKey];
        _skipSeconds = (savedSkip == 5 || savedSkip == 15 || savedSkip == 30) ? savedSkip : 10;
        atomic_init(&_remuxCancelled, false);
        _player = [AVPlayer new];
        [self buildSiblingPlaylist];
    }
    return self;
}

- (void)dealloc
{
    atomic_store(&_remuxCancelled, true);
    [self saveCurrentPlaybackProgress];
    [_hlsBridge stop];
    [_sleepTimer invalidate];
    if (_observedItem) {
        @try { [_observedItem removeObserver:self forKeyPath:@"status"]; } @catch (NSException *__unused e) {}
        _observedItem = nil;
    }
    if (_timeObserver) [_player removeTimeObserver:_timeObserver];
    if (_endObserver) [NSNotificationCenter.defaultCenter removeObserver:_endObserver];
    MPRemoteCommandCenter *rcc = MPRemoteCommandCenter.sharedCommandCenter;
    [rcc.playCommand removeTarget:self];
    [rcc.pauseCommand removeTarget:self];
    [rcc.skipForwardCommand removeTarget:self];
    [rcc.skipBackwardCommand removeTarget:self];
    [rcc.nextTrackCommand removeTarget:self];
    [rcc.previousTrackCommand removeTarget:self];
    [rcc.changePlaybackPositionCommand removeTarget:self];
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = nil;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback error:nil];
    [AVAudioSession.sharedInstance setActive:YES error:nil];

    _videoContainer = [UIView new];
    _videoContainer.translatesAutoresizingMaskIntoConstraints = NO;
    _videoContainer.backgroundColor = UIColor.blackColor;
    _videoContainer.clipsToBounds = YES;
    [self.view addSubview:_videoContainer];

    _playerLayer = [AVPlayerLayer playerLayerWithPlayer:_player];
    _playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    [_videoContainer.layer addSublayer:_playerLayer];

    if ([AVPictureInPictureController isPictureInPictureSupported]) {
        _pip = [[AVPictureInPictureController alloc] initWithPlayerLayer:_playerLayer];
        _pip.delegate = self;
    }

    [self buildOverlayUI];
    [self installGestures];
    [self setupRemoteCommands];
    [self attachPlayerObservers];
    [self autoLoadSiblingSubtitles];
    [self applySubtitleAppearance];

    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIBarButtonItem *> *rightItems = [NSMutableArray new];
    UIBarButtonItem *infoItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"info.circle"]
                                                                 style:UIBarButtonItemStylePlain
                                                                target:self
                                                                action:@selector(showMediaStatsHUD)];
    [rightItems addObject:infoItem];
    if (self.onConvert) {
        [rightItems addObject:[[UIBarButtonItem alloc] initWithPrimaryAction:
            [UIAction actionWithTitle:WQLocalized(@"Convert")
                                image:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"]
                           identifier:nil handler:^(UIAction *__unused a) {
            [weakSelf.player pause];
            if (weakSelf.onConvert) weakSelf.onConvert();
        }]]];
    }
    self.navigationItem.rightBarButtonItems = rightItems;
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    [self layoutPlayerLayerForAspectAndZoom];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self saveCurrentPlaybackProgress];
    if (self.isMovingFromParentViewController && !_pip.isPictureInPictureActive) {
        [_player pause];
        [_hlsBridge stop];
    }
}

#pragma mark - Aspect Ratio & Pinch-to-Zoom Layout

- (void)layoutPlayerLayerForAspectAndZoom
{
    CGRect bounds = _videoContainer.bounds;
    if (bounds.size.width <= 0 || bounds.size.height <= 0) return;

    CGRect target = bounds;
    _playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    if (_aspectMode == WQPlayerAspectFill) {
        _playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    } else if (_aspectMode == WQPlayerAspectStretch) {
        _playerLayer.videoGravity = AVLayerVideoGravityResize;
    } else if (_aspectMode == WQPlayerAspect16x9 || _aspectMode == WQPlayerAspect4x3 || _aspectMode == WQPlayerAspect21x9) {
        CGFloat ratio = (_aspectMode == WQPlayerAspect16x9) ? (16.0 / 9.0)
                      : (_aspectMode == WQPlayerAspect4x3) ? (4.0 / 3.0) : (21.0 / 9.0);
        CGFloat w = bounds.size.width;
        CGFloat h = w / ratio;
        if (h > bounds.size.height) {
            h = bounds.size.height;
            w = h * ratio;
        }
        target = CGRectMake((bounds.size.width - w) * 0.5, (bounds.size.height - h) * 0.5, w, h);
        _playerLayer.videoGravity = AVLayerVideoGravityResize;
    }

    _playerLayer.frame = target;
    _playerLayer.transform = CATransform3DMakeScale(_pinchZoomScale, _pinchZoomScale, 1.0);
}

#pragma mark - Overlay UI Construction

- (void)buildOverlayUI
{
    __weak typeof(self) weakSelf = self;

    // 2x Hold Banner
    _hold2xPill = wq_theme_make_glass_card(16, YES);
    _hold2xPill.hidden = YES;
    UILabel *h2l = [UILabel new];
    h2l.translatesAutoresizingMaskIntoConstraints = NO;
    h2l.text = [NSString stringWithFormat:@"⏩ 2.0× %@", WQLocalized(@"Fast Forward")];
    h2l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    h2l.textColor = wq_theme_accent();
    [_hold2xPill.contentView addSubview:h2l];
    [self.view addSubview:_hold2xPill];

    // Resume Pill Banner
    _resumeBanner = wq_theme_make_glass_card(16, YES);
    _resumeBanner.hidden = YES;
    _resumeLabel = [UILabel new];
    _resumeLabel.font = [UIFont monospacedDigitSystemFontOfSize:12.5 weight:UIFontWeightSemibold];
    _resumeLabel.textColor = UIColor.whiteColor;
    UIButton *restartBtn = [self makePillBtn:WQLocalized(@"Start Over") symbol:@"arrow.counterclockwise" action:^{
        WQProMediaPlayerViewController *me = weakSelf;
        if (!me) return;
        [me.player seekToTime:kCMTimeZero];
        me->_resumeBanner.hidden = YES;
    }];
    UIStackView *resStack = [[UIStackView alloc] initWithArrangedSubviews:@[_resumeLabel, restartBtn]];
    resStack.translatesAutoresizingMaskIntoConstraints = NO;
    resStack.axis = UILayoutConstraintAxisHorizontal;
    resStack.alignment = UIStackViewAlignmentCenter;
    resStack.spacing = 10;
    [_resumeBanner.contentView addSubview:resStack];
    [self.view addSubview:_resumeBanner];

    // Preparing / Remux Progress Pill
    _prepCard = wq_theme_make_glass_card(18, YES);
    _prepCard.hidden = YES;
    _prepLabel = [UILabel new];
    _prepLabel.font = [UIFont systemFontOfSize:13.5 weight:UIFontWeightSemibold];
    _prepLabel.textColor = UIColor.whiteColor;
    _prepLabel.textAlignment = NSTextAlignmentCenter;
    _prepProgress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _prepProgress.tintColor = wq_theme_accent();
    UIStackView *prepStack = [[UIStackView alloc] initWithArrangedSubviews:@[_prepLabel, _prepProgress]];
    prepStack.translatesAutoresizingMaskIntoConstraints = NO;
    prepStack.axis = UILayoutConstraintAxisVertical;
    prepStack.spacing = 8;
    [_prepCard.contentView addSubview:prepStack];
    [self.view addSubview:_prepCard];

    // Up Next Episode Banner
    _upNextBanner = wq_theme_make_glass_card(16, YES);
    _upNextBanner.hidden = YES;
    _upNextLabel = [UILabel new];
    _upNextLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
    _upNextLabel.textColor = UIColor.whiteColor;
    UIButton *playNextNow = [self makePillBtn:WQLocalized(@"Next") symbol:@"forward.end.fill" action:^{
        [weakSelf playNextEpisode];
    }];
    UIStackView *upStack = [[UIStackView alloc] initWithArrangedSubviews:@[_upNextLabel, playNextNow]];
    upStack.translatesAutoresizingMaskIntoConstraints = NO;
    upStack.axis = UILayoutConstraintAxisHorizontal;
    upStack.alignment = UIStackViewAlignmentCenter;
    upStack.spacing = 8;
    [_upNextBanner.contentView addSubview:upStack];
    [self.view addSubview:_upNextBanner];

    // Subtitle Box
    _subtitleBox = wq_theme_make_glass_card(12, NO);
    _subtitleBox.hidden = YES;
    _subtitleLabel = [UILabel new];
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _subtitleLabel.numberOfLines = 0;
    _subtitleLabel.textAlignment = NSTextAlignmentCenter;
    _subtitleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    _subtitleLabel.textColor = UIColor.whiteColor;
    [_subtitleBox.contentView addSubview:_subtitleLabel];
    [self.view addSubview:_subtitleBox];

    // Center Gesture HUD + Scrub Thumbnail
    _gestureHudBox = wq_theme_make_glass_card(16, YES);
    _gestureHudBox.hidden = YES;
    _scrubPreviewView = [UIImageView new];
    _scrubPreviewView.contentMode = UIViewContentModeScaleAspectFill;
    _scrubPreviewView.layer.cornerRadius = 8;
    _scrubPreviewView.clipsToBounds = YES;
    _scrubPreviewView.hidden = YES;
    [_scrubPreviewView.widthAnchor constraintEqualToConstant:156].active = YES;
    [_scrubPreviewView.heightAnchor constraintEqualToConstant:88].active = YES;

    _gestureHudLabel = [UILabel new];
    _gestureHudLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightBold];
    _gestureHudLabel.textColor = UIColor.whiteColor;
    _gestureHudLabel.textAlignment = NSTextAlignmentCenter;
    UIStackView *hudStack = [[UIStackView alloc] initWithArrangedSubviews:@[_scrubPreviewView, _gestureHudLabel]];
    hudStack.translatesAutoresizingMaskIntoConstraints = NO;
    hudStack.axis = UILayoutConstraintAxisVertical;
    hudStack.alignment = UIStackViewAlignmentCenter;
    hudStack.spacing = 6;
    [_gestureHudBox.contentView addSubview:hudStack];
    [self.view addSubview:_gestureHudBox];

    // Controls Dock
    _controlsCard = wq_theme_make_glass_card(22, YES);
    [self.view addSubview:_controlsCard];

    _elapsedLabel = [UILabel new];
    _elapsedLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.5 weight:UIFontWeightMedium];
    _elapsedLabel.textColor = wq_theme_secondary_text();
    _elapsedLabel.text = @"00:00";

    _durationLabel = [UILabel new];
    _durationLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.5 weight:UIFontWeightMedium];
    _durationLabel.textColor = wq_theme_secondary_text();
    _durationLabel.text = @"00:00";
    _durationLabel.textAlignment = NSTextAlignmentRight;

    _scrubber = [UISlider new];
    _scrubber.minimumTrackTintColor = wq_theme_accent();
    _scrubber.maximumTrackTintColor = [UIColor.whiteColor colorWithAlphaComponent:0.25];
    [_scrubber addTarget:self action:@selector(scrubberDown) forControlEvents:UIControlEventTouchDown];
    [_scrubber addTarget:self action:@selector(scrubberChanged) forControlEvents:UIControlEventValueChanged];
    [_scrubber addTarget:self action:@selector(scrubberUp) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];

    UIStackView *timeRow = [[UIStackView alloc] initWithArrangedSubviews:@[_elapsedLabel, _scrubber, _durationLabel]];
    timeRow.axis = UILayoutConstraintAxisHorizontal;
    timeRow.alignment = UIStackViewAlignmentCenter;
    timeRow.spacing = 8;

    _prevBtn = [self makeIconBtn:@"backward.end.fill" size:17 action:^{ [weakSelf playPreviousEpisode]; }];
    _skipBackBtn = [self makeIconBtn:[NSString stringWithFormat:@"gobackward.%ld", (long)_skipSeconds] size:19 action:^{
        WQProMediaPlayerViewController *me = weakSelf;
        if (me) [me skipBy:-(NSTimeInterval)me->_skipSeconds showHUD:YES];
    }];
    _playPauseBtn = [self makeIconBtn:@"pause.fill" size:24 action:^{ [weakSelf togglePlayPause]; }];
    _skipFwdBtn = [self makeIconBtn:[NSString stringWithFormat:@"goforward.%ld", (long)_skipSeconds] size:19 action:^{
        WQProMediaPlayerViewController *me = weakSelf;
        if (me) [me skipBy:(NSTimeInterval)me->_skipSeconds showHUD:YES];
    }];
    _nextBtn = [self makeIconBtn:@"forward.end.fill" size:17 action:^{ [weakSelf playNextEpisode]; }];
    _prevBtn.enabled = (_playlistPaths.count > 1);
    _nextBtn.enabled = (_playlistPaths.count > 1);

    UIStackView *transportRow = [[UIStackView alloc] initWithArrangedSubviews:@[_prevBtn, _skipBackBtn, _playPauseBtn, _skipFwdBtn, _nextBtn]];
    transportRow.axis = UILayoutConstraintAxisHorizontal;
    transportRow.distribution = UIStackViewDistributionEqualSpacing;
    transportRow.alignment = UIStackViewAlignmentCenter;
    transportRow.spacing = 18;

    _speedBtn = [self makePillBtn:@"1.0×" symbol:nil action:^{ [weakSelf cycleSpeed]; }];
    _aspectBtn = [self makePillBtn:WQLocalized(@"Fit") symbol:nil action:^{ [weakSelf cycleAspectRatio]; }];
    _loopBtn = [self makePillBtn:nil symbol:@"repeat" action:^{ [weakSelf cycleLoopMode]; }];
    _pipBtn = [self makePillBtn:nil symbol:@"pip.enter" action:^{ [weakSelf togglePiP]; }];
    _pipBtn.enabled = (_pip != nil);
    _audioBtn = [self makePillBtn:nil symbol:@"speaker.wave.3.fill" action:^{ [weakSelf showAudioOptions]; }];
    _subBtn = [self makePillBtn:nil symbol:@"captions.bubble" action:^{ [weakSelf showSubtitleOptions]; }];
    _lockBtn = [self makePillBtn:nil symbol:@"lock.open" action:^{ [weakSelf setScreenLocked:YES]; }];
    _moreBtn = [self makePillBtn:nil symbol:@"ellipsis.circle" action:^{ [weakSelf showCinemaExtrasMenu]; }];

    AVRoutePickerView *airplay = [[AVRoutePickerView alloc] initWithFrame:CGRectMake(0, 0, 28, 28)];
    airplay.activeTintColor = wq_theme_accent();
    airplay.tintColor = wq_theme_primary_text();
    [airplay.widthAnchor constraintEqualToConstant:28].active = YES;
    [airplay.heightAnchor constraintEqualToConstant:28].active = YES;

    UIScrollView *toolsScroll = [UIScrollView new];
    toolsScroll.showsHorizontalScrollIndicator = NO;
    UIStackView *toolsRow = [[UIStackView alloc] initWithArrangedSubviews:@[_speedBtn, _aspectBtn, _audioBtn, _subBtn, _loopBtn, _pipBtn, airplay, _lockBtn, _moreBtn]];
    toolsRow.translatesAutoresizingMaskIntoConstraints = NO;
    toolsRow.axis = UILayoutConstraintAxisHorizontal;
    toolsRow.alignment = UIStackViewAlignmentCenter;
    toolsRow.spacing = 8;
    [toolsScroll addSubview:toolsRow];
    [NSLayoutConstraint activateConstraints:@[
        [toolsRow.topAnchor constraintEqualToAnchor:toolsScroll.contentLayoutGuide.topAnchor],
        [toolsRow.bottomAnchor constraintEqualToAnchor:toolsScroll.contentLayoutGuide.bottomAnchor],
        [toolsRow.leadingAnchor constraintEqualToAnchor:toolsScroll.contentLayoutGuide.leadingAnchor],
        [toolsRow.trailingAnchor constraintEqualToAnchor:toolsScroll.contentLayoutGuide.trailingAnchor],
        [toolsRow.heightAnchor constraintEqualToAnchor:toolsScroll.frameLayoutGuide.heightAnchor],
        [toolsScroll.heightAnchor constraintEqualToConstant:34],
    ]];

    UIStackView *panel = [[UIStackView alloc] initWithArrangedSubviews:@[timeRow, transportRow, toolsScroll]];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.axis = UILayoutConstraintAxisVertical;
    panel.spacing = 10;
    [_controlsCard.contentView addSubview:panel];

    _unlockBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _unlockBtn.translatesAutoresizingMaskIntoConstraints = NO;
    wq_theme_style_secondary_button(_unlockBtn, WQLocalized(@"Unlock"), @"lock.fill");
    _unlockBtn.hidden = YES;
    [_unlockBtn addAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
        [weakSelf setScreenLocked:NO];
    }] forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_unlockBtn];

    _subtitleBottomConstraint = [_subtitleBox.bottomAnchor constraintEqualToAnchor:_controlsCard.topAnchor constant:-12];

    [NSLayoutConstraint activateConstraints:@[
        [_videoContainer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_videoContainer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_videoContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_videoContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [_hold2xPill.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [_hold2xPill.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [h2l.topAnchor constraintEqualToAnchor:_hold2xPill.contentView.topAnchor constant:6],
        [h2l.bottomAnchor constraintEqualToAnchor:_hold2xPill.contentView.bottomAnchor constant:-6],
        [h2l.leadingAnchor constraintEqualToAnchor:_hold2xPill.contentView.leadingAnchor constant:14],
        [h2l.trailingAnchor constraintEqualToAnchor:_hold2xPill.contentView.trailingAnchor constant:-14],

        [_resumeBanner.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:14],
        [_resumeBanner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [resStack.topAnchor constraintEqualToAnchor:_resumeBanner.contentView.topAnchor constant:8],
        [resStack.bottomAnchor constraintEqualToAnchor:_resumeBanner.contentView.bottomAnchor constant:-8],
        [resStack.leadingAnchor constraintEqualToAnchor:_resumeBanner.contentView.leadingAnchor constant:12],
        [resStack.trailingAnchor constraintEqualToAnchor:_resumeBanner.contentView.trailingAnchor constant:-12],

        [_prepCard.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_prepCard.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [_prepCard.widthAnchor constraintEqualToConstant:260],
        [prepStack.topAnchor constraintEqualToAnchor:_prepCard.contentView.topAnchor constant:14],
        [prepStack.bottomAnchor constraintEqualToAnchor:_prepCard.contentView.bottomAnchor constant:-14],
        [prepStack.leadingAnchor constraintEqualToAnchor:_prepCard.contentView.leadingAnchor constant:16],
        [prepStack.trailingAnchor constraintEqualToAnchor:_prepCard.contentView.trailingAnchor constant:-16],

        [_upNextBanner.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-14],
        [_upNextBanner.bottomAnchor constraintEqualToAnchor:_controlsCard.topAnchor constant:-12],
        [upStack.topAnchor constraintEqualToAnchor:_upNextBanner.contentView.topAnchor constant:8],
        [upStack.bottomAnchor constraintEqualToAnchor:_upNextBanner.contentView.bottomAnchor constant:-8],
        [upStack.leadingAnchor constraintEqualToAnchor:_upNextBanner.contentView.leadingAnchor constant:12],
        [upStack.trailingAnchor constraintEqualToAnchor:_upNextBanner.contentView.trailingAnchor constant:-12],

        [_gestureHudBox.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_gestureHudBox.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-36],
        [hudStack.topAnchor constraintEqualToAnchor:_gestureHudBox.contentView.topAnchor constant:10],
        [hudStack.bottomAnchor constraintEqualToAnchor:_gestureHudBox.contentView.bottomAnchor constant:-10],
        [hudStack.leadingAnchor constraintEqualToAnchor:_gestureHudBox.contentView.leadingAnchor constant:14],
        [hudStack.trailingAnchor constraintEqualToAnchor:_gestureHudBox.contentView.trailingAnchor constant:-14],

        [_controlsCard.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:14],
        [_controlsCard.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-14],
        [_controlsCard.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
        [panel.topAnchor constraintEqualToAnchor:_controlsCard.contentView.topAnchor constant:12],
        [panel.bottomAnchor constraintEqualToAnchor:_controlsCard.contentView.bottomAnchor constant:-12],
        [panel.leadingAnchor constraintEqualToAnchor:_controlsCard.contentView.leadingAnchor constant:14],
        [panel.trailingAnchor constraintEqualToAnchor:_controlsCard.contentView.trailingAnchor constant:-14],

        [_subtitleBox.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_subtitleBox.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:24],
        [_subtitleBox.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-24],
        _subtitleBottomConstraint,
        [_subtitleLabel.topAnchor constraintEqualToAnchor:_subtitleBox.contentView.topAnchor constant:6],
        [_subtitleLabel.bottomAnchor constraintEqualToAnchor:_subtitleBox.contentView.bottomAnchor constant:-6],
        [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_subtitleBox.contentView.leadingAnchor constant:12],
        [_subtitleLabel.trailingAnchor constraintEqualToAnchor:_subtitleBox.contentView.trailingAnchor constant:-12],

        [_unlockBtn.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:16],
        [_unlockBtn.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16],
    ]];
}

- (UIButton *)makeIconBtn:(NSString *)symbol size:(CGFloat)pt action:(void (^)(void))handler
{
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
    cfg.image = [UIImage systemImageNamed:symbol
                        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:pt weight:UIImageSymbolWeightBold]];
    cfg.baseForegroundColor = wq_theme_primary_text();
    btn.configuration = cfg;
    [btn addAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
        wq_haptic_selection();
        handler();
    }] forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

- (UIButton *)makePillBtn:(NSString *)title symbol:(NSString *)symbol action:(void (^)(void))handler
{
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *cfg = [UIButtonConfiguration glassButtonConfiguration];
    cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    cfg.contentInsets = NSDirectionalEdgeInsetsMake(6, 10, 6, 10);
    cfg.baseForegroundColor = wq_theme_primary_text();
    cfg.baseBackgroundColor = wq_theme_glass_tint();
    if (title.length) cfg.title = title;
    if (symbol.length) {
        cfg.image = [UIImage systemImageNamed:symbol
                            withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold]];
    }
    btn.configuration = cfg;
    [btn addAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
        wq_haptic_selection();
        handler();
    }] forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

#pragma mark - Pro Gestures (Double-Tap Skip, 2x Hold, Pinch Zoom, Edge Swipes)

- (void)installGestures
{
    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap:)];
    doubleTap.numberOfTapsRequired = 2;
    doubleTap.delegate = self;
    [_videoContainer addGestureRecognizer:doubleTap];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
    [tap requireGestureRecognizerToFail:doubleTap];
    tap.delegate = self;
    [_videoContainer addGestureRecognizer:tap];

    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleHold2x:)];
    hold.minimumPressDuration = 0.38;
    hold.delegate = self;
    [_videoContainer addGestureRecognizer:hold];

    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handlePinch:)];
    pinch.delegate = self;
    [_videoContainer addGestureRecognizer:pinch];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    pan.delegate = self;
    [_videoContainer addGestureRecognizer:pan];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *__unused)gestureRecognizer shouldReceiveTouch:(UITouch *)touch
{
    return ![touch.view isDescendantOfView:_controlsCard] && ![touch.view isDescendantOfView:_resumeBanner] && ![touch.view isDescendantOfView:_upNextBanner];
}

- (void)showTemporaryHUDText:(NSString *)text
{
    _scrubPreviewView.hidden = YES;
    _gestureHudLabel.text = text;
    _gestureHudBox.hidden = NO;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideTemporaryHUD) object:nil];
    [self performSelector:@selector(hideTemporaryHUD) withObject:nil afterDelay:1.0];
}

- (void)hideTemporaryHUD
{
    if (_panMode == 0) _gestureHudBox.hidden = YES;
}

- (void)handleTap
{
    if (_screenLocked) {
        _unlockBtn.hidden = !_unlockBtn.hidden;
        return;
    }
    _controlsHidden = !_controlsHidden;
    [UIView animateWithDuration:0.22 animations:^{
        self->_controlsCard.alpha = self->_controlsHidden ? 0.0 : 1.0;
        self->_resumeBanner.alpha = self->_controlsHidden ? 0.0 : 1.0;
    }];
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)gr
{
    if (_screenLocked) return;
    CGFloat x = [gr locationInView:_videoContainer].x;
    CGFloat w = MAX(1.0, _videoContainer.bounds.size.width);
    if (x < w * 0.33) {
        [self skipBy:-(NSTimeInterval)_skipSeconds showHUD:YES];
    } else if (x > w * 0.67) {
        [self skipBy:(NSTimeInterval)_skipSeconds showHUD:YES];
    } else {
        if (fabs(_pinchZoomScale - 1.0) > 0.05) {
            _pinchZoomScale = 1.0;
            [self layoutPlayerLayerForAspectAndZoom];
            [self showTemporaryHUDText:WQLocalized(@"Zoom Reset (1.0×)")];
        } else {
            [self togglePlayPause];
        }
    }
}

- (void)handleHold2x:(UILongPressGestureRecognizer *)hold
{
    if (_screenLocked) return;
    if (hold.state == UIGestureRecognizerStateBegan) {
        _preHoldRate = _rate;
        if (_player.rate <= 0.01f) [_player play];
        _player.rate = 2.0f;
        _hold2xPill.hidden = NO;
        wq_haptic_impact(UIImpactFeedbackStyleMedium);
    } else if (hold.state == UIGestureRecognizerStateEnded || hold.state == UIGestureRecognizerStateCancelled || hold.state == UIGestureRecognizerStateFailed) {
        _player.rate = _preHoldRate ?: 1.0f;
        _hold2xPill.hidden = YES;
    }
}

- (void)handlePinch:(UIPinchGestureRecognizer *)pinch
{
    if (_screenLocked) return;
    if (pinch.state == UIGestureRecognizerStateBegan) {
        _basePinchScale = _pinchZoomScale;
    } else if (pinch.state == UIGestureRecognizerStateChanged) {
        _pinchZoomScale = MIN(3.0, MAX(1.0, _basePinchScale * pinch.scale));
        [self layoutPlayerLayerForAspectAndZoom];
        [self showTemporaryHUDText:[NSString stringWithFormat:@"🔍 %.2f×", (double)_pinchZoomScale]];
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)pan
{
    if (_screenLocked) return;
    CGPoint loc = [pan locationInView:_videoContainer];
    CGPoint trans = [pan translationInView:_videoContainer];
    CGSize size = _videoContainer.bounds.size;

    if (pan.state == UIGestureRecognizerStateBegan) {
        CGPoint vel = [pan velocityInView:_videoContainer];
        if (fabs(vel.x) > fabs(vel.y)) {
            _panMode = 3;
            _panStartTime = CMTimeGetSeconds(_player.currentTime);
            if (!isfinite(_panStartTime)) _panStartTime = 0;
        } else if (loc.x < size.width * 0.45) {
            _panMode = 1;
            UIScreen *scr = self.view.window.windowScene.screen;
            _panStartValue = scr ? scr.brightness : 0.5;
        } else {
            _panMode = 2;
            _panStartValue = _player.volume;
        }
        _gestureHudBox.hidden = NO;
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        if (_panMode == 1) {
            _scrubPreviewView.hidden = YES;
            CGFloat delta = -trans.y / MAX(160.0, size.height * 0.55);
            CGFloat val = MIN(1.0, MAX(0.0, _panStartValue + delta));
            UIScreen *scr = self.view.window.windowScene.screen;
            if (scr) scr.brightness = val;
            _gestureHudLabel.text = [NSString stringWithFormat:@"☀️ %ld%%", (long)llround(val * 100.0)];
        } else if (_panMode == 2) {
            _scrubPreviewView.hidden = YES;
            CGFloat delta = -trans.y / MAX(160.0, size.height * 0.55);
            float val = (float)MIN(1.0, MAX(0.0, _panStartValue + delta));
            _player.volume = val;
            _gestureHudLabel.text = [NSString stringWithFormat:@"🔊 %ld%%", (long)llround(val * 100.0)];
        } else if (_panMode == 3) {
            double dur = CMTimeGetSeconds(_player.currentItem.duration);
            double delta = (trans.x / MAX(200.0, size.width)) * 90.0;
            _seekTargetTime = MAX(0.0, _panStartTime + delta);
            if (isfinite(dur) && dur > 0) _seekTargetTime = MIN(dur, _seekTargetTime);
            _gestureHudLabel.text = [NSString stringWithFormat:@"⏩ %@", wq_format_time(_seekTargetTime)];
            [self requestScrubThumbnailAt:_seekTargetTime];
        }
    } else {
        if (_panMode == 3) {
            [_player seekToTime:CMTimeMakeWithSeconds(_seekTargetTime, 600)];
        }
        _panMode = 0;
        _scrubPreviewView.hidden = YES;
        _gestureHudBox.hidden = YES;
    }
}

- (void)requestScrubThumbnailAt:(NSTimeInterval)seconds
{
    if (!_thumbGen) return;
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - _lastThumbRequestClock < 0.18) return;
    _lastThumbRequestClock = now;
    __weak typeof(self) weakSelf = self;
    CMTime t = CMTimeMakeWithSeconds(seconds, 600);
    [_thumbGen generateCGImagesAsynchronouslyForTimes:@[[NSValue valueWithCMTime:t]]
                                   completionHandler:^(CMTime __unused req, CGImageRef img, CMTime __unused act, AVAssetImageGeneratorResult res, NSError *__unused err) {
        if (res != AVAssetImageGeneratorSucceeded || !img) return;
        UIImage *uiImg = [UIImage imageWithCGImage:img];
        dispatch_async(dispatch_get_main_queue(), ^{
            WQProMediaPlayerViewController *me = weakSelf;
            if (!me || me->_panMode != 3) return;
            me->_scrubPreviewView.image = uiImg;
            me->_scrubPreviewView.hidden = NO;
        });
    }];
}

#pragma mark - Universal Format Loading (.ts/.m2ts Loopback HLS + WQMediaDemuxer Cache)

- (void)loadPlayerItem:(AVPlayerItem *)item
{
    if (_observedItem) {
        @try { [_observedItem removeObserver:self forKeyPath:@"status"]; } @catch (NSException *__unused e) {}
        _observedItem = nil;
    }
    _observedItem = item;
    _appliedInitialResume = NO;
    if (item) {
        [item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:nil];
        if ([item.asset isKindOfClass:AVURLAsset.class]) {
            _thumbGen = [[AVAssetImageGenerator alloc] initWithAsset:item.asset];
            _thumbGen.appliesPreferredTrackTransform = YES;
            _thumbGen.maximumSize = CGSizeMake(320, 180);
        }
    }
    [_player replaceCurrentItemWithPlayerItem:item];
    [self applyVolumeBoostMix];
    [_player play];
    _player.rate = _rate;
    [self updateNowPlaying];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (object != _observedItem || ![keyPath isEqualToString:@"status"]) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    AVPlayerItem *item = (AVPlayerItem *)object;
    if (item.status == AVPlayerItemStatusReadyToPlay && !_appliedInitialResume) {
        _appliedInitialResume = YES;
        NSTimeInterval dur = CMTimeGetSeconds(item.duration);
        NSTimeInterval saved = wq_playback_saved_position(_sourcePath);
        if (isfinite(dur) && dur > 20.0 && saved > 5.0 && saved < dur * 0.95) {
            [_player seekToTime:CMTimeMakeWithSeconds(saved, 600)];
            _resumeLabel.text = WQLocalizedFormat(@"Resumed from %@", wq_format_time(saved));
            _resumeBanner.hidden = NO;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                self->_resumeBanner.hidden = YES;
            });
        }
    } else if (item.status == AVPlayerItemStatusFailed) {
        NSString *localPath = _activeURL.isFileURL ? _activeURL.path : _sourcePath;
        if (_hlsBridge && !_didFallbackFromBridge && localPath.length) {
            _didFallbackFromBridge = YES;
            [_hlsBridge stop];
            _hlsBridge = nil;
            [self prepareDemuxedPlaybackForPath:localPath];
        } else {
            NSString *reason = item.error.localizedDescription ?: WQLocalized(@"This media stream or codec could not be decoded.");
            wq_alert(self, WQLocalized(@"Playback Failed"), reason);
        }
    }
}

- (void)replaceWithLocalURL:(NSURL *)url
{
    _activeURL = url;
    [_hlsBridge stop];
    _hlsBridge = nil;
    _didFallbackFromBridge = NO;

    NSString *path = url.isFileURL ? url.path : _sourcePath;
    NSString *ext = path.pathExtension.lowercaseString;

    if ([ext isEqualToString:@"ts"] || [ext isEqualToString:@"m2ts"] || [ext isEqualToString:@"mts"]) {
        // Fast path: check cached MP4 remux first for instant scrubbing; otherwise spin up 127.0.0.1 loopback HLS bridge
        NSString *cached = wq_media_remux_cache_path_for(path, @"mp4");
        if ([NSFileManager.defaultManager fileExistsAtPath:cached]) {
            [self loadPlayerItem:[AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:cached]]];
            return;
        }
        WQMediaProbeInfo *probe = wq_media_probe_file(path);
        double dur = probe.durationSeconds > 0 ? probe.durationSeconds : 3600.0;
        WQLocalHLSBridge *bridge = [[WQLocalHLSBridge alloc] initWithFilePath:path duration:dur];
        NSURL *pl = bridge.playlistURL;
        if (pl) {
            _hlsBridge = bridge;
            [self loadPlayerItem:[AVPlayerItem playerItemWithURL:pl]];
            return;
        }
        [self prepareDemuxedPlaybackForPath:path];
        return;
    }

    if (wq_media_needs_remux_extension(path)) {
        [self prepareDemuxedPlaybackForPath:path];
        return;
    }

    [self loadPlayerItem:[AVPlayerItem playerItemWithURL:url]];
}

- (void)prepareDemuxedPlaybackForPath:(NSString *)path
{
    if (!path.length) return;
    NSString *cached = wq_media_remux_cache_path_for(path, @"mp4");
    if ([NSFileManager.defaultManager fileExistsAtPath:cached]) {
        [self loadPlayerItem:[AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:cached]]];
        return;
    }
    _prepCard.hidden = NO;
    _prepProgress.progress = 0.05f;
    _prepLabel.text = WQLocalized(@"Preparing stream…");
    atomic_store(&_remuxCancelled, false);

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        wq_media_remux_cache_prune(512ULL * 1024ULL * 1024ULL);
        NSString *err = nil;
        BOOL ok = wq_media_remux_file(path, cached, AVFileTypeMPEG4, ^BOOL{
            WQProMediaPlayerViewController *me = weakSelf;
            return !me || atomic_load(&me->_remuxCancelled);
        }, ^(float frac) {
            dispatch_async(dispatch_get_main_queue(), ^{
                WQProMediaPlayerViewController *me = weakSelf;
                if (!me) return;
                me->_prepProgress.progress = frac;
                me->_prepLabel.text = WQLocalizedFormat(@"Preparing stream… %d%%", (int)lroundf(frac * 100.0f));
            });
        }, &err);
        dispatch_async(dispatch_get_main_queue(), ^{
            WQProMediaPlayerViewController *me = weakSelf;
            if (!me) return;
            me->_prepCard.hidden = YES;
            if (ok && [NSFileManager.defaultManager fileExistsAtPath:cached]) {
                [me loadPlayerItem:[AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:cached]]];
            } else {
                wq_alert(me, WQLocalized(@"Codec / Format Unsupported"),
                         err ?: WQLocalized(@"This container uses a legacy video codec without iOS hardware decode."));
            }
        });
    });
}

#pragma mark - Observers, Playlist & Up Next

- (void)buildSiblingPlaylist
{
    if (!_sourcePath.length || [_sourcePath hasPrefix:@"http"]) return;
    NSString *dir = _sourcePath.stringByDeletingLastPathComponent;
    NSArray<NSString *> *items = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil];
    if (!items.count) return;
    NSMutableArray<NSString *> *media = [NSMutableArray new];
    for (NSString *name in items) {
        if ([name hasPrefix:@"."]) continue;
        NSString *full = [dir stringByAppendingPathComponent:name];
        if (wq_is_convertible_media_path(full)) [media addObject:full];
    }
    [media sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [a.lastPathComponent compare:b.lastPathComponent options:NSNumericSearch | NSCaseInsensitiveSearch];
    }];
    _playlistPaths = media;
    _playlistIndex = (NSInteger)[media indexOfObject:_sourcePath];
}

- (void)attachPlayerObservers
{
    __weak typeof(self) weakSelf = self;
    _timeObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.25, 600)
                                                          queue:dispatch_get_main_queue()
                                                     usingBlock:^(CMTime time) {
        [weakSelf updateProgressForTime:CMTimeGetSeconds(time)];
    }];
    _endObserver = [NSNotificationCenter.defaultCenter addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                                                   object:nil
                                                                    queue:NSOperationQueue.mainQueue
                                                               usingBlock:^(NSNotification *note) {
        WQProMediaPlayerViewController *me = weakSelf;
        if (!me || note.object != me->_player.currentItem) return;
        wq_playback_save_progress(me->_sourcePath, 0.0, CMTimeGetSeconds(me->_player.currentItem.duration));
        if (me->_sleepAtEndOfVideo) {
            me->_sleepAtEndOfVideo = NO;
            [me updatePlayPauseIcon:NO];
            return;
        }
        if (me->_loopMode == WQPlayerLoopOne) {
            [me->_player seekToTime:kCMTimeZero];
            [me->_player play];
            me->_player.rate = me->_rate;
        } else if (me->_playlistPaths.count > 1 && me->_playlistIndex != NSNotFound &&
                   (me->_loopMode == WQPlayerLoopAll || me->_playlistIndex + 1 < (NSInteger)me->_playlistPaths.count)) {
            [me playNextEpisode];
        } else {
            [me updatePlayPauseIcon:NO];
        }
    }];
}

- (void)saveCurrentPlaybackProgress
{
    if (!_sourcePath.length || !_player.currentItem) return;
    double now = CMTimeGetSeconds(_player.currentTime);
    double dur = CMTimeGetSeconds(_player.currentItem.duration);
    if (isfinite(now) && isfinite(dur) && dur > 2.0) {
        wq_playback_save_progress(_sourcePath, now, dur);
    }
}

- (void)updateProgressForTime:(NSTimeInterval)now
{
    if (!isfinite(now) || now < 0) now = 0;
    NSTimeInterval dur = CMTimeGetSeconds(_player.currentItem.duration);
    if (!isfinite(dur) || dur < 0) dur = 0;

    // Enforce A-B Repeat Loop
    if (_abPointA >= 0 && _abPointB > _abPointA + 0.5 && now >= _abPointB) {
        [_player seekToTime:CMTimeMakeWithSeconds(_abPointA, 600)];
        return;
    }

    // Periodic Watch History save every 3s
    NSTimeInterval wall = CFAbsoluteTimeGetCurrent();
    if (dur > 5.0 && wall - _lastSavedClock > 3.0) {
        _lastSavedClock = wall;
        wq_playback_save_progress(_sourcePath, now, dur);
    }

    // Up Next Episode prompt when 12s remain
    if (_playlistPaths.count > 1 && _playlistIndex != NSNotFound && _playlistIndex + 1 < (NSInteger)_playlistPaths.count &&
        dur > 25.0 && (dur - now) <= 12.0 && (dur - now) > 1.0 && _loopMode != WQPlayerLoopOne) {
        NSString *nextName = _playlistPaths[(NSUInteger)(_playlistIndex + 1)].lastPathComponent;
        _upNextLabel.text = WQLocalizedFormat(@"Up Next: %@", nextName);
        _upNextBanner.hidden = NO;
    } else {
        _upNextBanner.hidden = YES;
    }

    if (!_scrubbing) {
        _elapsedLabel.text = wq_format_time(now);
        _durationLabel.text = wq_format_time(dur);
        _scrubber.value = dur > 0 ? (float)(now / dur) : 0.0f;
    }
    [self updatePlayPauseIcon:_player.rate > 0.01f];
    [self updateSubtitleForTime:now + _subOffset];
    [self updateNowPlaying];
}

- (void)playPreviousEpisode
{
    if (_playlistPaths.count <= 1 || _playlistIndex == NSNotFound) return;
    [self saveCurrentPlaybackProgress];
    _playlistIndex = (_playlistIndex - 1 + (NSInteger)_playlistPaths.count) % (NSInteger)_playlistPaths.count;
    NSString *next = _playlistPaths[(NSUInteger)_playlistIndex];
    _sourcePath = next;
    self.title = next.lastPathComponent;
    [self autoLoadSiblingSubtitles];
    [self replaceWithLocalURL:[NSURL fileURLWithPath:next]];
}

- (void)playNextEpisode
{
    if (_playlistPaths.count <= 1 || _playlistIndex == NSNotFound) return;
    [self saveCurrentPlaybackProgress];
    _playlistIndex = (_playlistIndex + 1) % (NSInteger)_playlistPaths.count;
    NSString *next = _playlistPaths[(NSUInteger)_playlistIndex];
    _sourcePath = next;
    self.title = next.lastPathComponent;
    [self autoLoadSiblingSubtitles];
    [self replaceWithLocalURL:[NSURL fileURLWithPath:next]];
}

- (void)updatePlayPauseIcon:(BOOL)playing
{
    UIButtonConfiguration *cfg = [_playPauseBtn.configuration copy];
    cfg.image = [UIImage systemImageNamed:playing ? @"pause.fill" : @"play.fill"
                        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightBold]];
    _playPauseBtn.configuration = cfg;
}

- (void)togglePlayPause
{
    if (_player.rate > 0.01f) {
        [_player pause];
        [self saveCurrentPlaybackProgress];
        [self updatePlayPauseIcon:NO];
    } else {
        [_player play];
        _player.rate = _rate;
        [self updatePlayPauseIcon:YES];
    }
    [self updateNowPlaying];
}

- (void)skipBy:(NSTimeInterval)delta showHUD:(BOOL)showHUD
{
    NSTimeInterval now = CMTimeGetSeconds(_player.currentTime);
    if (!isfinite(now)) now = 0;
    NSTimeInterval target = MAX(0.0, now + delta);
    [_player seekToTime:CMTimeMakeWithSeconds(target, 600)];
    if (showHUD) {
        NSString *txt = (delta >= 0)
            ? [NSString stringWithFormat:@"+%lds »", (long)llround(delta)]
            : [NSString stringWithFormat:@"« %lds", (long)llround(delta)];
        [self showTemporaryHUDText:txt];
    }
}

- (void)cycleSpeed
{
    static const float speeds[] = { 0.5f, 0.75f, 1.0f, 1.25f, 1.5f, 2.0f };
    NSInteger nextIdx = 0;
    for (NSInteger i = 0; i < 6; i++) {
        if (fabsf(_rate - speeds[i]) < 0.05f) {
            nextIdx = (i + 1) % 6;
            break;
        }
    }
    _rate = speeds[nextIdx];
    if (_player.rate > 0.01f) _player.rate = _rate;
    UIButtonConfiguration *cfg = [_speedBtn.configuration copy];
    cfg.title = [NSString stringWithFormat:@"%g×", _rate];
    _speedBtn.configuration = cfg;
    [self updateNowPlaying];
}

- (void)cycleAspectRatio
{
    _aspectMode = (WQPlayerAspectMode)((_aspectMode + 1) % 6);
    static NSString *const names[] = { @"Fit", @"Fill", @"Stretch", @"16:9", @"4:3", @"21:9" };
    UIButtonConfiguration *cfg = [_aspectBtn.configuration copy];
    cfg.title = WQLocalized(names[_aspectMode]);
    _aspectBtn.configuration = cfg;
    [self layoutPlayerLayerForAspectAndZoom];
    [self showTemporaryHUDText:[NSString stringWithFormat:@"📐 %@", WQLocalized(names[_aspectMode])]];
}

- (void)cycleLoopMode
{
    _loopMode = (WQPlayerLoopMode)((_loopMode + 1) % 3);
    UIButtonConfiguration *cfg = [_loopBtn.configuration copy];
    NSString *sym = (_loopMode == WQPlayerLoopOne) ? @"repeat.1" : @"repeat";
    cfg.image = [UIImage systemImageNamed:sym withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold]];
    cfg.baseForegroundColor = (_loopMode != WQPlayerLoopOff) ? wq_theme_accent() : wq_theme_primary_text();
    _loopBtn.configuration = cfg;
    NSString *msg = (_loopMode == WQPlayerLoopOne) ? WQLocalized(@"Loop One")
                  : (_loopMode == WQPlayerLoopAll) ? WQLocalized(@"Loop Playlist") : WQLocalized(@"Loop Off");
    [self showTemporaryHUDText:msg];
}

- (void)togglePiP
{
    if (!_pip) return;
    if (_pip.isPictureInPictureActive) [_pip stopPictureInPicture];
    else [_pip startPictureInPicture];
}

- (void)setScreenLocked:(BOOL)locked
{
    _screenLocked = locked;
    _controlsCard.hidden = locked;
    _unlockBtn.hidden = !locked;
}

- (void)scrubberDown { _scrubbing = YES; }
- (void)scrubberChanged
{
    NSTimeInterval dur = CMTimeGetSeconds(_player.currentItem.duration);
    if (isfinite(dur) && dur > 0) {
        _elapsedLabel.text = wq_format_time(dur * _scrubber.value);
    }
}
- (void)scrubberUp
{
    NSTimeInterval dur = CMTimeGetSeconds(_player.currentItem.duration);
    if (isfinite(dur) && dur > 0) {
        [_player seekToTime:CMTimeMakeWithSeconds(dur * _scrubber.value, 600)];
    }
    _scrubbing = NO;
}

#pragma mark - Audio Track Switcher, Delay & 200% Volume Boost

- (void)applyVolumeBoostMix
{
    AVPlayerItem *item = _player.currentItem;
    if (!item) return;
    if (fabsf(_volumeBoost - 1.0f) < 0.02f) {
        item.audioMix = nil;
        return;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSArray<AVAssetTrack *> *aTracks = [item.asset tracksWithMediaType:AVMediaTypeAudio];
#pragma clang diagnostic pop
    AVAssetTrack *track = aTracks.firstObject;
    if (!track) return;

    WQTapGainState *state = calloc(1, sizeof(WQTapGainState));
    if (!state) return;
    state->gain = _volumeBoost;

    MTAudioProcessingTapCallbacks cbs;
    memset(&cbs, 0, sizeof(cbs));
    cbs.version = kMTAudioProcessingTapCallbacksVersion_0;
    cbs.clientInfo = state;
    cbs.init = wq_audio_tap_init;
    cbs.finalize = wq_audio_tap_finalize;
    cbs.prepare = wq_audio_tap_prepare;
    cbs.unprepare = wq_audio_tap_unprepare;
    cbs.process = wq_audio_tap_process;

    MTAudioProcessingTapRef tap = NULL;
    if (MTAudioProcessingTapCreate(kCFAllocatorDefault, &cbs, kMTAudioProcessingTapCreationFlag_PreEffects, &tap) == noErr && tap) {
        AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
        AVMutableAudioMixInputParameters *params = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:track];
        params.audioTapProcessor = tap;
        mix.inputParameters = @[params];
        item.audioMix = mix;
        CFRelease(tap);
    } else {
        free(state);
    }
}

- (void)showAudioOptions
{
    UIAlertController *sheet = wq_alert_controller(WQLocalized(@"Audio & Boost"), nil, UIAlertControllerStyleActionSheet);

    // Embedded Audio Tracks
    AVPlayerItem *item = _player.currentItem;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    AVMediaSelectionGroup *audGrp = [item.asset mediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicAudible];
#pragma clang diagnostic pop
    if (audGrp.options.count > 0) {
        AVMediaSelectionOption *cur = [item.currentMediaSelection selectedMediaOptionInMediaSelectionGroup:audGrp];
        for (AVMediaSelectionOption *opt in audGrp.options) {
            NSString *prefix = (opt == cur) ? @"✓ " : @"";
            NSString *label = [NSString stringWithFormat:@"%@%@", prefix, opt.displayName ?: @"Track"];
            [sheet addAction:wq_alert_action(WQVerbatim(label), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
                [item selectMediaOption:opt inMediaSelectionGroup:audGrp];
            })];
        }
    }

    // Volume Boost 100% – 200%
    for (NSNumber *pct in @[@100, @125, @150, @200]) {
        float g = (float)pct.integerValue / 100.0f;
        NSString *mark = (fabsf(_volumeBoost - g) < 0.05f) ? @"✓ " : @"";
        [sheet addAction:wq_alert_action([NSString stringWithFormat:@"%@%@: %@%%", mark, WQLocalized(@"Volume Boost"), pct], UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            self->_volumeBoost = g;
            [self applyVolumeBoostMix];
            [self showTemporaryHUDText:[NSString stringWithFormat:@"🔊 %@ %@%%", WQLocalized(@"Boost"), pct]];
        })];
    }

    // Audio Sync Offset
    [sheet addAction:wq_alert_action([NSString stringWithFormat:@"%@: %+.1fs (+0.2s)", WQLocalized(@"Audio Sync"), _audioOffset], UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        self->_audioOffset = MIN(5.0, self->_audioOffset + 0.2);
        [self showTemporaryHUDText:[NSString stringWithFormat:@"%@ %+.1fs", WQLocalized(@"Audio Sync"), self->_audioOffset]];
    })];
    [sheet addAction:wq_alert_action([NSString stringWithFormat:@"%@: %+.1fs (-0.2s)", WQLocalized(@"Audio Sync"), _audioOffset], UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        self->_audioOffset = MAX(-5.0, self->_audioOffset - 0.2);
        [self showTemporaryHUDText:[NSString stringWithFormat:@"%@ %+.1fs", WQLocalized(@"Audio Sync"), self->_audioOffset]];
    })];

    [sheet addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    sheet.popoverPresentationController.sourceView = _audioBtn;
    sheet.popoverPresentationController.sourceRect = _audioBtn.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - Pro Subtitles (.srt, .vtt, .ass/.ssa) & Style Studio

- (void)applySubtitleAppearance
{
    CGFloat sz = [NSUserDefaults.standardUserDefaults floatForKey:kWQSubSizeKey];
    if (sz < 12.0 || sz > 28.0) sz = 16.0;
    _subtitleLabel.font = [UIFont systemFontOfSize:sz weight:UIFontWeightSemibold];
    NSInteger cIdx = [NSUserDefaults.standardUserDefaults integerForKey:kWQSubColorKey];
    _subtitleLabel.textColor = (cIdx == 1) ? UIColor.systemYellowColor : (cIdx == 2 ? UIColor.systemTealColor : UIColor.whiteColor);
    CGFloat bgAlpha = [NSUserDefaults.standardUserDefaults objectForKey:kWQSubOpacityKey]
        ? [NSUserDefaults.standardUserDefaults floatForKey:kWQSubOpacityKey] : 0.65;
    _subtitleBox.alpha = MAX(0.25, MIN(1.0, bgAlpha));
}

- (void)autoLoadSiblingSubtitles
{
    _subtitles = nil;
    if (!_sourcePath.length || [_sourcePath hasPrefix:@"http"]) return;
    NSString *base = _sourcePath.stringByDeletingPathExtension;
    for (NSString *ext in @[@"srt", @"vtt", @"ass", @"ssa"]) {
        NSString *candidate = [base stringByAppendingPathExtension:ext];
        NSData *data = wq_read(candidate, 8 * 1024 * 1024, nil);
        if (data.length) {
            NSString *txt = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (txt.length) {
                _subtitles = wq_parse_subtitles(txt);
                UIButtonConfiguration *cfg = [_subBtn.configuration copy];
                cfg.baseForegroundColor = wq_theme_accent();
                _subBtn.configuration = cfg;
                break;
            }
        }
    }
}

- (void)showSubtitleOptions
{
    UIAlertController *sheet = wq_alert_controller(WQLocalized(@"Subtitles & Styling"), nil, UIAlertControllerStyleActionSheet);

    [sheet addAction:wq_alert_action(WQLocalized(@"Load Subtitle File (.srt / .vtt / .ass)…"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [self pickSubtitles];
    })];

    AVPlayerItem *item = _player.currentItem;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    AVMediaSelectionGroup *legGrp = [item.asset mediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicLegible];
#pragma clang diagnostic pop
    if (legGrp.options.count > 0) {
        AVMediaSelectionOption *cur = [item.currentMediaSelection selectedMediaOptionInMediaSelectionGroup:legGrp];
        for (AVMediaSelectionOption *opt in legGrp.options) {
            NSString *prefix = (opt == cur) ? @"✓ " : @"";
            [sheet addAction:wq_alert_action(WQVerbatim([prefix stringByAppendingString:opt.displayName ?: @"Track"]), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
                [item selectMediaOption:opt inMediaSelectionGroup:legGrp];
            })];
        }
    }

    [sheet addAction:wq_alert_action([NSString stringWithFormat:@"%@ (+0.5s): %+.1fs", WQLocalized(@"Subtitle Delay"), _subOffset], UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        self->_subOffset = MIN(10.0, self->_subOffset + 0.5);
        [self showTemporaryHUDText:[NSString stringWithFormat:@"💬 %+.1fs", self->_subOffset]];
    })];
    [sheet addAction:wq_alert_action([NSString stringWithFormat:@"%@ (-0.5s): %+.1fs", WQLocalized(@"Subtitle Delay"), _subOffset], UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        self->_subOffset = MAX(-10.0, self->_subOffset - 0.5);
        [self showTemporaryHUDText:[NSString stringWithFormat:@"💬 %+.1fs", self->_subOffset]];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Cycle Font Size (S / M / L / XL)"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        CGFloat cur = [NSUserDefaults.standardUserDefaults floatForKey:kWQSubSizeKey];
        CGFloat next = (cur < 14) ? 16 : (cur < 18) ? 20 : (cur < 22) ? 24 : 13;
        [NSUserDefaults.standardUserDefaults setFloat:next forKey:kWQSubSizeKey];
        [self applySubtitleAppearance];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Cycle Text Color (White / Yellow / Cyan)"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        NSInteger next = ([NSUserDefaults.standardUserDefaults integerForKey:kWQSubColorKey] + 1) % 3;
        [NSUserDefaults.standardUserDefaults setInteger:next forKey:kWQSubColorKey];
        [self applySubtitleAppearance];
    })];
    if (_subtitles.count) {
        [sheet addAction:wq_alert_action(WQLocalized(@"Disable Sidecar Subtitles"), UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
            self->_subtitles = nil;
            self->_subtitleBox.hidden = YES;
        })];
    }
    [sheet addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    sheet.popoverPresentationController.sourceView = _subBtn;
    sheet.popoverPresentationController.sourceRect = _subBtn.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)pickSubtitles
{
    NSMutableArray<UTType *> *types = [NSMutableArray new];
    for (NSString *ext in @[@"srt", @"vtt", @"ass", @"ssa"]) {
        UTType *t = [UTType typeWithFilenameExtension:ext];
        if (t) [types addObject:t];
    }
    if (!types.count) [types addObject:UTTypePlainText];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *__unused)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    NSURL *url = urls.firstObject;
    if (!url) return;
    NSString *txt = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
    if (txt.length) {
        _subtitles = wq_parse_subtitles(txt);
        UIButtonConfiguration *cfg = [_subBtn.configuration copy];
        cfg.baseForegroundColor = wq_theme_accent();
        _subBtn.configuration = cfg;
    }
}

- (void)updateSubtitleForTime:(NSTimeInterval)now
{
    if (!_subtitles.count) {
        _subtitleBox.hidden = YES;
        return;
    }
    NSString *active = nil;
    for (WQSubtitleCue *cue in _subtitles) {
        if (now >= cue.start && now <= cue.end) {
            active = cue.text;
            break;
        }
    }
    _subtitleBox.hidden = (active.length == 0);
    _subtitleLabel.text = active;
}

#pragma mark - Cinema Extras (Sleep Timer, A-B Repeat, Screenshot, Skip Interval, Media Stats HUD)

- (void)showCinemaExtrasMenu
{
    UIAlertController *sheet = wq_alert_controller(WQLocalized(@"Cinema Studio Tools"), nil, UIAlertControllerStyleActionSheet);

    [sheet addAction:wq_alert_action(WQLocalized(@"Capture Frame Screenshot"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [self captureFrameScreenshot];
    })];

    NSString *abLabel = (_abPointA < 0)
        ? WQLocalized(@"A–B Loop: Set Point A")
        : (_abPointB < 0 ? WQLocalized(@"A–B Loop: Set Point B") : WQLocalized(@"A–B Loop: Clear"));
    [sheet addAction:wq_alert_action(abLabel, UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        NSTimeInterval now = CMTimeGetSeconds(self->_player.currentTime);
        if (self->_abPointA < 0) {
            self->_abPointA = MAX(0.0, now);
            [self showTemporaryHUDText:[NSString stringWithFormat:@"🅰 %@", wq_format_time(self->_abPointA)]];
        } else if (self->_abPointB < 0) {
            if (now > self->_abPointA + 0.5) {
                self->_abPointB = now;
                [self showTemporaryHUDText:[NSString stringWithFormat:@"🔁 %@ – %@", wq_format_time(self->_abPointA), wq_format_time(self->_abPointB)]];
            }
        } else {
            self->_abPointA = -1.0;
            self->_abPointB = -1.0;
            [self showTemporaryHUDText:WQLocalized(@"A–B Loop Cleared")];
        }
    })];

    [sheet addAction:wq_alert_action(WQLocalized(@"Sleep Timer…"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [self showSleepTimerMenu];
    })];

    [sheet addAction:wq_alert_action(WQLocalizedFormat(@"Skip Interval: %lds (Tap to Cycle)", (long)_skipSeconds), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        self->_skipSeconds = (self->_skipSeconds == 5) ? 10 : (self->_skipSeconds == 10) ? 15 : (self->_skipSeconds == 15) ? 30 : 5;
        [NSUserDefaults.standardUserDefaults setInteger:self->_skipSeconds forKey:kWQSkipIntervalKey];
        [self showTemporaryHUDText:[NSString stringWithFormat:@"⏩ ±%lds", (long)self->_skipSeconds]];
    })];

    [sheet addAction:wq_alert_action(WQLocalized(@"Media Info & Codec Stats"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [self showMediaStatsHUD];
    })];

    [sheet addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    sheet.popoverPresentationController.sourceView = _moreBtn;
    sheet.popoverPresentationController.sourceRect = _moreBtn.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showSleepTimerMenu
{
    UIAlertController *sheet = wq_alert_controller(WQLocalized(@"Sleep Timer"), nil, UIAlertControllerStyleActionSheet);
    for (NSNumber *mins in @[@15, @30, @45, @60]) {
        [sheet addAction:wq_alert_action(WQLocalizedFormat(@"%@ min", mins), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            [self->_sleepTimer invalidate];
            self->_sleepAtEndOfVideo = NO;
            self->_sleepRemaining = mins.doubleValue * 60.0;
            __weak typeof(self) weakSelf = self;
            self->_sleepTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
                WQProMediaPlayerViewController *me = weakSelf;
                if (!me) { [t invalidate]; return; }
                me->_sleepRemaining -= 1.0;
                if (me->_sleepRemaining <= 0) {
                    [t invalidate];
                    [me->_player pause];
                    [me updatePlayPauseIcon:NO];
                }
            }];
            [self showTemporaryHUDText:[NSString stringWithFormat:@"🌙 %@ min", mins]];
        })];
    }
    [sheet addAction:wq_alert_action(WQLocalized(@"End of Video"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [self->_sleepTimer invalidate];
        self->_sleepTimer = nil;
        self->_sleepAtEndOfVideo = YES;
        [self showTemporaryHUDText:WQLocalized(@"🌙 Sleep at End")];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Turn Off Sleep Timer"), UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
        [self->_sleepTimer invalidate];
        self->_sleepTimer = nil;
        self->_sleepAtEndOfVideo = NO;
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    sheet.popoverPresentationController.sourceView = _moreBtn;
    sheet.popoverPresentationController.sourceRect = _moreBtn.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)captureFrameScreenshot
{
    AVAsset *asset = _player.currentItem.asset;
    if (!asset) return;
    CMTime t = _player.currentTime;
    AVAssetImageGenerator *gen = [[AVAssetImageGenerator alloc] initWithAsset:asset];
    gen.appliesPreferredTrackTransform = YES;
    gen.requestedTimeToleranceBefore = kCMTimeZero;
    gen.requestedTimeToleranceAfter = kCMTimeZero;
    [gen generateCGImagesAsynchronouslyForTimes:@[[NSValue valueWithCMTime:t]]
                              completionHandler:^(CMTime __unused req, CGImageRef img, CMTime __unused act, AVAssetImageGeneratorResult res, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (res == AVAssetImageGeneratorSucceeded && img) {
                UIImage *shot = [UIImage imageWithCGImage:img];
                UIImageWriteToSavedPhotosAlbum(shot, nil, NULL, NULL);
                wq_haptic_notify(UINotificationFeedbackTypeSuccess);
                [self showTemporaryHUDText:WQLocalized(@"📸 Saved to Photos")];
            } else {
                wq_alert(self, WQLocalized(@"Screenshot Failed"), err.localizedDescription ?: WQLocalized(@"Could not capture video frame."));
            }
        });
    }];
}

- (void)showMediaStatsHUD
{
    WQMediaProbeInfo *info = (_sourcePath.length && ![_sourcePath hasPrefix:@"http"]) ? wq_media_probe_file(_sourcePath) : nil;
    NSMutableArray<NSString *> *lines = [NSMutableArray new];
    if (info) {
        [lines addObject:[NSString stringWithFormat:@"%@: %@", WQLocalized(@"Container"), info.containerFormat]];
        if (info.videoCodec.length) [lines addObject:[NSString stringWithFormat:@"%@: %@", WQLocalized(@"Video"), info.videoCodec]];
        if (info.width > 0 && info.height > 0) [lines addObject:[NSString stringWithFormat:@"%@: %ld×%ld", WQLocalized(@"Resolution"), (long)info.width, (long)info.height]];
        if (info.fps > 0) [lines addObject:[NSString stringWithFormat:@"FPS: %.2f", info.fps]];
        if (info.audioCodec.length) [lines addObject:[NSString stringWithFormat:@"%@: %@", WQLocalized(@"Audio"), info.audioCodec]];
        if (info.bitrateBps > 0) [lines addObject:[NSString stringWithFormat:@"Bitrate: %.2f Mbps", (double)info.bitrateBps / 1000000.0]];
        [lines addObject:[NSString stringWithFormat:@"%@: %@", WQLocalized(@"Size"), wq_size_text(info.fileSizeBytes)]];
    } else {
        NSTimeInterval dur = CMTimeGetSeconds(_player.currentItem.duration);
        [lines addObject:[NSString stringWithFormat:@"Source: %@", _sourcePath ?: @"Stream"]];
        if (isfinite(dur) && dur > 0) [lines addObject:[NSString stringWithFormat:@"%@: %@", WQLocalized(@"Duration"), wq_format_time(dur)]];
    }
    wq_alert(self, WQLocalized(@"Media Info & Codec Stats"), [lines componentsJoinedByString:@"\n"]);
}

#pragma mark - Lock Screen Controls

- (void)setupRemoteCommands
{
    MPRemoteCommandCenter *rcc = MPRemoteCommandCenter.sharedCommandCenter;
    __weak typeof(self) weakSelf = self;
    [rcc.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *__unused event) {
        typeof(self) me = weakSelf;
        if (!me) return MPRemoteCommandHandlerStatusCommandFailed;
        [me.player play];
        me.player.rate = me->_rate;
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [rcc.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *__unused event) {
        [weakSelf.player pause];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    rcc.skipForwardCommand.preferredIntervals = @[@(_skipSeconds)];
    [rcc.skipForwardCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *__unused event) {
        typeof(self) me = weakSelf;
        if (me) [me skipBy:(NSTimeInterval)me->_skipSeconds showHUD:NO];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    rcc.skipBackwardCommand.preferredIntervals = @[@(_skipSeconds)];
    [rcc.skipBackwardCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *__unused event) {
        typeof(self) me = weakSelf;
        if (me) [me skipBy:-(NSTimeInterval)me->_skipSeconds showHUD:NO];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [rcc.nextTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *__unused event) {
        [weakSelf playNextEpisode];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [rcc.previousTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *__unused event) {
        [weakSelf playPreviousEpisode];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [rcc.changePlaybackPositionCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        MPChangePlaybackPositionCommandEvent *pos = (MPChangePlaybackPositionCommandEvent *)event;
        [weakSelf.player seekToTime:CMTimeMakeWithSeconds(pos.positionTime, 600)];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
}

- (void)updateNowPlaying
{
    NSMutableDictionary *info = [NSMutableDictionary new];
    info[MPMediaItemPropertyTitle] = self.title ?: @"WQ Glass";
    NSTimeInterval dur = CMTimeGetSeconds(_player.currentItem.duration);
    NSTimeInterval now = CMTimeGetSeconds(_player.currentTime);
    if (isfinite(dur) && dur > 0) info[MPMediaItemPropertyPlaybackDuration] = @(dur);
    if (isfinite(now) && now >= 0) info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(now);
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(_player.rate);
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = info;
}

@end

#pragma mark - Swipeable Gallery & Image Studio

BOOL wq_is_gallery_image_path(NSString *path)
{
    NSString *ext = path.pathExtension.lowercaseString;
    return [@[@"jpg", @"jpeg", @"png", @"gif", @"webp", @"heic", @"heif", @"bmp", @"tif", @"tiff"] containsObject:ext];
}

@interface WQGalleryPageViewController : UIViewController <UIScrollViewDelegate>
@property (nonatomic, copy, readonly) NSString *path;
@property (nonatomic, readonly) NSUInteger pageIndex;
@property (nonatomic, strong, readonly) UIImage *loadedImage;
@property (nonatomic, strong, readonly) NSData *loadedData;
@end

@implementation WQGalleryPageViewController {
    UIScrollView *_scroll;
    UIImageView *_imageView;
    UILabel *_errorLabel;
}

- (instancetype)initWithPath:(NSString *)path index:(NSUInteger)index
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _path = [path copy];
        _pageIndex = index;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    _scroll = [UIScrollView new];
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.delegate = self;
    _scroll.minimumZoomScale = 1.0;
    _scroll.maximumZoomScale = 5.0;
    _scroll.showsVerticalScrollIndicator = NO;
    _scroll.showsHorizontalScrollIndicator = NO;
    [self.view addSubview:_scroll];

    _imageView = [UIImageView new];
    _imageView.translatesAutoresizingMaskIntoConstraints = NO;
    _imageView.contentMode = UIViewContentModeScaleAspectFit;
    [_scroll addSubview:_imageView];

    _errorLabel = [UILabel new];
    _errorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _errorLabel.textColor = wq_theme_secondary_text();
    _errorLabel.textAlignment = NSTextAlignmentCenter;
    _errorLabel.numberOfLines = 0;
    _errorLabel.hidden = YES;
    [self.view addSubview:_errorLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_imageView.widthAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.widthAnchor],
        [_imageView.heightAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.heightAnchor],
        [_imageView.centerXAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.centerXAnchor],
        [_imageView.centerYAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.centerYAnchor],
        [_errorLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_errorLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [_errorLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:24],
    ]];

    UITapGestureRecognizer *dbl = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleZoom)];
    dbl.numberOfTapsRequired = 2;
    [_scroll addGestureRecognizer:dbl];

    NSString *p = _path;
    __weak typeof(self) weakSelf = self;
    dispatch_async(wq_io(), ^{
        NSString *err = nil;
        NSData *data = wq_read(p, 48 * 1024 * 1024, &err);
        UIImage *img = nil;
        if (data.length) {
            CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
            if (src) {
                size_t cnt = CGImageSourceGetCount(src);
                if (cnt > 1) {
                    NSMutableArray<UIImage *> *frames = [NSMutableArray arrayWithCapacity:MIN(cnt, (size_t)90)];
                    NSTimeInterval duration = 0;
                    for (size_t i = 0; i < cnt && i < 90; i++) {
                        CGImageRef cg = CGImageSourceCreateImageAtIndex(src, i, NULL);
                        if (cg) {
                            [frames addObject:[UIImage imageWithCGImage:cg]];
                            CGImageRelease(cg);
                        }
                        duration += 0.08;
                    }
                    if (frames.count) img = [UIImage animatedImageWithImages:frames duration:MAX(0.4, duration)];
                }
                CFRelease(src);
            }
            if (!img) img = [UIImage imageWithData:data];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            WQGalleryPageViewController *me = weakSelf;
            if (!me) return;
            me->_loadedData = data;
            me->_loadedImage = img;
            if (img) {
                me->_imageView.image = img;
            } else {
                me->_errorLabel.text = err ?: WQLocalized(@"Cannot display image");
                me->_errorLabel.hidden = NO;
            }
        });
    });
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *__unused)scrollView
{
    return _imageView;
}

- (void)toggleZoom
{
    [_scroll setZoomScale:(_scroll.zoomScale > 1.2 ? 1.0 : 2.5) animated:YES];
}

@end

@interface WQGalleryViewController () <UIPageViewControllerDataSource, UIPageViewControllerDelegate>
@end

@implementation WQGalleryViewController {
    NSArray<NSString *> *_paths;
    NSUInteger _currentIndex;
    UIPageViewController *_pager;
    UIVisualEffectView *_bottomBar;
}

- (instancetype)initWithImagePaths:(NSArray<NSString *> *)paths initialIndex:(NSUInteger)index
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _paths = [paths copy];
        _currentIndex = index < paths.count ? index : 0;
        self.title = _paths.count ? _paths[_currentIndex].lastPathComponent : WQLocalized(@"Gallery");
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    wq_prism_install_background(self);

    _pager = [[UIPageViewController alloc] initWithTransitionStyle:UIPageViewControllerTransitionStyleScroll
                                             navigationOrientation:UIPageViewControllerNavigationOrientationHorizontal
                                                           options:@{UIPageViewControllerOptionInterPageSpacingKey: @16}];
    _pager.dataSource = self;
    _pager.delegate = self;
    [self addChildViewController:_pager];
    _pager.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_pager.view];
    [_pager didMoveToParentViewController:self];

    WQGalleryPageViewController *first = [[WQGalleryPageViewController alloc] initWithPath:_paths[_currentIndex] index:_currentIndex];
    [_pager setViewControllers:@[first] direction:UIPageViewControllerNavigationDirectionForward animated:NO completion:nil];

    _bottomBar = wq_theme_make_glass_card(20, YES);
    [self.view addSubview:_bottomBar];

    __weak typeof(self) weakSelf = self;
    UIButton *exifBtn = [self barBtn:@"info.circle" label:WQLocalized(@"EXIF") action:^{ [weakSelf showExif]; }];
    UIButton *saveBtn = [self barBtn:@"square.and.arrow.down" label:WQLocalized(@"Save") action:^{ [weakSelf saveToPhotos]; }];
    UIButton *convBtn = [self barBtn:@"arrow.triangle.2.circlepath" label:WQLocalized(@"Convert") action:^{ [weakSelf convertImage]; }];
    UIButton *shareBtn = [self barBtn:@"square.and.arrow.up" label:WQLocalized(@"Share") action:^{ [weakSelf shareCurrent]; }];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[exifBtn, saveBtn, convBtn, shareBtn]];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    [_bottomBar.contentView addSubview:row];

    [NSLayoutConstraint activateConstraints:@[
        [_pager.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_pager.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_pager.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_pager.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [_bottomBar.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:16],
        [_bottomBar.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
        [_bottomBar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
        [row.topAnchor constraintEqualToAnchor:_bottomBar.contentView.topAnchor constant:8],
        [row.bottomAnchor constraintEqualToAnchor:_bottomBar.contentView.bottomAnchor constant:-8],
        [row.leadingAnchor constraintEqualToAnchor:_bottomBar.contentView.leadingAnchor constant:8],
        [row.trailingAnchor constraintEqualToAnchor:_bottomBar.contentView.trailingAnchor constant:-8],
    ]];
}

- (UIButton *)barBtn:(NSString *)symbol label:(NSString *)title action:(void (^)(void))handler
{
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
    cfg.image = [UIImage systemImageNamed:symbol
                        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold]];
    cfg.title = title;
    cfg.imagePlacement = NSDirectionalRectEdgeTop;
    cfg.imagePadding = 3;
    cfg.baseForegroundColor = wq_theme_primary_text();
    cfg.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *in) {
        NSMutableDictionary *out = [in mutableCopy] ?: [NSMutableDictionary new];
        out[NSFontAttributeName] = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        return out;
    };
    btn.configuration = cfg;
    [btn addAction:[UIAction actionWithHandler:^(UIAction *__unused a) {
        wq_haptic_selection();
        handler();
    }] forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

- (UIViewController *)pageViewController:(UIPageViewController *__unused)pvc viewControllerBeforeViewController:(UIViewController *)vc
{
    NSUInteger idx = ((WQGalleryPageViewController *)vc).pageIndex;
    if (idx == 0) return nil;
    return [[WQGalleryPageViewController alloc] initWithPath:_paths[idx - 1] index:idx - 1];
}

- (UIViewController *)pageViewController:(UIPageViewController *__unused)pvc viewControllerAfterViewController:(UIViewController *)vc
{
    NSUInteger idx = ((WQGalleryPageViewController *)vc).pageIndex;
    if (idx + 1 >= _paths.count) return nil;
    return [[WQGalleryPageViewController alloc] initWithPath:_paths[idx + 1] index:idx + 1];
}

- (void)pageViewController:(UIPageViewController *__unused)pvc didFinishAnimating:(BOOL)finished
    previousViewControllers:(NSArray<UIViewController *> *__unused)prev transitionCompleted:(BOOL)completed
{
    if (!finished || !completed) return;
    WQGalleryPageViewController *cur = (WQGalleryPageViewController *)_pager.viewControllers.firstObject;
    _currentIndex = cur.pageIndex;
    self.title = _paths[_currentIndex].lastPathComponent;
}

- (WQGalleryPageViewController *)currentPage
{
    return (WQGalleryPageViewController *)_pager.viewControllers.firstObject;
}

- (void)showExif
{
    NSData *data = [self currentPage].loadedData;
    if (!data.length) return;
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    NSDictionary *props = src ? (__bridge_transfer NSDictionary *)CGImageSourceCopyPropertiesAtIndex(src, 0, NULL) : nil;
    if (src) CFRelease(src);
    NSMutableString *msg = [NSMutableString new];
    [msg appendFormat:@"%@ × %@ px\n", props[(NSString *)kCGImagePropertyPixelWidth] ?: @"?", props[(NSString *)kCGImagePropertyPixelHeight] ?: @"?"];
    if (props[(NSString *)kCGImagePropertyColorModel]) [msg appendFormat:@"Color: %@\n", props[(NSString *)kCGImagePropertyColorModel]];
    if (props[(NSString *)kCGImagePropertyProfileName]) [msg appendFormat:@"Profile: %@\n", props[(NSString *)kCGImagePropertyProfileName]];
    NSDictionary *exif = props[(NSString *)kCGImagePropertyExifDictionary];
    if (exif) [msg appendFormat:@"\nEXIF:\n%@", exif];
    wq_alert(self, _paths[_currentIndex].lastPathComponent, msg);
}

- (void)saveToPhotos
{
    UIImage *img = [self currentPage].loadedImage;
    if (!img) return;
    UIImageWriteToSavedPhotosAlbum(img, self, @selector(savedImage:error:ctx:), NULL);
}

- (void)savedImage:(UIImage *__unused)img error:(NSError *)error ctx:(void *__unused)ctx
{
    wq_alert(self, error ? WQLocalized(@"Save Failed") : WQLocalized(@"Saved to Photos"), error.localizedDescription);
}

- (void)convertImage
{
    UIImage *img = [self currentPage].loadedImage;
    NSString *srcPath = _paths[_currentIndex];
    if (!img) return;
    UIAlertController *sheet = wq_alert_controller(WQLocalized(@"Convert Image"), srcPath.lastPathComponent, UIAlertControllerStyleActionSheet);
    [sheet addAction:wq_alert_action(@"Convert to JPEG", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        NSData *out = UIImageJPEGRepresentation(img, 0.92);
        [self writeConvertedData:out ext:@"jpg" from:srcPath];
    })];
    [sheet addAction:wq_alert_action(@"Convert to PNG", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        NSData *out = UIImagePNGRepresentation(img);
        [self writeConvertedData:out ext:@"png" from:srcPath];
    })];
    [sheet addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    sheet.popoverPresentationController.sourceView = _bottomBar;
    sheet.popoverPresentationController.sourceRect = _bottomBar.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)writeConvertedData:(NSData *)data ext:(NSString *)ext from:(NSString *)srcPath
{
    if (!data.length) return;
    NSString *base = srcPath.stringByDeletingPathExtension;
    NSString *dest = [base stringByAppendingPathExtension:ext];
    NSString *err = nil;
    if (!wq_create_file(dest, data, &err)) {
        NSString *dl = NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES).firstObject;
        if (dl.length) {
            [NSFileManager.defaultManager createDirectoryAtPath:dl withIntermediateDirectories:YES attributes:nil error:nil];
            dest = [dl stringByAppendingPathComponent:[srcPath.lastPathComponent.stringByDeletingPathExtension stringByAppendingPathExtension:ext]];
            [data writeToFile:dest atomically:YES];
            wq_alert(self, WQLocalized(@"Converted"), dest.lastPathComponent);
            return;
        }
        wq_alert(self, WQLocalized(@"Convert Failed"), err);
        return;
    }
    wq_alert(self, WQLocalized(@"Converted"), dest.lastPathComponent);
}

- (void)shareCurrent
{
    UIImage *img = [self currentPage].loadedImage;
    if (!img) return;
    UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[img] applicationActivities:nil];
    avc.popoverPresentationController.sourceView = _bottomBar;
    avc.popoverPresentationController.sourceRect = _bottomBar.bounds;
    [self presentViewController:avc animated:YES completion:nil];
}

@end
