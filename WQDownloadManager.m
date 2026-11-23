//
//  WQDownloadManager.m
//  WQ Glass IDM / 1DM Style Multi-Part Accelerated Download Engine & HLS Quality Picker
//  GPL-3.0-or-later.
//

#import "WQDownloadManager.h"
#import "WQArchive.h"
#import "WQCryptoTools.h"
#import "WQDir.h"
#import "WQDownloadBrowser.h"
#import "WQFloatingHUD.h"
#import "WQLocalization.h"
#import "WQMediaConverter.h"
#import "WQMotion.h"
#import "WQTheme.h"
#import "WQUI.h"
#import "WQWorkspace.h"
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonDigest.h>
#import <errno.h>
#import <fcntl.h>
#import <ifaddrs.h>
#import <math.h>
#import <net/if.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

NSNotificationName const WQDownloadManagerDidUpdateNotification = @"WQDownloadManagerDidUpdateNotification";

static NSString *const kWQDLPartsPref = @"WQDLDefaultParts";
static NSString *const kWQDLMaxConcPref = @"WQDLMaxConcurrent";
static NSString *const kWQDLSpeedLimitPref = @"WQDLSpeedLimitKBps";
static NSString *const kWQDLWifiOnlyPref = @"WQDLWifiOnly";
static const int64_t kWQDLMinMultiPartBytes = 2 * 1024 * 1024; // 2 MB

#pragma mark - Models

@implementation WQDownloadPart
- (double)progress
{
    int64_t span = (_endOffset >= _startOffset) ? (_endOffset - _startOffset + 1) : 0;
    if (span <= 0) return _finished ? 1.0 : 0.0;
    double p = (double)_downloadedBytes / (double)span;
    return MAX(0.0, MIN(1.0, p));
}
@end

@implementation WQDownloadItem
- (double)progress
{
    if (_state == WQDownloadStateCompleted) return 1.0;
    if (_isHLS && _hlsTotalSegments > 0) {
        return MAX(0.0, MIN(1.0, (double)_hlsDoneSegments / (double)_hlsTotalSegments));
    }
    if (_totalBytes > 0) {
        return MAX(0.0, MIN(1.0, (double)_downloadedBytes / (double)_totalBytes));
    }
    return 0.0;
}
@end

@implementation WQHLSVariant
@end

#pragma mark - Helpers

NSString *wq_downloads_root_dir(void)
{
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    NSString *dir = [docs stringByAppendingPathComponent:@"Downloads"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *wq_downloads_state_path(void)
{
    NSString *appSup = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    [NSFileManager.defaultManager createDirectoryAtPath:appSup withIntermediateDirectories:YES attributes:nil error:nil];
    return [appSup stringByAppendingPathComponent:@"WQDownloads.json"];
}

static NSString *wq_downloads_partial_dir(void)
{
    NSString *dir = [wq_downloads_root_dir() stringByAppendingPathComponent:@".partial"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

NSString *wq_download_category_for_filename(NSString *filename)
{
    NSString *ext = filename.pathExtension.lowercaseString;
    if (!ext.length) return @"Other";
    static NSDictionary<NSString *, NSString *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *m = [NSMutableDictionary new];
        for (NSString *x in @[@"mp4", @"m4v", @"mov", @"mkv", @"webm", @"avi", @"ts", @"m3u8", @"3gp"]) m[x] = @"Videos";
        for (NSString *x in @[@"mp3", @"m4a", @"aac", @"wav", @"flac", @"ogg", @"opus", @"caf"]) m[x] = @"Audio";
        for (NSString *x in @[@"pdf", @"doc", @"docx", @"xls", @"xlsx", @"ppt", @"pptx", @"txt", @"md", @"epub", @"csv", @"rtf", @"json", @"xml", @"plist"]) m[x] = @"Documents";
        for (NSString *x in @[@"zip", @"rar", @"7z", @"tar", @"gz", @"bz2", @"xz", @"wqenc"]) m[x] = @"Archives";
        for (NSString *x in @[@"ipa", @"deb", @"dmg", @"pkg", @"apk"]) m[x] = @"Apps";
        for (NSString *x in @[@"jpg", @"jpeg", @"png", @"heic", @"heif", @"gif", @"webp", @"svg", @"bmp", @"tiff"]) m[x] = @"Images";
        map = m;
    });
    return map[ext] ?: @"Other";
}

static NSString *wq_sanitize_filename(NSString *raw, NSString *fallbackURL)
{
    NSString *name = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length && fallbackURL.length) {
        NSURL *u = [NSURL URLWithString:fallbackURL];
        name = u.lastPathComponent;
        if (!name.length || [name isEqualToString:@"/"]) name = u.host ?: @"download";
    }
    if (!name.length) name = @"download.bin";
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\:?*\"<>|\n\r\t"];
    name = [[name componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"];
    if (name.length > 140) {
        NSString *ext = name.pathExtension;
        NSString *base = [name.stringByDeletingPathExtension substringToIndex:MIN((NSUInteger)120, name.stringByDeletingPathExtension.length)];
        name = ext.length ? [base stringByAppendingPathExtension:ext] : base;
    }
    return name.length ? name : @"download.bin";
}

static NSString *wq_unique_file_path(NSString *dir, NSString *filename)
{
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *candidate = [dir stringByAppendingPathComponent:filename];
    if (![NSFileManager.defaultManager fileExistsAtPath:candidate]) return candidate;
    NSString *ext = filename.pathExtension;
    NSString *stem = ext.length ? filename.stringByDeletingPathExtension : filename;
    for (NSUInteger i = 1; i < 10000; i++) {
        NSString *alt = ext.length
            ? [NSString stringWithFormat:@"%@ (%lu).%@", stem, (unsigned long)i, ext]
            : [NSString stringWithFormat:@"%@ (%lu)", stem, (unsigned long)i];
        NSString *p = [dir stringByAppendingPathComponent:alt];
        if (![NSFileManager.defaultManager fileExistsAtPath:p]) return p;
    }
    return [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_%@", NSUUID.UUID.UUIDString.lowercaseString, filename]];
}

static BOOL wq_wifi_interface_active(void)
{
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0 || !list) return YES;
    BOOL hasWifi = NO;
    for (struct ifaddrs *cur = list; cur; cur = cur->ifa_next) {
        if (!cur->ifa_addr || !cur->ifa_name) continue;
        int fam = cur->ifa_addr->sa_family;
        if (fam != AF_INET && fam != AF_INET6) continue;
        if (!(cur->ifa_flags & IFF_UP) || (cur->ifa_flags & IFF_LOOPBACK)) continue;
        if (strncmp(cur->ifa_name, "en", 2) == 0) {
            hasWifi = YES;
            break;
        }
    }
    freeifaddrs(list);
    return hasWifi;
}

static NSString *wq_filename_from_content_disposition(NSString *cd)
{
    if (!cd.length) return nil;
    NSRange rStar = [cd rangeOfString:@"filename*=" options:NSCaseInsensitiveSearch];
    if (rStar.location != NSNotFound) {
        NSString *tail = [cd substringFromIndex:NSMaxRange(rStar)];
        NSRange semi = [tail rangeOfString:@";"];
        if (semi.location != NSNotFound) tail = [tail substringToIndex:semi.location];
        NSRange q = [tail rangeOfString:@"''"];
        if (q.location != NSNotFound) tail = [tail substringFromIndex:NSMaxRange(q)];
        tail = [tail stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\"' "]];
        NSString *dec = [tail stringByRemovingPercentEncoding] ?: tail;
        if (dec.length) return dec;
    }
    NSRange r = [cd rangeOfString:@"filename=" options:NSCaseInsensitiveSearch];
    if (r.location != NSNotFound) {
        NSString *tail = [cd substringFromIndex:NSMaxRange(r)];
        NSRange semi = [tail rangeOfString:@";"];
        if (semi.location != NSNotFound) tail = [tail substringToIndex:semi.location];
        tail = [tail stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\"' "]];
        if (tail.length) return tail;
    }
    return nil;
}

static NSString *wq_format_eta(double seconds)
{
    if (!isfinite(seconds) || seconds < 0 || seconds > 86400 * 7) return @"--";
    long s = (long)ceil(seconds);
    if (s >= 3600) return [NSString stringWithFormat:@"%ldh %ldm", s / 3600, (s % 3600) / 60];
    if (s >= 60) return [NSString stringWithFormat:@"%ldm %lds", s / 60, s % 60];
    return [NSString stringWithFormat:@"%lds", s];
}

static NSString *wq_symbol_for_category(NSString *cat)
{
    if ([cat isEqualToString:@"Videos"]) return @"film.fill";
    if ([cat isEqualToString:@"Audio"]) return @"music.note";
    if ([cat isEqualToString:@"Documents"]) return @"doc.text.fill";
    if ([cat isEqualToString:@"Archives"]) return @"archivebox.fill";
    if ([cat isEqualToString:@"Apps"]) return @"app.badge.fill";
    if ([cat isEqualToString:@"Images"]) return @"photo.fill";
    return @"arrow.down.doc.fill";
}

static BOOL wq_pwrite_all(int fd, const void *buf, size_t len, int64_t offset)
{
    const uint8_t *p = (const uint8_t *)buf;
    size_t rem = len;
    off_t off = (off_t)offset;
    while (rem > 0) {
        ssize_t w = pwrite(fd, p, rem, off);
        if (w <= 0) {
            if (w < 0 && errno == EINTR) continue;
            return NO;
        }
        p += (size_t)w;
        rem -= (size_t)w;
        off += (off_t)w;
    }
    return YES;
}

static NSMutableURLRequest *wq_make_download_request(NSURL *url, NSDictionary<NSString *, NSString *> *headers)
{
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:30.0];
    BOOL hasUA = NO;
    for (NSString *k in headers) {
        if (!k.length) continue;
        NSString *v = headers[k];
        if (!v.length) continue;
        [req setValue:v forHTTPHeaderField:k];
        if ([k.lowercaseString isEqualToString:@"user-agent"]) hasUA = YES;
    }
    if (!hasUA) {
        [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
            forHTTPHeaderField:@"User-Agent"];
    }
    return req;
}

#pragma mark - HLS (.m3u8) Master Playlist Parser & Quality Picker

static NSString *wq_hls_attr_value(NSString *line, NSString *attrName)
{
    NSString *needle = [attrName stringByAppendingString:@"="];
    NSRange r = [line rangeOfString:needle options:NSCaseInsensitiveSearch];
    if (r.location == NSNotFound) return nil;
    NSString *tail = [line substringFromIndex:NSMaxRange(r)];
    if ([tail hasPrefix:@"\""]) {
        tail = [tail substringFromIndex:1];
        NSRange endQ = [tail rangeOfString:@"\""];
        return (endQ.location != NSNotFound) ? [tail substringToIndex:endQ.location] : tail;
    }
    NSRange comma = [tail rangeOfString:@","];
    return (comma.location != NSNotFound) ? [tail substringToIndex:comma.location] : tail;
}

static NSString *wq_hls_quality_label(NSInteger height, long long bandwidth, BOOL audioOnly)
{
    if (audioOnly) return WQLocalized(@"Audio Only");
    if (height >= 2160) return @"2160p 4K";
    if (height >= 1440) return @"1440p QHD";
    if (height >= 1080) return @"1080p Full HD";
    if (height >= 720) return @"720p HD";
    if (height >= 480) return @"480p SD";
    if (height >= 360) return @"360p";
    if (height > 0) return [NSString stringWithFormat:@"%ldp", (long)height];
    if (bandwidth >= 1000000) return [NSString stringWithFormat:@"%.1f Mbps", (double)bandwidth / 1000000.0];
    if (bandwidth > 0) return [NSString stringWithFormat:@"%lld kbps", bandwidth / 1000];
    return WQLocalized(@"Original Stream");
}

