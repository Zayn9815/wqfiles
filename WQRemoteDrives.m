//
//  WQRemoteDrives.m
//  WQ Glass Remote Drives Client (WebDAV HTTP/HTTPS & FTP via BSD Sockets)
//  GPL-3.0-or-later.
//

#import "WQRemoteDrives.h"
#import "WQAccess.h"
#import "WQCore.h"
#import "WQLocalization.h"
#import "WQMediaStream.h"
#import "WQProMediaPlayer.h"
#import "WQTheme.h"
#import "WQUI.h"
#import <Security/Security.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <sys/socket.h>
#import <unistd.h>

static NSString *const kWQRemoteDrivesPref = @"WQRemoteDrivesBookmarks";
static NSString *const kWQKeychainService = @"com.zayn.wqglass.remotedrives";

@implementation WQRemoteDriveBookmark
@end

@interface WQRemoteItem : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *remotePath;
@property (nonatomic) BOOL isDirectory;
@property (nonatomic) unsigned long long size;
@end

@implementation WQRemoteItem
@end

#pragma mark - Keychain Credential Storage

static void wq_rd_keychain_set(NSString *account, NSString *password)
{
    if (!account.length) return;
    NSData *pwData = [password ?: @"" dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kWQKeychainService,
        (__bridge id)kSecAttrAccount: account,
    };
    SecItemDelete((__bridge CFDictionaryRef)query);
    if (!pwData.length) return;
    NSMutableDictionary *add = [query mutableCopy];
    add[(__bridge id)kSecValueData] = pwData;
    add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    SecItemAdd((__bridge CFDictionaryRef)add, NULL);
}

static NSString *wq_rd_keychain_get(NSString *account)
{
    if (!account.length) return @"";
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kWQKeychainService,
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    };
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) == errSecSuccess && result) {
        NSData *data = (__bridge_transfer NSData *)result;
        return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    }
    return @"";
}

#pragma mark - Bookmark Persistence

static NSArray<WQRemoteDriveBookmark *> *wq_rd_load_bookmarks(void)
{
    NSArray *raw = [NSUserDefaults.standardUserDefaults arrayForKey:kWQRemoteDrivesPref];
    NSMutableArray<WQRemoteDriveBookmark *> *out = [NSMutableArray new];
    if (![raw isKindOfClass:NSArray.class]) return out;
    for (id obj in raw) {
        if (![obj isKindOfClass:NSDictionary.class]) continue;
        WQRemoteDriveBookmark *b = [WQRemoteDriveBookmark new];
        b.driveID = [obj[@"id"] isKindOfClass:NSString.class] ? obj[@"id"] : NSUUID.UUID.UUIDString;
        b.name = [obj[@"name"] isKindOfClass:NSString.class] ? obj[@"name"] : @"Drive";
        b.protocol = [obj[@"protocol"] isKindOfClass:NSString.class] ? obj[@"protocol"] : @"webdav";
        b.host = [obj[@"host"] isKindOfClass:NSString.class] ? obj[@"host"] : @"";
        b.port = [obj[@"port"] integerValue];
        b.useTLS = [obj[@"useTLS"] boolValue];
        b.basePath = [obj[@"basePath"] isKindOfClass:NSString.class] ? obj[@"basePath"] : @"/";
        b.username = [obj[@"username"] isKindOfClass:NSString.class] ? obj[@"username"] : @"";
        [out addObject:b];
    }
    return out;
}

static void wq_rd_save_bookmarks(NSArray<WQRemoteDriveBookmark *> *list)
{
    NSMutableArray *raw = [NSMutableArray arrayWithCapacity:list.count];
    for (WQRemoteDriveBookmark *b in list) {
        [raw addObject:@{
            @"id": b.driveID ?: NSUUID.UUID.UUIDString,
            @"name": b.name ?: @"Drive",
            @"protocol": b.protocol ?: @"webdav",
            @"host": b.host ?: @"",
            @"port": @(b.port),
            @"useTLS": @(b.useTLS),
            @"basePath": b.basePath ?: @"/",
            @"username": b.username ?: @"",
        }];
    }
    [NSUserDefaults.standardUserDefaults setObject:raw forKey:kWQRemoteDrivesPref];
}

#pragma mark - WebDAV XML Parser

@interface WQWebDAVParser : NSObject <NSXMLParserDelegate>
@property (nonatomic, copy) NSString *basePath;
@property (nonatomic, strong) NSMutableArray<WQRemoteItem *> *items;
@end