void wq_fetch_hls_variants(NSString *m3u8URL,
                           NSDictionary<NSString *, NSString *> *headers,
                           void (^completion)(NSArray<WQHLSVariant *> *variants, BOOL isDRM, NSString *errorText))
{
    NSURL *baseURL = [NSURL URLWithString:m3u8URL];
    if (!baseURL) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], NO, WQLocalized(@"Invalid HLS URL.")); });
        return;
    }
    NSMutableURLRequest *req = wq_make_download_request(baseURL, headers);
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data.length) {
            NSString *msg = error.localizedDescription ?: WQLocalized(@"Could not load HLS playlist.");
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], NO, msg); });
            return;
        }
        NSURL *resolvedBase = response.URL ?: baseURL;
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
            ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
        if (!text.length || ![text containsString:@"#EXTM3U"]) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], NO, WQLocalized(@"Not a valid M3U8 playlist.")); });
            return;
        }

        BOOL isDRM = NO;
        NSMutableArray<WQHLSVariant *> *variants = [NSMutableArray new];
        NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
        for (NSUInteger i = 0; i < lines.count; i++) {
            NSString *line = [lines[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (!line.length) continue;
            if ([line hasPrefix:@"#EXT-X-KEY:"]) {
                NSString *method = wq_hls_attr_value(line, @"METHOD").uppercaseString;
                NSString *keyFmt = wq_hls_attr_value(line, @"KEYFORMAT").lowercaseString;
                if ([method isEqualToString:@"SAMPLE-AES"] || [keyFmt containsString:@"streamingkeydelivery"] || [keyFmt containsString:@"widevine"] || [keyFmt containsString:@"playready"]) {
                    isDRM = YES;
                }
            } else if ([line hasPrefix:@"#EXT-X-STREAM-INF:"]) {
                NSString *nextURI = nil;
                for (NSUInteger j = i + 1; j < lines.count; j++) {
                    NSString *cand = [lines[j] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                    if (!cand.length || [cand hasPrefix:@"#"]) continue;
                    nextURI = cand;
                    i = j;
                    break;
                }
                if (!nextURI.length) continue;
                NSURL *u = [NSURL URLWithString:nextURI relativeToURL:resolvedBase];
                if (!u) continue;
                WQHLSVariant *v = [WQHLSVariant new];
                v.urlString = u.absoluteString;
                NSString *bwStr = wq_hls_attr_value(line, @"AVERAGE-BANDWIDTH") ?: wq_hls_attr_value(line, @"BANDWIDTH");
                v.bandwidth = bwStr.longLongValue;
                NSString *resStr = wq_hls_attr_value(line, @"RESOLUTION");
                if (resStr.length) {
                    NSArray<NSString *> *dims = [resStr componentsSeparatedByString:@"x"];
                    if (dims.count == 2) {
                        v.width = dims[0].integerValue;
                        v.height = dims[1].integerValue;
                    }
                }
                v.title = wq_hls_quality_label(v.height, v.bandwidth, NO);
                NSMutableArray<NSString *> *meta = [NSMutableArray new];
                if (v.width > 0 && v.height > 0) [meta addObject:[NSString stringWithFormat:@"%ld×%ld", (long)v.width, (long)v.height]];
                if (v.bandwidth >= 1000000) [meta addObject:[NSString stringWithFormat:@"%.1f Mbps", (double)v.bandwidth / 1000000.0]];
                else if (v.bandwidth > 0) [meta addObject:[NSString stringWithFormat:@"%lld kbps", v.bandwidth / 1000]];
                NSString *fps = wq_hls_attr_value(line, @"FRAME-RATE");
                if (fps.length) [meta addObject:[NSString stringWithFormat:@"%@ fps", fps]];
                v.detail = meta.count ? [meta componentsJoinedByString:@" · "] : @"HLS Stream";
                [variants addObject:v];
            } else if ([line hasPrefix:@"#EXT-X-MEDIA:"] && [line.uppercaseString containsString:@"TYPE=AUDIO"]) {
                NSString *uri = wq_hls_attr_value(line, @"URI");
                if (uri.length) {
                    NSURL *u = [NSURL URLWithString:uri relativeToURL:resolvedBase];
                    if (u) {
                        WQHLSVariant *v = [WQHLSVariant new];
                        v.urlString = u.absoluteString;
                        v.isAudioOnly = YES;
                        NSString *name = wq_hls_attr_value(line, @"NAME") ?: WQLocalized(@"Audio Track");
                        NSString *lang = wq_hls_attr_value(line, @"LANGUAGE");
                        v.title = lang.length ? [NSString stringWithFormat:@"Audio Only (%@ · %@)", name, lang] : [NSString stringWithFormat:@"Audio Only (%@)", name];
                        v.detail = @"HLS Audio Stream";
                        [variants addObject:v];
                    }
                }
            }
        }

        if (!variants.count) {
            // Single media playlist (not a master playlist)
            WQHLSVariant *v = [WQHLSVariant new];
            v.urlString = resolvedBase.absoluteString;
            v.title = WQLocalized(@"Original Stream (HLS)");
            v.detail = @"Single-quality M3U8 playlist";
            [variants addObject:v];
        } else {
            [variants sortUsingComparator:^NSComparisonResult(WQHLSVariant *a, WQHLSVariant *b) {
                if (a.isAudioOnly != b.isAudioOnly) return a.isAudioOnly ? NSOrderedDescending : NSOrderedAscending;
                if (a.height != b.height) return (a.height > b.height) ? NSOrderedAscending : NSOrderedDescending;
                if (a.bandwidth != b.bandwidth) return (a.bandwidth > b.bandwidth) ? NSOrderedAscending : NSOrderedDescending;
                return NSOrderedSame;
            }];
        }
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(variants, isDRM, nil);
            });
        }
    }];
    [task resume];
}

void wq_present_hls_quality_picker(UIViewController *host,
                                   NSString *m3u8URL,
                                   NSString *suggestedFilename,
                                   NSDictionary<NSString *, NSString *> *headers)
{
    if (!host || !m3u8URL.length) return;
    UIAlertController *loading = wq_alert_controller(WQLocalized(@"Checking Stream Qualities…"),
                                                     WQLocalized(@"Reading HLS master playlist variants."),
                                                     UIAlertControllerStyleAlert);
    [host presentViewController:loading animated:YES completion:nil];
    __weak UIViewController *weakHost = host;
    wq_fetch_hls_variants(m3u8URL, headers, ^(NSArray<WQHLSVariant *> *variants, BOOL isDRM, NSString *errorText) {
        [loading dismissViewControllerAnimated:YES completion:^{
            UIViewController *h = weakHost;
            if (!h) return;
            if (isDRM) {
                wq_alert(h, WQLocalized(@"DRM-Protected Stream"),
                         WQLocalized(@"This video stream uses FairPlay / hardware DRM encryption and cannot be downloaded."));
                return;
            }
            if (errorText.length || !variants.count) {
                wq_alert(h, WQLocalized(@"Stream Unavailable"), errorText ?: WQLocalized(@"Could not read stream qualities."));
                return;
            }
            UIAlertController *sheet = wq_alert_controller(WQLocalized(@"Select Video / Audio Quality"),
                                                           WQVerbatim(suggestedFilename ?: @"HLS Stream"),
                                                           UIAlertControllerStyleActionSheet);
            for (WQHLSVariant *v in variants) {
                NSString *label = [NSString stringWithFormat:@"%@  ·  %@", v.title, v.detail];
                [sheet addAction:wq_alert_action(WQVerbatim(label), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
                    NSString *baseName = suggestedFilename.length ? suggestedFilename.stringByDeletingPathExtension : @"video_stream";
                    NSString *ext = v.isAudioOnly ? @"m4a" : @"ts";
                    NSString *outName = [NSString stringWithFormat:@"%@_%@.%@",
                                         baseName,
                                         [v.title stringByReplacingOccurrencesOfString:@" " withString:@"_"],
                                         ext];
                    wq_present_add_download_sheet(h, v.urlString, outName, -1, headers, YES, v.title);
                })];
            }
            [sheet addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
            sheet.popoverPresentationController.sourceView = h.view;
            sheet.popoverPresentationController.sourceRect = CGRectMake(h.view.bounds.size.width * 0.5, h.view.bounds.size.height * 0.5, 1, 1);
            [h presentViewController:sheet animated:YES completion:nil];
        }];
    });
}

#pragma mark - Active Multi-Part & Single-Stream Contexts

static const NSUInteger kWQDLWriteBufBytes = 256 * 1024;

@interface WQActivePartTask : NSObject
@property (nonatomic, strong) WQDownloadItem *item;
@property (nonatomic, strong) WQDownloadPart *part;
@property (nonatomic, strong) NSURLSessionDataTask *dataTask;
@property (nonatomic) int fd;
@property (nonatomic, strong) NSMutableData *writeBuf;
@property (nonatomic) int64_t writeBufOffset;
@end
@implementation WQActivePartTask
- (instancetype)init
{
    if ((self = [super init])) {
        _writeBuf = [NSMutableData dataWithCapacity:kWQDLWriteBufBytes];
        _writeBufOffset = -1;
    }
    return self;
}
@end

static BOOL wq_flush_part_task(WQActivePartTask *pt, int fd)
{
    if (!pt || fd < 0 || !pt.writeBuf.length) return YES;
    int64_t off = (pt.writeBufOffset >= 0) ? pt.writeBufOffset : (pt.part.startOffset + pt.part.downloadedBytes);
    BOOL ok = wq_pwrite_all(fd, pt.writeBuf.bytes, pt.writeBuf.length, off);
    if (ok) {
        pt.part.downloadedBytes += (int64_t)pt.writeBuf.length;
        pt.writeBuf.length = 0;
        pt.writeBufOffset = -1;
    }
    return ok;
}

@interface WQActiveDownloadRun : NSObject
@property (nonatomic, strong) WQDownloadItem *item;
@property (nonatomic) int fd;
@property (nonatomic, strong) NSMutableArray<WQActivePartTask *> *partTasks;
@property (nonatomic, strong, nullable) NSURLSessionDownloadTask *singleTask;
@property (nonatomic, strong, nullable) NSData *resumeData;
@property (nonatomic, strong, nullable) NSURLSessionDataTask *probeTask;
@property (atomic) BOOL cancelled;
@property (nonatomic) CFAbsoluteTime lastSpeedTime;
@property (nonatomic) int64_t lastSpeedBytes;
@end

@implementation WQActiveDownloadRun
- (instancetype)init
{
    if ((self = [super init])) {
        _fd = -1;
        _partTasks = [NSMutableArray new];
    }
    return self;
}
@end

#pragma mark - WQDownloadManager

@interface WQDownloadManager () <NSURLSessionDataDelegate, NSURLSessionDownloadDelegate>
@end

@implementation WQDownloadManager {
    NSMutableArray<WQDownloadItem *> *_items;
    NSMutableDictionary<NSString *, WQActiveDownloadRun *> *_runs;
    NSMutableDictionary<NSNumber *, WQActivePartTask *> *_partByTaskID;
    NSMutableDictionary<NSNumber *, WQActiveDownloadRun *> *_singleByTaskID;
    NSURLSession *_session;
    dispatch_queue_t _workQueue;
    NSTimer *_uiTimer;
}

+ (instancetype)sharedManager
{
    static WQDownloadManager *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [WQDownloadManager new]; });
    return inst;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _items = [NSMutableArray new];
        _runs = [NSMutableDictionary new];
        _partByTaskID = [NSMutableDictionary new];
        _singleByTaskID = [NSMutableDictionary new];
        _workQueue = dispatch_queue_create("com.wqglass.download.engine", DISPATCH_QUEUE_SERIAL);

        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.HTTPMaximumConnectionsPerHost = 24;
        cfg.timeoutIntervalForRequest = 30.0;
        cfg.timeoutIntervalForResource = 3600.0;
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        NSOperationQueue *delQ = [NSOperationQueue new];
        delQ.maxConcurrentOperationCount = 1;
        delQ.qualityOfService = NSQualityOfServiceUtility;
        _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:delQ];

        [self loadState];
    }
    return self;
}

- (NSArray<WQDownloadItem *> *)items
{
    @synchronized (_items) {
        return [_items copy];
    }
}

- (NSUInteger)activeCount
{
    @synchronized (_items) {
        NSUInteger c = 0;
        for (WQDownloadItem *it in _items) {
            if (it.state == WQDownloadStateDownloading || it.state == WQDownloadStateProbing || it.state == WQDownloadStateQueued) c++;
        }
        return c;
    }
}

- (NSInteger)defaultPartCount
{
    NSInteger v = [NSUserDefaults.standardUserDefaults integerForKey:kWQDLPartsPref];
    return (v == 2 || v == 4 || v == 8 || v == 16) ? v : 4;
}
- (void)setDefaultPartCount:(NSInteger)v
{
    if (v != 2 && v != 4 && v != 8 && v != 16) v = 4;
    [NSUserDefaults.standardUserDefaults setInteger:v forKey:kWQDLPartsPref];
}

- (NSInteger)maxConcurrentDownloads
{
    NSInteger v = [NSUserDefaults.standardUserDefaults integerForKey:kWQDLMaxConcPref];
    return (v >= 1 && v <= 3) ? v : 2;
}
- (void)setMaxConcurrentDownloads:(NSInteger)v
{
    [NSUserDefaults.standardUserDefaults setInteger:MAX(1, MIN(3, v)) forKey:kWQDLMaxConcPref];
}

- (NSInteger)speedLimitKBps
{
    return [NSUserDefaults.standardUserDefaults integerForKey:kWQDLSpeedLimitPref];
}
- (void)setSpeedLimitKBps:(NSInteger)v
{
    [NSUserDefaults.standardUserDefaults setInteger:MAX(0, v) forKey:kWQDLSpeedLimitPref];
}

- (BOOL)wifiOnly
{
    return [NSUserDefaults.standardUserDefaults boolForKey:kWQDLWifiOnlyPref];
}
- (void)setWifiOnly:(BOOL)v
{
    [NSUserDefaults.standardUserDefaults setBool:v forKey:kWQDLWifiOnlyPref];
}

#pragma mark Persistence

- (void)saveState
{
    NSArray<WQDownloadItem *> *snap = self.items;
    dispatch_async(_workQueue, ^{
        NSMutableArray *arr = [NSMutableArray arrayWithCapacity:snap.count];
        for (WQDownloadItem *it in snap) {
            NSMutableArray *partsArr = [NSMutableArray arrayWithCapacity:it.parts.count];
            for (WQDownloadPart *p in it.parts) {
                [partsArr addObject:@{
                    @"i": @(p.index),
                    @"s": @(p.startOffset),
                    @"e": @(p.endOffset),
                    @"d": @(p.downloadedBytes),
                    @"f": @(p.finished),
                }];
            }
            WQDownloadState persistState = it.state;
            if (persistState == WQDownloadStateDownloading || persistState == WQDownloadStateProbing) {
                persistState = WQDownloadStatePaused;
            }
            [arr addObject:@{
                @"id": it.itemID ?: @"",
                @"url": it.urlString ?: @"",
                @"fn": it.filename ?: @"download",
                @"cat": it.category ?: @"Other",
                @"dst": it.destinationDir ?: wq_downloads_root_dir(),
                @"loc": it.localPath ?: @"",
                @"part": it.partialPath ?: @"",
                @"hdr": it.headers ?: @{},
                @"st": @(persistState),
                @"tot": @(it.totalBytes),
                @"dl": @(it.downloadedBytes),
                @"pc": @(it.partCount),
                @"rng": @(it.supportsRanges),
                @"hls": @(it.isHLS),
                @"ht": @(it.hlsTotalSegments),
                @"hd": @(it.hlsDoneSegments),
                @"ql": it.qualityLabel ?: @"",
                @"err": it.errorMessage ?: @"",
                @"at": @(it.createdAt),
                @"parts": partsArr,
            }];
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:arr options:0 error:nil];
        if (json) [json writeToFile:wq_downloads_state_path() atomically:YES];
    });
}

- (void)loadState
{
    NSData *data = [NSData dataWithContentsOfFile:wq_downloads_state_path()];
    if (!data.length) return;
    NSArray *arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![arr isKindOfClass:NSArray.class]) return;
    @synchronized (_items) {
        [_items removeAllObjects];
        for (NSDictionary *d in arr) {
            if (![d isKindOfClass:NSDictionary.class]) continue;
            WQDownloadItem *it = [WQDownloadItem new];
            it.itemID = [d[@"id"] isKindOfClass:NSString.class] ? d[@"id"] : NSUUID.UUID.UUIDString;
            it.urlString = [d[@"url"] isKindOfClass:NSString.class] ? d[@"url"] : @"";
            it.filename = [d[@"fn"] isKindOfClass:NSString.class] ? d[@"fn"] : @"download";
            it.category = [d[@"cat"] isKindOfClass:NSString.class] ? d[@"cat"] : @"Other";
            it.destinationDir = [d[@"dst"] isKindOfClass:NSString.class] ? d[@"dst"] : wq_downloads_root_dir();
            NSString *loc = [d[@"loc"] isKindOfClass:NSString.class] ? d[@"loc"] : @"";
            it.localPath = loc.length ? loc : nil;
            NSString *pp = [d[@"part"] isKindOfClass:NSString.class] ? d[@"part"] : @"";
            it.partialPath = pp.length ? pp : nil;
            it.headers = [d[@"hdr"] isKindOfClass:NSDictionary.class] ? d[@"hdr"] : @{};
            it.state = (WQDownloadState)[d[@"st"] integerValue];
            it.totalBytes = [d[@"tot"] longLongValue];
            it.downloadedBytes = [d[@"dl"] longLongValue];
            it.partCount = MAX(1, [d[@"pc"] integerValue]);
            it.supportsRanges = [d[@"rng"] boolValue];
            it.isHLS = [d[@"hls"] boolValue];
            it.hlsTotalSegments = [d[@"ht"] integerValue];
            it.hlsDoneSegments = [d[@"hd"] integerValue];
            NSString *ql = [d[@"ql"] isKindOfClass:NSString.class] ? d[@"ql"] : @"";
            it.qualityLabel = ql.length ? ql : nil;
            NSString *err = [d[@"err"] isKindOfClass:NSString.class] ? d[@"err"] : @"";
            it.errorMessage = err.length ? err : nil;
            it.createdAt = [d[@"at"] doubleValue];
            NSMutableArray<WQDownloadPart *> *ps = [NSMutableArray new];
            if ([d[@"parts"] isKindOfClass:NSArray.class]) {
                for (NSDictionary *pd in d[@"parts"]) {
                    if (![pd isKindOfClass:NSDictionary.class]) continue;
                    WQDownloadPart *p = [WQDownloadPart new];
                    p.index = [pd[@"i"] integerValue];
                    p.startOffset = [pd[@"s"] longLongValue];
                    p.endOffset = [pd[@"e"] longLongValue];
                    p.downloadedBytes = [pd[@"d"] longLongValue];
                    p.finished = [pd[@"f"] boolValue];
                    [ps addObject:p];
                }
            }
            it.parts = ps;
            [_items addObject:it];
        }
    }
}

#pragma mark UI Progress Timer (Zero Idle Drain)

- (void)ensureUITimerOnMain
{
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL anyRunning = NO;
        @synchronized (self->_items) {
            for (WQDownloadItem *it in self->_items) {
                if (it.state == WQDownloadStateDownloading || it.state == WQDownloadStateProbing) {
                    anyRunning = YES;
                    break;
                }
            }
        }
        if (anyRunning && !self->_uiTimer) {
            __weak typeof(self) weakSelf = self;
            self->_uiTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *__unused t) {
                [weakSelf sampleSpeedsAndNotify];
            }];
        } else if (!anyRunning && self->_uiTimer) {
            [self->_uiTimer invalidate];
            self->_uiTimer = nil;
        }
        [NSNotificationCenter.defaultCenter postNotificationName:WQDownloadManagerDidUpdateNotification object:self];
    });
}

- (void)sampleSpeedsAndNotify
{
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL anyRunning = NO;
    @synchronized (_runs) {
        for (NSString *key in _runs) {
            WQActiveDownloadRun *run = _runs[key];
            WQDownloadItem *it = run.item;
            if (it.state == WQDownloadStateDownloading || it.state == WQDownloadStateProbing) {
                anyRunning = YES;
                if (run.lastSpeedTime > 0 && now > run.lastSpeedTime) {
                    double dt = now - run.lastSpeedTime;
                    int64_t delta = MAX(0LL, it.downloadedBytes - run.lastSpeedBytes);
                    double inst = (double)delta / dt;
                    it.bytesPerSec = (it.bytesPerSec > 0) ? (it.bytesPerSec * 0.65 + inst * 0.35) : inst;
                }
                run.lastSpeedTime = now;
                run.lastSpeedBytes = it.downloadedBytes;
            }
        }
    }
    if (!anyRunning && _uiTimer) {
        [_uiTimer invalidate];
        _uiTimer = nil;
    }
    [NSNotificationCenter.defaultCenter postNotificationName:WQDownloadManagerDidUpdateNotification object:self];
}

#pragma mark Queue API