@implementation WQWebDAVParser {
    NSMutableString *_buf;
    NSString *_href;
    BOOL _isDir;
    unsigned long long _size;
    BOOL _inPropStat;
}

- (instancetype)initWithBasePath:(NSString *)basePath
{
    if ((self = [super init])) {
        _basePath = [basePath copy];
        _items = [NSMutableArray new];
    }
    return self;
}

- (void)parser:(NSXMLParser *__unused)parser didStartElement:(NSString *)el namespaceURI:(NSString *__unused)ns
 qualifiedName:(NSString *__unused)qName attributes:(NSDictionary<NSString *, NSString *> *__unused)attrs
{
    NSString *local = [el componentsSeparatedByString:@":"].lastObject.lowercaseString;
    if ([local isEqualToString:@"response"]) {
        _href = nil;
        _isDir = NO;
        _size = 0;
    } else if ([local isEqualToString:@"collection"]) {
        _isDir = YES;
    } else if ([local isEqualToString:@"propstat"]) {
        _inPropStat = YES;
    }
    _buf = [NSMutableString new];
}

- (void)parser:(NSXMLParser *__unused)parser foundCharacters:(NSString *)string
{
    [_buf appendString:string];
}

- (void)parser:(NSXMLParser *__unused)parser didEndElement:(NSString *)el namespaceURI:(NSString *__unused)ns qualifiedName:(NSString *__unused)qName
{
    NSString *local = [el componentsSeparatedByString:@":"].lastObject.lowercaseString;
    NSString *val = [_buf stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([local isEqualToString:@"href"]) {
        _href = val;
    } else if (_inPropStat && [local isEqualToString:@"getcontentlength"]) {
        _size = (unsigned long long)val.longLongValue;
    } else if ([local isEqualToString:@"propstat"]) {
        _inPropStat = NO;
    } else if ([local isEqualToString:@"response"]) {
        if (_href.length) {
            NSURL *u = [NSURL URLWithString:_href];
            NSString *decoded = (u ? u.path : _href).stringByRemovingPercentEncoding ?: _href;
            NSString *trimBase = [_basePath stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
            NSString *trimDec = [decoded stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
            if (![trimBase isEqualToString:trimDec]) {
                NSString *name = decoded.lastPathComponent;
                if (name.length && ![name isEqualToString:@"/"]) {
                    WQRemoteItem *it = [WQRemoteItem new];
                    it.name = name;
                    it.remotePath = decoded;
                    it.isDirectory = _isDir || [_href hasSuffix:@"/"];
                    it.size = _size;
                    [_items addObject:it];
                }
            }
        }
    }
    _buf = nil;
}

@end

#pragma mark - BSD Socket FTP Client (Zero Deprecated CFStream APIs)

static int wq_ftp_connect_tcp(NSString *host, NSInteger port, NSString **errOut)
{
    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    char portStr[16];
    snprintf(portStr, sizeof(portStr), "%ld", (long)port);
    int rc = getaddrinfo(host.UTF8String, portStr, &hints, &res);
    if (rc != 0 || !res) {
        if (errOut) *errOut = [NSString stringWithFormat:@"DNS failed: %s", gai_strerror(rc)];
        return -1;
    }
    int fd = -1;
    for (struct addrinfo *p = res; p; p = p->ai_next) {
        fd = socket(p->ai_family, p->ai_socktype, p->ai_protocol);
        if (fd < 0) continue;
        struct timeval tv = { .tv_sec = 12, .tv_usec = 0 };
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
        if (connect(fd, p->ai_addr, p->ai_addrlen) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0 && errOut) *errOut = @(strerror(errno));
    return fd;
}

static NSString *wq_ftp_read_reply(int fd, int *codeOut)
{
    NSMutableString *reply = [NSMutableString new];
    char buf[2048];
    int code = 0;
    for (;;) {
        ssize_t n = recv(fd, buf, sizeof(buf) - 1, 0);
        if (n <= 0) break;
        buf[n] = 0;
        NSString *chunk = @(buf) ?: @"";
        [reply appendString:chunk];
        NSArray<NSString *> *lines = [reply componentsSeparatedByString:@"\n"];
        BOOL done = NO;
        for (NSString *line in lines) {
            NSString *trim = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (trim.length >= 4 && isdigit([trim characterAtIndex:0]) && isdigit([trim characterAtIndex:1]) &&
                isdigit([trim characterAtIndex:2]) && [trim characterAtIndex:3] == ' ') {
                code = [[trim substringToIndex:3] intValue];
                done = YES;
            }
        }
        if (done) break;
    }
    if (codeOut) *codeOut = code;
    return reply;
}

static BOOL wq_ftp_send_cmd(int fd, NSString *cmd, int *codeOut, NSString **replyOut)
{
    NSData *d = [[cmd stringByAppendingString:@"\r\n"] dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *p = d.bytes;
    size_t rem = d.length;
    while (rem > 0) {
        ssize_t w = send(fd, p, rem, 0);
        if (w <= 0) return NO;
        p += w;
        rem -= (size_t)w;
    }
    NSString *rep = wq_ftp_read_reply(fd, codeOut);
    if (replyOut) *replyOut = rep;
    return rep.length > 0;
}

static int wq_ftp_open_pasv(int ctrlFd, NSString *fallbackHost, NSString **errOut)
{
    int code = 0;
    NSString *rep = nil;
    if (!wq_ftp_send_cmd(ctrlFd, @"PASV", &code, &rep) || code != 227) {
        if (errOut) *errOut = rep ?: @"PASV failed";
        return -1;
    }
    NSRange open = [rep rangeOfString:@"("];
    NSRange closeP = [rep rangeOfString:@")"];
    if (open.location == NSNotFound || closeP.location == NSNotFound || closeP.location <= open.location) {
        if (errOut) *errOut = @"Invalid PASV response";
        return -1;
    }
    NSString *inside = [rep substringWithRange:NSMakeRange(open.location + 1, closeP.location - open.location - 1)];
    NSArray<NSString *> *nums = [inside componentsSeparatedByString:@","];
    if (nums.count < 6) return -1;
    NSString *ip = [NSString stringWithFormat:@"%@.%@.%@.%@", nums[0], nums[1], nums[2], nums[3]];
    NSInteger port = nums[4].integerValue * 256 + nums[5].integerValue;
    if ([ip isEqualToString:@"0.0.0.0"]) ip = fallbackHost;
    return wq_ftp_connect_tcp(ip, port, errOut);
}

static int wq_ftp_login(WQRemoteDriveBookmark *bm, NSString **errOut)
{
    NSInteger port = bm.port > 0 ? bm.port : 21;
    int fd = wq_ftp_connect_tcp(bm.host, port, errOut);
    if (fd < 0) return -1;
    int code = 0;
    wq_ftp_read_reply(fd, &code);
    NSString *user = bm.username.length ? bm.username : @"anonymous";
    NSString *pw = wq_rd_keychain_get(bm.driveID);
    NSString *rep = nil;
    wq_ftp_send_cmd(fd, [@"USER " stringByAppendingString:user], &code, &rep);
    if (code == 331) {
        wq_ftp_send_cmd(fd, [@"PASS " stringByAppendingString:(pw.length ? pw : @"wqglass@local")], &code, &rep);
    }
    if (code < 200 || code >= 300) {
        if (errOut) *errOut = rep ?: @"FTP login failed";
        close(fd);
        return -1;
    }
    wq_ftp_send_cmd(fd, @"TYPE I", &code, nil);
    return fd;
}

#pragma mark - Remote Directory Browser

@interface WQRemoteBrowserViewController : UITableViewController <UIDocumentPickerDelegate>
- (instancetype)initWithBookmark:(WQRemoteDriveBookmark *)bookmark remotePath:(NSString *)remotePath;
@end

@implementation WQRemoteBrowserViewController {
    WQRemoteDriveBookmark *_bm;
    NSString *_remotePath;
    NSArray<WQRemoteItem *> *_items;
    NSString *_status;
}

- (instancetype)initWithBookmark:(WQRemoteDriveBookmark *)bookmark remotePath:(NSString *)remotePath
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _bm = bookmark;
        _remotePath = remotePath.length ? [remotePath copy] : @"/";
        self.title = [_remotePath isEqualToString:@"/"] ? bookmark.name : _remotePath.lastPathComponent;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    wq_prism_install_background(self);
    self.tableView.backgroundColor = UIColor.clearColor;
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(reloadRemote) forControlEvents:UIControlEventValueChanged];

    __weak typeof(self) weakSelf = self;
    UIMenu *actionsMenu = [UIMenu menuWithChildren:@[
        [UIAction actionWithTitle:WQLocalized(@"Upload File…") image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(UIAction *__unused a) {
            [weakSelf pickUploadFile];
        }],
        [UIAction actionWithTitle:WQLocalizedNullable(@"New Folder") image:[UIImage systemImageNamed:@"folder.badge.plus"] identifier:nil handler:^(UIAction *__unused a) {
            [weakSelf promptNewRemoteFolder];
        }],
    ]];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus.circle"] menu:actionsMenu];
    [self reloadRemote];
}

- (NSURL *)webdavURLForPath:(NSString *)path
{
    NSString *scheme = _bm.useTLS ? @"https" : @"http";
    NSInteger port = _bm.port > 0 ? _bm.port : (_bm.useTLS ? 443 : 80);
    NSString *cleanPath = [path hasPrefix:@"/"] ? path : [@"/" stringByAppendingString:path];
    NSString *encoded = [cleanPath stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet] ?: cleanPath;
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@:%ld%@", scheme, _bm.host, (long)port, encoded]];
}

- (NSMutableURLRequest *)webdavRequestWithMethod:(NSString *)method path:(NSString *)path
{
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[self webdavURLForPath:path]];
    req.HTTPMethod = method;
    req.timeoutInterval = 20;
    if (_bm.username.length) {
        NSString *pw = wq_rd_keychain_get(_bm.driveID);
        NSString *creds = [NSString stringWithFormat:@"%@:%@", _bm.username, pw];
        NSString *b64 = [[creds dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
        [req setValue:[@"Basic " stringByAppendingString:b64] forHTTPHeaderField:@"Authorization"];
    }
    return req;
}

- (void)reloadRemote
{
    _status = WQLocalized(@"Loading remote folder…");
    [self.tableView reloadData];

    if ([_bm.protocol isEqualToString:@"ftp"]) {
        WQRemoteDriveBookmark *bm = _bm;
        NSString *rPath = _remotePath;
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSString *err = nil;
            int ctrl = wq_ftp_login(bm, &err);
            NSMutableArray<WQRemoteItem *> *parsed = [NSMutableArray new];
            if (ctrl >= 0) {
                int code = 0;
                wq_ftp_send_cmd(ctrl, [@"CWD " stringByAppendingString:rPath], &code, nil);
                int dataFd = wq_ftp_open_pasv(ctrl, bm.host, &err);
                if (dataFd >= 0) {
                    wq_ftp_send_cmd(ctrl, @"LIST", &code, nil);
                    NSMutableData *raw = [NSMutableData new];
                    char buf[4096];
                    for (;;) {
                        ssize_t n = recv(dataFd, buf, sizeof(buf), 0);
                        if (n <= 0) break;
                        [raw appendBytes:buf length:(NSUInteger)n];
                    }
                    close(dataFd);
                    wq_ftp_read_reply(ctrl, &code);
                    NSString *listing = [[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding]
                                        ?: [[NSString alloc] initWithData:raw encoding:NSISOLatin1StringEncoding] ?: @"";
                    for (NSString *line in [listing componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
                        NSString *trim = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                        if (trim.length < 10) continue;
                        BOOL isDir = [trim hasPrefix:@"d"];
                        NSArray<NSString *> *cols = [trim componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                        NSMutableArray<NSString *> *nonEmpty = [NSMutableArray new];
                        for (NSString *c in cols) if (c.length) [nonEmpty addObject:c];
                        if (nonEmpty.count < 9) continue;
                        NSString *name = [[nonEmpty subarrayWithRange:NSMakeRange(8, nonEmpty.count - 8)] componentsJoinedByString:@" "];
                        if ([name isEqualToString:@"."] || [name isEqualToString:@".."]) continue;
                        WQRemoteItem *it = [WQRemoteItem new];
                        it.name = name;
                        it.remotePath = [rPath isEqualToString:@"/"] ? [@"/" stringByAppendingString:name] : [rPath stringByAppendingPathComponent:name];
                        it.isDirectory = isDir;
                        it.size = (unsigned long long)nonEmpty[4].longLongValue;
                        [parsed addObject:it];
                    }
                }
                wq_ftp_send_cmd(ctrl, @"QUIT", &code, nil);
                close(ctrl);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                WQRemoteBrowserViewController *me = weakSelf;
                if (!me) return;
                [me.refreshControl endRefreshing];
                me->_items = [parsed sortedArrayUsingComparator:^NSComparisonResult(WQRemoteItem *a, WQRemoteItem *b) {
                    if (a.isDirectory != b.isDirectory) return a.isDirectory ? NSOrderedAscending : NSOrderedDescending;
                    return [a.name localizedStandardCompare:b.name];
                }];
                me->_status = err ?: (me->_items.count ? nil : WQLocalized(@"Remote folder is empty."));
                [me.tableView reloadData];
            });
        });
        return;
    }

    NSMutableURLRequest *req = [self webdavRequestWithMethod:@"PROPFIND" path:_remotePath];
    [req setValue:@"1" forHTTPHeaderField:@"Depth"];
    [req setValue:@"application/xml" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [@"<?xml version=\"1.0\" encoding=\"utf-8\"?><D:propfind xmlns:D=\"DAV:\"><D:allprop/></D:propfind>" dataUsingEncoding:NSUTF8StringEncoding];
    __weak typeof(self) weakSelf = self;
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSInteger code = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        NSArray<WQRemoteItem *> *items = @[];
        NSString *errMsg = err.localizedDescription;
        if (!err && (code == 207 || code == 200) && data.length) {
            WQWebDAVParser *parser = [[WQWebDAVParser alloc] initWithBasePath:self->_remotePath];
            NSXMLParser *xml = [[NSXMLParser alloc] initWithData:data];
            xml.delegate = parser;
            [xml parse];
            items = [parser.items sortedArrayUsingComparator:^NSComparisonResult(WQRemoteItem *a, WQRemoteItem *b) {
                if (a.isDirectory != b.isDirectory) return a.isDirectory ? NSOrderedAscending : NSOrderedDescending;
                return [a.name localizedStandardCompare:b.name];
            }];
            errMsg = nil;
        } else if (!errMsg && code >= 400) {
            errMsg = [NSString stringWithFormat:@"HTTP %ld", (long)code];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            WQRemoteBrowserViewController *me = weakSelf;
            if (!me) return;
            [me.refreshControl endRefreshing];
            me->_items = items;
            me->_status = errMsg ?: (items.count ? nil : WQLocalized(@"Remote folder is empty."));
            [me.tableView reloadData];
        });
    }] resume];
}

- (void)downloadRemoteItem:(WQRemoteItem *)item streamMedia:(BOOL)stream
{
    NSString *dl = NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    [NSFileManager.defaultManager createDirectoryAtPath:dl withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *localDest = [dl stringByAppendingPathComponent:item.name];

    if (stream && [_bm.protocol isEqualToString:@"webdav"]) {
        NSMutableURLRequest *req = [self webdavRequestWithMethod:@"GET" path:item.remotePath];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:req.URL options:@{ @"AVURLAssetHTTPHeaderFieldsKey": req.allHTTPHeaderFields ?: @{} }];
        AVPlayerItem *pi = [AVPlayerItem playerItemWithAsset:asset];
        WQProMediaPlayerViewController *player = [[WQProMediaPlayerViewController alloc] initWithTitle:item.name sourcePath:item.remotePath];
        [self.navigationController pushViewController:player animated:YES];
        [player loadPlayerItem:pi];
        return;
    }

    __weak typeof(self) weakSelf = self;
    if ([_bm.protocol isEqualToString:@"ftp"]) {
        WQRemoteDriveBookmark *bm = _bm;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSString *err = nil;
            int ctrl = wq_ftp_login(bm, &err);
            BOOL ok = NO;
            if (ctrl >= 0) {
                int dataFd = wq_ftp_open_pasv(ctrl, bm.host, &err);
                if (dataFd >= 0) {
                    int code = 0;
                    wq_ftp_send_cmd(ctrl, [@"RETR " stringByAppendingString:item.remotePath], &code, nil);
                    NSMutableData *out = [NSMutableData new];
                    char buf[8192];
                    for (;;) {
                        ssize_t n = recv(dataFd, buf, sizeof(buf), 0);
                        if (n <= 0) break;
                        [out appendBytes:buf length:(NSUInteger)n];
                    }
                    close(dataFd);
                    wq_ftp_read_reply(ctrl, &code);
                    ok = [out writeToFile:localDest atomically:YES];
                }
                int qCode = 0;
                wq_ftp_send_cmd(ctrl, @"QUIT", &qCode, nil);
                close(ctrl);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                WQRemoteBrowserViewController *me = weakSelf;
                if (!me) return;
                if (ok && stream) {
                    WQProMediaPlayerViewController *player = [[WQProMediaPlayerViewController alloc] initWithTitle:item.name sourcePath:localDest];
                    [me.navigationController pushViewController:player animated:YES];
                    [player replaceWithLocalURL:[NSURL fileURLWithPath:localDest]];
                } else {
                    wq_alert(me, ok ? WQLocalized(@"Downloaded") : WQLocalized(@"Download Failed"), ok ? localDest : err);
                }
            });
        });
        return;
    }

    NSMutableURLRequest *req = [self webdavRequestWithMethod:@"GET" path:item.remotePath];
    [[NSURLSession.sharedSession downloadTaskWithRequest:req completionHandler:^(NSURL *tmp, NSURLResponse *__unused r, NSError *err) {
        BOOL ok = NO;
        if (!err && tmp) {
            [NSFileManager.defaultManager removeItemAtPath:localDest error:nil];
            ok = [NSFileManager.defaultManager moveItemAtURL:tmp toURL:[NSURL fileURLWithPath:localDest] error:nil];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            WQRemoteBrowserViewController *me = weakSelf;
            if (!me) return;
            wq_alert(me, ok ? WQLocalized(@"Downloaded") : WQLocalized(@"Download Failed"), ok ? localDest : err.localizedDescription);
        });
    }] resume];
}