- (WQDownloadItem *)enqueueURLString:(NSString *)urlString
                   suggestedFilename:(NSString *)filename
                      destinationDir:(NSString *)destinationDir
                             headers:(NSDictionary<NSString *, NSString *> *)headers
                           partCount:(NSInteger)partCount
                               isHLS:(BOOL)isHLS
                        qualityLabel:(NSString *)qualityLabel
                          startNow:(BOOL)startNow
{
    WQDownloadItem *it = [WQDownloadItem new];
    it.itemID = NSUUID.UUID.UUIDString;
    it.urlString = [urlString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    it.filename = wq_sanitize_filename(filename, it.urlString);
    it.category = isHLS ? @"Videos" : wq_download_category_for_filename(it.filename);
    if (destinationDir.length) {
        it.destinationDir = destinationDir;
    } else {
        it.destinationDir = [wq_downloads_root_dir() stringByAppendingPathComponent:it.category];
    }
    it.partialPath = [wq_downloads_partial_dir() stringByAppendingPathComponent:[it.itemID stringByAppendingPathExtension:@"wqpart"]];
    it.headers = headers ?: @{};
    it.partCount = (partCount >= 1 && partCount <= 16) ? partCount : self.defaultPartCount;
    it.isHLS = isHLS || [it.urlString.lowercaseString containsString:@".m3u8"];
    it.qualityLabel = qualityLabel;
    it.state = startNow ? WQDownloadStateQueued : WQDownloadStatePaused;
    it.createdAt = NSDate.date.timeIntervalSince1970;
    it.parts = @[];

    @synchronized (_items) {
        [_items insertObject:it atIndex:0];
    }
    [self saveState];
    if (startNow) {
        [self pumpQueue];
    } else {
        [self ensureUITimerOnMain];
    }
    return it;
}

- (void)pumpQueue
{
    NSInteger maxConc = self.maxConcurrentDownloads;
    NSMutableArray<WQDownloadItem *> *toStart = [NSMutableArray new];
    @synchronized (_items) {
        NSInteger running = 0;
        for (WQDownloadItem *it in _items) {
            if (it.state == WQDownloadStateDownloading || it.state == WQDownloadStateProbing) running++;
        }
        for (WQDownloadItem *it in _items) {
            if (running >= maxConc) break;
            if (it.state == WQDownloadStateQueued) {
                [toStart addObject:it];
                running++;
            }
        }
    }
    for (WQDownloadItem *it in toStart) {
        [self beginItem:it];
    }
    [self ensureUITimerOnMain];
}

- (void)startOrResumeItem:(WQDownloadItem *)item
{
    if (!item || item.state == WQDownloadStateCompleted || item.state == WQDownloadStateDownloading || item.state == WQDownloadStateProbing) return;
    item.errorMessage = nil;
    item.state = WQDownloadStateQueued;
    [self saveState];
    [self pumpQueue];
}

- (void)retryItem:(WQDownloadItem *)item
{
    if (!item) return;
    item.errorMessage = nil;
    if (item.partialPath.length && !item.supportsRanges) {
        [NSFileManager.defaultManager removeItemAtPath:item.partialPath error:nil];
        item.downloadedBytes = 0;
        item.parts = @[];
    }
    item.state = WQDownloadStateQueued;
    [self saveState];
    [self pumpQueue];
}

- (void)refreshAddressForItem:(WQDownloadItem *)item
                 newURLString:(NSString *)newURLString
                   newHeaders:(NSDictionary<NSString *, NSString *> *)newHeaders
{
    if (!item || !newURLString.length) return;
    [self pauseItem:item];
    item.urlString = [newURLString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (newHeaders.count) item.headers = newHeaders;
    item.errorMessage = nil;
    item.state = WQDownloadStateQueued;
    [self saveState];
    [self pumpQueue];
}

- (void)pauseItem:(WQDownloadItem *)item
{
    if (!item) return;
    WQActiveDownloadRun *run = nil;
    @synchronized (_runs) {
        run = _runs[item.itemID];
        [_runs removeObjectForKey:item.itemID];
    }
    if (run) {
        run.cancelled = YES;
        [run.probeTask cancel];
        for (WQActivePartTask *pt in run.partTasks) {
            [pt.dataTask cancel];
            @synchronized (_partByTaskID) {
                [_partByTaskID removeObjectForKey:@(pt.dataTask.taskIdentifier)];
            }
        }
        if (run.singleTask) {
            NSURLSessionDownloadTask *st = run.singleTask;
            @synchronized (_singleByTaskID) {
                [_singleByTaskID removeObjectForKey:@(st.taskIdentifier)];
            }
            [st cancelByProducingResumeData:^(NSData *resumeData) {
                if (resumeData.length && item.partialPath.length) {
                    [resumeData writeToFile:[item.partialPath stringByAppendingString:@".resume"] atomically:YES];
                }
            }];
        }
        @synchronized (run) {
            if (run.fd >= 0) {
                for (WQActivePartTask *pt in run.partTasks) {
                    wq_flush_part_task(pt, run.fd);
                }
                fsync(run.fd);
                close(run.fd);
                run.fd = -1;
            }
        }
    }
    if (item.state != WQDownloadStateCompleted) {
        item.state = WQDownloadStatePaused;
        item.bytesPerSec = 0;
    }
    [self saveState];
    [self pumpQueue];
}

- (void)pauseAll
{
    for (WQDownloadItem *it in self.items) {
        if (it.state == WQDownloadStateDownloading || it.state == WQDownloadStateProbing || it.state == WQDownloadStateQueued) {
            [self pauseItem:it];
        }
    }
}

- (void)resumeAll
{
    for (WQDownloadItem *it in self.items) {
        if (it.state == WQDownloadStatePaused || it.state == WQDownloadStateFailed) {
            it.state = WQDownloadStateQueued;
            it.errorMessage = nil;
        }
    }
    [self saveState];
    [self pumpQueue];
}

- (void)deleteItem:(WQDownloadItem *)item removeFile:(BOOL)removeFile
{
    if (!item) return;
    [self pauseItem:item];
    if (item.partialPath.length) {
        [NSFileManager.defaultManager removeItemAtPath:item.partialPath error:nil];
        [NSFileManager.defaultManager removeItemAtPath:[item.partialPath stringByAppendingString:@".resume"] error:nil];
    }
    if (removeFile && item.localPath.length) {
        [NSFileManager.defaultManager removeItemAtPath:item.localPath error:nil];
    }
    @synchronized (_items) {
        [_items removeObject:item];
    }
    [self saveState];
    [self ensureUITimerOnMain];
}

- (void)clearCompleted
{
    @synchronized (_items) {
        NSIndexSet *done = [_items indexesOfObjectsPassingTest:^BOOL(WQDownloadItem *obj, NSUInteger __unused idx, BOOL *__unused stop) {
            return obj.state == WQDownloadStateCompleted;
        }];
        [_items removeObjectsAtIndexes:done];
    }
    [self saveState];
    [self ensureUITimerOnMain];
}

#pragma mark Execution Engine (Probe -> Multi-Part Range / Single Stream / HLS)

- (void)beginItem:(WQDownloadItem *)item
{
    if (self.wifiOnly && !wq_wifi_interface_active()) {
        item.state = WQDownloadStatePaused;
        item.errorMessage = WQLocalized(@"Waiting for Wi-Fi (Wi-Fi Only is enabled)");
        [self saveState];
        [self ensureUITimerOnMain];
        return;
    }

    NSURL *url = [NSURL URLWithString:item.urlString];
    if (!url || !url.scheme.length) {
        [self failItem:item message:WQLocalized(@"Invalid download URL.")];
        return;
    }

    WQActiveDownloadRun *run = [WQActiveDownloadRun new];
    run.item = item;
    run.lastSpeedTime = CFAbsoluteTimeGetCurrent();
    run.lastSpeedBytes = item.downloadedBytes;
    @synchronized (_runs) {
        _runs[item.itemID] = run;
    }

    if (item.isHLS) {
        item.state = WQDownloadStateDownloading;
        [self runHLSDownload:run];
        return;
    }

    // Resume existing multi-part download cleanly if partial file + parts already exist!
    if (item.supportsRanges && item.totalBytes >= kWQDLMinMultiPartBytes && item.parts.count > 1 &&
        item.partialPath.length && [NSFileManager.defaultManager fileExistsAtPath:item.partialPath]) {
        item.state = WQDownloadStateDownloading;
        [self launchMultiPartRun:run];
        return;
    }

    // Probe server for Content-Length, Accept-Ranges, and Content-Disposition.
    item.state = WQDownloadStateProbing;
    NSMutableURLRequest *headReq = wq_make_download_request(url, item.headers);
    headReq.HTTPMethod = @"HEAD";
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *probe = [NSURLSession.sharedSession dataTaskWithRequest:headReq completionHandler:^(NSData *__unused d, NSURLResponse *resp, NSError *err) {
        WQDownloadManager *me = weakSelf;
        if (!me || run.cancelled) return;
        NSHTTPURLResponse *http = [resp isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)resp : nil;
        int64_t contentLen = http ? http.expectedContentLength : -1;
        BOOL rangesOK = NO;
        if (http) {
            for (NSString *k in http.allHeaderFields) {
                NSString *lk = k.lowercaseString;
                NSString *val = [NSString stringWithFormat:@"%@", http.allHeaderFields[k]];
                if ([lk isEqualToString:@"accept-ranges"] && [val.lowercaseString containsString:@"bytes"]) {
                    rangesOK = YES;
                } else if ([lk isEqualToString:@"content-disposition"]) {
                    NSString *cdName = wq_filename_from_content_disposition(val);
                    if (cdName.length) {
                        item.filename = wq_sanitize_filename(cdName, item.urlString);
                        item.category = wq_download_category_for_filename(item.filename);
                    }
                }
            }
        }
        if (err || !http || http.statusCode >= 400 || contentLen <= 0) {
            // Fallback probe using 1-byte Range GET (many CDNs reject HEAD with 403/405).
            NSMutableURLRequest *rReq = wq_make_download_request(url, item.headers);
            [rReq setValue:@"bytes=0-0" forHTTPHeaderField:@"Range"];
            NSURLSessionDataTask *rProbe = [NSURLSession.sharedSession dataTaskWithRequest:rReq completionHandler:^(NSData *__unused d2, NSURLResponse *resp2, NSError *__unused err2) {
                if (run.cancelled) return;
                NSHTTPURLResponse *h2 = [resp2 isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)resp2 : nil;
                int64_t tot2 = -1;
                BOOL rng2 = NO;
                if (h2 && h2.statusCode == 206) {
                    rng2 = YES;
                    for (NSString *k in h2.allHeaderFields) {
                        if ([k.lowercaseString isEqualToString:@"content-range"]) {
                            NSString *cr = [NSString stringWithFormat:@"%@", h2.allHeaderFields[k]];
                            NSRange sl = [cr rangeOfString:@"/"];
                            if (sl.location != NSNotFound) {
                                tot2 = [[cr substringFromIndex:sl.location + 1] longLongValue];
                            }
                        }
                    }
                } else if (h2 && h2.expectedContentLength > 0) {
                    tot2 = h2.expectedContentLength;
                }
                [me startAfterProbeRun:run totalBytes:tot2 supportsRanges:rng2];
            }];
            run.probeTask = rProbe;
            [rProbe resume];
            return;
        }
        [me startAfterProbeRun:run totalBytes:contentLen supportsRanges:rangesOK];
    }];
    run.probeTask = probe;
    [probe resume];
}

- (void)startAfterProbeRun:(WQActiveDownloadRun *)run totalBytes:(int64_t)totalBytes supportsRanges:(BOOL)supportsRanges
{
    if (run.cancelled) return;
    WQDownloadItem *item = run.item;
    item.totalBytes = totalBytes;
    item.supportsRanges = supportsRanges;
    item.state = WQDownloadStateDownloading;

    if (supportsRanges && totalBytes >= kWQDLMinMultiPartBytes && item.partCount > 1) {
        NSMutableArray<WQDownloadPart *> *parts = [NSMutableArray arrayWithCapacity:(NSUInteger)item.partCount];
        int64_t chunk = totalBytes / item.partCount;
        for (NSInteger i = 0; i < item.partCount; i++) {
            WQDownloadPart *p = [WQDownloadPart new];
            p.index = i;
            p.startOffset = i * chunk;
            p.endOffset = (i == item.partCount - 1) ? (totalBytes - 1) : ((i + 1) * chunk - 1);
            p.downloadedBytes = 0;
            p.finished = NO;
            [parts addObject:p];
        }
        item.parts = parts;
        item.downloadedBytes = 0;
        [self saveState];
        [self launchMultiPartRun:run];
    } else {
        item.parts = @[];
        [self launchSingleStreamRun:run];
    }
}

- (void)launchMultiPartRun:(WQActiveDownloadRun *)run
{
    WQDownloadItem *item = run.item;
    NSURL *url = [NSURL URLWithString:item.urlString];
    if (!url || !item.partialPath.length) {
        [self failItem:item message:WQLocalized(@"Could not create partial file.")];
        return;
    }
    int fd = open(item.partialPath.fileSystemRepresentation, O_RDWR | O_CREAT, 0644);
    if (fd < 0) {
        [self failItem:item message:[NSString stringWithUTF8String:strerror(errno)]];
        return;
    }
    struct stat st;
    if (fstat(fd, &st) == 0 && st.st_size < item.totalBytes) {
        if (ftruncate(fd, (off_t)item.totalBytes) != 0) {
            close(fd);
            [self failItem:item message:WQLocalized(@"Not enough free disk space for this download.")];
            return;
        }
    }
    run.fd = fd;

    NSUInteger launched = 0;
    for (WQDownloadPart *p in item.parts) {
        if (p.finished) continue;
        int64_t reqStart = p.startOffset + p.downloadedBytes;
        if (reqStart > p.endOffset) {
            p.finished = YES;
            continue;
        }
        NSMutableURLRequest *req = wq_make_download_request(url, item.headers);
        [req setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", reqStart, p.endOffset] forHTTPHeaderField:@"Range"];
        NSURLSessionDataTask *dt = [_session dataTaskWithRequest:req];
        WQActivePartTask *pt = [WQActivePartTask new];
        pt.item = item;
        pt.part = p;
        pt.dataTask = dt;
        pt.fd = fd;
        [run.partTasks addObject:pt];
        @synchronized (_partByTaskID) {
            _partByTaskID[@(dt.taskIdentifier)] = pt;
        }
        [dt resume];
        launched++;
    }
    if (launched == 0) {
        [self finalizeCompletedRun:run sourcePath:item.partialPath];
    } else {
        [self ensureUITimerOnMain];
    }
}

- (void)launchSingleStreamRun:(WQActiveDownloadRun *)run
{
    WQDownloadItem *item = run.item;
    NSURL *url = [NSURL URLWithString:item.urlString];
    NSString *resumePath = [item.partialPath stringByAppendingString:@".resume"];
    NSData *resumeData = [NSData dataWithContentsOfFile:resumePath];
    NSURLSessionDownloadTask *dt = nil;
    if (resumeData.length) {
        [NSFileManager.defaultManager removeItemAtPath:resumePath error:nil];
        dt = [_session downloadTaskWithResumeData:resumeData];
    } else {
        NSMutableURLRequest *req = wq_make_download_request(url, item.headers);
        dt = [_session downloadTaskWithRequest:req];
    }
    run.singleTask = dt;
    @synchronized (_singleByTaskID) {
        _singleByTaskID[@(dt.taskIdentifier)] = run;
    }
    [dt resume];
    [self ensureUITimerOnMain];
}

#pragma mark HLS Segment Downloader (Concurrent + Clear-Key AES-128)

- (void)runHLSDownload:(WQActiveDownloadRun *)run
{
    WQDownloadItem *item = run.item;
    NSURL *playlistURL = [NSURL URLWithString:item.urlString];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        WQDownloadManager *me = weakSelf;
        if (!me || run.cancelled) return;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block NSData *plData = nil;
        __block NSURL *resolvedBase = playlistURL;
        __block NSError *plErr = nil;
        NSMutableURLRequest *req = wq_make_download_request(playlistURL, item.headers);
        [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            plData = d;
            if (r.URL) resolvedBase = r.URL;
            plErr = e;
            dispatch_semaphore_signal(sem);
        }] resume];
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        if (run.cancelled) return;
        if (plErr || !plData.length) {
            [me failItem:item message:plErr.localizedDescription ?: WQLocalized(@"Failed to download HLS playlist.")];
            return;
        }
        NSString *text = [[NSString alloc] initWithData:plData encoding:NSUTF8StringEncoding]
            ?: [[NSString alloc] initWithData:plData encoding:NSISOLatin1StringEncoding];
        NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];

        // If user handed us a master playlist directly, auto-pick highest quality variant!
        if ([text containsString:@"#EXT-X-STREAM-INF:"]) {
            NSString *bestURI = nil;
            long long bestBW = -1;
            for (NSUInteger i = 0; i < lines.count; i++) {
                NSString *l = [lines[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if ([l hasPrefix:@"#EXT-X-STREAM-INF:"]) {
                    long long bw = wq_hls_attr_value(l, @"BANDWIDTH").longLongValue;
                    for (NSUInteger j = i + 1; j < lines.count; j++) {
                        NSString *c = [lines[j] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                        if (!c.length || [c hasPrefix:@"#"]) continue;
                        if (bw > bestBW) { bestBW = bw; bestURI = c; }
                        i = j;
                        break;
                    }
                }
            }
            if (bestURI.length) {
                NSURL *nextURL = [NSURL URLWithString:bestURI relativeToURL:resolvedBase];
                if (nextURL) {
                    item.urlString = nextURL.absoluteString;
                    [me runHLSDownload:run];
                    return;
                }
            }
        }

        NSString *keyMethod = nil;
        NSString *keyURI = nil;
        NSData *keyIV = nil;
        NSUInteger mediaSequence = 0;
        NSMutableArray<NSURL *> *segURLs = [NSMutableArray new];
        for (NSString *rawLine in lines) {
            NSString *l = [rawLine stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (!l.length) continue;
            if ([l hasPrefix:@"#EXT-X-MEDIA-SEQUENCE:"]) {
                mediaSequence = (NSUInteger)[[l substringFromIndex:22] integerValue];
            } else if ([l hasPrefix:@"#EXT-X-KEY:"]) {
                keyMethod = wq_hls_attr_value(l, @"METHOD").uppercaseString;
                NSString *kf = wq_hls_attr_value(l, @"KEYFORMAT").lowercaseString;
                if ([keyMethod isEqualToString:@"SAMPLE-AES"] || [kf containsString:@"streamingkeydelivery"]) {
                    [me failItem:item message:WQLocalized(@"Stream uses FairPlay DRM encryption and cannot be downloaded.")];
                    return;
                }
                keyURI = wq_hls_attr_value(l, @"URI");
                NSString *ivHex = wq_hls_attr_value(l, @"IV");
                if ([ivHex.lowercaseString hasPrefix:@"0x"] && ivHex.length == 34) {
                    NSMutableData *ivd = [NSMutableData dataWithLength:16];
                    uint8_t *ivBytes = ivd.mutableBytes;
                    for (NSUInteger b = 0; b < 16; b++) {
                        unsigned int val = 0;
                        [[NSScanner scannerWithString:[ivHex substringWithRange:NSMakeRange(2 + b * 2, 2)]] scanHexInt:&val];
                        ivBytes[b] = (uint8_t)val;
                    }
                    keyIV = ivd;
                }
            } else if ([l hasPrefix:@"#EXT-X-MAP:"]) {
                NSString *mapURI = wq_hls_attr_value(l, @"URI");
                if (mapURI.length) {
                    NSURL *mu = [NSURL URLWithString:mapURI relativeToURL:resolvedBase];
                    if (mu) [segURLs addObject:mu];
                }
            } else if (![l hasPrefix:@"#"]) {
                NSURL *su = [NSURL URLWithString:l relativeToURL:resolvedBase];
                if (su) [segURLs addObject:su];
            }
        }
        if (!segURLs.count) {
            [me failItem:item message:WQLocalized(@"HLS playlist contains no media segments.")];
            return;
        }

        // Fetch AES-128 clear key if specified
        NSData *aesKey = nil;
        if ([keyMethod isEqualToString:@"AES-128"] && keyURI.length) {
            NSURL *ku = [NSURL URLWithString:keyURI relativeToURL:resolvedBase];
            if (ku) {
                dispatch_semaphore_t ksem = dispatch_semaphore_create(0);
                __block NSData *kd = nil;
                [[NSURLSession.sharedSession dataTaskWithRequest:wq_make_download_request(ku, item.headers) completionHandler:^(NSData *d, NSURLResponse *__unused r, NSError *__unused e) {
                    kd = d;
                    dispatch_semaphore_signal(ksem);
                }] resume];
                dispatch_semaphore_wait(ksem, DISPATCH_TIME_FOREVER);
                if (kd.length == 16) aesKey = kd;
            }
        }

        item.hlsTotalSegments = (NSInteger)segURLs.count;
        item.hlsDoneSegments = 0;
        item.downloadedBytes = 0;

        int fd = open(item.partialPath.fileSystemRepresentation, O_RDWR | O_CREAT | O_TRUNC, 0644);
        if (fd < 0) {
            [me failItem:item message:[NSString stringWithUTF8String:strerror(errno)]];
            return;
        }
        run.fd = fd;

        // Fetch segments in small concurrent batches (4 at a time) and write strictly in sequence.
        const NSUInteger batchSize = 4;
        int64_t writeOffset = 0;
        for (NSUInteger base = 0; base < segURLs.count && !run.cancelled; base += batchSize) {
            NSUInteger count = MIN(batchSize, segURLs.count - base);
            NSMutableArray<id> *results = [NSMutableArray arrayWithCapacity:count];
            for (NSUInteger k = 0; k < count; k++) [results addObject:NSNull.null];
            dispatch_group_t grp = dispatch_group_create();
            for (NSUInteger k = 0; k < count; k++) {
                dispatch_group_enter(grp);
                NSURL *su = segURLs[base + k];
                NSMutableURLRequest *sReq = wq_make_download_request(su, item.headers);
                [[NSURLSession.sharedSession dataTaskWithRequest:sReq completionHandler:^(NSData *d, NSURLResponse *__unused r, NSError *__unused e) {
                    if (d.length) {
                        @synchronized (results) { results[k] = d; }
                    }
                    dispatch_group_leave(grp);
                }] resume];
            }
            dispatch_group_wait(grp, DISPATCH_TIME_FOREVER);
            if (run.cancelled) break;

            for (NSUInteger k = 0; k < count && !run.cancelled; k++) {
                id obj = results[k];
                if (![obj isKindOfClass:NSData.class]) continue;
                NSData *segData = (NSData *)obj;
                if (aesKey.length == 16) {
                    uint8_t iv[16] = {0};
                    if (keyIV.length == 16) {
                        memcpy(iv, keyIV.bytes, 16);
                    } else {
                        uint64_t seq = (uint64_t)(mediaSequence + base + k);
                        for (int b = 15; b >= 8; b--) { iv[b] = (uint8_t)(seq & 0xFF); seq >>= 8; }
                    }
                    NSMutableData *dec = [NSMutableData dataWithLength:segData.length + kCCBlockSizeAES128];
                    size_t outLen = 0;
                    if (CCCrypt(kCCDecrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding,
                                aesKey.bytes, 16, iv,
                                segData.bytes, segData.length,
                                dec.mutableBytes, dec.length, &outLen) == kCCSuccess) {
                        dec.length = outLen;
                        segData = dec;
                    }
                }
                if (!wq_pwrite_all(fd, segData.bytes, segData.length, writeOffset)) {
                    close(fd);
                    run.fd = -1;
                    [me failItem:item message:WQLocalized(@"Disk write error while assembling stream.")];
                    return;
                }
                writeOffset += (int64_t)segData.length;
                item.downloadedBytes = writeOffset;
                item.hlsDoneSegments = (NSInteger)(base + k + 1);
            }
        }
        if (run.cancelled) {
            if (run.fd >= 0) { close(run.fd); run.fd = -1; }
            return;
        }
        fsync(fd);
        close(fd);
        run.fd = -1;
        item.totalBytes = writeOffset;
        [me finalizeCompletedRun:run sourcePath:item.partialPath];
    });
}

#pragma mark NSURLSession Delegates

- (void)URLSession:(NSURLSession *__unused)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler
{
    WQActivePartTask *pt = nil;
    @synchronized (_partByTaskID) { pt = _partByTaskID[@(dataTask.taskIdentifier)]; }
    if (!pt) { completionHandler(NSURLSessionResponseAllow); return; }
    NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
    if (http && http.statusCode >= 400) {
        completionHandler(NSURLSessionResponseCancel);
        [self failItem:pt.item message:WQLocalizedFormat(@"Server returned HTTP %ld", (long)http.statusCode)];
        return;
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *__unused)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data
{
    WQActivePartTask *pt = nil;
    @synchronized (_partByTaskID) { pt = _partByTaskID[@(dataTask.taskIdentifier)]; }
    if (!pt || !data.length) return;
    WQActiveDownloadRun *run = nil;
    @synchronized (_runs) { run = _runs[pt.item.itemID]; }
    if (!run || run.cancelled) return;

    BOOL writeFailed = NO;
    @synchronized (run) {
        if (run.cancelled || run.fd < 0) return;
        if (pt.writeBufOffset < 0) {
            pt.writeBufOffset = pt.part.startOffset + pt.part.downloadedBytes;
        }
        [pt.writeBuf appendData:data];
        if (pt.writeBuf.length >= kWQDLWriteBufBytes) {
            if (!wq_flush_part_task(pt, run.fd)) {
                writeFailed = YES;
            }
        }
    }
    if (writeFailed) {
        [self failItem:pt.item message:WQLocalized(@"Disk write failed (storage full?).")];
        return;
    }
    pt.item.downloadedBytes += (int64_t)data.length;

    NSInteger limitKB = self.speedLimitKBps;
    if (limitKB > 0 && pt.item.bytesPerSec > (double)limitKB * 1024.0) {
        usleep(35000);
    }
}

- (void)URLSession:(NSURLSession *__unused)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    WQActivePartTask *pt = nil;
    @synchronized (_partByTaskID) {
        pt = _partByTaskID[@(task.taskIdentifier)];
        [_partByTaskID removeObjectForKey:@(task.taskIdentifier)];
    }
    if (pt) {
        WQActiveDownloadRun *run = nil;
        @synchronized (_runs) { run = _runs[pt.item.itemID]; }
        if (!run || run.cancelled) return;
        BOOL flushOK = YES;
        @synchronized (run) {
            if (!run.cancelled && run.fd >= 0) {
                flushOK = wq_flush_part_task(pt, run.fd);
            }
        }
        if (error) {
            if (error.code != NSURLErrorCancelled) {
                [self failItem:pt.item message:error.localizedDescription ?: WQLocalized(@"Segment failed.")];
            }
            return;
        }
        if (!flushOK) {
            [self failItem:pt.item message:WQLocalized(@"Disk write failed (storage full?).")];
            return;
        }
        pt.part.finished = YES;
        BOOL allDone = YES;
        for (WQDownloadPart *p in pt.item.parts) {
            if (!p.finished) { allDone = NO; break; }
        }
        if (allDone) {
            @synchronized (run) {
                if (run.fd >= 0) { fsync(run.fd); close(run.fd); run.fd = -1; }
            }
            [self finalizeCompletedRun:run sourcePath:pt.item.partialPath];
        } else {
            [self saveState];
        }
        return;
    }

    WQActiveDownloadRun *singleRun = nil;
    @synchronized (_singleByTaskID) {
        singleRun = _singleByTaskID[@(task.taskIdentifier)];
        [_singleByTaskID removeObjectForKey:@(task.taskIdentifier)];
    }
    if (singleRun && !singleRun.cancelled && error && error.code != NSURLErrorCancelled) {
        NSData *rd = error.userInfo[NSURLSessionDownloadTaskResumeData];
        if (rd.length && singleRun.item.partialPath.length) {
            [rd writeToFile:[singleRun.item.partialPath stringByAppendingString:@".resume"] atomically:YES];
        }
        [self failItem:singleRun.item message:error.localizedDescription ?: WQLocalized(@"Download failed.")];
    }
}

- (void)URLSession:(NSURLSession *__unused)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
    (void)bytesWritten;
    WQActiveDownloadRun *run = nil;
    @synchronized (_singleByTaskID) { run = _singleByTaskID[@(downloadTask.taskIdentifier)]; }
    if (!run || run.cancelled) return;
    run.item.downloadedBytes = totalBytesWritten;
    if (totalBytesExpectedToWrite > 0) run.item.totalBytes = totalBytesExpectedToWrite;
}

- (void)URLSession:(NSURLSession *__unused)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location
{
    WQActiveDownloadRun *run = nil;
    @synchronized (_singleByTaskID) {
        run = _singleByTaskID[@(downloadTask.taskIdentifier)];
        [_singleByTaskID removeObjectForKey:@(downloadTask.taskIdentifier)];
    }
    if (!run || run.cancelled) return;
    // Move temp download out of CFNetwork's ephemeral temp location immediately.
    NSString *staged = run.item.partialPath ?: [wq_downloads_partial_dir() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager removeItemAtPath:staged error:nil];
    NSError *mvErr = nil;
    if (![NSFileManager.defaultManager moveItemAtPath:location.path toPath:staged error:&mvErr]) {
        [self failItem:run.item message:mvErr.localizedDescription ?: WQLocalized(@"Failed to save downloaded file.")];
        return;
    }
    struct stat st;
    if (lstat(staged.fileSystemRepresentation, &st) == 0) {
        run.item.totalBytes = st.st_size;
        run.item.downloadedBytes = st.st_size;
    }
    [self finalizeCompletedRun:run sourcePath:staged];
}

- (void)finalizeCompletedRun:(WQActiveDownloadRun *)run sourcePath:(NSString *)srcPath
{
    WQDownloadItem *item = run.item;
    @synchronized (_runs) { [_runs removeObjectForKey:item.itemID]; }
    NSString *destDir = item.destinationDir.length
        ? item.destinationDir
        : [wq_downloads_root_dir() stringByAppendingPathComponent:item.category];
    NSString *finalPath = wq_unique_file_path(destDir, item.filename);
    NSError *err = nil;
    if (![NSFileManager.defaultManager moveItemAtPath:srcPath toPath:finalPath error:&err]) {
        if (![NSFileManager.defaultManager copyItemAtPath:srcPath toPath:finalPath error:&err]) {
            [self failItem:item message:err.localizedDescription ?: WQLocalized(@"Could not finalize downloaded file.")];
            return;
        }
        [NSFileManager.defaultManager removeItemAtPath:srcPath error:nil];
    }
    item.localPath = finalPath;
    item.filename = finalPath.lastPathComponent;
    item.state = WQDownloadStateCompleted;
    item.bytesPerSec = 0;
    item.errorMessage = nil;
    [self saveState];
    dispatch_async(dispatch_get_main_queue(), ^{
        wq_haptic_notify(UINotificationFeedbackTypeSuccess);
    });
    [self pumpQueue];
}

- (void)failItem:(WQDownloadItem *)item message:(NSString *)message
{
    WQActiveDownloadRun *run = nil;
    @synchronized (_runs) {
        run = _runs[item.itemID];
        [_runs removeObjectForKey:item.itemID];
    }
    if (run) {
        run.cancelled = YES;
        for (WQActivePartTask *pt in run.partTasks) {
            [pt.dataTask cancel];
            @synchronized (_partByTaskID) { [_partByTaskID removeObjectForKey:@(pt.dataTask.taskIdentifier)]; }
        }
        [run.singleTask cancel];
        @synchronized (run) {
            if (run.fd >= 0) { close(run.fd); run.fd = -1; }
        }
    }
    item.state = WQDownloadStateFailed;
    item.bytesPerSec = 0;
    item.errorMessage = message;
    [self saveState];
    [self pumpQueue];
}

@end

#pragma mark - Shared Frosted "Add Download" Confirmation Sheet

static void wq_present_add_download_sheet_parts(UIViewController *host,
                                                NSString *urlString,
                                                NSString *suggestedFilename,
                                                int64_t knownSize,
                                                NSDictionary<NSString *, NSString *> *headers,
                                                BOOL isHLS,
                                                NSString *qualityLabel,
                                                NSInteger chosenParts)
{
    if (!host || !urlString.length) return;
    NSString *cleanName = wq_sanitize_filename(suggestedFilename, urlString);
    NSString *sizeTag = (knownSize > 0) ? wq_size_text((unsigned long long)knownSize) : (isHLS ? @"HLS Stream" : WQLocalized(@"Unknown size"));
    NSString *cat = isHLS ? @"Videos" : wq_download_category_for_filename(cleanName);
    NSString *msg = [NSString stringWithFormat:@"%@\n%@ · Documents/Downloads/%@\nIDM Parallel Parts: %ld",
                     urlString.length > 80 ? [[urlString substringToIndex:80] stringByAppendingString:@"…"] : urlString,
                     sizeTag, cat, (long)chosenParts];

    UIAlertController *a = wq_alert_controller(qualityLabel.length ? WQLocalizedFormat(@"Download (%@)", qualityLabel) : WQLocalized(@"Add Download"),
                                               WQVerbatim(msg),
                                               UIAlertControllerStyleAlert);
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = cleanName;
        tf.placeholder = WQLocalized(@"Filename");
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [a addAction:wq_alert_action(WQLocalizedFormat(@"Download Now (%ld Parts)", (long)chosenParts), UIAlertActionStyleDefault, ^(UIAlertAction *__unused act) {
        NSString *fn = a.textFields.firstObject.text.length ? a.textFields.firstObject.text : cleanName;
        [WQDownloadManager.sharedManager enqueueURLString:urlString
                                        suggestedFilename:fn
                                           destinationDir:nil
                                                  headers:headers
                                                partCount:chosenParts
                                                    isHLS:isHLS
                                             qualityLabel:qualityLabel
                                                 startNow:YES];
        wq_haptic_notify(UINotificationFeedbackTypeSuccess);
    })];

    if (!isHLS) {
        NSInteger nextParts = (chosenParts == 2) ? 4 : (chosenParts == 4) ? 8 : (chosenParts == 8) ? 16 : 2;
        [a addAction:wq_alert_action(WQLocalizedFormat(@"Change Parallel Parts → %ld Parts", (long)nextParts), UIAlertActionStyleDefault, ^(UIAlertAction *__unused act) {
            NSString *fn = a.textFields.firstObject.text.length ? a.textFields.firstObject.text : cleanName;
            wq_present_add_download_sheet_parts(host, urlString, fn, knownSize, headers, isHLS, qualityLabel, nextParts);
        })];
    }

    NSArray<WQWorkspaceTab *> *tabs = wq_workspace_tabs();
    if (tabs.count > 0) {
        [a addAction:wq_alert_action(WQLocalized(@"Save to Open Folder Tab…"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused act) {
            NSString *fn = a.textFields.firstObject.text.length ? a.textFields.firstObject.text : cleanName;
            UIAlertController *pick = wq_alert_controller(WQLocalized(@"Choose Destination Tab"), nil, UIAlertControllerStyleActionSheet);
            for (WQWorkspaceTab *t in tabs) {
                [pick addAction:wq_alert_action(WQVerbatim(t.title), UIAlertActionStyleDefault, ^(UIAlertAction *__unused b) {
                    [WQDownloadManager.sharedManager enqueueURLString:urlString
                                                    suggestedFilename:fn
                                                       destinationDir:t.path
                                                               headers:headers
                                                             partCount:chosenParts
                                                                 isHLS:isHLS
                                                          qualityLabel:qualityLabel
                                                              startNow:YES];
                    wq_haptic_notify(UINotificationFeedbackTypeSuccess);
                })];
            }
            [pick addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
            pick.popoverPresentationController.sourceView = host.view;
            pick.popoverPresentationController.sourceRect = CGRectMake(host.view.bounds.size.width * 0.5, host.view.bounds.size.height * 0.5, 1, 1);
            [host presentViewController:pick animated:YES completion:nil];
        })];
    }

    [a addAction:wq_alert_action(WQLocalized(@"Add Paused to Queue"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused act) {
        NSString *fn = a.textFields.firstObject.text.length ? a.textFields.firstObject.text : cleanName;
        [WQDownloadManager.sharedManager enqueueURLString:urlString
                                        suggestedFilename:fn
                                           destinationDir:nil
                                                  headers:headers
                                                partCount:chosenParts
                                                    isHLS:isHLS
                                             qualityLabel:qualityLabel
                                                 startNow:NO];
    })];
    [a addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    [host presentViewController:a animated:YES completion:nil];
}

void wq_present_add_download_sheet(UIViewController *host,
                                   NSString *urlString,
                                   NSString *suggestedFilename,
                                   int64_t knownSize,
                                   NSDictionary<NSString *, NSString *> *headers,
                                   BOOL isHLS,
                                   NSString *qualityLabel)
{
    wq_present_add_download_sheet_parts(host, urlString, suggestedFilename, knownSize, headers, isHLS, qualityLabel,
                                        WQDownloadManager.sharedManager.defaultPartCount);
}

#pragma mark - IDM Multi-Segment Progress Bar View & Cell

@interface WQSegmentProgressStrip : UIView
- (void)configureWithItem:(WQDownloadItem *)item;
@end

@implementation WQSegmentProgressStrip {
    UIStackView *_stack;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        self.layer.cornerRadius = 4.0;
        self.clipsToBounds = YES;
        self.backgroundColor = [wq_theme_hairline() colorWithAlphaComponent:0.45];
        _stack = [UIStackView new];
        _stack.translatesAutoresizingMaskIntoConstraints = NO;
        _stack.axis = UILayoutConstraintAxisHorizontal;
        _stack.distribution = UIStackViewDistributionFillEqually;
        _stack.spacing = 2.0;
        [self addSubview:_stack];
        [NSLayoutConstraint activateConstraints:@[
            [_stack.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        ]];
    }
    return self;
}

- (void)configureWithItem:(WQDownloadItem *)item
{
    for (UIView *sub in _stack.arrangedSubviews) {
        [_stack removeArrangedSubview:sub];
        [sub removeFromSuperview];
    }
    UIColor *fillColor = (item.state == WQDownloadStateCompleted) ? UIColor.systemGreenColor
                       : (item.state == WQDownloadStateFailed) ? UIColor.systemRedColor
                       : (item.state == WQDownloadStatePaused) ? UIColor.systemOrangeColor
                       : wq_theme_accent();

    if (item.parts.count > 1 && item.state != WQDownloadStateCompleted) {
        for (WQDownloadPart *p in item.parts) {
            UIView *slot = [UIView new];
            slot.backgroundColor = [wq_theme_hairline() colorWithAlphaComponent:0.5];
            slot.layer.cornerRadius = 2.0;
            slot.clipsToBounds = YES;
            UIView *fill = [UIView new];
            fill.translatesAutoresizingMaskIntoConstraints = NO;
            fill.backgroundColor = p.finished ? wq_theme_aurora_teal() : fillColor;
            [slot addSubview:fill];
            CGFloat frac = (CGFloat)MAX(0.0, MIN(1.0, p.progress));
            [NSLayoutConstraint activateConstraints:@[
                [fill.topAnchor constraintEqualToAnchor:slot.topAnchor],
                [fill.bottomAnchor constraintEqualToAnchor:slot.bottomAnchor],
                [fill.leadingAnchor constraintEqualToAnchor:slot.leadingAnchor],
                [fill.widthAnchor constraintEqualToAnchor:slot.widthAnchor multiplier:frac],
            ]];
            [_stack addArrangedSubview:slot];
        }
    } else {
        UIView *slot = [UIView new];
        slot.backgroundColor = [wq_theme_hairline() colorWithAlphaComponent:0.5];
        UIView *fill = [UIView new];
        fill.translatesAutoresizingMaskIntoConstraints = NO;
        fill.backgroundColor = fillColor;
        [slot addSubview:fill];
        CGFloat frac = (CGFloat)MAX(0.0, MIN(1.0, item.progress));
        [NSLayoutConstraint activateConstraints:@[
            [fill.topAnchor constraintEqualToAnchor:slot.topAnchor],
            [fill.bottomAnchor constraintEqualToAnchor:slot.bottomAnchor],
            [fill.leadingAnchor constraintEqualToAnchor:slot.leadingAnchor],
            [fill.widthAnchor constraintEqualToAnchor:slot.widthAnchor multiplier:frac],
        ]];
        [_stack addArrangedSubview:slot];
    }
}

@end

@interface WQDownloadCell : UITableViewCell
- (void)configureWithItem:(WQDownloadItem *)item;
- (void)configureWithItem:(WQDownloadItem *)item onToggle:(void (^)(void))onToggle;
@end

@implementation WQDownloadCell {
    UIImageView *_icon;
    UILabel *_titleLabel;
    UILabel *_metaLabel;
    UILabel *_speedLabel;
    WQSegmentProgressStrip *_strip;
    UIButton *_actionBtn;
    void (^_onToggle)(void);
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        _icon = [UIImageView new];
        _icon.translatesAutoresizingMaskIntoConstraints = NO;
        _icon.contentMode = UIViewContentModeScaleAspectFit;

        _titleLabel = [UILabel new];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:14.5 weight:UIFontWeightSemibold];
        _titleLabel.textColor = wq_theme_primary_text();
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

        _metaLabel = [UILabel new];
        _metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _metaLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.5 weight:UIFontWeightMedium];
        _metaLabel.textColor = wq_theme_secondary_text();

        _speedLabel = [UILabel new];
        _speedLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _speedLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.5 weight:UIFontWeightBold];
        _speedLabel.textColor = wq_theme_aurora_teal();

        _strip = [WQSegmentProgressStrip new];
        _strip.translatesAutoresizingMaskIntoConstraints = NO;

        _actionBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        _actionBtn.translatesAutoresizingMaskIntoConstraints = NO;
        [_actionBtn addTarget:self action:@selector(toggleTapped) forControlEvents:UIControlEventTouchUpInside];

        UIView *cv = self.contentView;
        [cv addSubview:_icon];
        [cv addSubview:_titleLabel];
        [cv addSubview:_metaLabel];
        [cv addSubview:_speedLabel];
        [cv addSubview:_strip];
        [cv addSubview:_actionBtn];

        [NSLayoutConstraint activateConstraints:@[
            [_icon.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor constant:14],
            [_icon.centerYAnchor constraintEqualToAnchor:cv.centerYAnchor],
            [_icon.widthAnchor constraintEqualToConstant:28],
            [_icon.heightAnchor constraintEqualToConstant:28],

            [_actionBtn.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-12],
            [_actionBtn.centerYAnchor constraintEqualToAnchor:cv.centerYAnchor],
            [_actionBtn.widthAnchor constraintEqualToConstant:34],
            [_actionBtn.heightAnchor constraintEqualToConstant:34],

            [_titleLabel.topAnchor constraintEqualToAnchor:cv.topAnchor constant:10],
            [_titleLabel.leadingAnchor constraintEqualToAnchor:_icon.trailingAnchor constant:10],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:_actionBtn.leadingAnchor constant:-8],

            [_strip.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:6],
            [_strip.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_strip.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],
            [_strip.heightAnchor constraintEqualToConstant:7],

            [_metaLabel.topAnchor constraintEqualToAnchor:_strip.bottomAnchor constant:5],
            [_metaLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_metaLabel.bottomAnchor constraintEqualToAnchor:cv.bottomAnchor constant:-10],

            [_speedLabel.centerYAnchor constraintEqualToAnchor:_metaLabel.centerYAnchor],
            [_speedLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],
            [_speedLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_metaLabel.trailingAnchor constant:8],
        ]];
    }
    return self;
}

- (void)toggleTapped
{
    if (_onToggle) _onToggle();
}

- (void)configureWithItem:(WQDownloadItem *)item onToggle:(void (^)(void))onToggle
{
    _onToggle = [onToggle copy];
    [self configureWithItem:item];
}

- (void)configureWithItem:(WQDownloadItem *)item
{
    _icon.image = [UIImage systemImageNamed:wq_symbol_for_category(item.category)];
    _icon.tintColor = (item.state == WQDownloadStateCompleted) ? UIColor.systemGreenColor
                    : (item.state == WQDownloadStateFailed) ? UIColor.systemRedColor
                    : wq_theme_accent();
    _titleLabel.text = item.qualityLabel.length
        ? [NSString stringWithFormat:@"%@ [%@]", item.filename, item.qualityLabel]
        : item.filename;
    _titleLabel.textColor = wq_theme_primary_text();
    [_strip configureWithItem:item];

    NSString *dlText = wq_size_text((unsigned long long)MAX(0LL, item.downloadedBytes));
    NSString *totText = (item.totalBytes > 0) ? wq_size_text((unsigned long long)item.totalBytes) : @"--";

    if (item.state == WQDownloadStateDownloading) {
        NSString *eta = (item.bytesPerSec > 10.0 && item.totalBytes > item.downloadedBytes)
            ? wq_format_eta((double)(item.totalBytes - item.downloadedBytes) / item.bytesPerSec)
            : @"--";
        if (item.isHLS && item.hlsTotalSegments > 0) {
            _metaLabel.text = [NSString stringWithFormat:@"HLS %ld/%ld · %@", (long)item.hlsDoneSegments, (long)item.hlsTotalSegments, dlText];
        } else if (item.parts.count > 1) {
            _metaLabel.text = [NSString stringWithFormat:@"%@ / %@ · %ldP", dlText, totText, (long)item.parts.count];
        } else {
            _metaLabel.text = [NSString stringWithFormat:@"%@ / %@", dlText, totText];
        }
        _speedLabel.text = [NSString stringWithFormat:@"%@ · %@", wq_format_net_speed(item.bytesPerSec), eta];
        _speedLabel.textColor = wq_theme_aurora_teal();
        [_actionBtn setImage:[UIImage systemImageNamed:@"pause.circle.fill"] forState:UIControlStateNormal];
        _actionBtn.tintColor = wq_theme_accent();
    } else if (item.state == WQDownloadStateProbing) {
        _metaLabel.text = WQLocalized(@"Connecting & probing range support…");
        _speedLabel.text = @"…";
        [_actionBtn setImage:[UIImage systemImageNamed:@"pause.circle.fill"] forState:UIControlStateNormal];
        _actionBtn.tintColor = wq_theme_accent();
    } else if (item.state == WQDownloadStateQueued) {
        _metaLabel.text = WQLocalized(@"Queued");
        _speedLabel.text = @"";
        [_actionBtn setImage:[UIImage systemImageNamed:@"pause.circle"] forState:UIControlStateNormal];
        _actionBtn.tintColor = wq_theme_secondary_text();
    } else if (item.state == WQDownloadStatePaused) {
        _metaLabel.text = [NSString stringWithFormat:@"%@ · %@ / %@", WQLocalized(@"Paused"), dlText, totText];
        _speedLabel.text = [NSString stringWithFormat:@"%.0f%%", item.progress * 100.0];
        _speedLabel.textColor = UIColor.systemOrangeColor;
        [_actionBtn setImage:[UIImage systemImageNamed:@"play.circle.fill"] forState:UIControlStateNormal];
        _actionBtn.tintColor = UIColor.systemOrangeColor;
    } else if (item.state == WQDownloadStateFailed) {
        _metaLabel.text = item.errorMessage ?: WQLocalized(@"Failed");
        _speedLabel.text = WQLocalized(@"Retry");
        _speedLabel.textColor = UIColor.systemRedColor;
        [_actionBtn setImage:[UIImage systemImageNamed:@"arrow.clockwise.circle.fill"] forState:UIControlStateNormal];
        _actionBtn.tintColor = UIColor.systemRedColor;
    } else {
        _metaLabel.text = [NSString stringWithFormat:@"%@ · %@", item.category, totText];
        _speedLabel.text = WQLocalized(@"Done");
        _speedLabel.textColor = UIColor.systemGreenColor;
        [_actionBtn setImage:[UIImage systemImageNamed:@"ellipsis.circle"] forState:UIControlStateNormal];
        _actionBtn.tintColor = wq_theme_secondary_text();
    }
}