- (void)pickUploadFile
{
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *__unused)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    NSURL *u = urls.firstObject;
    if (!u) return;
    NSData *data = [NSData dataWithContentsOfURL:u];
    if (!data.length) return;
    NSString *target = [_remotePath isEqualToString:@"/"]
        ? [@"/" stringByAppendingString:u.lastPathComponent]
        : [_remotePath stringByAppendingPathComponent:u.lastPathComponent];
    __weak typeof(self) weakSelf = self;

    if ([_bm.protocol isEqualToString:@"ftp"]) {
        WQRemoteDriveBookmark *bm = _bm;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSString *err = nil;
            int ctrl = wq_ftp_login(bm, &err);
            BOOL ok = NO;
            if (ctrl >= 0) {
                int dataFd = wq_ftp_open_pasv(ctrl, bm.host, &err);
                if (dataFd >= 0) {
                    int code = 0;
                    wq_ftp_send_cmd(ctrl, [@"STOR " stringByAppendingString:target], &code, nil);
                    const uint8_t *p = data.bytes;
                    size_t rem = data.length;
                    ok = YES;
                    while (rem > 0) {
                        ssize_t w = send(dataFd, p, rem, 0);
                        if (w <= 0) { ok = NO; break; }
                        p += w; rem -= (size_t)w;
                    }
                    close(dataFd);
                    wq_ftp_read_reply(ctrl, &code);
                }
                int qCode = 0;
                wq_ftp_send_cmd(ctrl, @"QUIT", &qCode, nil);
                close(ctrl);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf reloadRemote];
                if (!ok) wq_alert(weakSelf, WQLocalized(@"Upload Failed"), err);
            });
        });
        return;
    }

    NSMutableURLRequest *req = [self webdavRequestWithMethod:@"PUT" path:target];
    [[NSURLSession.sharedSession uploadTaskWithRequest:req fromData:data completionHandler:^(NSData *__unused d, NSURLResponse *__unused r, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf reloadRemote];
            if (err) wq_alert(weakSelf, WQLocalized(@"Upload Failed"), err.localizedDescription);
        });
    }] resume];
}

- (void)promptNewRemoteFolder
{
    UIAlertController *a = wq_alert_controller(WQLocalizedNullable(@"New Folder"), nil, UIAlertControllerStyleAlert);
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = WQLocalizedNullable(@"Name"); }];
    [a addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [a addAction:wq_alert_action(@"Create", UIAlertActionStyleDefault, ^(UIAlertAction *__unused act) {
        NSString *name = a.textFields.firstObject.text;
        if (!name.length) return;
        NSString *target = [self->_remotePath isEqualToString:@"/"] ? [@"/" stringByAppendingString:name] : [self->_remotePath stringByAppendingPathComponent:name];
        __weak typeof(self) weakSelf = self;
        if ([self->_bm.protocol isEqualToString:@"ftp"]) {
            WQRemoteDriveBookmark *bm = self->_bm;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                int ctrl = wq_ftp_login(bm, nil);
                if (ctrl >= 0) {
                    int c = 0;
                    wq_ftp_send_cmd(ctrl, [@"MKD " stringByAppendingString:target], &c, nil);
                    wq_ftp_send_cmd(ctrl, @"QUIT", &c, nil);
                    close(ctrl);
                }
                dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf reloadRemote]; });
            });
            return;
        }
        NSMutableURLRequest *req = [self webdavRequestWithMethod:@"MKCOL" path:target];
        [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *__unused d, NSURLResponse *__unused r, NSError *__unused e) {
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf reloadRemote]; });
        }] resume];
    })];
    [self presentViewController:a animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *__unused)tableView numberOfRowsInSection:(NSInteger __unused)section
{
    return _status ? 1 : (NSInteger)_items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"rd-item"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"rd-item"];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    if (_status) {
        c.text = _status;
        c.textProperties.color = wq_theme_secondary_text();
        cell.contentConfiguration = c;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    WQRemoteItem *it = _items[(NSUInteger)indexPath.row];
    c.text = it.name;
    c.secondaryText = it.isDirectory ? WQLocalized(@"Folder") : wq_size_text(it.size);
    c.image = [UIImage systemImageNamed:it.isDirectory ? @"folder.fill" : @"doc.fill"];
    c.imageProperties.tintColor = it.isDirectory ? wq_theme_accent() : wq_theme_secondary_text();
    cell.contentConfiguration = c;
    cell.accessoryType = it.isDirectory ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_status) return;
    WQRemoteItem *it = _items[(NSUInteger)indexPath.row];
    if (it.isDirectory) {
        WQRemoteBrowserViewController *next = [[WQRemoteBrowserViewController alloc] initWithBookmark:_bm remotePath:it.remotePath];
        [self.navigationController pushViewController:next animated:YES];
        return;
    }
    UIAlertController *sheet = wq_alert_controller(WQVerbatim(it.name), nil, UIAlertControllerStyleActionSheet);
    [sheet addAction:wq_alert_action(WQLocalized(@"Download to Downloads"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [self downloadRemoteItem:it streamMedia:NO];
    })];
    if ([WQMediaStream opensAsMediaByDefault:it.name]) {
        [sheet addAction:wq_alert_action(WQLocalized(@"Stream in Pro Player"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
            [self downloadRemoteItem:it streamMedia:YES];
        })];
    }
    [sheet addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [self presentViewController:sheet animated:YES completion:nil];
}