@end

#pragma mark - WQDownloadManagerViewController

@implementation WQDownloadManagerViewController {
    UISegmentedControl *_filter;
    NSArray<WQDownloadItem *> *_visible;
}

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = WQLocalized(@"Download Manager");
        self.hidesBottomBarWhenPushed = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone;
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
    [self.tableView registerClass:WQDownloadCell.class forCellReuseIdentifier:@"dl-cell"];

    __weak typeof(self) weakSelf = self;
    UIBarButtonItem *folderBtn = [[UIBarButtonItem alloc] initWithPrimaryAction:
        [UIAction actionWithTitle:WQLocalized(@"Folder") image:[UIImage systemImageNamed:@"folder.fill"] identifier:nil handler:^(UIAction *__unused a) {
        wq_haptic_selection();
        [weakSelf openDownloadsRootFolder];
    }]];
    UIBarButtonItem *browserBtn = [[UIBarButtonItem alloc] initWithPrimaryAction:
        [UIAction actionWithTitle:WQLocalized(@"Browser") image:[UIImage systemImageNamed:@"safari.fill"] identifier:nil handler:^(UIAction *__unused a) {
        wq_haptic_selection();
        [weakSelf.navigationController pushViewController:[[WQDownloadBrowserViewController alloc] initWithInitialURL:nil] animated:YES];
    }]];
    UIBarButtonItem *addBtn = [[UIBarButtonItem alloc] initWithPrimaryAction:
        [UIAction actionWithTitle:WQLocalized(@"Add") image:[UIImage systemImageNamed:@"plus.circle.fill"] identifier:nil handler:^(UIAction *__unused a) {
        [weakSelf showAddMenu];
    }]];
    self.navigationItem.rightBarButtonItems = @[addBtn, browserBtn, folderBtn];

    [self installFilterHeader];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadItems) name:WQDownloadManagerDidUpdateNotification object:nil];
    [self reloadItems];
}

- (void)openDownloadsRootFolder
{
    NSString *root = wq_downloads_root_dir();
    [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    WQDirViewController *dir = [[WQDirViewController alloc] initWithPath:root title:WQLocalized(@"Downloads")];
    [self.navigationController pushViewController:dir animated:YES];
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)installFilterHeader
{
    CGFloat w = self.tableView.bounds.size.width ?: self.view.bounds.size.width ?: 360.0;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 98)];
    box.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UIButton *locBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    locBtn.translatesAutoresizingMaskIntoConstraints = NO;
    locBtn.backgroundColor = [wq_theme_accent() colorWithAlphaComponent:0.12];
    locBtn.layer.cornerRadius = 12;
    locBtn.clipsToBounds = YES;
    locBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [locBtn setImage:[UIImage systemImageNamed:@"folder.badge.gearshape"] forState:UIControlStateNormal];
    [locBtn setTitle:WQLocalized(@"  Saved in: Documents/Downloads  ›") forState:UIControlStateNormal];
    locBtn.tintColor = wq_theme_accent();
    locBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [locBtn addTarget:self action:@selector(openDownloadsRootFolder) forControlEvents:UIControlEventTouchUpInside];
    [box addSubview:locBtn];

    _filter = [[UISegmentedControl alloc] initWithItems:@[
        WQLocalized(@"All"),
        WQLocalized(@"Active"),
        WQLocalized(@"Completed"),
    ]];
    _filter.translatesAutoresizingMaskIntoConstraints = NO;
    _filter.selectedSegmentIndex = 0;
    [_filter addTarget:self action:@selector(reloadItems) forControlEvents:UIControlEventValueChanged];
    [box addSubview:_filter];
    [NSLayoutConstraint activateConstraints:@[
        [locBtn.topAnchor constraintEqualToAnchor:box.topAnchor constant:8],
        [locBtn.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:16],
        [locBtn.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-16],
        [locBtn.heightAnchor constraintEqualToConstant:36],
        [_filter.topAnchor constraintEqualToAnchor:locBtn.bottomAnchor constant:8],
        [_filter.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-8],
        [_filter.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:16],
        [_filter.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-16],
    ]];
    self.tableView.tableHeaderView = box;
}

- (void)reloadItems
{
    NSArray<WQDownloadItem *> *all = WQDownloadManager.sharedManager.items;
    NSInteger mode = _filter ? _filter.selectedSegmentIndex : 0;
    NSMutableArray<WQDownloadItem *> *out = [NSMutableArray new];
    for (WQDownloadItem *it in all) {
        if (mode == 1 && it.state == WQDownloadStateCompleted) continue;
        if (mode == 2 && it.state != WQDownloadStateCompleted) continue;
        [out addObject:it];
    }
    BOOL sameOrder = (out.count == _visible.count && out.count > 0);
    if (sameOrder) {
        for (NSUInteger i = 0; i < out.count; i++) {
            if (![out[i].itemID isEqualToString:_visible[i].itemID]) {
                sameOrder = NO;
                break;
            }
        }
    }
    _visible = out;
    if (sameOrder) {
        // Update visible cells in-place for silky 60fps scrolling & unbroken swipe actions.
        for (NSIndexPath *ip in self.tableView.indexPathsForVisibleRows) {
            if (ip.row >= 0 && (NSUInteger)ip.row < _visible.count) {
                UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:ip];
                if ([cell isKindOfClass:WQDownloadCell.class]) {
                    [(WQDownloadCell *)cell configureWithItem:_visible[(NSUInteger)ip.row]];
                }
            }
        }
    } else {
        [self.tableView reloadData];
    }
}

- (void)showAddMenu
{
    wq_haptic_selection();
    UIAlertController *sheet = wq_alert_controller(WQLocalized(@"IDM Download Manager"), nil, UIAlertControllerStyleActionSheet);
    [sheet addAction:wq_alert_action(WQLocalized(@"Add Direct URL / HLS (.m3u8)…"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [self promptSingleURL];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Batch Import Multiple URLs…"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [self promptBatchURLs];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Open IDM Browser & Media Sniffer"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [self.navigationController pushViewController:[[WQDownloadBrowserViewController alloc] initWithInitialURL:nil] animated:YES];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Open Downloads Folder"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        WQDirViewController *dir = [[WQDirViewController alloc] initWithPath:wq_downloads_root_dir() title:WQLocalized(@"Downloads")];
        [self.navigationController pushViewController:dir animated:YES];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Download Settings (Parts / Speed / Wi-Fi)…"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [self showSettingsSheet];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Pause All Active"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [WQDownloadManager.sharedManager pauseAll];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Resume All Paused"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [WQDownloadManager.sharedManager resumeAll];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Clear Completed List"), UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
        [WQDownloadManager.sharedManager clearCompleted];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.firstObject;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)promptSingleURL
{
    NSString *clip = UIPasteboard.generalPasteboard.string;
    NSString *prefill = ([clip hasPrefix:@"http://"] || [clip hasPrefix:@"https://"]) ? clip : @"";
    UIAlertController *a = wq_alert_controller(WQLocalized(@"Add Download URL"),
                                               WQLocalized(@"Supports direct files, MP4/MP3/ZIP/IPA, and HLS (.m3u8) streams with Quality Picker."),
                                               UIAlertControllerStyleAlert);
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"https://example.com/file.zip";
        tf.text = prefill;
        tf.keyboardType = UIKeyboardTypeURL;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = WQLocalized(@"Optional custom Referer header");
        tf.keyboardType = UIKeyboardTypeURL;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [a addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    [a addAction:wq_alert_action(WQLocalized(@"Continue"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused act) {
        NSString *u = [a.textFields[0].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *ref = [a.textFields[1].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!u.length) return;
        NSDictionary *hdrs = ref.length ? @{ @"Referer": ref } : nil;
        if ([u.lowercaseString containsString:@".m3u8"]) {
            wq_present_hls_quality_picker(self, u, nil, hdrs);
        } else {
            wq_present_add_download_sheet(self, u, nil, -1, hdrs, NO, nil);
        }
    })];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)promptBatchURLs
{
    UIViewController *vc = [UIViewController new];
    vc.title = WQLocalized(@"Batch Import URLs");
    vc.view.backgroundColor = wq_theme_canvas_top();

    UITextView *tv = [UITextView new];
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    tv.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    tv.textColor = wq_theme_primary_text();
    tv.backgroundColor = [wq_theme_glass_tint() colorWithAlphaComponent:0.45];
    tv.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tv.autocorrectionType = UITextAutocorrectionTypeNo;
    tv.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    tv.text = @"";
    [vc.view addSubview:tv];
    [NSLayoutConstraint activateConstraints:@[
        [tv.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor constant:8],
        [tv.bottomAnchor constraintEqualToAnchor:vc.view.keyboardLayoutGuide.topAnchor constant:-8],
        [tv.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor constant:12],
        [tv.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor constant:-12],
    ]];

    __weak UIViewController *weakVC = vc;
    vc.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithPrimaryAction:
        [UIAction actionWithTitle:WQLocalized(@"Cancel") image:nil identifier:nil handler:^(UIAction *__unused a) {
        [weakVC dismissViewControllerAnimated:YES completion:nil];
    }]];
    vc.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithPrimaryAction:
        [UIAction actionWithTitle:WQLocalized(@"Enqueue") image:nil identifier:nil handler:^(UIAction *__unused a) {
        NSString *raw = tv.text ?: @"";
        [weakVC dismissViewControllerAnimated:YES completion:^{
            NSUInteger added = 0;
            for (NSString *line in [raw componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
                NSString *u = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if ([u hasPrefix:@"http://"] || [u hasPrefix:@"https://"]) {
                    [WQDownloadManager.sharedManager enqueueURLString:u
                                                    suggestedFilename:nil
                                                       destinationDir:nil
                                                              headers:nil
                                                            partCount:WQDownloadManager.sharedManager.defaultPartCount
                                                                isHLS:[u.lowercaseString containsString:@".m3u8"]
                                                         qualityLabel:nil
                                                             startNow:YES];
                    added++;
                }
            }
            if (added > 0) wq_haptic_notify(UINotificationFeedbackTypeSuccess);
        }];
    }]];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:^{ [tv becomeFirstResponder]; }];
}

- (void)showSettingsSheet
{
    WQDownloadManager *mgr = WQDownloadManager.sharedManager;
    NSString *speedStr = (mgr.speedLimitKBps == 0) ? WQLocalized(@"Unlimited") : [NSString stringWithFormat:@"%ld MB/s", (long)(mgr.speedLimitKBps / 1024)];
    UIAlertController *sheet = wq_alert_controller(WQLocalized(@"IDM Engine Settings"), nil, UIAlertControllerStyleActionSheet);
    [sheet addAction:wq_alert_action(WQLocalizedFormat(@"Parallel Parts per File: %ld (Tap to cycle 2/4/8/16)", (long)mgr.defaultPartCount), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        NSInteger p = mgr.defaultPartCount;
        mgr.defaultPartCount = (p == 2) ? 4 : (p == 4) ? 8 : (p == 8) ? 16 : 2;
        [self showSettingsSheet];
    })];
    [sheet addAction:wq_alert_action(WQLocalizedFormat(@"Max Simultaneous Downloads: %ld (1/2/3)", (long)mgr.maxConcurrentDownloads), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        NSInteger m = mgr.maxConcurrentDownloads;
        mgr.maxConcurrentDownloads = (m >= 3) ? 1 : (m + 1);
        [self showSettingsSheet];
    })];
    [sheet addAction:wq_alert_action(WQLocalizedFormat(@"Speed Limiter: %@", speedStr), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        NSInteger s = mgr.speedLimitKBps;
        mgr.speedLimitKBps = (s == 0) ? 1024 : (s == 1024) ? 2048 : (s == 2048) ? 5120 : 0;
        [self showSettingsSheet];
    })];
    [sheet addAction:wq_alert_action(mgr.wifiOnly ? WQLocalized(@"Wi-Fi Only Downloads: ON") : WQLocalized(@"Wi-Fi Only Downloads: OFF"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        mgr.wifiOnly = !mgr.wifiOnly;
        [self showSettingsSheet];
    })];
    [sheet addAction:wq_alert_action(WQLocalized(@"Done"), UIAlertActionStyleCancel, nil)];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.firstObject;
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark Post-Download Offline Pro Actions