@end

#pragma mark - Bookmarks List Controller

@implementation WQRemoteDrivesViewController {
    NSMutableArray<WQRemoteDriveBookmark *> *_bookmarks;
}

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = WQLocalized(@"Remote Drives");
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    wq_prism_install_background(self);
    self.tableView.backgroundColor = UIColor.clearColor;
    _bookmarks = [wq_rd_load_bookmarks() mutableCopy];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                                           target:self
                                                                                           action:@selector(promptAddDrive)];
}

- (void)promptAddDrive
{
    UIAlertController *sheet = wq_alert_controller(WQLocalized(@"Add Remote Drive"), nil, UIAlertControllerStyleActionSheet);
    [sheet addAction:wq_alert_action(@"WebDAV (HTTP / HTTPS)", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [self promptDriveFormWithProtocol:@"webdav"];
    })];
    [sheet addAction:wq_alert_action(@"FTP Server", UIAlertActionStyleDefault, ^(UIAlertAction *__unused a) {
        [self promptDriveFormWithProtocol:@"ftp"];
    })];
    [sheet addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)promptDriveFormWithProtocol:(NSString *)proto
{
    BOOL isWebDAV = [proto isEqualToString:@"webdav"];
    UIAlertController *a = wq_alert_controller(isWebDAV ? @"WebDAV" : @"FTP", WQLocalized(@"Enter server connection details."), UIAlertControllerStyleAlert);
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = WQLocalized(@"Display Name"); }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.placeholder = isWebDAV ? @"https://cloud.example.com/dav" : @"192.168.1.10";
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.placeholder = WQLocalized(@"Username (optional)");
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.placeholder = WQLocalized(@"Password (optional)");
        f.secureTextEntry = YES;
    }];
    [a addAction:wq_alert_action(@"Cancel", UIAlertActionStyleCancel, nil)];
    [a addAction:wq_alert_action(WQLocalized(@"Save"), UIAlertActionStyleDefault, ^(UIAlertAction *__unused act) {
        NSString *name = a.textFields[0].text;
        NSString *rawHost = a.textFields[1].text;
        if (!rawHost.length) return;
        WQRemoteDriveBookmark *bm = [WQRemoteDriveBookmark new];
        bm.driveID = NSUUID.UUID.UUIDString;
        bm.protocol = proto;
        bm.name = name.length ? name : rawHost;
        if (isWebDAV && ([rawHost hasPrefix:@"http://"] || [rawHost hasPrefix:@"https://"])) {
            NSURL *u = [NSURL URLWithString:rawHost];
            bm.useTLS = [u.scheme.lowercaseString isEqualToString:@"https"];
            bm.host = u.host ?: rawHost;
            bm.port = u.port ? u.port.integerValue : (bm.useTLS ? 443 : 80);
            bm.basePath = u.path.length ? u.path : @"/";
        } else {
            bm.host = rawHost;
            bm.port = isWebDAV ? 443 : 21;
            bm.useTLS = isWebDAV;
            bm.basePath = @"/";
        }
        bm.username = a.textFields[2].text ?: @"";
        wq_rd_keychain_set(bm.driveID, a.textFields[3].text ?: @"");
        [self->_bookmarks addObject:bm];
        wq_rd_save_bookmarks(self->_bookmarks);
        [self.tableView reloadData];
    })];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)testBookmark:(WQRemoteDriveBookmark *)bm
{
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    __weak typeof(self) weakSelf = self;
    if ([bm.protocol isEqualToString:@"ftp"]) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSString *err = nil;
            int fd = wq_ftp_login(bm, &err);
            BOOL ok = fd >= 0;
            if (ok) {
                int c = 0;
                wq_ftp_send_cmd(fd, @"QUIT", &c, nil);
                close(fd);
            }
            double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
            dispatch_async(dispatch_get_main_queue(), ^{
                wq_alert(weakSelf, ok ? WQLocalized(@"Connection OK") : WQLocalized(@"Connection Failed"),
                         ok ? [NSString stringWithFormat:@"%@ (%.0f ms)", bm.host, ms] : err);
            });
        });
        return;
    }
    NSString *scheme = bm.useTLS ? @"https" : @"http";
    NSURL *u = [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@:%ld%@", scheme, bm.host, (long)bm.port, bm.basePath ?: @"/"]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
    req.HTTPMethod = @"OPTIONS";
    req.timeoutInterval = 12;
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *__unused d, NSURLResponse *resp, NSError *err) {
        NSInteger code = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
        BOOL ok = !err && code > 0 && code < 500;
        dispatch_async(dispatch_get_main_queue(), ^{
            wq_alert(weakSelf, ok ? WQLocalized(@"Connection OK") : WQLocalized(@"Connection Failed"),
                     ok ? [NSString stringWithFormat:@"HTTP %ld (%.0f ms)", (long)code, ms] : err.localizedDescription);
        });
    }] resume];
}