- (void)extractAudioFromVideoPath:(NSString *)videoPath
{
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:videoPath] options:nil];
    AVAssetExportSession *exp = [[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPresetAppleM4A];
    if (!exp) {
        wq_alert(self, WQLocalized(@"Export Unavailable"), WQLocalized(@"Could not read audio track from this file."));
        return;
    }
    NSString *audioDir = [wq_downloads_root_dir() stringByAppendingPathComponent:@"Audio"];
    NSString *outName = [videoPath.lastPathComponent.stringByDeletingPathExtension stringByAppendingPathExtension:@"m4a"];
    NSString *outPath = wq_unique_file_path(audioDir, outName);
    exp.outputURL = [NSURL fileURLWithPath:outPath];
    exp.outputFileType = AVFileTypeAppleM4A;
    __weak typeof(self) weakSelf = self;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [exp exportAsynchronouslyWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            WQDownloadManagerViewController *me = weakSelf;
            if (!me) return;
            if (exp.status == AVAssetExportSessionStatusCompleted) {
                wq_haptic_notify(UINotificationFeedbackTypeSuccess);
                wq_alert(me, WQLocalized(@"Audio Extracted"), WQLocalizedFormat(@"Saved to Downloads/Audio/%@", outPath.lastPathComponent));
            } else {
                wq_alert(me, WQLocalized(@"Extraction Failed"), exp.error.localizedDescription ?: WQLocalized(@"Could not extract M4A audio."));
            }
        });
    }];
#pragma clang diagnostic pop
}

- (void)transcodeVideoPath:(NSString *)videoPath preset:(NSString *)preset label:(NSString *)label
{
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:videoPath] options:nil];
    AVAssetExportSession *exp = [[AVAssetExportSession alloc] initWithAsset:asset presetName:preset];
    if (!exp) {
        wq_alert(self, WQLocalized(@"Export Unavailable"), WQLocalized(@"This video format cannot be transcoded on device."));
        return;
    }
    NSString *outDir = videoPath.stringByDeletingLastPathComponent;
    NSString *outName = [NSString stringWithFormat:@"%@_%@.mp4", videoPath.lastPathComponent.stringByDeletingPathExtension, label];
    NSString *outPath = wq_unique_file_path(outDir, outName);
    exp.outputURL = [NSURL fileURLWithPath:outPath];
    exp.outputFileType = AVFileTypeMPEG4;
    exp.shouldOptimizeForNetworkUse = YES;
    __weak typeof(self) weakSelf = self;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [exp exportAsynchronouslyWithCompletionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            WQDownloadManagerViewController *me = weakSelf;
            if (!me) return;
            if (exp.status == AVAssetExportSessionStatusCompleted) {
                wq_haptic_notify(UINotificationFeedbackTypeSuccess);
                wq_alert(me, WQLocalized(@"Video Compressed"), WQLocalizedFormat(@"Saved %@", outPath.lastPathComponent));
            } else {
                wq_alert(me, WQLocalized(@"Compression Failed"), exp.error.localizedDescription ?: WQLocalized(@"Could not compress video."));
            }
        });
    }];
#pragma clang diagnostic pop
}

- (void)computeSHA256ForPath:(NSString *)path
{
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int fd = open(path.fileSystemRepresentation, O_RDONLY);
        if (fd < 0) return;
        CC_SHA256_CTX ctx;
        CC_SHA256_Init(&ctx);
        uint8_t buf[65536];
        ssize_t n = 0;
        while ((n = read(fd, buf, sizeof(buf))) > 0) {
            CC_SHA256_Update(&ctx, buf, (CC_LONG)n);
        }
        close(fd);
        uint8_t digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256_Final(digest, &ctx);
        NSMutableString *hex = [NSMutableString stringWithCapacity:64];
        for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
        dispatch_async(dispatch_get_main_queue(), ^{
            WQDownloadManagerViewController *me = weakSelf;
            if (!me) return;
            UIAlertController *a = wq_alert_controller(WQLocalized(@"SHA-256 Checksum"), WQVerbatim(hex), UIAlertControllerStyleAlert);
            [a addAction:wq_alert_action(WQLocalized(@"Copy Hash"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused act) {
                UIPasteboard.generalPasteboard.string = hex;
                wq_haptic_notify(UINotificationFeedbackTypeSuccess);
            })];
            [a addAction:wq_alert_action(WQLocalized(@"OK"), UIAlertActionStyleCancel, nil)];
            [me presentViewController:a animated:YES completion:nil];
        });
    });
}

- (void)showItemActions:(WQDownloadItem *)item sourceCell:(UITableViewCell *)cell
{
    WQDownloadManager *mgr = WQDownloadManager.sharedManager;
    NSString *subtitle = (item.state == WQDownloadStateCompleted && item.localPath.length)
        ? [NSString stringWithFormat:@"Saved in: Documents/Downloads/%@", item.category]
        : item.urlString;
    UIAlertController *sheet = wq_alert_controller(WQVerbatim(item.filename), WQVerbatim(subtitle), UIAlertControllerStyleActionSheet);

    if (item.state == WQDownloadStateCompleted && item.localPath.length) {
        NSString *ext = item.localPath.pathExtension.lowercaseString;
        if (wq_is_convertible_media_path(item.localPath)) {
            [sheet addAction:wq_alert_action(WQLocalized(@"Play Video / Audio"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
                [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback error:nil];
                AVPlayerViewController *p = [AVPlayerViewController new];
                p.player = [AVPlayer playerWithURL:[NSURL fileURLWithPath:item.localPath]];
                [self presentViewController:p animated:YES completion:^{ [p.player play]; }];
            })];
            [sheet addAction:wq_alert_action(WQLocalized(@"Convert Format & Encoding…"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
                wq_present_media_converter(self, item.localPath);
            })];
        }
        [sheet addAction:wq_alert_action(WQLocalized(@"Open Containing Folder"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            WQDirViewController *dir = [[WQDirViewController alloc] initWithPath:item.localPath.stringByDeletingLastPathComponent title:item.category];
            [self.navigationController pushViewController:dir animated:YES];
        })];
        [sheet addAction:wq_alert_action(WQLocalized(@"Share / Open In…"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:item.localPath]] applicationActivities:nil];
            share.popoverPresentationController.sourceView = cell ?: self.view;
            [self presentViewController:share animated:YES completion:nil];
        })];
        if ([ext isEqualToString:@"mp4"] || [ext isEqualToString:@"mov"] || [ext isEqualToString:@"m4v"]) {
            [sheet addAction:wq_alert_action(WQLocalized(@"Quick Extract Audio (.m4a)"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
                [self extractAudioFromVideoPath:item.localPath];
            })];
            [sheet addAction:wq_alert_action(WQLocalized(@"Quick Compress 720p (.mp4)"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
                [self transcodeVideoPath:item.localPath preset:AVAssetExportPreset1280x720 label:@"720p"];
            })];
            [sheet addAction:wq_alert_action(WQLocalized(@"Quick Compress 480p (.mp4)"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
                [self transcodeVideoPath:item.localPath preset:AVAssetExportPreset640x480 label:@"480p"];
            })];
        }
        if ([ext isEqualToString:@"zip"] || [ext isEqualToString:@"ipa"]) {
            [sheet addAction:wq_alert_action(WQLocalized(@"Extract Archive Here"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
                NSString *outDir = wq_unique_file_path(item.localPath.stringByDeletingLastPathComponent, item.localPath.lastPathComponent.stringByDeletingPathExtension);
                [NSFileManager.defaultManager createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    NSString *err = nil;
                    BOOL ok = wq_zip_extract(item.localPath, outDir, wq_archive_posix_io(), 2ULL * 1024ULL * 1024ULL * 1024ULL, nil, nil, NULL, NULL, &err);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        wq_haptic_notify(ok ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeError);
                        if (ok) {
                            WQDirViewController *dir = [[WQDirViewController alloc] initWithPath:outDir title:outDir.lastPathComponent];
                            [self.navigationController pushViewController:dir animated:YES];
                        } else {
                            wq_alert(self, WQLocalized(@"Extraction Failed"), err ?: WQLocalized(@"Could not extract archive."));
                        }
                    });
                });
            })];
        }
        [sheet addAction:wq_alert_action(WQLocalized(@"Verify SHA-256 Checksum"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            [self computeSHA256ForPath:item.localPath];
        })];
        [sheet addAction:wq_alert_action(WQLocalized(@"Encrypt in .wqenc Locker…"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            wq_present_crypto_tools(self, item.localPath);
        })];
        [sheet addAction:wq_alert_action(WQLocalized(@"Delete Entry & File"), UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
            [mgr deleteItem:item removeFile:YES];
        })];
    } else {
        if (item.state == WQDownloadStateDownloading || item.state == WQDownloadStateProbing || item.state == WQDownloadStateQueued) {
            [sheet addAction:wq_alert_action(WQLocalized(@"Pause Download"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
                [mgr pauseItem:item];
            })];
        } else {
            [sheet addAction:wq_alert_action(WQLocalized(@"Resume Download"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
                [mgr startOrResumeItem:item];
            })];
        }
        [sheet addAction:wq_alert_action(WQLocalized(@"Refresh Download Address (IDM)…"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            UIAlertController *ed = wq_alert_controller(WQLocalized(@"Refresh Download Address"),
                                                        WQLocalized(@"Paste a fresh link to resume this partial download from where it stopped."),
                                                        UIAlertControllerStyleAlert);
            [ed addTextFieldWithConfigurationHandler:^(UITextField *tf) {
                tf.text = item.urlString;
                tf.keyboardType = UIKeyboardTypeURL;
                tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
            }];
            [ed addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
            [ed addAction:wq_alert_action(WQLocalized(@"Resume with New Link"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused b) {
                NSString *nu = ed.textFields.firstObject.text;
                if (nu.length) [mgr refreshAddressForItem:item newURLString:nu newHeaders:nil];
            })];
            [self presentViewController:ed animated:YES completion:nil];
        })];
        [sheet addAction:wq_alert_action(WQLocalized(@"Copy Download URL"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            UIPasteboard.generalPasteboard.string = item.urlString;
            wq_haptic_notify(UINotificationFeedbackTypeSuccess);
        })];
        [sheet addAction:wq_alert_action(WQLocalized(@"Cancel & Delete"), UIAlertActionStyleDestructive, ^(UIAlertAction *__unused a) {
            [mgr deleteItem:item removeFile:YES];
        })];
    }

    [sheet addAction:wq_alert_action(WQLocalized(@"Cancel"), UIAlertActionStyleCancel, nil)];
    sheet.popoverPresentationController.sourceView = cell ?: self.view;
    sheet.popoverPresentationController.sourceRect = (cell ?: self.view).bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark TableView DataSource & Delegate

- (NSInteger)numberOfSectionsInTableView:(UITableView *__unused)tableView { return 1; }

- (NSInteger)tableView:(UITableView *__unused)tableView numberOfRowsInSection:(NSInteger __unused)section
{
    return MAX(1, (NSInteger)_visible.count);
}

- (NSString *)tableView:(UITableView *__unused)tableView titleForHeaderInSection:(NSInteger __unused)section
{
    WQDownloadManager *mgr = WQDownloadManager.sharedManager;
    return WQLocalizedFormat(@"%lu Items · %ld Parts · Max %ld Concurrent%@",
                             (unsigned long)_visible.count,
                             (long)mgr.defaultPartCount,
                             (long)mgr.maxConcurrentDownloads,
                             mgr.wifiOnly ? @" · Wi-Fi Only" : @"");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (!_visible.count) {
        UITableViewCell *empty = [tableView dequeueReusableCellWithIdentifier:@"dl-empty"]
            ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"dl-empty"];
        UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
        c.text = WQLocalized(@"No Downloads Yet");
        c.secondaryText = WQLocalized(@"Tap Safari icon to open the 1DM/IDM Browser & Media Sniffer, or tap + to add any file or HLS (.m3u8) URL.");
        c.secondaryTextProperties.numberOfLines = 3;
        c.image = [UIImage systemImageNamed:@"arrow.down.circle"];
        c.imageProperties.tintColor = wq_theme_accent();
        empty.contentConfiguration = c;
        empty.selectionStyle = UITableViewCellSelectionStyleNone;
        return empty;
    }
    WQDownloadCell *cell = [tableView dequeueReusableCellWithIdentifier:@"dl-cell" forIndexPath:indexPath];
    WQDownloadItem *item = _visible[(NSUInteger)indexPath.row];
    __weak typeof(self) weakSelf = self;
    __weak UITableViewCell *weakCell = cell;
    [cell configureWithItem:item onToggle:^{
        wq_haptic_selection();
        WQDownloadManager *mgr = WQDownloadManager.sharedManager;
        if (item.state == WQDownloadStateDownloading || item.state == WQDownloadStateProbing || item.state == WQDownloadStateQueued) {
            [mgr pauseItem:item];
        } else if (item.state == WQDownloadStatePaused) {
            [mgr startOrResumeItem:item];
        } else if (item.state == WQDownloadStateFailed) {
            [mgr retryItem:item];
        } else {
            [weakSelf showItemActions:item sourceCell:weakCell];
        }
    }];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!_visible.count) return;
    wq_haptic_selection();
    WQDownloadItem *item = _visible[(NSUInteger)indexPath.row];
    [self showItemActions:item sourceCell:[tableView cellForRowAtIndexPath:indexPath]];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *__unused)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (!_visible.count) return nil;
    WQDownloadItem *item = _visible[(NSUInteger)indexPath.row];
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                      title:WQLocalized(@"Delete")
                                                                    handler:^(UIContextualAction *__unused a, UIView *__unused s, void (^done)(BOOL)) {
        [WQDownloadManager.sharedManager deleteItem:item removeFile:YES];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

@end