- (NSInteger)tableView:(UITableView *__unused)tableView numberOfRowsInSection:(NSInteger __unused)section
{
    return MAX(1, (NSInteger)_bookmarks.count);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"rd-bm"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"rd-bm"];
    UIListContentConfiguration *c = [UIListContentConfiguration subtitleCellConfiguration];
    if (!_bookmarks.count) {
        c.text = WQLocalized(@"No Remote Drives");
        c.secondaryText = WQLocalized(@"Tap + to add a WebDAV or FTP server.");
        c.textProperties.color = wq_theme_secondary_text();
        cell.contentConfiguration = c;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    WQRemoteDriveBookmark *bm = _bookmarks[(NSUInteger)indexPath.row];
    c.text = bm.name;
    c.secondaryText = [NSString stringWithFormat:@"%@ · %@:%ld", bm.protocol.uppercaseString, bm.host, (long)bm.port];
    c.image = [UIImage systemImageNamed:@"externaldrive.connected.to.line.below.fill"];
    c.imageProperties.tintColor = wq_theme_accent();
    cell.contentConfiguration = c;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *__unused)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (!_bookmarks.count) return nil;
    WQRemoteDriveBookmark *bm = _bookmarks[(NSUInteger)indexPath.row];
    UIContextualAction *test = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                       title:WQLocalized(@"Test")
                                                                     handler:^(UIContextualAction *__unused a, UIView *__unused s, void (^done)(BOOL)) {
        [self testBookmark:bm];
        done(YES);
    }];
    test.backgroundColor = wq_theme_accent();
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                      title:WQLocalizedNullable(@"Delete")
                                                                    handler:^(UIContextualAction *__unused a, UIView *__unused s, void (^done)(BOOL)) {
        wq_rd_keychain_set(bm.driveID, @"");
        [self->_bookmarks removeObjectAtIndex:(NSUInteger)indexPath.row];
        wq_rd_save_bookmarks(self->_bookmarks);
        [self.tableView reloadData];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del, test]];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!_bookmarks.count) {
        [self promptAddDrive];
        return;
    }
    WQRemoteDriveBookmark *bm = _bookmarks[(NSUInteger)indexPath.row];
    WQRemoteBrowserViewController *browser = [[WQRemoteBrowserViewController alloc] initWithBookmark:bm remotePath:bm.basePath ?: @"/"];
    [self.navigationController pushViewController:browser animated:YES];
}

@end
